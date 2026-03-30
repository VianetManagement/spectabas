defmodule Spectabas.Workers.EmailReportDelivery do
  @moduledoc "Fetches analytics data, renders, and delivers a single email report."

  use Oban.Worker, queue: :mailer, max_attempts: 3
  require Logger

  alias Spectabas.{Analytics, Reports}
  alias Spectabas.Reports.EmailReportHTML
  alias Spectabas.Accounts.UserNotifier

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => sub_id}}) do
    sub = Reports.get_email_subscription!(sub_id)
    site = sub.site
    user = sub.user
    tz = site.timezone || "UTC"

    {:ok, local_now} = DateTime.now(tz)

    # Idempotency check
    current_key = Reports.period_key(sub.frequency, local_now)
    if current_key == sub.last_period_key, do: throw(:already_sent)

    # Compute date ranges
    {current_range, previous_range} = compute_ranges(sub.frequency, local_now, tz)

    # Fetch analytics data (use overview_stats with a system-level bypass)
    current_stats = fetch_stats(site, user, current_range)
    previous_stats = fetch_stats(site, user, previous_range)
    top_pages = fetch_list(fn -> Analytics.top_pages(site, user, current_range) end, 5)
    top_sources = fetch_list(fn -> Analytics.top_sources(site, user, current_range) end, 5)

    top_countries =
      fetch_list(fn -> Analytics.top_countries_summary(site, user, current_range) end, 5)

    # Generate unsubscribe token
    unsubscribe_token =
      Phoenix.Token.sign(SpectabasWeb.Endpoint, "email_report_unsub", sub.id)

    # Build report data and render
    report_data = %{
      site: site,
      user: user,
      frequency: sub.frequency,
      current_range: current_range,
      previous_range: previous_range,
      current_stats: current_stats,
      previous_stats: previous_stats,
      top_pages: top_pages,
      top_sources: top_sources,
      top_countries: top_countries,
      unsubscribe_token: unsubscribe_token
    }

    {html, text} = EmailReportHTML.render(report_data)

    freq_label =
      case sub.frequency do
        :daily -> "Daily"
        :weekly -> "Weekly"
        :monthly -> "Monthly"
        _ -> "Analytics"
      end

    UserNotifier.deliver_report_email(
      user.email,
      "#{freq_label} Report: #{site.name}",
      html,
      text
    )

    # Mark as sent
    Reports.mark_subscription_sent(sub, current_key)
    Logger.info("[EmailReports] Sent #{sub.frequency} report for #{site.name} to #{user.email}")

    :ok
  catch
    :already_sent -> :ok
  end

  defp compute_ranges(:daily, local_now, tz) do
    today = DateTime.to_date(local_now)
    yesterday = Date.add(today, -1)

    {date_to_utc_range(today, today, tz), date_to_utc_range(yesterday, yesterday, tz)}
  end

  defp compute_ranges(:weekly, local_now, tz) do
    today = DateTime.to_date(local_now)
    week_start = Date.add(today, -6)
    prev_end = Date.add(week_start, -1)
    prev_start = Date.add(prev_end, -6)

    {date_to_utc_range(week_start, today, tz), date_to_utc_range(prev_start, prev_end, tz)}
  end

  defp compute_ranges(:monthly, local_now, tz) do
    today = DateTime.to_date(local_now)
    month_start = Date.new!(today.year, today.month, 1)
    prev_month_end = Date.add(month_start, -1)
    prev_month_start = Date.new!(prev_month_end.year, prev_month_end.month, 1)

    {date_to_utc_range(month_start, today, tz),
     date_to_utc_range(prev_month_start, prev_month_end, tz)}
  end

  defp compute_ranges(_, local_now, tz) do
    compute_ranges(:weekly, local_now, tz)
  end

  defp date_to_utc_range(from, to, tz) do
    case DateTime.new(from, ~T[00:00:00], tz) do
      {:ok, from_dt} ->
        {:ok, to_dt} = DateTime.new(to, ~T[23:59:59], tz)

        %{
          from: DateTime.shift_zone!(from_dt, "Etc/UTC"),
          to: DateTime.shift_zone!(to_dt, "Etc/UTC")
        }

      _ ->
        %{
          from: DateTime.new!(from, ~T[00:00:00]),
          to: DateTime.new!(to, ~T[23:59:59])
        }
    end
  end

  defp fetch_stats(site, user, range) do
    case Analytics.overview_stats(site, user, range) do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  defp fetch_list(fun, limit) do
    case fun.() do
      {:ok, rows} when is_list(rows) -> Enum.take(rows, limit)
      _ -> []
    end
  end
end
