defmodule Spectabas.AdIntegrations.Platforms.BraintreePlatform do
  @moduledoc """
  Braintree integration for importing transactions, refunds, and subscriptions.
  Uses the Braintree HTTP API with Basic auth (public_key:private_key).
  """

  require Logger

  alias Spectabas.{AdIntegrations, ClickHouse}
  alias Spectabas.AdIntegrations.{HTTP, SyncLock}

  @doc """
  Fetch settled/submitted transactions from Braintree for a given date.
  Uses the transaction search API with created_at range.
  Returns {:ok, [transaction_map]} or {:error, reason}.
  """
  def fetch_transactions(integration, date) do
    case auth(integration) do
      {:error, :no_credentials} ->
        {:error, "Braintree credentials not configured"}

      {:ok, merchant_id, auth_header} ->
        fetch_transactions_with_auth(merchant_id, auth_header, date)
    end
  end

  defp fetch_transactions_with_auth(merchant_id, auth_header, date) do
    day_start = Date.to_iso8601(date) <> "T00:00:00Z"
    day_end = Date.to_iso8601(Date.add(date, 1)) <> "T00:00:00Z"

    search_body = """
    <search>
      <created-at>
        <min type="datetime">#{day_start}</min>
        <max type="datetime">#{day_end}</max>
      </created-at>
      <status type="array"><item>settled</item><item>settling</item><item>submitted_for_settlement</item></status>
    </search>
    """

    # Braintree two-step search:
    # 1. POST advanced_search_ids → get ALL matching transaction IDs
    # 2. POST advanced_search with batches of IDs → get full transaction data
    fetch_all_by_ids(merchant_id, auth_header, search_body)
  end

  defp fetch_all_by_ids(merchant_id, auth_header, search_body) do
    ids_url = "#{base_url(merchant_id)}/transactions/advanced_search_ids"

    case HTTP.post(ids_url,
           body: search_body,
           headers: xml_headers(auth_header),
           receive_timeout: 60_000,
           connect_options: [timeout: 15_000]
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        ids = parse_ids(resp_body)
        page_size = parse_page_size(resp_body)
        Logger.info("[BraintreeSync] Got #{length(ids)} transaction IDs, page_size=#{page_size}")

        if ids == [] do
          {:ok, []}
        else
          # Fetch full transaction data in batches
          batch_size = max(page_size, 50)
          search_url = "#{base_url(merchant_id)}/transactions/advanced_search"

          txns =
            ids
            |> Enum.chunk_every(batch_size)
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {batch_ids, batch_num} ->
              ids_xml = Enum.map_join(batch_ids, "", fn id -> "<item>#{id}</item>" end)

              batch_body =
                String.replace(
                  search_body,
                  "</search>",
                  "<ids type=\"array\">#{ids_xml}</ids></search>"
                )

              fetch_batch(search_url, batch_body, auth_header, batch_num)
            end)

          Logger.info("[BraintreeSync] Total: #{length(txns)} transactions fetched")
          {:ok, txns}
        end

      {:ok, %{status: 401}} ->
        {:error, "Invalid Braintree credentials"}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Braintree HTTP #{status}: #{String.slice(to_string(resp_body), 0, 200)}"}

      {:error, reason} ->
        {:error, "Braintree API error: #{inspect(reason)}"}
    end
  end

  defp fetch_batch(url, body, auth_header, batch_num) do
    case HTTP.post(url,
           body: body,
           headers: xml_headers(auth_header),
           receive_timeout: 60_000,
           connect_options: [timeout: 15_000]
         ) do
      {:ok, %{status: 200, body: resp}} ->
        txns = parse_transactions(resp)
        Logger.info("[BraintreeSync] Batch #{batch_num}: #{length(txns)} txns fetched")
        txns

      {:ok, %{status: status}} ->
        Logger.warning("[BraintreeSync] Batch #{batch_num} returned HTTP #{status}")
        []

      {:error, reason} ->
        Logger.warning("[BraintreeSync] Batch #{batch_num} failed: #{inspect(reason)}")
        []
    end
  end

  defp parse_ids(body) do
    ~r/<ids[^>]*>(.*?)<\/ids>/s
    |> Regex.run(body)
    |> case do
      [_, ids_block] ->
        ~r/<item>(.*?)<\/item>/
        |> Regex.scan(ids_block)
        |> Enum.map(fn [_, id] -> String.trim(id) end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_page_size(body) do
    case Regex.run(~r/<page-size[^>]*>(\d+)<\/page-size>/, body) do
      [_, size] -> String.to_integer(size)
      _ -> 50
    end
  end

  @doc """
  Fetch refunded transactions from Braintree for a given date.
  """
  def fetch_refunds(integration, date) do
    case auth(integration) do
      {:error, :no_credentials} ->
        {:error, "Braintree credentials not configured"}

      {:ok, merchant_id, auth_header} ->
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

        case fetch_all_by_ids(merchant_id, auth_header, body) do
          {:ok, transactions} ->
            refunds =
              transactions
              |> Enum.map(fn t ->
                %{
                  id: t.id,
                  amount: t.amount,
                  refunded_transaction_id: extract_refunded_id_from_txn(t)
                }
              end)
              |> Enum.reject(fn r -> r.refunded_transaction_id == "" end)

            {:ok, refunds}

          error ->
            error
        end
    end
  end

  defp extract_refunded_id_from_txn(%{refunded_transaction_id: id})
       when is_binary(id) and id != "",
       do: id

  defp extract_refunded_id_from_txn(_), do: ""

  @doc """
  Fetch all subscriptions from Braintree.
  """
  def fetch_subscriptions(integration) do
    case auth(integration) do
      {:error, :no_credentials} ->
        {:error, "Braintree credentials not configured"}

      {:ok, merchant_id, auth_header} ->
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

        fetch_subscriptions_with_auth(merchant_id, auth_header, body)
    end
  end

  defp fetch_subscriptions_with_auth(merchant_id, auth_header, body) do
    url = "#{base_url(merchant_id)}/subscriptions/advanced_search"

    case HTTP.post(url,
           body: body,
           headers: xml_headers(auth_header),
           receive_timeout: 60_000,
           connect_options: [timeout: 15_000]
         ) do
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
    lock_key = "bt_sync:#{integration.id}:#{Date.to_iso8601(date)}"

    if SyncLock.locked?(lock_key) do
      Logger.info("[BraintreeSync] Skipping #{date} — already syncing")
      :ok
    else
      SyncLock.acquire(lock_key)

      try do
        do_sync_transactions(site, integration, date)
      after
        SyncLock.release(lock_key)
      end
    end
  end

  defp do_sync_transactions(site, integration, date) do
    case fetch_transactions(integration, date) do
      {:ok, []} ->
        Logger.info("[BraintreeSync] No transactions for #{date}")
        AdIntegrations.mark_synced(integration)
        :ok

      {:ok, transactions} ->
        # Skip transactions already imported (prevents re-importing same IDs on re-sync).
        # Cross-source dedup handled at query time via ecommerce_source_filter.
        existing_ids = existing_order_ids(site.id, date)
        new_txns = Enum.reject(transactions, fn t -> t.id in existing_ids end)

        if new_txns == [] do
          AdIntegrations.mark_synced(integration)
          :ok
        else
          # Batch-resolve all emails to avoid N+1 queries
          emails = new_txns |> Enum.map(& &1.email) |> Enum.uniq() |> Enum.reject(&(&1 == ""))
          visitor_map = batch_resolve_visitors(site.id, emails)

          rows =
            Enum.map(new_txns, fn txn ->
              visitor_id = Map.get(visitor_map, txn.email, "")

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
                "items" => Jason.encode!(txn.items || []),
                "timestamp" => txn.created_at
              }
            end)

          # Insert in chunks to avoid oversized HTTP payloads
          chunk_size = 200

          results =
            rows
            |> Enum.chunk_every(chunk_size)
            |> Enum.with_index(1)
            |> Enum.map(fn {chunk, batch_num} ->
              case ClickHouse.insert("ecommerce_events", chunk) do
                :ok ->
                  Logger.info(
                    "[BraintreeSync] Batch #{batch_num}: inserted #{length(chunk)} rows for #{date}"
                  )

                  :ok

                {:error, reason} ->
                  Logger.error(
                    "[BraintreeSync] CH insert batch #{batch_num} failed for #{date}: #{inspect(reason) |> String.slice(0, 500)}"
                  )

                  {:error, reason}
              end
            end)

          if Enum.all?(results, &(&1 == :ok)) do
            Logger.info("[BraintreeSync] Synced #{length(rows)} transactions for #{date}")
            AdIntegrations.mark_synced(integration)
            :ok
          else
            AdIntegrations.mark_error(integration, "ClickHouse insert failed (partial)")
            {:error, "ClickHouse insert failed"}
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

      {:error, reason} ->
        Logger.warning("[BraintreeSync] Refund fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Sync subscription snapshots to ClickHouse."
  def sync_subscriptions(site, integration) do
    case fetch_subscriptions(integration) do
      {:ok, []} ->
        :ok

      {:ok, subs} ->
        # Batch-resolve all emails to avoid N+1 queries
        emails = subs |> Enum.map(& &1.email) |> Enum.uniq() |> Enum.reject(&(&1 == ""))
        visitor_map = batch_resolve_visitors(site.id, emails)

        rows =
          Enum.map(subs, fn sub ->
            visitor_id = Map.get(visitor_map, sub.email, "")

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

    if merchant_id == "" or public_key == "" or private_key == "" do
      {:error, :no_credentials}
    else
      auth = Base.encode64("#{public_key}:#{private_key}")
      {:ok, merchant_id, "Basic #{auth}"}
    end
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
      amount = parse_amount(extract_xml(block, "amount"))
      plan_id = extract_xml(block, "plan-id")
      txn_type = extract_xml(block, "type")

      items =
        if plan_id != "" do
          category = if txn_type == "sale", do: "subscription", else: "one_time"
          [%{"name" => plan_id, "price" => amount, "quantity" => 1, "category" => category}]
        else
          []
        end

      %{
        id: extract_xml(block, "id"),
        amount: amount,
        currency: extract_xml(block, "currency-iso-code") |> String.upcase(),
        email: extract_xml(block, "email") |> String.downcase(),
        created_at: extract_xml(block, "created-at") |> format_bt_datetime(),
        status: extract_xml(block, "status"),
        refunded_transaction_id: extract_xml(block, "refunded-transaction-id"),
        items: items
      }
    end)
    |> Enum.reject(fn t -> t.id == "" end)
  end

  defp parse_transactions(_), do: []

  defp parse_subscriptions(body) when is_binary(body) do
    ~r/<subscription>.*?<\/subscription>/s
    |> Regex.scan(body)
    |> Enum.map(fn [block] ->
      # Try to get customer email from nested customer block
      customer_email =
        case Regex.run(~r/<customer>.*?<email>(.*?)<\/email>.*?<\/customer>/s, block) do
          [_, email] -> String.downcase(email)
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

  # Batch-resolve visitor IDs by email in Postgres (avoids N+1)
  defp batch_resolve_visitors(site_id, emails) when emails != [] do
    import Ecto.Query

    Spectabas.Repo.all(
      from(v in Spectabas.Visitors.Visitor,
        where: v.site_id == ^site_id and v.email in ^emails,
        select: {v.email, v.id}
      )
    )
    |> Map.new()
  end

  defp batch_resolve_visitors(_, _), do: %{}
end
