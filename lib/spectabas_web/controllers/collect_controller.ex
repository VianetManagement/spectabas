defmodule SpectabasWeb.CollectController do
  use SpectabasWeb, :controller

  alias Spectabas.Events.{CollectPayload, Ingest, IngestBuffer}
  alias Spectabas.{Sites, Visitors}

  @max_content_length 8_192
  @optout_cookie "_sab_optout"
  @optout_max_age 63_072_000

  def create(conn, params) do
    with :ok <- check_content_length(conn),
         {:ok, payload} <- CollectPayload.validate(params),
         {:ok, site} <- resolve_site(conn, params),
         :ok <- check_origin(conn, site),
         false <- Sites.ip_blocked?(site, client_ip(conn)) do
      conn = assign(conn, :site, site)
      {:ok, event} = Ingest.process(payload, conn)
      IngestBuffer.push(event)
      send_resp(conn, 204, "")
    else
      {:error, :site_not_found} ->
        send_resp(conn, 204, "")

      {:error, :origin_not_allowed} ->
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
          {:ok, event} = Ingest.process(payload, conn)
          IngestBuffer.push(event)

        _ ->
          :ok
      end
    end

    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
    |> send_resp(200, @gif_pixel)
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
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      _ ->
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
    domain = params["s"] || params["site"] || conn.host

    case Spectabas.Sites.get_site_by_domain(domain) do
      %Spectabas.Sites.Site{} = site -> {:ok, site}
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

      if origin_host in allowed or referer_host in allowed or origin_host == "" do
        :ok
      else
        {:error, :origin_not_allowed}
      end
    end
  end

  defp allowed_domains(site) do
    base = [site.domain]

    cross =
      if site.cross_domain_tracking do
        site.cross_domain_sites || []
      else
        []
      end

    base ++ cross
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
