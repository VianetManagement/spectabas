defmodule SpectabasWeb.API.StatsController do
  use SpectabasWeb, :controller

  alias Spectabas.{Sites, Analytics, Accounts, Visitors}
  alias SpectabasWeb.Plugs.ApiAuth
  require Logger

  def overview(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, stats} <- Analytics.overview_stats(site, user, date_range) do
      json(conn, %{data: stats})
    else
      error -> handle_error(conn, error)
    end
  end

  def pages(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_pages(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def sources(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_sources(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def countries(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_countries(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def devices(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.top_devices(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def realtime(conn, %{"site_id" => site_id}) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, _user} <- authorize_site(conn, site_id),
         {:ok, data} <- Analytics.realtime_visitors(site) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def realtime_visitors(conn, %{"site_id" => site_id}) do
    with :ok <- require_scope(conn, "read:visitors"),
         {:ok, site, _user} <- authorize_site(conn, site_id),
         {:ok, data} <- Analytics.realtime_visitors_grouped(site) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  Server-side visitor identification.

  POST /api/v1/sites/:site_id/identify
  Body: {"visitor_id": "<_sab cookie value>", "email": "user@example.com", "user_id": "123"}

  Links an email/user_id to an existing Spectabas visitor. The visitor_id
  is the value of the _sab cookie set by the tracker script.
  """
  def identify(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "write:identify"),
         {:ok, site, _user} <- authorize_site(conn, site_id) do
      # Note: occurred_at is accepted but not currently used for identify
      _occurred_at = params["occurred_at"]
      visitor_id = params["visitor_id"]

      if is_nil(visitor_id) or visitor_id == "" do
        conn |> put_status(400) |> json(%{error: "visitor_id required"})
      else
        traits = Map.take(params, ["email", "user_id"])
        ip = params["ip"]

        try do
          case Visitors.identify(site.id, visitor_id, traits, ip) do
            {:ok, visitor} ->
              json(conn, %{
                ok: true,
                visitor_id: visitor.id,
                email_hash: visitor.email_hash
              })

            {:error, :not_found} ->
              conn |> put_status(404) |> json(%{error: "visitor not found"})

            {:error, reason} ->
              conn |> put_status(422) |> json(%{error: inspect(reason)})
          end
        rescue
          e ->
            Logger.error("[API] Identify crashed: #{Exception.message(e)}")
            conn |> put_status(503) |> json(%{error: "service temporarily unavailable"})
        end
      end
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  Record an ecommerce transaction from your server.

  POST /api/v1/sites/:site_id/ecommerce/transactions
  Body: {
    "order_id": "ORD-123",
    "revenue": 99.99,
    "visitor_id": "<_sab cookie value>",  (optional)
    "subtotal": 89.99,                    (optional)
    "tax": 7.20,                          (optional)
    "shipping": 2.80,                     (optional)
    "discount": 0,                        (optional)
    "currency": "USD",                    (optional, defaults to site currency)
    "items": [                            (optional)
      {"name": "Widget", "price": 29.99, "quantity": 3}
    ]
  }
  """
  def record_transaction(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "write:events"),
         {:ok, site, _user} <- authorize_site(conn, site_id) do
      order_id = params["order_id"]

      if is_nil(order_id) or order_id == "" do
        conn |> put_status(400) |> json(%{error: "order_id required"})
      else
        now = parse_occurred_at(params["occurred_at"])

        # Resolve visitor_id synchronously (just a lookup), defer identify + CH insert
        visitor_id = resolve_transaction_visitor_fast(site, params)

        row = %{
          "site_id" => site.id,
          "visitor_id" => visitor_id,
          "session_id" => params["session_id"] || "",
          "order_id" => order_id,
          "revenue" => parse_amount(params["revenue"]),
          "subtotal" => parse_amount(params["subtotal"]),
          "tax" => parse_amount(params["tax"]),
          "shipping" => parse_amount(params["shipping"]),
          "discount" => parse_amount(params["discount"]),
          "currency" => params["currency"] || site.currency || "USD",
          "items" => Jason.encode!(params["items"] || []),
          "timestamp" => Calendar.strftime(now, "%Y-%m-%d %H:%M:%S")
        }

        # Async: ClickHouse insert + visitor identification (same as ingest fire-and-forget)
        email = params["email"]

        Task.start(fn ->
          case Spectabas.ClickHouse.insert("ecommerce_events", [row]) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[API] Ecommerce insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )
          end

          # Deferred identify: link email to visitor after responding
          if is_binary(email) and email != "" and visitor_id != "" do
            Visitors.identify(site.id, visitor_id, %{email: email})
          end
        end)

        json(conn, %{ok: true, order_id: order_id})
      end
    else
      error -> handle_error(conn, error)
    end
  end

  # Parse optional occurred_at Unix timestamp (UTC seconds).
  # Falls back to now if missing, invalid, or outside the allowed window
  # (last 7 days to 60 seconds in the future).
  defp parse_occurred_at(nil), do: DateTime.utc_now()

  defp parse_occurred_at(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} ->
        now = DateTime.utc_now()
        week_ago = DateTime.add(now, -7, :day)

        if DateTime.compare(dt, week_ago) == :gt and
             DateTime.compare(dt, DateTime.add(now, 60, :second)) != :gt do
          dt
        else
          now
        end

      _ ->
        DateTime.utc_now()
    end
  end

  defp parse_occurred_at(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> parse_occurred_at(n)
      :error -> DateTime.utc_now()
    end
  end

  defp parse_occurred_at(_), do: DateTime.utc_now()

  defp parse_amount(nil), do: 0
  defp parse_amount(n) when is_number(n), do: n

  defp parse_amount(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp parse_amount(_), do: 0

  def ecommerce_stats(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, stats} <- Analytics.ecommerce_stats(site, user, date_range) do
      json(conn, %{data: stats})
    else
      error -> handle_error(conn, error)
    end
  end

  def ecommerce_products(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.ecommerce_top_products(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  def ecommerce_orders(conn, %{"site_id" => site_id} = params) do
    with :ok <- require_scope(conn, "read:stats"),
         {:ok, site, user} <- authorize_site(conn, site_id),
         date_range <- parse_date_range(params),
         {:ok, data} <- Analytics.ecommerce_orders(site, user, date_range) do
      json(conn, %{data: data})
    else
      error -> handle_error(conn, error)
    end
  end

  # --- Shared error handler ---

  defp handle_error(conn, {:error, :insufficient_scope}) do
    conn |> put_status(403) |> json(%{error: "insufficient scope"})
  end

  defp handle_error(conn, {:error, :not_found}) do
    conn |> put_status(404) |> json(%{error: "site not found"})
  end

  defp handle_error(conn, {:error, :unauthorized}) do
    conn |> put_status(403) |> json(%{error: "unauthorized"})
  end

  defp handle_error(conn, {:error, reason}) do
    Logger.warning("[API] Query error: #{inspect(reason) |> String.slice(0, 200)}")
    conn |> put_status(500) |> json(%{error: "internal error"})
  end

  defp handle_error(conn, _) do
    conn |> put_status(500) |> json(%{error: "internal error"})
  end

  # --- Private helpers ---

  defp require_scope(conn, scope) do
    if ApiAuth.has_scope?(conn, scope) do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  defp authorize_site(conn, site_id) do
    user_id = conn.assigns[:current_user_id]
    allowed_site_ids = conn.assigns[:api_site_ids] || []

    with {:ok, site} <- fetch_site(site_id),
         {:ok, user} <- fetch_user(user_id),
         true <- Accounts.can_access_site?(user, site),
         true <- site_allowed?(site.id, allowed_site_ids) do
      {:ok, site, user}
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  # Empty list = all sites allowed
  defp site_allowed?(_site_id, []), do: true
  defp site_allowed?(site_id, allowed), do: site_id in allowed

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

  # Fast visitor resolution — lookup only, no writes. Identify deferred to async Task.
  defp resolve_transaction_visitor_fast(site, params) do
    email = params["email"]
    visitor_id = params["visitor_id"] || ""

    cond do
      # Has visitor_id: use it directly (identify deferred to async)
      visitor_id != "" ->
        visitor_id

      # Email only (no visitor_id): look up by email in Postgres
      is_binary(email) and email != "" ->
        case find_visitor_by_email(site.id, email) do
          %{id: id} -> id
          nil -> ""
        end

      true ->
        ""
    end
  end

  defp find_visitor_by_email(site_id, email) do
    import Ecto.Query

    normalized = String.downcase(String.trim(email))

    Spectabas.Repo.one(
      from(v in Spectabas.Visitors.Visitor,
        where: v.site_id == ^site_id and v.email == ^normalized,
        order_by: [desc: v.last_seen_at],
        limit: 1
      )
    )
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
