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

  alias Spectabas.Events.{CollectPayload, IntentClassifier}
  alias Spectabas.{Sessions, Visitors}
  alias Spectabas.Visitors.Visitor

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
    ua_data = parse_user_agent(ua_string)
    client_bot_hint = payload._bot == 1
    is_bot = detect_bot(ua_string) || client_bot_hint
    ip_data = enrich_ip(client_ip, gdpr_mode, is_bot)

    visitor_id = resolve_visitor(site, payload, gdpr_mode, client_ip, ua_string)
    session = resolve_session(site.id, visitor_id, payload, ua_data, ip_data)

    {url_parsed, url_path, url_host, url_scheme} = normalize_url(payload.u, gdpr_mode)
    referrer_domain = parse_referrer_domain(payload.r)
    utms = extract_utms(url_parsed, payload)

    now = DateTime.utc_now()

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
        url_path: url_path,
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
        props: payload.p || %{},
        user_agent: ua_string,
        browser_fingerprint:
          if(payload.vid && String.starts_with?(to_string(payload.vid), "fp_"),
            do: payload.vid,
            else: ""
          )
      }
      |> Map.merge(ip_data)

    # Classify visitor intent
    session_context = %{
      pageview_count: session.pageview_count || 0,
      is_returning: (session.pageview_count || 0) > 0
    }

    intent = IntentClassifier.classify(event, session_context)
    event = Map.put(event, :visitor_intent, intent)

    {:ok, event}
  end

  @doc """
  Extract client IP from x-forwarded-for header or conn.remote_ip.
  """
  def extract_client_ip(conn) do
    cond do
      # Cloudflare proxy: CF-Connecting-IP is the true client IP
      (cf = Plug.Conn.get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

      # Standard proxy: x-forwarded-for (first IP in chain)
      (xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

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

  defp parse_user_agent(""),
    do: %{device_type: "", browser: "", browser_version: "", os: "", os_version: ""}

  defp parse_user_agent(ua_string) do
    case UAInspector.parse(ua_string) do
      %UAInspector.Result{} = result ->
        %{
          device_type: get_in_result(result, [:device, :type]) || "",
          browser: get_in_result(result, [:client, :name]) || "",
          browser_version: get_in_result(result, [:client, :version]) || "",
          os: get_in_result(result, [:os, :name]) || "",
          os_version: get_in_result(result, [:os, :version]) || ""
        }

      _ ->
        %{device_type: "", browser: "", browser_version: "", os: "", os_version: ""}
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

  defp detect_bot(ua_string) do
    case UAInspector.parse(ua_string) do
      %UAInspector.Result.Bot{} -> true
      _ -> UAInspector.bot?(ua_string)
    end
  end

  defp enrich_ip(client_ip, gdpr_mode, is_bot) do
    if Code.ensure_loaded?(Spectabas.IPEnricher) do
      case Spectabas.IPEnricher.enrich(client_ip, gdpr_mode) do
        data when is_map(data) ->
          # Mark as bot if UA detection or datacenter IP
          bot_flag = if is_bot || data[:ip_is_datacenter] == 1, do: 1, else: 0
          Map.put(data, :ip_is_bot, bot_flag)

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
      # In GDPR-on mode, always use server-generated fingerprint (ignore client vid)
      gdpr_mode == :on ->
        fingerprint = generate_fingerprint(ua_string, client_ip)

        case Visitors.get_or_create(site.id, fingerprint, :on, client_ip) do
          {:ok, visitor} -> visitor.id
          _ -> fingerprint
        end

      # If the payload includes a visitor id in GDPR-off mode, use it
      payload.vid != nil and payload.vid != "" ->
        case Visitors.get_or_create(site.id, payload.vid, gdpr_mode, client_ip) do
          {:ok, visitor} ->
            # Store fingerprint for future dedup if cookie is ever lost
            if visitor.fingerprint_id == nil or visitor.fingerprint_id == "" do
              fp = generate_fingerprint(ua_string, client_ip)

              visitor
              |> Visitor.changeset(%{fingerprint_id: fp})
              |> Spectabas.Repo.update()
            end

            visitor.id

          _ ->
            payload.vid
        end

      # GDPR-off: no cookie present — try fingerprint dedup, then create new
      gdpr_mode == :off ->
        fp = generate_fingerprint(ua_string, client_ip)

        case Visitors.find_by_fingerprint(site.id, fp) do
          %{id: existing_id, cookie_id: existing_cookie} when not is_nil(existing_cookie) ->
            # Found an existing visitor with this fingerprint — reuse their cookie_id
            case Visitors.get_or_create(site.id, existing_cookie, :off, client_ip) do
              {:ok, visitor} -> visitor.id
              _ -> existing_id
            end

          _ ->
            # No fingerprint match — create a new visitor
            cookie_id = Ecto.UUID.generate()

            case Visitors.get_or_create(site.id, cookie_id, :off, client_ip) do
              {:ok, visitor} ->
                # Store the fingerprint on the new visitor for future dedup
                visitor
                |> Visitor.changeset(%{fingerprint_id: fp})
                |> Spectabas.Repo.update()

                visitor.id

              _ ->
                cookie_id
            end
        end

      # GDPR-on: use fingerprint-based identification
      true ->
        fingerprint = generate_fingerprint(ua_string, client_ip)

        case Visitors.get_or_create(site.id, fingerprint, :on, client_ip) do
          {:ok, visitor} -> visitor.id
          _ -> fingerprint
        end
    end
  end

  defp generate_fingerprint(ua_string, client_ip) do
    data = "#{ua_string}|#{client_ip}|#{Date.utc_today()}"
    :crypto.hash(:sha256, data) |> Base.url_encode64(padding: false) |> String.slice(0, 32)
  end

  defp resolve_session(site_id, visitor_id, payload, ua_data, ip_data) do
    event_data = %{
      entry_url: payload.u,
      referrer: payload.r,
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

  defp parse_referrer_domain(nil), do: ""
  defp parse_referrer_domain(""), do: ""

  defp parse_referrer_domain(referrer) do
    case URI.parse(referrer) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
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
