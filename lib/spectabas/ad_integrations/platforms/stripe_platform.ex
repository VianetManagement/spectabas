defmodule Spectabas.AdIntegrations.Platforms.StripePlatform do
  @moduledoc """
  Stripe integration for importing charges as ecommerce events.
  Uses the Stripe API to fetch completed charges and maps them to
  identified visitors via email → visitor lookup.
  """

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.ClickHouse

  @stripe_api "https://api.stripe.com/v1"

  @doc """
  Fetch completed charges from Stripe for a given date.
  Returns {:ok, [charge_map]} or {:error, reason}.
  Each charge_map has: charge_id, email, amount, currency, created_at.
  """
  def fetch_charges(integration, date) do
    api_key = AdIntegrations.decrypt_access_token(integration)

    # Date range: start of day to end of day (UTC)
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    fetch_charges_page(api_key, day_start, day_end, nil, [])
  end

  defp fetch_charges_page(api_key, day_start, day_end, starting_after, acc) do
    params = %{
      "created[gte]" => DateTime.to_unix(day_start),
      "created[lt]" => DateTime.to_unix(day_end),
      "status" => "succeeded",
      "limit" => "100",
      "expand[]" => "data.customer"
    }

    params =
      if starting_after,
        do: Map.put(params, "starting_after", starting_after),
        else: params

    qs = URI.encode_query(params)

    case Req.get("#{@stripe_api}/charges?#{qs}",
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"stripe-version", "2024-12-18.acacia"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"data" => charges, "has_more" => has_more}}} ->
        parsed =
          Enum.map(charges, fn charge ->
            email =
              cond do
                is_binary(charge["receipt_email"]) and charge["receipt_email"] != "" ->
                  charge["receipt_email"]

                is_map(charge["customer"]) ->
                  charge["customer"]["email"] || ""

                true ->
                  ""
              end

            %{
              charge_id: charge["id"],
              email: email,
              amount: (charge["amount"] || 0) / 100.0,
              currency: String.upcase(charge["currency"] || "usd"),
              created_at: DateTime.from_unix!(charge["created"])
            }
          end)

        new_acc = acc ++ parsed

        if has_more and length(charges) > 0 do
          last_id = List.last(charges)["id"]
          fetch_charges_page(api_key, day_start, day_end, last_id, new_acc)
        else
          {:ok, new_acc}
        end

      {:ok, %{status: 401}} ->
        {:error, "Invalid Stripe API key"}

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        {:error, msg}

      {:error, reason} ->
        {:error, "Stripe API error: #{inspect(reason)}"}
    end
  end

  @doc """
  Sync Stripe charges for a date into ecommerce_events.
  Matches charges to visitors via email lookup.
  """
  def sync_charges(site, integration, date) do
    case fetch_charges(integration, date) do
      {:ok, []} ->
        Logger.info("[StripSync] No charges for #{date}")
        AdIntegrations.mark_synced(integration)
        :ok

      {:ok, charges} ->
        # Check for duplicates — skip charges already in ecommerce_events
        existing = existing_order_ids(site.id, date)

        new_charges = Enum.reject(charges, fn c -> c.charge_id in existing end)

        if new_charges == [] do
          Logger.info("[StripSync] All #{length(charges)} charges already synced for #{date}")
          AdIntegrations.mark_synced(integration)
          :ok
        else
          rows =
            Enum.map(new_charges, fn charge ->
              visitor_id = resolve_visitor(site.id, charge.email)

              %{
                "site_id" => site.id,
                "visitor_id" => visitor_id,
                "session_id" => "",
                "order_id" => charge.charge_id,
                "revenue" => charge.amount,
                "subtotal" => charge.amount,
                "tax" => 0,
                "shipping" => 0,
                "discount" => 0,
                "currency" => charge.currency,
                "items" => "[]",
                "timestamp" => Calendar.strftime(charge.created_at, "%Y-%m-%d %H:%M:%S")
              }
            end)

          case ClickHouse.insert("ecommerce_events", rows) do
            :ok ->
              Logger.info(
                "[StripSync] Synced #{length(rows)} charges for #{date} (#{length(charges) - length(new_charges)} dupes skipped)"
              )

              AdIntegrations.mark_synced(integration)
              :ok

            {:error, reason} ->
              Logger.error(
                "[StripSync] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )

              AdIntegrations.mark_error(integration, "ClickHouse insert failed")
              {:error, reason}
          end
        end

      {:error, reason} ->
        Logger.warning("[StripSync] Fetch failed: #{inspect(reason) |> String.slice(0, 200)}")
        AdIntegrations.mark_error(integration, reason)
        {:error, reason}
    end
  end

  # Look up existing order_ids to prevent duplicate inserts
  defp existing_order_ids(site_id, date) do
    from_dt = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    sql = """
    SELECT DISTINCT order_id
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND timestamp >= #{ClickHouse.param(Calendar.strftime(from_dt, "%Y-%m-%d %H:%M:%S"))}
      AND timestamp < #{ClickHouse.param(Calendar.strftime(to_dt, "%Y-%m-%d %H:%M:%S"))}
      AND order_id LIKE 'ch_%'
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> Enum.map(rows, & &1["order_id"])
      _ -> []
    end
  end

  # Look up visitor by email in Postgres
  defp resolve_visitor(site_id, email) when is_binary(email) and email != "" do
    import Ecto.Query

    case Spectabas.Repo.one(
           from(v in Spectabas.Visitors.Visitor,
             where: v.site_id == ^site_id and v.email == ^email,
             select: v.id,
             limit: 1
           )
         ) do
      nil -> ""
      id -> id
    end
  end

  defp resolve_visitor(_, _), do: ""
end
