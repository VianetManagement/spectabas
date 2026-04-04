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
    lock_key = "stripe_sync:#{integration.id}:#{Date.to_iso8601(date)}"

    if locked?(lock_key) do
      Logger.info("[StripSync] Skipping #{date} — already syncing")
      :ok
    else
      acquire_lock(lock_key)

      try do
        do_sync_charges(site, integration, date)
      after
        release_lock(lock_key)
      end
    end
  end

  defp do_sync_charges(site, integration, date) do
    case fetch_charges(integration, date) do
      {:ok, []} ->
        Logger.info("[StripSync] No charges for #{date}")
        AdIntegrations.mark_synced(integration)
        :ok

      {:ok, charges} ->
        # Skip charges already imported (prevents re-importing same ch_* IDs on re-sync).
        # Cross-source dedup (API vs Stripe for same payment) is handled at query time
        # via ecommerce_dedup() — all sources insert freely, queries deduplicate.
        existing_ids = existing_order_ids(site.id, date)
        new_charges = Enum.reject(charges, fn c -> c.charge_id in existing_ids end)

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
                "import_source" => "stripe",
                "tax" => 0,
                "shipping" => 0,
                "discount" => 0,
                "refund_amount" => 0,
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

              # Also sync refunds for this date
              sync_refunds(site, integration, date)

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

  @doc """
  Fetch refunds from Stripe for a given date.
  Returns {:ok, [refund_map]} or {:error, reason}.
  """
  def fetch_refunds(integration, date) do
    api_key = AdIntegrations.decrypt_access_token(integration)

    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

    fetch_refunds_page(api_key, day_start, day_end, nil, [])
  end

  defp fetch_refunds_page(api_key, day_start, day_end, starting_after, acc) do
    params = %{
      "created[gte]" => DateTime.to_unix(day_start),
      "created[lt]" => DateTime.to_unix(day_end),
      "limit" => "100",
      "expand[]" => "data.charge"
    }

    params =
      if starting_after,
        do: Map.put(params, "starting_after", starting_after),
        else: params

    qs = URI.encode_query(params)

    case Req.get("#{@stripe_api}/refunds?#{qs}",
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"stripe-version", "2024-12-18.acacia"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"data" => refunds, "has_more" => has_more}}} ->
        parsed =
          Enum.map(refunds, fn refund ->
            charge_id =
              case refund["charge"] do
                %{"id" => id} -> id
                id when is_binary(id) -> id
                _ -> ""
              end

            %{
              refund_id: refund["id"],
              charge_id: charge_id,
              amount: (refund["amount"] || 0) / 100.0,
              currency: String.upcase(refund["currency"] || "usd"),
              created_at: DateTime.from_unix!(refund["created"])
            }
          end)

        new_acc = acc ++ parsed

        if has_more and length(refunds) > 0 do
          last_id = List.last(refunds)["id"]
          fetch_refunds_page(api_key, day_start, day_end, last_id, new_acc)
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
  Sync Stripe refunds for a date by updating refund_amount on matching ecommerce_events.
  """
  def sync_refunds(site, integration, date) do
    case fetch_refunds(integration, date) do
      {:ok, []} ->
        Logger.info("[StripSync] No refunds for #{date}")
        :ok

      {:ok, refunds} ->
        Enum.each(refunds, fn refund ->
          sql = """
          ALTER TABLE ecommerce_events UPDATE refund_amount = #{ClickHouse.param(refund.amount)}
          WHERE site_id = #{ClickHouse.param(site.id)} AND order_id = #{ClickHouse.param(refund.charge_id)}
          """

          case ClickHouse.execute(sql) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[StripSync] Refund update failed for #{refund.refund_id}: #{inspect(reason) |> String.slice(0, 200)}"
              )
          end
        end)

        Logger.info("[StripSync] Processed #{length(refunds)} refunds for #{date}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[StripSync] Refund fetch failed: #{inspect(reason) |> String.slice(0, 200)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Fetch all subscriptions from Stripe (active, past_due, canceled).
  Returns {:ok, [subscription_map]} or {:error, reason}.
  """
  def fetch_subscriptions(integration) do
    api_key = AdIntegrations.decrypt_access_token(integration)
    fetch_subscriptions_page(api_key, nil, [])
  end

  defp fetch_subscriptions_page(api_key, starting_after, acc) do
    params = %{
      "status" => "all",
      "limit" => "100",
      "expand[]" => "data.customer"
    }

    params =
      if starting_after,
        do: Map.put(params, "starting_after", starting_after),
        else: params

    qs = URI.encode_query(params)

    case Req.get("#{@stripe_api}/subscriptions?#{qs}",
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"stripe-version", "2024-12-18.acacia"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"data" => subs, "has_more" => has_more}}} ->
        parsed =
          Enum.map(subs, fn sub ->
            customer_email =
              case sub["customer"] do
                %{"email" => email} when is_binary(email) -> email
                _ -> ""
              end

            item = get_in(sub, ["items", "data", Access.at(0)]) || %{}
            price = item["price"] || %{}

            plan_name = price["nickname"] || price["product"] || ""
            interval = get_in(price, ["recurring", "interval"]) || "month"
            unit_amount = (price["unit_amount"] || 0) / 100.0
            currency = String.upcase(price["currency"] || "usd")

            mrr =
              case interval do
                "year" -> Float.round(unit_amount / 12.0, 2)
                _ -> unit_amount
              end

            canceled_at_dt =
              if sub["canceled_at"],
                do: DateTime.from_unix!(sub["canceled_at"]),
                else: DateTime.from_unix!(0)

            %{
              id: sub["id"],
              customer_email: customer_email,
              plan_name: plan_name,
              plan_interval: interval,
              amount: unit_amount,
              mrr: mrr,
              currency: currency,
              status: sub["status"] || "unknown",
              current_period_end: DateTime.from_unix!(sub["current_period_end"] || 0),
              created: DateTime.from_unix!(sub["created"] || 0),
              canceled_at: canceled_at_dt
            }
          end)

        new_acc = acc ++ parsed

        if has_more and length(subs) > 0 do
          last_id = List.last(subs)["id"]
          fetch_subscriptions_page(api_key, last_id, new_acc)
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
  Sync subscription snapshots to ClickHouse subscription_events table.
  """
  def sync_subscriptions(site, integration) do
    case fetch_subscriptions(integration) do
      {:ok, []} ->
        Logger.info("[StripSync] No subscriptions found")
        :ok

      {:ok, subscriptions} ->
        now = DateTime.utc_now()
        today = Date.utc_today()

        rows =
          Enum.map(subscriptions, fn sub ->
            visitor_id = resolve_visitor(site.id, sub.customer_email)

            %{
              "site_id" => site.id,
              "subscription_id" => sub.id,
              "customer_email" => sub.customer_email,
              "visitor_id" => visitor_id,
              "plan_name" => sub.plan_name,
              "plan_interval" => sub.plan_interval,
              "mrr_amount" => sub.mrr,
              "currency" => sub.currency,
              "status" => sub.status,
              "event_type" => "snapshot",
              "started_at" => Calendar.strftime(sub.created, "%Y-%m-%d %H:%M:%S"),
              "canceled_at" => Calendar.strftime(sub.canceled_at, "%Y-%m-%d %H:%M:%S"),
              "current_period_end" =>
                Calendar.strftime(sub.current_period_end, "%Y-%m-%d %H:%M:%S"),
              "snapshot_date" => Date.to_string(today),
              "timestamp" => Calendar.strftime(now, "%Y-%m-%d %H:%M:%S")
            }
          end)

        case ClickHouse.insert("subscription_events", rows) do
          :ok ->
            Logger.info("[StripSync] Synced #{length(rows)} subscription snapshots")
            :ok

          {:error, reason} ->
            Logger.error(
              "[StripSync] Subscription insert failed: #{inspect(reason) |> String.slice(0, 200)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning(
          "[StripSync] Subscription fetch failed: #{inspect(reason) |> String.slice(0, 200)}"
        )

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

  # Simple process-level lock to prevent concurrent syncs for the same integration+date
  defp locked?(key) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil -> false
      ts -> System.monotonic_time(:second) - ts < 300
    end
  end

  defp acquire_lock(key) do
    :persistent_term.put({__MODULE__, key}, System.monotonic_time(:second))
  end

  defp release_lock(key) do
    :persistent_term.erase({__MODULE__, key})
  catch
    _, _ -> :ok
  end
end
