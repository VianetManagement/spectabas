defmodule Spectabas.Workers.ASNDiscovery do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Spectabas.{ClickHouse, ASNManagement}
  alias Spectabas.IPEnricher.ASNBlocklist
  import Spectabas.TypeHelpers

  @hosting_keywords ~w(hosting server cloud vps dedicated colocation datacenter data-center
                       hetzner ovh contabo vultr linode digitalocean amazon aws google gcp
                       azure microsoft oracle rackspace hostinger godaddy bluehost)

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(600)

  @impl Oban.Worker
  def perform(_job) do
    Logger.notice("[ASNDiscovery] Starting weekly scan")

    case discover_candidates() do
      {:ok, candidates} ->
        {auto_added, reviewed} = process_candidates(candidates)

        Logger.notice(
          "[ASNDiscovery] Complete: #{auto_added} auto-added, #{reviewed} logged for review"
        )

        :ok

      {:error, reason} ->
        Logger.warning("[ASNDiscovery] Failed: #{inspect(reason)}")
        :ok
    end
  end

  defp discover_candidates do
    sql = """
    SELECT
      ip_asn,
      any(ip_asn_org) AS asn_org,
      count(DISTINCT visitor_id) AS visitors,
      uniqIf(url_path, event_type = 'pageview') AS total_pages,
      avg(pv) AS avg_pages_per_visitor,
      countDistinctIf(visitor_id, pv = 1) AS single_page_visitors,
      count(DISTINCT ip_address) AS unique_ips
    FROM (
      SELECT
        visitor_id,
        ip_asn,
        any(ip_asn_org) AS ip_asn_org,
        any(ip_address) AS ip_address,
        uniqIf(url_path, event_type = 'pageview') AS pv
      FROM events
      WHERE timestamp >= now() - INTERVAL 30 DAY
        AND ip_is_bot = 0
        AND ip_is_datacenter = 0
        AND ip_asn > 0
      GROUP BY visitor_id, ip_asn
    )
    GROUP BY ip_asn
    HAVING visitors >= 10
    ORDER BY visitors DESC
    LIMIT 200
    """

    ClickHouse.query(sql, receive_timeout: 60_000)
  end

  defp process_candidates(candidates) do
    Enum.reduce(candidates, {0, 0}, fn row, {auto_count, review_count} ->
      asn = to_num(row["ip_asn"])
      org = row["asn_org"] || ""

      cond do
        # Already in the blocklist
        asn == 0 ->
          {auto_count, review_count}

        blocklist_datacenter?(asn) ->
          {auto_count, review_count}

        ASNManagement.already_tracked?(asn, "datacenter") ->
          {auto_count, review_count}

        true ->
          evidence = build_evidence(row)
          score = score_candidate(evidence, org)

          if score >= 80 do
            auto_add(asn, org, evidence, score)
            {auto_count + 1, review_count}
          else
            if score >= 50 do
              log_candidate(asn, org, evidence, score)
              {auto_count, review_count + 1}
            else
              {auto_count, review_count}
            end
          end
      end
    end)
  end

  defp build_evidence(row) do
    visitors = to_num(row["visitors"])
    single_page = to_num(row["single_page_visitors"])

    %{
      visitors: visitors,
      total_pages: to_num(row["total_pages"]),
      avg_pages: to_float(row["avg_pages_per_visitor"]),
      unique_ips: to_num(row["unique_ips"]),
      single_page_pct:
        if(visitors > 0, do: Float.round(single_page / visitors * 100, 1), else: 0),
      bounce_rate: if(visitors > 0, do: Float.round(single_page / visitors * 100, 1), else: 0)
    }
  end

  defp score_candidate(evidence, org) do
    score = 0

    # Hosting-related org name
    org_lower = String.downcase(org)

    score =
      if Enum.any?(@hosting_keywords, &String.contains?(org_lower, &1)),
        do: score + 40,
        else: score

    # Very low engagement (bot farm pattern)
    score = if evidence.avg_pages < 1.5 and evidence.visitors >= 50, do: score + 30, else: score
    score = if evidence.avg_pages < 3.0 and evidence.visitors >= 100, do: score + 15, else: score

    # High bounce rate
    score = if evidence.bounce_rate > 80.0, do: score + 20, else: score
    score = if evidence.bounce_rate > 90.0, do: score + 10, else: score

    # Few unique IPs relative to visitors (same IPs rotating cookies)
    score =
      if evidence.visitors > 50 and evidence.unique_ips < evidence.visitors * 0.1,
        do: score + 20,
        else: score

    min(score, 100)
  end

  defp auto_add(asn, org, evidence, score) do
    reason =
      "Auto-detected: #{org} (AS#{asn}) — #{evidence.visitors} visitors, " <>
        "#{Float.round(evidence.avg_pages, 1)} avg pages, #{evidence.bounce_rate}% bounce, " <>
        "confidence score #{score}/100"

    case ASNManagement.add_override(%{
           asn_number: asn,
           asn_org: org,
           classification: "datacenter",
           source: "auto",
           reason: reason,
           auto_evidence: evidence
         }) do
      {:ok, override} ->
        Logger.notice("[ASNDiscovery] Auto-added AS#{asn} (#{org}) score=#{score}")
        submit_backfill(override)

      {:error, changeset} ->
        Logger.warning("[ASNDiscovery] Failed to add AS#{asn}: #{inspect(changeset.errors)}")
    end
  end

  defp log_candidate(asn, org, evidence, score) do
    reason =
      "Candidate for review: #{org} (AS#{asn}) — #{evidence.visitors} visitors, " <>
        "#{Float.round(evidence.avg_pages, 1)} avg pages, #{evidence.bounce_rate}% bounce, " <>
        "confidence score #{score}/100"

    Logger.notice("[ASNDiscovery] Candidate: AS#{asn} (#{org}) score=#{score}")

    ASNManagement.add_override(%{
      asn_number: asn,
      asn_org: org,
      classification: "datacenter",
      source: "auto",
      reason: reason,
      auto_evidence: evidence,
      active: false
    })
  end

  defp submit_backfill(%ASNManagement.Override{} = override) do
    asn = override.asn_number

    sql = """
    ALTER TABLE events UPDATE ip_is_datacenter = 1
    WHERE ip_asn = #{ClickHouse.param(asn)}
      AND ip_is_datacenter = 0
    SETTINGS mutations_sync = 0
    """

    case ClickHouse.execute(sql) do
      :ok ->
        ASNManagement.mark_backfilled(override.id)
        Logger.notice("[ASNDiscovery] Backfill submitted for AS#{asn}")

      {:error, reason} ->
        Logger.warning("[ASNDiscovery] Backfill failed for AS#{asn}: #{inspect(reason)}")
    end
  end

  defp blocklist_datacenter?(asn) do
    try do
      ASNBlocklist.datacenter?(asn)
    rescue
      _ -> false
    end
  end
end
