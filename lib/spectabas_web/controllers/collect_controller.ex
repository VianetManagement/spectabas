defmodule SpectabasWeb.CollectController do
  use SpectabasWeb, :controller

  alias Spectabas.Events.{CollectPayload, Ingest, IngestBuffer}
  alias Spectabas.{Sites, Visitors}

  @max_content_length 8_192
  @optout_cookie "_sab_optout"
  @optout_max_age 63_072_000

  def create(conn, params) do
    require Logger

    # Respect opt-out cookie
    cond do
      conn.cookies[@optout_cookie] ->
        send_resp(conn, 204, "")

      IngestBuffer.full?() ->
        Logger.warning("[Collect] IngestBuffer backpressure — rejecting event with 503")
        send_resp(conn, 503, "")

      true ->
        do_create(conn, params)
    end
  end

  defp do_create(conn, params) do
    require Logger

    with :ok <- check_content_length(conn),
         {:ok, payload} <- CollectPayload.validate(params),
         {:ok, site} <- resolve_site(conn, params),
         :ok <- check_origin(conn, site),
         false <- Sites.ip_blocked?(site, client_ip(conn)) do
      gdpr_mode = if site.gdpr_mode == "off", do: :off, else: :on
      conn = conn |> assign(:site, site) |> assign(:gdpr_mode, gdpr_mode)

      try do
        {:ok, event} = Ingest.process(payload, conn)
        IngestBuffer.push(event)
      rescue
        e ->
          Logger.error("[Collect] Ingest.process crashed: #{Exception.message(e)}")
      end

      send_resp(conn, 204, "")
    else
      {:error, :site_not_found} ->
        Logger.warning(
          "[Collect] Site not found for params: #{inspect(Map.take(params, ["s", "site"]))}"
        )

        send_resp(conn, 204, "")

      {:error, :origin_not_allowed} ->
        Logger.warning("[Collect] Origin not allowed")
        send_resp(conn, 204, "")

      {:error, changeset} ->
        conn
        |> put_status(400)
        |> json(%{error: format_errors(changeset)})

      true ->
        send_resp(conn, 204, "")

      :content_too_large ->
        conn
        |> put_status(413)
        |> json(%{error: "payload too large"})
    end
  end

  def identify(conn, params) do
    site =
      case resolve_site(conn, params) do
        {:ok, s} -> s
        _ -> nil
      end

    if site do
      visitor_id = params["vid"]
      traits = Map.drop(params, ["vid"])

      case Visitors.identify(site.id, visitor_id, traits) do
        {:ok, _visitor} -> send_resp(conn, 204, "")
        {:error, _reason} -> send_resp(conn, 204, "")
      end
    else
      conn
      |> put_status(404)
      |> json(%{error: "site not found"})
    end
  end

  def cross_domain(conn, params) do
    site =
      case resolve_site(conn, params) do
        {:ok, s} -> s
        _ -> nil
      end

    if site do
      destination = params["destination"] || ""

      if destination_allowed?(site, destination) do
        token = Visitors.generate_xdomain_token(params["vid"])
        json(conn, %{token: token})
      else
        conn
        |> put_status(403)
        |> json(%{error: "destination not allowed"})
      end
    else
      conn
      |> put_status(404)
      |> json(%{error: "site not found"})
    end
  end

  def optout(conn, _params) do
    conn
    |> put_resp_cookie(@optout_cookie, "1",
      max_age: @optout_max_age,
      http_only: true,
      same_site: "Lax",
      secure: true
    )
    |> send_resp(204, "")
  end

  @gif_pixel <<71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 255, 255, 255, 0, 0, 0, 33, 249, 4,
               0, 0, 0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 68, 1, 0, 59>>

  def pixel(conn, params) do
    # Respect opt-out cookie (same as /c/e endpoint)
    if conn.cookies[@optout_cookie] do
      return_pixel(conn)
    else
      do_pixel(conn, params)
    end
  end

  defp return_pixel(conn) do
    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
    |> send_resp(200, @gif_pixel)
  end

  defp do_pixel(conn, params) do
    require Logger

    site =
      cond do
        # Lookup by public key (obfuscated)
        params["s"] ->
          Spectabas.Repo.get_by(Spectabas.Sites.Site, public_key: params["s"])

        # Fallback to domain
        params["site"] ->
          Spectabas.Sites.get_site_by_domain(params["site"])

        # Fallback to host
        true ->
          Spectabas.Sites.get_site_by_domain(conn.host)
      end

    if site && !Sites.ip_blocked?(site, client_ip(conn)) do
      gdpr_mode = if site.gdpr_mode == "off", do: :off, else: :on
      conn = conn |> assign(:site, site) |> assign(:gdpr_mode, gdpr_mode)

      payload_params = %{
        "t" => "pageview",
        "u" => params["u"] || get_req_header(conn, "referer") |> List.first() || "",
        "r" => params["r"] || "",
        "d" => 0,
        "sw" => 0,
        "sh" => 0,
        "p" => %{"noscript" => "true"}
      }

      case CollectPayload.validate(payload_params) do
        {:ok, payload} ->
          try do
            {:ok, event} = Ingest.process(payload, conn)
            IngestBuffer.push(event)
          rescue
            e ->
              Logger.error("[Collect:pixel] Ingest.process crashed: #{Exception.message(e)}")
          end

        _ ->
          :ok
      end
    end

    return_pixel(conn)
  end

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  # --- Private helpers ---

  defp check_content_length(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [length] ->
        case Integer.parse(length) do
          {n, _} when n > @max_content_length -> :content_too_large
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp client_ip(conn) do
    cond do
      (cf = Plug.Conn.get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

      (xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

      true ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp destination_allowed?(site, destination) do
    allowed = site.cross_domain_sites || []

    if site.cross_domain_tracking and allowed != [] do
      uri = URI.parse(destination)
      host = uri.host || ""
      Enum.any?(allowed, fn allowed_domain -> host == allowed_domain end)
    else
      false
    end
  end

  defp resolve_site(conn, params) do
    alias Spectabas.Sites.DomainCache

    key = params["s"] || params["site"]

    site =
      cond do
        # Try public key lookup — ETS cache first, then DB fallback
        key && !String.contains?(key, ".") ->
          case DomainCache.lookup_by_key(key) do
            {:ok, site} -> site
            :error -> Spectabas.Repo.get_by(Spectabas.Sites.Site, public_key: key)
          end

        # Domain-based lookup — ETS cache first, then DB fallback
        key ->
          case DomainCache.lookup(key) do
            {:ok, site} -> site
            :error -> Spectabas.Sites.get_site_by_domain(key)
          end

        # Fallback to host header
        true ->
          case DomainCache.lookup(conn.host) do
            {:ok, site} -> site
            :error -> Spectabas.Sites.get_site_by_domain(conn.host)
          end
      end

    case site do
      %Spectabas.Sites.Site{} = s -> {:ok, s}
      nil -> {:error, :site_not_found}
    end
  end

  defp check_origin(conn, site) do
    origin = get_req_header(conn, "origin") |> List.first() || ""
    referer = get_req_header(conn, "referer") |> List.first() || ""

    # Allow if no origin (server-side, curl, etc)
    if origin == "" and referer == "" do
      :ok
    else
      origin_host = extract_host(origin)
      referer_host = extract_host(referer)

      allowed = allowed_domains(site)

      cond do
        # Origin header present and matches
        origin_host != "" and origin_host in allowed -> :ok
        # No Origin but Referer matches (e.g., sendBeacon, img tags)
        origin_host == "" and referer_host in allowed -> :ok
        # No Origin and no Referer (shouldn't reach here due to outer check, but be safe)
        origin_host == "" and referer_host == "" -> :ok
        true -> {:error, :origin_not_allowed}
      end
    end
  end

  defp allowed_domains(site) do
    # Always allow: the analytics subdomain itself + its parent domain
    parent = parent_domain(site.domain)
    base = [site.domain | if(parent, do: [parent, "www.#{parent}"], else: [])]

    cross = site.cross_domain_sites || []

    base ++ cross
  end

  defp parent_domain(domain) do
    parts = String.split(domain, ".")

    if length(parts) > 2 do
      parts |> Enum.drop(1) |> Enum.join(".")
    else
      nil
    end
  end

  defp extract_host(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  defp extract_host(_), do: ""

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_errors(reason), do: to_string(reason)
end
