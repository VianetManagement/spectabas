defmodule Spectabas.Visitors do
  @moduledoc """
  Context for visitor management. Handles upsert by cookie_id or
  fingerprint_id depending on GDPR mode, visitor identification,
  and cross-domain token generation/resolution.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Visitors.Visitor

  @xdomain_table :spectabas_xdomain_tokens

  @doc """
  Batch-lookup emails for a list of visitor_ids (UUIDs from ClickHouse).
  Returns a map of %{visitor_id => %{email: "...", user_id: "..."}} for identified visitors.
  Unidentified visitors are not included in the map.
  """
  def emails_for_visitor_ids(visitor_ids) when is_list(visitor_ids) do
    visitor_ids = Enum.reject(visitor_ids, &(is_nil(&1) or &1 == ""))

    if visitor_ids == [] do
      %{}
    else
      # visitor_id in ClickHouse maps to the Visitor primary key (id)
      query =
        from(v in Visitor,
          where: v.id in ^visitor_ids and not is_nil(v.email) and v.email != "",
          select: {v.id, %{email: v.email, user_id: v.user_id}}
        )

      Repo.all(query) |> Map.new()
    end
  end

  def scraper_scores_for_visitor_ids(visitor_ids) when is_list(visitor_ids) do
    visitor_ids = Enum.reject(visitor_ids, &(is_nil(&1) or &1 == ""))

    if visitor_ids == [] do
      %{}
    else
      query =
        from(v in Visitor,
          where: v.id in ^visitor_ids and not is_nil(v.scraper_webhook_score),
          select: {v.id, v.scraper_webhook_score}
        )

      Repo.all(query) |> Map.new()
    end
  end

  @doc """
  Count identified visitors (those with an email) seen in a given time range.

  Backed by the partial index `visitors_identified_by_site_last_seen_idx` —
  a simple index range scan, microseconds even on 30-day ranges with millions
  of visitors.
  """
  def count_identified_between(site_id, %DateTime{} = from, %DateTime{} = to) do
    from(v in Visitor,
      where:
        v.site_id == ^site_id and v.last_seen_at >= ^from and v.last_seen_at <= ^to and
          not is_nil(v.email) and v.email != "",
      select: count(v.id)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Count visitors with email set, filtered to given site_id and visitor_id list."
  def count_identified(site_id, visitor_ids) when is_list(visitor_ids) do
    visitor_ids = Enum.reject(visitor_ids, &(is_nil(&1) or &1 == ""))

    if visitor_ids == [] do
      0
    else
      from(v in Visitor,
        where:
          v.site_id == ^site_id and v.id in ^visitor_ids and not is_nil(v.email) and
            v.email != "",
        select: count(v.id)
      )
      |> Repo.one()
    end
  end

  @doc """
  Find an existing visitor by fingerprint ID for a site.
  Used to deduplicate visitors who lost their cookie.
  """
  def find_by_fingerprint(site_id, fingerprint)
      when is_binary(fingerprint) and fingerprint != "" do
    query =
      from(v in Visitor,
        where: v.site_id == ^site_id and v.fingerprint_id == ^fingerprint,
        limit: 1
      )

    Repo.one(query)
  end

  def find_by_fingerprint(_, _), do: nil

  @doc """
  Find an existing visitor by external_id (from a customer-set identity cookie).
  Uses partial index on (site_id, external_id) WHERE external_id IS NOT NULL.
  """
  def find_by_external_id(site_id, external_id)
      when is_binary(external_id) and external_id != "" do
    Repo.one(
      from(v in Visitor,
        where: v.site_id == ^site_id and v.external_id == ^external_id,
        limit: 1
      )
    )
  end

  def find_by_external_id(_, _), do: nil

  @doc """
  Set external_id on an existing visitor. Silently skips on conflict
  (another visitor already has this external_id for the site).
  """
  def set_external_id(%Visitor{} = visitor, external_id)
      when is_binary(external_id) and external_id != "" do
    visitor
    |> Visitor.changeset(%{external_id: external_id})
    |> Repo.update()
  rescue
    Ecto.ConstraintError -> {:ok, visitor}
  end

  def set_external_id(visitor, _), do: {:ok, visitor}

  @doc """
  Get or create a visitor for the given site. In GDPR-off mode,
  `id_value` is used as cookie_id; in GDPR-on mode, as fingerprint_id.
  """
  def get_or_create(site_id, id_value, gdpr_mode, client_ip \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {field, mode_str} =
      case gdpr_mode do
        :off -> {:cookie_id, "off"}
        _ -> {:fingerprint_id, "on"}
      end

    query =
      from(v in Visitor,
        where: v.site_id == ^site_id and field(v, ^field) == ^id_value,
        limit: 1
      )

    case Repo.one(query) do
      %Visitor{} = visitor ->
        known_ips = update_known_ips(visitor.known_ips, client_ip)

        update_attrs =
          %{last_seen_at: now}
          |> maybe_put(:last_ip, client_ip)
          |> maybe_put(:known_ips, known_ips)

        visitor
        |> Visitor.changeset(update_attrs)
        |> Repo.update()

      nil ->
        attrs =
          %{
            site_id: site_id,
            first_seen_at: now,
            last_seen_at: now,
            gdpr_mode: mode_str
          }
          |> Map.put(field, id_value)
          |> maybe_put(:last_ip, client_ip)
          |> maybe_put(:known_ips, if(client_ip, do: [client_ip], else: []))

        case %Visitor{} |> Visitor.changeset(attrs) |> Repo.insert() do
          {:ok, visitor} ->
            {:ok, visitor}

          {:error, %Ecto.Changeset{errors: errors}} ->
            # Unique constraint violation — another process inserted first, just fetch it
            if Keyword.has_key?(errors, :site_id) or Keyword.has_key?(errors, :cookie_id) or
                 Keyword.has_key?(errors, :fingerprint_id) do
              case Repo.one(query) do
                %Visitor{} = visitor -> {:ok, visitor}
                nil -> {:error, :insert_conflict}
              end
            else
              {:error, :insert_failed}
            end
        end
    end
  end

  @doc """
  Merge identification data (user_id, email) into an existing visitor.
  Computes email_hash from email and updates last_seen_at and last_ip.

  Returns `{:ok, %Visitor{}}` or `{:error, reason}`.
  """
  def identify(site_id, visitor_id, traits, client_ip \\ nil) do
    # Try cookie_id first (from _sab cookie), then fall back to primary key (from ClickHouse visitor_id)
    visitor =
      Repo.one(
        from(v in Visitor,
          where: v.site_id == ^site_id and v.cookie_id == ^visitor_id,
          limit: 1
        )
      ) || try_get_by_uuid(site_id, visitor_id)

    case visitor do
      nil ->
        {:error, :not_found}

      visitor ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        email =
          case Map.get(traits, :email) || Map.get(traits, "email") do
            nil -> nil
            e -> e |> String.trim() |> String.downcase()
          end

        user_id = Map.get(traits, :user_id) || Map.get(traits, "user_id")

        email_hash =
          if email do
            :crypto.hash(:sha256, email)
            |> Base.hex_encode32(case: :lower, padding: false)
          else
            visitor.email_hash
          end

        known_ips = update_known_ips(visitor.known_ips, client_ip)

        attrs =
          %{
            last_seen_at: now,
            email_hash: email_hash
          }
          |> maybe_put(:email, email)
          |> maybe_put(:user_id, user_id)
          |> maybe_put(:last_ip, client_ip)
          |> maybe_put(:known_ips, known_ips)

        visitor
        |> Visitor.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Generate a single-use cross-domain token that maps to a visitor_id.
  Token expires after 30 seconds (configurable via :xdomain_token_ttl_seconds).
  Returns the token string.
  """
  def generate_xdomain_token(visitor_id) do
    ensure_xdomain_table()
    sweep_expired_xdomain_tokens()

    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    ttl_ms = xdomain_ttl_ms()
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(@xdomain_table, {token, visitor_id, expires_at})
    token
  end

  defp sweep_expired_xdomain_tokens do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@xdomain_table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])
  rescue
    _ -> :ok
  end

  @doc """
  Resolve a cross-domain token to a visitor_id.
  Single-use: the token is deleted after resolution.
  Returns `{:ok, visitor_id}` or `:error` if expired or not found.
  """
  def resolve_xdomain_token(token) do
    ensure_xdomain_table()

    case :ets.lookup(@xdomain_table, token) do
      [{^token, visitor_id, expires_at}] ->
        :ets.delete(@xdomain_table, token)

        if System.monotonic_time(:millisecond) <= expires_at do
          {:ok, visitor_id}
        else
          :error
        end

      [] ->
        :error
    end
  end

  @doc """
  List visitors for a site with optional search and pagination.
  Returns `{visitors, total_count}`.
  """
  def list_visitors(site_id, opts \\ []) do
    search = Keyword.get(opts, :search, "")
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    base_query = from(v in Visitor, where: v.site_id == ^site_id)

    query =
      if search != "" do
        search_term = "%#{search}%"

        from(v in base_query,
          where:
            ilike(v.email, ^search_term) or
              ilike(v.user_id, ^search_term) or
              ilike(v.cookie_id, ^search_term)
        )
      else
        base_query
      end

    total = Repo.aggregate(query, :count, :id)

    visitors =
      query
      |> order_by([v], desc: v.last_seen_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {visitors, total}
  end

  @doc """
  Get a single visitor by ID. Raises if not found.
  """
  def get_visitor!(id), do: Repo.get!(Visitor, id)

  # --- Private ---

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Try to look up visitor by UUID primary key. Returns nil if not a valid UUID.
  defp try_get_by_uuid(site_id, visitor_id) do
    Repo.get_by(Visitor, id: visitor_id, site_id: site_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp update_known_ips(existing, nil), do: existing

  defp update_known_ips(existing, ip) do
    existing = existing || []

    if ip in existing do
      existing
    else
      Enum.take([ip | existing], 50)
    end
  end

  defp xdomain_ttl_ms do
    ttl_s = Application.get_env(:spectabas, :xdomain_token_ttl_seconds, 30)
    ttl_s * 1000
  end

  defp ensure_xdomain_table do
    case :ets.whereis(@xdomain_table) do
      :undefined ->
        :ets.new(@xdomain_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end
end
