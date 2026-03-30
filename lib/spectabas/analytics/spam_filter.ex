defmodule Spectabas.Analytics.SpamFilter do
  @moduledoc "Filters known referrer spam domains from analytics queries."

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Analytics.SpamDomain
  alias Spectabas.ClickHouse

  @builtin_domains ~w(
    semalt.com buttons-for-website.com makemoneyonline.com
    best-seo-offer.com buy-cheap-online.info event-tracking.com
    free-share-buttons.com get-free-traffic-now.com
    hundredmb.com ilovevitaly.com trafficmonetize.org
    webmonetizer.net descargar-musica-gratis.me
    musclebuildfaster.com darodar.com hulfingtonpost.com
    priceg.com savetubevideo.com screentoolkit.com
    kambasoft.com econom.co socialmediascanner.com
  )

  @doc "Returns true if the given domain is a known referrer spam domain."
  def spam_domain?(domain) when is_binary(domain) do
    downcased = String.downcase(domain)
    downcased in all_domains()
  end

  def spam_domain?(_), do: false

  @doc "Returns the list of builtin spam domains (hardcoded)."
  def spam_domains, do: @builtin_domains

  @doc "Returns the builtin domains list (alias for spam_domains/0)."
  def builtin_domains, do: @builtin_domains

  @doc "Returns all active spam domains: builtins merged with DB entries."
  def all_domains do
    db_domains =
      from(sd in SpamDomain, where: sd.active == true, select: sd.domain)
      |> Repo.all()

    (@builtin_domains ++ db_domains) |> Enum.uniq()
  end

  @doc "Adds a domain to the spam blocklist. Upserts if already exists."
  def add_domain(domain, source \\ "manual") when is_binary(domain) do
    downcased = String.downcase(String.trim(domain))

    %SpamDomain{}
    |> SpamDomain.changeset(%{domain: downcased, source: source, active: true})
    |> Repo.insert(
      on_conflict: [
        set: [
          source: source,
          active: true,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      ],
      conflict_target: :domain
    )
  end

  @doc "Removes a custom domain from the DB. Cannot remove builtins (deactivate instead)."
  def remove_domain(domain) when is_binary(domain) do
    downcased = String.downcase(String.trim(domain))

    if downcased in @builtin_domains do
      {:error, :builtin_domain}
    else
      case Repo.get_by(SpamDomain, domain: downcased) do
        nil -> {:error, :not_found}
        record -> Repo.delete(record)
      end
    end
  end

  @doc "Returns all domains with their source, hits, and last_seen info."
  def list_domains do
    db_records = Repo.all(from(sd in SpamDomain, order_by: [desc: sd.hits_total]))

    db_map = Map.new(db_records, fn r -> {r.domain, r} end)

    builtin_entries =
      Enum.map(@builtin_domains, fn d ->
        case Map.get(db_map, d) do
          nil ->
            %{
              domain: d,
              source: "builtin",
              hits_total: 0,
              last_seen_at: nil,
              active: true,
              id: nil
            }

          record ->
            %{
              domain: d,
              source: "builtin",
              hits_total: record.hits_total,
              last_seen_at: record.last_seen_at,
              active: record.active,
              id: record.id
            }
        end
      end)

    custom_entries =
      db_records
      |> Enum.reject(fn r -> r.domain in @builtin_domains end)
      |> Enum.map(fn r ->
        %{
          domain: r.domain,
          source: r.source,
          hits_total: r.hits_total,
          last_seen_at: r.last_seen_at,
          active: r.active,
          id: r.id
        }
      end)

    (builtin_entries ++ custom_entries)
    |> Enum.sort_by(& &1.hits_total, :desc)
  end

  @doc "Queries ClickHouse for hit counts per spam domain across all sites in last 30 days."
  def domain_stats do
    known = all_domains()

    if known == [] do
      %{}
    else
      params = Enum.map_join(known, ", ", &ClickHouse.param/1)

      sql = """
      SELECT
        referrer_domain,
        count() AS hits,
        max(timestamp) AS last_seen
      FROM events
      WHERE timestamp >= now() - INTERVAL 30 DAY
        AND referrer_domain IN (#{params})
      GROUP BY referrer_domain
      ORDER BY hits DESC
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          Map.new(rows, fn row ->
            {row["referrer_domain"], %{hits: to_num(row["hits"]), last_seen: row["last_seen"]}}
          end)

        {:error, _} ->
          %{}
      end
    end
  end

  @doc """
  Finds suspicious referrer domains: high bot %, hitting multiple sites, high volume.
  Returns candidates not already in the blocklist.
  """
  def detect_spam_candidates do
    known = all_domains()

    exclude_clause =
      if known == [] do
        ""
      else
        params = Enum.map_join(known, ", ", &ClickHouse.param/1)
        "AND referrer_domain NOT IN (#{params})"
      end

    sql = """
    SELECT
      referrer_domain,
      count() AS hits,
      uniq(site_id) AS sites_affected,
      round(countIf(ip_is_bot = 1) / greatest(count(), 1) * 100, 1) AS bot_pct
    FROM events
    WHERE timestamp >= now() - INTERVAL 30 DAY
      AND referrer_domain != ''
      #{exclude_clause}
    GROUP BY referrer_domain
    HAVING (bot_pct > 50 OR hits > 100)
      AND sites_affected >= 2
    ORDER BY hits DESC
    LIMIT 20
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{
            domain: row["referrer_domain"],
            hits: to_num(row["hits"]),
            sites_affected: to_num(row["sites_affected"]),
            bot_pct: to_float(row["bot_pct"])
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp to_num(nil), do: 0
  defp to_num(v) when is_integer(v), do: v
  defp to_num(v) when is_binary(v), do: String.to_integer(v)

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
