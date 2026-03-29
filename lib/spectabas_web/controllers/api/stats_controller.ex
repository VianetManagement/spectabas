defmodule SpectabasWeb.API.StatsController do
  use SpectabasWeb, :controller

  alias Spectabas.{Sites, Analytics, Accounts}

  def overview(conn, %{"site_id" => site_id} = params) do
    with {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, stats} <- Analytics.overview_stats(site, user, date_range) do
      json(conn, %{data: stats})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def pages(conn, %{"site_id" => site_id} = params) do
    with {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_pages(site, user, date_range) do
      json(conn, %{data: data})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def sources(conn, %{"site_id" => site_id} = params) do
    with {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_sources(site, user, date_range) do
      json(conn, %{data: data})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def countries(conn, %{"site_id" => site_id} = params) do
    with {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_countries(site, user, date_range) do
      json(conn, %{data: data})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def devices(conn, %{"site_id" => site_id} = params) do
    with {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_devices(site, user, date_range) do
      json(conn, %{data: data})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  def realtime(conn, %{"site_id" => site_id}) do
    with {:ok, site, _user} <- authorize_site(conn, site_id),
         {:ok, data} <- Analytics.realtime_visitors(site) do
      json(conn, %{data: data})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "site not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: to_string(reason)})
    end
  end

  # --- Private helpers ---

  defp authorize_site(conn, site_id) do
    user_id = conn.assigns[:current_user_id]

    with {:ok, site} <- fetch_site(site_id),
         {:ok, user} <- fetch_user(user_id),
         true <- Accounts.can_access_site?(user, site) do
      {:ok, site, user}
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  defp fetch_site(site_id) do
    try do
      {:ok, Sites.get_site!(site_id)}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp fetch_user(nil), do: {:error, :unauthorized}

  defp fetch_user(user_id) do
    try do
      {:ok, Accounts.get_user!(user_id)}
    rescue
      Ecto.NoResultsError -> {:error, :unauthorized}
    end
  end

  defp parse_date_range(params) do
    period = params["period"] || "7d"

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case period do
      "24h" ->
        %{from: DateTime.add(now, -24, :hour), to: now}

      "7d" ->
        %{from: DateTime.add(now, -7, :day), to: now}

      "30d" ->
        %{from: DateTime.add(now, -30, :day), to: now}

      "custom" ->
        from = parse_datetime(params["from"]) || DateTime.add(now, -7, :day)
        to = parse_datetime(params["to"]) || now
        # Cap custom ranges at 12 months to prevent expensive full-table scans
        max_from = DateTime.add(now, -366, :day)
        from = if DateTime.compare(from, max_from) == :lt, do: max_from, else: from
        %{from: from, to: to}

      _ ->
        %{from: DateTime.add(now, -7, :day), to: now}
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end
end
