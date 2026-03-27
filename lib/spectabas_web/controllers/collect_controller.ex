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
         site when not is_nil(site) <- conn.assigns[:site],
         false <- Sites.ip_blocked?(site, client_ip(conn)) do
      {:ok, event} = Ingest.process(payload, conn)
      IngestBuffer.push(event)
      send_resp(conn, 204, "")
    else
      {:error, changeset} ->
        conn
        |> put_status(400)
        |> json(%{error: format_errors(changeset)})

      true ->
        # IP is blocked — silently drop
        send_resp(conn, 204, "")

      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "site not found"})

      :content_too_large ->
        conn
        |> put_status(413)
        |> json(%{error: "payload too large"})
    end
  end

  def identify(conn, params) do
    site = conn.assigns[:site]

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
    site = conn.assigns[:site]

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
    site_domain = params["site"] || conn.host

    site =
      case Spectabas.Sites.get_site_by_domain(site_domain) do
        %Spectabas.Sites.Site{} = s -> s
        nil -> nil
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

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_errors(reason), do: to_string(reason)
end
