defmodule Spectabas.AdIntegrations.Platforms.BraintreePlatform do
  @moduledoc """
  Braintree integration for importing transactions, refunds, and subscriptions.
  Uses the Braintree HTTP API with Basic auth (public_key:private_key).
  """

  require Logger

  alias Spectabas.{AdIntegrations, ClickHouse}

  @doc """
  Fetch settled/submitted transactions from Braintree for a given date.
  Uses the transaction search API with created_at range.
  Returns {:ok, [transaction_map]} or {:error, reason}.
  """
  def fetch_transactions(integration, date) do
    {merchant_id, auth_header} = auth(integration)

    day_start = Date.to_iso8601(date) <> "T00:00:00Z"
    day_end = Date.to_iso8601(Date.add(date, 1)) <> "T00:00:00Z"

    body = """
    <search>
      <created-at>
        <min type="datetime">#{day_start}</min>
        <max type="datetime">#{day_end}</max>
      </created-at>
      <status type="array"><item>settled</item><item>settling</item><item>submitted_for_settlement</item></status>
    </search>
    """

    url = "#{base_url(merchant_id)}/transactions/advanced_search"

    case Req.post(url, body: body, headers: xml_headers(auth_header)) do
      {:ok, %{status: 200, body: resp_body}} ->
        transactions = parse_transactions(resp_body)
        {:ok, transactions}

      {:ok, %{status: 401}} ->
        {:error, "Invalid Braintree credentials"}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Braintree HTTP #{status}: #{String.slice(to_string(resp_body), 0, 200)}"}

      {:error, reason} ->
        {:error, "Braintree API error: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetch refunded transactions from Braintree for a given date.
  """
  def fetch_refunds(integration, date) do
    {merchant_id, auth_header} = auth(integration)

    day_start = Date.to_iso8601(date) <> "T00:00:00Z"
    day_end = Date.to_iso8601(Date.add(date, 1)) <> "T00:00:00Z"

    body = """
    <search>
      <created-at>
        <min type="datetime">#{day_start}</min>
        <max type="datetime">#{day_end}</max>
      </created-at>
      <type><is>credit</is></type>
    </search>
    """

    url = "#{base_url(merchant_id)}/transactions/advanced_search"

    case Req.post(url, body: body, headers: xml_headers(auth_header)) do
      {:ok, %{status: 200, body: resp_body}} ->
        refunds = parse_refunds(resp_body)
        {:ok, refunds}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Fetch all subscriptions from Braintree.
  """
  def fetch_subscriptions(integration) do
    {merchant_id, auth_header} = auth(integration)

    # Search for active + past_due + canceled subscriptions
    body = """
    <search>
      <status type="array">
        <item>Active</item>
        <item>Past Due</item>
        <item>Canceled</item>
        <item>Expired</item>
      </status>
    </search>
    """

    url = "#{base_url(merchant_id)}/subscriptions/advanced_search"

    case Req.post(url, body: body, headers: xml_headers(auth_header)) do
      {:ok, %{status: 200, body: resp_body}} ->
        subs = parse_subscriptions(resp_body)
        {:ok, subs}

      {:ok, %{status: status}} ->
        {:error, "Braintree subscriptions HTTP #{status}"}

      {:error, reason} ->
        {:error, "Braintree API error: #{inspect(reason)}"}
    end
  end

  @doc "Sync transactions for a date into ecommerce_events."
  def sync_transactions(site, integration, date) do
    case fetch_transactions(integration, date) do
      {:ok, []} ->
        Logger.info("[BraintreeSync] No transactions for #{date}")
        AdIntegrations.mark_synced(integration)
        :ok

      {:ok, transactions} ->
        # Dedup: skip transactions already imported (by order_id) OR matching
        # an existing transaction by amount + timestamp proximity (within 10 min)
        existing_ids = existing_order_ids(site.id, date)
        existing_txns = existing_transactions_for_dedup(site.id, date)

        new_txns =
          Enum.reject(transactions, fn t ->
            t.id in existing_ids or
              Enum.any?(existing_txns, fn txn ->
                abs(txn.amount - t.amount) < 0.02 and
                  abs(txn.timestamp_unix - parse_timestamp_unix(t.created_at)) < 600
              end)
          end)

        if new_txns == [] do
          AdIntegrations.mark_synced(integration)
          :ok
        else
          rows =
            Enum.map(new_txns, fn txn ->
              visitor_id = resolve_visitor(site.id, txn.email)

              %{
                "site_id" => site.id,
                "visitor_id" => visitor_id,
                "session_id" => "",
                "order_id" => txn.id,
                "revenue" => txn.amount,
                "subtotal" => txn.amount,
                "import_source" => "braintree",
                "tax" => 0,
                "shipping" => 0,
                "discount" => 0,
                "refund_amount" => 0,
                "currency" => txn.currency,
                "items" => "[]",
                "timestamp" => txn.created_at
              }
            end)

          case ClickHouse.insert("ecommerce_events", rows) do
            :ok ->
              Logger.info("[BraintreeSync] Synced #{length(rows)} transactions for #{date}")
              AdIntegrations.mark_synced(integration)
              :ok

            {:error, reason} ->
              Logger.error(
                "[BraintreeSync] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )

              AdIntegrations.mark_error(integration, "ClickHouse insert failed")
              {:error, reason}
          end
        end

      {:error, reason} ->
        Logger.warning("[BraintreeSync] Fetch failed: #{inspect(reason) |> String.slice(0, 200)}")
        AdIntegrations.mark_error(integration, reason)
        {:error, reason}
    end
  end

  @doc "Sync refunds for a date — updates refund_amount on matching transactions."
  def sync_refunds(site, integration, date) do
    case fetch_refunds(integration, date) do
      {:ok, []} ->
        :ok

      {:ok, refunds} ->
        Enum.each(refunds, fn refund ->
          sql = """
          ALTER TABLE ecommerce_events
          UPDATE refund_amount = toDecimal64(#{refund.amount}, 2)
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND order_id = #{ClickHouse.param(refund.refunded_transaction_id)}
          """

          case ClickHouse.execute(sql) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("[BraintreeSync] Refund update failed: #{inspect(reason)}")
          end
        end)

        Logger.info("[BraintreeSync] Processed #{length(refunds)} refunds for #{date}")
        :ok

      _ ->
        :ok
    end
  end

  @doc "Sync subscription snapshots to ClickHouse."
  def sync_subscriptions(site, integration) do
    case fetch_subscriptions(integration) do
      {:ok, []} ->
        :ok

      {:ok, subs} ->
        rows =
          Enum.map(subs, fn sub ->
            visitor_id = resolve_visitor(site.id, sub.email)

            # Calculate MRR: if billing cycle is 12 months, divide by 12
            mrr =
              case sub.billing_cycle_months do
                m when m >= 12 -> sub.amount / 12.0
                m when m > 0 -> sub.amount / m
                _ -> sub.amount
              end

            status =
              case sub.status do
                "Active" -> "active"
                "Past Due" -> "past_due"
                "Canceled" -> "canceled"
                "Expired" -> "canceled"
                s -> String.downcase(s)
              end

            %{
              "site_id" => site.id,
              "subscription_id" => sub.id,
              "customer_email" => sub.email || "",
              "visitor_id" => visitor_id,
              "plan_name" => sub.plan_id || "",
              "plan_interval" => if(sub.billing_cycle_months >= 12, do: "year", else: "month"),
              "mrr_amount" => Float.round(mrr, 2),
              "currency" => sub.currency || "USD",
              "status" => status,
              "event_type" => "snapshot",
              "started_at" => sub.created_at,
              "canceled_at" => sub.canceled_at || "1970-01-01 00:00:00",
              "current_period_end" => sub.next_billing_date || "1970-01-01 00:00:00",
              "snapshot_date" => Date.to_iso8601(Date.utc_today()),
              "timestamp" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
            }
          end)

        case ClickHouse.insert("subscription_events", rows) do
          :ok ->
            Logger.info("[BraintreeSync] Synced #{length(rows)} subscription snapshots")
            :ok

          {:error, reason} ->
            Logger.error(
              "[BraintreeSync] Subscription insert failed: #{inspect(reason) |> String.slice(0, 200)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[BraintreeSync] Subscription fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Private helpers ---

  defp auth(integration) do
    creds =
      AdIntegrations.Credentials.get_for_platform(
        Spectabas.Repo.preload(integration, :site).site,
        "braintree"
      )

    merchant_id = creds["merchant_id"] || ""
    public_key = creds["public_key"] || ""
    private_key = creds["private_key"] || ""
    auth = Base.encode64("#{public_key}:#{private_key}")

    {merchant_id, "Basic #{auth}"}
  end

  defp base_url(merchant_id) do
    # Production Braintree API
    "https://api.braintreegateway.com/merchants/#{merchant_id}"
  end

  defp xml_headers(auth_header) do
    [
      {"authorization", auth_header},
      {"content-type", "application/xml"},
      {"accept", "application/xml"},
      {"x-apiversion", "6"}
    ]
  end

  # Parse Braintree XML transaction response into maps
  # Braintree returns XML — we extract key fields with simple regex
  defp parse_transactions(body) when is_binary(body) do
    # Extract each <transaction>...</transaction> block
    ~r/<transaction>.*?<\/transaction>/s
    |> Regex.scan(body)
    |> Enum.map(fn [block] ->
      %{
        id: extract_xml(block, "id"),
        amount: parse_amount(extract_xml(block, "amount")),
        currency: extract_xml(block, "currency-iso-code") |> String.upcase(),
        email: extract_xml(block, "email"),
        created_at: extract_xml(block, "created-at") |> format_bt_datetime(),
        status: extract_xml(block, "status")
      }
    end)
    |> Enum.reject(fn t -> t.id == "" end)
  end

  defp parse_transactions(_), do: []

  defp parse_refunds(body) when is_binary(body) do
    ~r/<transaction>.*?<\/transaction>/s
    |> Regex.scan(body)
    |> Enum.map(fn [block] ->
      %{
        id: extract_xml(block, "id"),
        amount: parse_amount(extract_xml(block, "amount")),
        refunded_transaction_id: extract_xml(block, "refunded-transaction-id")
      }
    end)
    |> Enum.reject(fn r -> r.refunded_transaction_id == "" end)
  end

  defp parse_refunds(_), do: []

  defp parse_subscriptions(body) when is_binary(body) do
    ~r/<subscription>.*?<\/subscription>/s
    |> Regex.scan(body)
    |> Enum.map(fn [block] ->
      # Try to get customer email from nested customer block
      customer_email =
        case Regex.run(~r/<customer>.*?<email>(.*?)<\/email>.*?<\/customer>/s, block) do
          [_, email] -> email
          _ -> ""
        end

      billing_months =
        case extract_xml(block, "number-of-billing-cycles") do
          "" -> 1
          n -> parse_int(n)
        end

      %{
        id: extract_xml(block, "id"),
        plan_id: extract_xml(block, "plan-id"),
        amount: parse_amount(extract_xml(block, "price")),
        currency:
          extract_xml(block, "currency-iso-code")
          |> then(fn c -> if c == "", do: "USD", else: String.upcase(c) end),
        status: extract_xml(block, "status"),
        email: customer_email,
        billing_cycle_months: billing_months,
        created_at: extract_xml(block, "created-at") |> format_bt_datetime(),
        canceled_at: extract_xml(block, "updated-at") |> format_bt_datetime(),
        next_billing_date: extract_xml(block, "next-billing-date") |> format_bt_date()
      }
    end)
    |> Enum.reject(fn s -> s.id == "" end)
  end

  defp parse_subscriptions(_), do: []

  defp extract_xml(block, tag) do
    case Regex.run(~r/<#{tag}[^>]*>(.*?)<\/#{tag}>/s, block) do
      [_, value] -> String.trim(value)
      _ -> ""
    end
  end

  defp parse_amount(""), do: 0.0

  defp parse_amount(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> 1
    end
  end

  # Braintree datetime: "2024-01-15T10:30:00Z" → "2024-01-15 10:30:00"
  defp format_bt_datetime(""), do: "1970-01-01 00:00:00"

  defp format_bt_datetime(dt) do
    dt
    |> String.replace("T", " ")
    |> String.replace(~r/[Z+].*$/, "")
    |> String.slice(0, 19)
    |> then(fn s -> if String.length(s) >= 19, do: s, else: "1970-01-01 00:00:00" end)
  end

  # Braintree date: "2024-01-15" → "2024-01-15 00:00:00"
  defp format_bt_date(""), do: "1970-01-01 00:00:00"
  defp format_bt_date(d) when byte_size(d) == 10, do: d <> " 00:00:00"
  defp format_bt_date(d), do: format_bt_datetime(d)

  defp existing_order_ids(site_id, date) do
    from_dt = Date.to_iso8601(date) <> " 00:00:00"
    to_dt = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00"

    sql = """
    SELECT DISTINCT order_id
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND timestamp >= #{ClickHouse.param(from_dt)}
      AND timestamp < #{ClickHouse.param(to_dt)}
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> Enum.map(rows, & &1["order_id"])
      _ -> []
    end
  end

  defp existing_transactions_for_dedup(site_id, date) do
    from_dt = Date.to_iso8601(date) <> " 00:00:00"
    to_dt = Date.to_iso8601(Date.add(date, 1)) <> " 00:00:00"

    sql = """
    SELECT toFloat64(revenue) AS amount, toUnixTimestamp(timestamp) AS ts
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND timestamp >= #{ClickHouse.param(from_dt)}
      AND timestamp < #{ClickHouse.param(to_dt)}
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn r ->
          %{amount: parse_float(r["amount"]), timestamp_unix: parse_int_val(r["ts"])}
        end)

      _ ->
        []
    end
  end

  defp parse_float(n) when is_float(n), do: n

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  defp parse_int_val(n) when is_integer(n), do: n

  defp parse_int_val(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp parse_int_val(_), do: 0

  defp parse_timestamp_unix(dt_str) when is_binary(dt_str) do
    case DateTime.from_iso8601(dt_str <> "Z") do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      _ ->
        case NaiveDateTime.from_iso8601(String.replace(dt_str, " ", "T")) do
          {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
          _ -> 0
        end
    end
  end

  defp parse_timestamp_unix(_), do: 0

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
