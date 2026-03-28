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
  Get or create a visitor for the given site. In GDPR-off mode,
  `id_value` is used as cookie_id; in GDPR-on mode, as fingerprint_id.

  Returns `{:ok, %Visitor{}}` or `{:error, changeset}`.
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

        %Visitor{}
        |> Visitor.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Merge identification data (user_id, email) into an existing visitor.
  Computes email_hash from email and updates last_seen_at and last_ip.

  Returns `{:ok, %Visitor{}}` or `{:error, reason}`.
  """
  def identify(visitor_id, traits, client_ip \\ nil) do
    case Repo.get(Visitor, visitor_id) do
      nil ->
        {:error, :not_found}

      visitor ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        email = Map.get(traits, :email) || Map.get(traits, "email")
        user_id = Map.get(traits, :user_id) || Map.get(traits, "user_id")

        email_hash =
          if email do
            :crypto.hash(:sha256, String.downcase(String.trim(email)))
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
