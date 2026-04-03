defmodule Spectabas.Events.Ingest do
  @moduledoc """
  Processes a validated `CollectPayload` and a Plug.Conn into a fully
  enriched event map ready for the IngestBuffer.

  Steps:
  1. Extract client IP from x-forwarded-for or conn.remote_ip
  2. Parse User-Agent via UAInspector
  3. Enrich IP via IPEnricher (respects GDPR mode)
  4. Resolve or generate visitor_id
  5. Resolve session via Sessions context
  6. Normalize URL (strip tracking params in GDPR-on mode)
  7. Parse referrer domain
  8. Extract UTM params
  9. Build complete event map
  """

  import Ecto.Query
  alias Spectabas.Events.{CollectPayload, IntentClassifier}
  alias Spectabas.{Sessions, Visitors}
  alias Spectabas.Visitors.{Cache, Visitor}

  @tracking_params ~w(utm_source utm_medium utm_campaign utm_term utm_content
                      gclid fbclid msclkid mc_cid mc_eid _ga _gl)

  @doc """
  Process a validated payload and conn into an enriched event map.
  Returns `{:ok, event_map}` or `{:error, reason}`.
  """
  def process(%CollectPayload{} = payload, conn) do
    site = conn.assigns[:site]
    gdpr_mode = conn.assigns[:gdpr_mode] || :on

    client_ip = extract_client_ip(conn)
    ua_string = get_user_agent(conn)
    # Parse UA once — reuse for both data extraction and bot detection
    {ua_data, is_bot} = parse_and_detect(ua_string, payload._bot == 1)
    ip_data = enrich_ip(client_ip, gdpr_mode, is_bot)

    visitor_id = resolve_visitor(site, payload, gdpr_mode, client_ip, ua_string)
    session = resolve_session(site.id, visitor_id, payload, ua_data, ip_data)

    # Extract UTMs, search query, and ad click IDs from the ORIGINAL URL before GDPR stripping
    utms = extract_utms(payload.u, payload)
    search_query = extract_search_query(payload.u)
    {click_id, click_id_type} = extract_click_id(payload)

    {_url_parsed, url_path, url_host, url_scheme} = normalize_url(payload.u, gdpr_mode)
    referrer_domain = parse_referrer_domain(payload.r, site)

    now = resolve_timestamp(payload._oa)

    event =
      %{
        event_id: Ecto.UUID.generate(),
        site_id: site.id,
        visitor_id: visitor_id,
        session_id: session.id,
        event_type: payload.t,
        event_name: payload.n,
        timestamp: now,
        url: payload.u,
        url_path: normalize_path(url_path),
        url_host: url_host,
        url_scheme: url_scheme,
        referrer: payload.r,
        referrer_domain: referrer_domain,
        utm_source: utms[:utm_source],
        utm_medium: utms[:utm_medium],
        utm_campaign: utms[:utm_campaign],
        utm_term: utms[:utm_term],
        utm_content: utms[:utm_content],
        device_type: ua_data[:device_type],
        browser: ua_data[:browser],
        browser_version: ua_data[:browser_version],
        os: ua_data[:os],
        os_version: ua_data[:os_version],
        screen_width: payload.sw,
        screen_height: payload.sh,
        duration: payload.d,
        props: merge_search_query(payload.p || %{}, search_query),
        user_agent: ua_string,
        browser_fingerprint:
          cond do
            payload._fp && payload._fp != "" -> payload._fp
            payload.vid && String.starts_with?(to_string(payload.vid), "fp_") -> payload.vid
            true -> ""
          end,
        click_id: click_id,
        click_id_type: click_id_type
      }
      |> Map.merge(ip_data)

    # Classify visitor intent
    session_context = %{
      pageview_count: session.pageview_count || 0,
      is_returning: (session.pageview_count || 0) > 0
    }

    intent = IntentClassifier.classify(event, session_context, site.intent_config || %{})
    event = Map.put(event, :visitor_intent, intent)

    {:ok, event}
  end

  @doc """
  Extract client IP from x-forwarded-for header or conn.remote_ip.
  """
  def extract_client_ip(conn) do
    cond do
      # Render always sets X-Forwarded-For — trust it first to prevent
      # CF-Connecting-IP spoofing when not behind Cloudflare
      (xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

      # Fallback: CF-Connecting-IP (only meaningful when proxied through Cloudflare)
      (cf = Plug.Conn.get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

      true ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> ""
    end
  end

  # Single UA parse for both data extraction and bot detection (was 2-3 parses before)
  defp parse_and_detect("", client_bot_hint),
    do:
      {%{device_type: "", browser: "", browser_version: "", os: "", os_version: ""},
       client_bot_hint}

  defp parse_and_detect(ua_string, client_bot_hint) do
    case UAInspector.parse(ua_string) do
      %UAInspector.Result.Bot{} ->
        {%{device_type: "", browser: "", browser_version: "", os: "", os_version: ""}, true}

      %UAInspector.Result{} = result ->
        data = %{
          device_type: get_in_result(result, [:device, :type]) || "",
          browser: get_in_result(result, [:client, :name]) || "",
          browser_version: get_in_result(result, [:client, :version]) || "",
          os: get_in_result(result, [:os, :name]) || "",
          os_version: get_in_result(result, [:os, :version]) || ""
        }

        {data, client_bot_hint}

      _ ->
        {%{device_type: "", browser: "", browser_version: "", os: "", os_version: ""},
         client_bot_hint}
    end
  end

  defp get_in_result(result, keys) do
    Enum.reduce_while(keys, result, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          val = Map.get(acc, key)
          if val == :unknown, do: {:halt, nil}, else: {:cont, val}

        is_struct(acc) and Map.has_key?(acc, key) ->
          val = Map.get(acc, key)
          if val == :unknown, do: {:halt, nil}, else: {:cont, val}

        true ->
          {:halt, nil}
      end
    end)
    |> case do
      val when is_binary(val) -> val
      val when is_atom(val) and val != nil -> to_string(val)
      _ -> nil
    end
  end

  defp enrich_ip(client_ip, gdpr_mode, is_bot) do
    if Code.ensure_loaded?(Spectabas.IPEnricher) do
      case Spectabas.IPEnricher.enrich(client_ip, gdpr_mode) do
        data when is_map(data) ->
          # Mark as bot only from UA detection — datacenter IPs are tracked
          # separately via ip_is_datacenter (VPN/corporate proxy users are real)
          Map.put(data, :ip_is_bot, if(is_bot, do: 1, else: 0))

        _ ->
          default_ip_data() |> Map.put(:ip_is_bot, if(is_bot, do: 1, else: 0))
      end
    else
      default_ip_data() |> Map.put(:ip_is_bot, if(is_bot, do: 1, else: 0))
    end
  end

  defp default_ip_data do
    %{
      ip_address: "",
      ip_country: "",
      ip_country_name: "",
      ip_continent: "",
      ip_continent_name: "",
      ip_region_code: "",
      ip_region_name: "",
      ip_city: "",
      ip_postal_code: "",
      ip_lat: 0.0,
      ip_lon: 0.0,
      ip_accuracy_radius: 0,
      ip_timezone: "",
      ip_asn: 0,
      ip_asn_org: "",
      ip_org: "",
      ip_is_datacenter: 0,
      ip_is_vpn: 0,
      ip_is_tor: 0,
      ip_is_bot: 0,
      ip_is_eu: 0,
      ip_gdpr_anonymized: 0
    }
  end

  defp resolve_visitor(site, payload, gdpr_mode, client_ip, ua_string) do
    cond do
      # In GDPR-on mode, use the client browser fingerprint (stable canvas/WebGL)
      # or fall back to server-generated fingerprint (UA + IP + date)
      gdpr_mode == :on ->
        fingerprint =
          cond do
            payload._fp && payload._fp != "" -> payload._fp
            payload.vid && String.starts_with?(to_string(payload.vid), "fp_") -> payload.vid
            true -> generate_fingerprint(ua_string, client_ip)
          end

        # ETS cache check — avoid Postgres round-trip for repeat visitors
        case Cache.get(site.id, fingerprint) do
          nil ->
            case Visitors.get_or_create(site.id, fingerprint, :on, client_ip) do
              {:ok, visitor} ->
                Cache.put(site.id, fingerprint, visitor.id)
                visitor.id

              _ ->
                fingerprint
            end

          cached_id ->
            cached_id
        end

      # GDPR-off with fingerprint as vid (cookies blocked) — treat like GDPR-on
      gdpr_mode == :off and is_binary(payload.vid) and String.starts_with?(payload.vid, "fp_") ->
        case Cache.get(site.id, payload.vid) do
          nil ->
            case Visitors.get_or_create(site.id, payload.vid, :on, client_ip) do
              {:ok, visitor} ->
                Cache.put(site.id, payload.vid, visitor.id)
                visitor.id

              _ ->
                payload.vid
            end

          cached_id ->
            cached_id
        end

      # GDPR-off with cookie UUID as vid
      gdpr_mode == :off and payload.vid != nil and payload.vid != "" ->
        # ETS cache check — most common path for returning GDPR-off visitors
        case Cache.get(site.id, payload.vid) do
          cached_id when not is_nil(cached_id) ->
            cached_id

          nil ->
            fp = if payload._fp && payload._fp != "", do: payload._fp, else: nil

            # Step 1: Try to find visitor by this cookie_id
            existing_by_cookie =
              Spectabas.Repo.one(
                from(v in Visitor,
                  where: v.site_id == ^site.id and v.cookie_id == ^payload.vid,
                  limit: 1
                )
              )

            if existing_by_cookie do
              # Cookie matches an existing visitor — return visit
              if fp &&
                   (existing_by_cookie.fingerprint_id == nil or
                      existing_by_cookie.fingerprint_id == "") do
                try_update_fingerprint(existing_by_cookie, fp)
              end

              Visitors.get_or_create(site.id, payload.vid, :off, client_ip)
              Cache.put(site.id, payload.vid, existing_by_cookie.id)
              existing_by_cookie.id
            else
              # New cookie — check fingerprint for dedup
              # New cookie = new visitor. Do NOT merge by fingerprint in cookie mode —
              # fingerprint dedup causes false merges when different people on the same
              # device model/browser share a fingerprint (e.g. two iPhone 15 users).
              case Visitors.get_or_create(site.id, payload.vid, :off, client_ip) do
                {:ok, visitor} ->
                  if fp, do: try_update_fingerprint(visitor, fp)

                  Cache.put(site.id, payload.vid, visitor.id)
                  visitor.id

                _ ->
                  payload.vid
              end
            end
        end

      # Fallback: no vid (defensive)
      gdpr_mode == :off ->
        # Use client-side browser fingerprint (canvas/WebGL) — much more stable
        # than the server-side fingerprint (UA + IP + date which rotates daily)
        fp =
          if payload._fp && payload._fp != "",
            do: payload._fp,
            else: generate_fingerprint(ua_string, client_ip)

        case Cache.get(site.id, fp) do
          cached_id when not is_nil(cached_id) ->
            cached_id

          nil ->
            case Visitors.find_by_fingerprint(site.id, fp) do
              %{id: existing_id, cookie_id: existing_cookie} when not is_nil(existing_cookie) ->
                # Found an existing visitor with this fingerprint — reuse their cookie_id
                case Visitors.get_or_create(site.id, existing_cookie, :off, client_ip) do
                  {:ok, visitor} ->
                    Cache.put(site.id, fp, visitor.id)
                    visitor.id

                  _ ->
                    Cache.put(site.id, fp, existing_id)
                    existing_id
                end

              _ ->
                # No fingerprint match — create a new visitor
                cookie_id = Ecto.UUID.generate()

                case Visitors.get_or_create(site.id, cookie_id, :off, client_ip) do
                  {:ok, visitor} ->
                    # Store the fingerprint on the new visitor for future dedup
                    try_update_fingerprint(visitor, fp)

                    Cache.put(site.id, fp, visitor.id)
                    visitor.id

                  _ ->
                    cookie_id
                end
            end
        end

      # GDPR-on: use fingerprint-based identification
      true ->
        fingerprint = generate_fingerprint(ua_string, client_ip)

        case Cache.get(site.id, fingerprint) do
          nil ->
            case Visitors.get_or_create(site.id, fingerprint, :on, client_ip) do
              {:ok, visitor} ->
                Cache.put(site.id, fingerprint, visitor.id)
                visitor.id

              _ ->
                fingerprint
            end

          cached_id ->
            cached_id
        end
    end
  end

  defp generate_fingerprint(ua_string, client_ip) do
    data = "#{ua_string}|#{client_ip}|#{Date.utc_today()}"
    :crypto.hash(:sha256, data) |> Base.url_encode64(padding: false) |> String.slice(0, 32)
  end

  defp resolve_session(site_id, visitor_id, payload, ua_data, ip_data) do
    event_data = %{
      entry_url: String.slice(payload.u || "", 0, 2048),
      referrer: String.slice(payload.r || "", 0, 2048),
      country: ip_data[:ip_country] || "",
      city: ip_data[:ip_city] || "",
      device_type: ua_data[:device_type] || "",
      browser: ua_data[:browser] || "",
      os: ua_data[:os] || ""
    }

    case Sessions.resolve(site_id, visitor_id, event_data) do
      {:ok, session} -> session
      {:error, _} -> %{id: Ecto.UUID.generate()}
    end
  end

  defp normalize_url(url, gdpr_mode) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{path: path, host: host, scheme: scheme} = uri ->
        clean_path = path || "/"
        clean_host = host || ""
        clean_scheme = scheme || "https"

        cleaned_url =
          if gdpr_mode == :on do
            strip_tracking_params(uri) |> URI.to_string()
          else
            url
          end

        {cleaned_url, clean_path, clean_host, clean_scheme}

      _ ->
        {url, "/", "", "https"}
    end
  end

  defp normalize_url(_, _gdpr_mode), do: {"", "/", "", "https"}

  defp strip_tracking_params(%URI{query: nil} = uri), do: uri

  defp strip_tracking_params(%URI{query: query} = uri) do
    cleaned =
      URI.decode_query(query)
      |> Enum.reject(fn {k, _v} -> k in @tracking_params end)

    new_query = if cleaned == [], do: nil, else: URI.encode_query(cleaned)
    %{uri | query: new_query}
  end

  # Normalize URL path: lowercase, strip trailing slash (unless root)
  defp normalize_path("/"), do: "/"

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.downcase()
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      p -> p
    end
  end

  defp normalize_path(_), do: "/"

  # Extract internal site search query from page URL query params
  @search_params ~w(q query search s keyword)
  defp extract_search_query(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: query} when is_binary(query) ->
        params = URI.decode_query(query)
        Enum.find_value(@search_params, "", fn key -> params[key] end)

      _ ->
        ""
    end
  end

  defp extract_search_query(_), do: ""

  defp merge_search_query(props, ""), do: props
  defp merge_search_query(props, query), do: Map.put(props, "_search_query", query)

  defp parse_referrer_domain(nil, _site), do: ""
  defp parse_referrer_domain("", _site), do: ""

  defp parse_referrer_domain(referrer, site) do
    case URI.parse(referrer) do
      %URI{host: host} when is_binary(host) ->
        # Strip self-referrals — the site's own domain and its parent domain
        # e.g. for analytics subdomain b.roommates.com, strip both
        # b.roommates.com and roommates.com (and www.roommates.com)
        site_domain = site.domain || ""
        parent = parent_domain(site_domain)

        cond do
          host == site_domain -> ""
          host == parent -> ""
          host == "www.#{parent}" -> ""
          true -> host
        end

      _ ->
        ""
    end
  end

  defp parent_domain(domain) do
    parts = String.split(domain, ".")

    if length(parts) > 2 do
      parts |> Enum.drop(1) |> Enum.join(".")
    else
      domain
    end
  end

  # Use client-provided occurred_at timestamp if valid (within last 7 days, not in future)
  defp resolve_timestamp(nil), do: DateTime.utc_now()

  defp resolve_timestamp(oa) when is_integer(oa) do
    now = DateTime.utc_now()
    seven_days_ago = DateTime.add(now, -7, :day)

    case DateTime.from_unix(oa) do
      {:ok, dt} ->
        if DateTime.compare(dt, seven_days_ago) != :lt and DateTime.compare(dt, now) != :gt do
          dt
        else
          now
        end

      _ ->
        now
    end
  end

  defp resolve_timestamp(_), do: DateTime.utc_now()

  # Best-effort fingerprint update — silently skip if the fingerprint is already
  # claimed by another visitor (unique constraint on site_id + fingerprint_id).
  defp try_update_fingerprint(visitor, fp) do
    visitor
    |> Visitor.changeset(%{fingerprint_id: fp})
    |> Spectabas.Repo.update()
  rescue
    Ecto.ConstraintError -> :ok
  end

  # Extract ad platform click IDs (gclid, msclkid, fbclid) from payload or URL
  @click_id_params [{"gclid", "google_ads"}, {"msclkid", "bing_ads"}, {"fbclid", "meta_ads"}]

  defp extract_click_id(payload) do
    # Prefer client-sent click ID (persisted in sessionStorage across pages)
    cid = payload._cid || ""
    cidt = payload._cidt || ""

    if cid != "" do
      if valid_click_id?(cid, cidt), do: {cid, cidt}, else: {"", ""}
    else
      # Fall back to extracting from URL query params
      url_params =
        case payload.u do
          url when is_binary(url) and url != "" ->
            case URI.parse(url) do
              %URI{query: q} when is_binary(q) -> URI.decode_query(q)
              _ -> %{}
            end

          _ ->
            %{}
        end

      Enum.find_value(@click_id_params, {"", ""}, fn {param, platform} ->
        case url_params[param] do
          val when is_binary(val) and val != "" ->
            if valid_click_id?(val, platform), do: {val, platform}, else: nil

          _ ->
            nil
        end
      end)
    end
  end

  # Validate click ID format: alphanumeric + base64/UUID chars, reasonable length
  defp valid_click_id?(id, _platform) when byte_size(id) > 256, do: false
  defp valid_click_id?(id, _platform) when byte_size(id) < 5, do: false

  defp valid_click_id?(id, _platform) do
    # gclid: base64url chars; msclkid: hex + hyphens; fbclid: alphanumeric + punctuation
    # Allow alphanumeric, hyphens, underscores, dots, equals (covers all three formats)
    Regex.match?(~r/\A[a-zA-Z0-9\-_=.]+\z/, id)
  end

  defp extract_utms(url, payload) do
    url_params =
      case url do
        url when is_binary(url) and url != "" ->
          case URI.parse(url) do
            %URI{query: q} when is_binary(q) -> URI.decode_query(q)
            _ -> %{}
          end

        _ ->
          %{}
      end

    props = payload.p || %{}

    %{
      utm_source: props["utm_source"] || url_params["utm_source"] || "",
      utm_medium: props["utm_medium"] || url_params["utm_medium"] || "",
      utm_campaign: props["utm_campaign"] || url_params["utm_campaign"] || "",
      utm_term: props["utm_term"] || url_params["utm_term"] || "",
      utm_content: props["utm_content"] || url_params["utm_content"] || ""
    }
  end
end
