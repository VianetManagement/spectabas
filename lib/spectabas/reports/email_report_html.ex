defmodule Spectabas.Reports.EmailReportHTML do
  @moduledoc "Renders HTML and text email reports with inline styles."

  import Spectabas.TypeHelpers

  @doc "Returns {html_body, text_body} for the email report."
  def render(data) do
    {html_body(data), text_body(data)}
  end

  defp html_body(data) do
    freq_label = frequency_label(data.frequency)
    period_label = format_date_range(data.current_range)
    stats = data.current_stats
    prev = data.previous_stats

    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
    <body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 0;">
    <tr><td align="center">
    <table width="600" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,0.1);">

    <!-- Header -->
    <tr><td style="background:#4f46e5;padding:24px 32px;">
      <span style="font-size:20px;font-weight:700;color:#fff;">Spectabas</span>
      <span style="font-size:14px;color:#c7d2fe;margin-left:12px;">#{freq_label} Report</span>
    </td></tr>

    <!-- Site + Period -->
    <tr><td style="padding:24px 32px 0;">
      <h2 style="margin:0;font-size:18px;color:#111827;">#{esc(data.site.name)}</h2>
      <p style="margin:4px 0 0;font-size:13px;color:#6b7280;">#{period_label}</p>
    </td></tr>

    <!-- Stats Grid -->
    <tr><td style="padding:20px 32px;">
      <table width="100%" cellpadding="0" cellspacing="0">
      <tr>
        #{stat_cell("Pageviews", stats["pageviews"], prev["pageviews"])}
        #{stat_cell("Visitors", stats["unique_visitors"], prev["unique_visitors"])}
        #{stat_cell("Sessions", stats["total_sessions"], prev["total_sessions"])}
      </tr>
      <tr>
        #{stat_cell("Bounce Rate", stats["bounce_rate"], prev["bounce_rate"], "%", true)}
        #{stat_cell("Avg Duration", stats["avg_duration"], prev["avg_duration"], "s")}
        <td width="33%" style="padding:8px;"></td>
      </tr>
      </table>
    </td></tr>

    <!-- Top Pages -->
    #{section_table("Top Pages", ["Page", "Views", "Visitors"], Enum.map(data.top_pages, fn p -> [esc(p["url_path"] || "/"), p["pageviews"], p["unique_visitors"]] end))}

    <!-- Top Sources -->
    #{section_table("Top Sources", ["Source", "Views", "Sessions"], Enum.map(data.top_sources, fn s -> [esc(s["referrer_domain"] || "Direct"), s["pageviews"], s["sessions"]] end))}

    <!-- Top Countries -->
    #{section_table("Top Countries", ["Country", "Visitors"], Enum.map(data.top_countries, fn c -> [esc(c["ip_country"] || "Unknown"), c["unique_visitors"]] end))}

    <!-- Footer -->
    <tr><td style="padding:24px 32px;border-top:1px solid #e5e7eb;">
      <a href="https://www.spectabas.com/dashboard/sites/#{data.site.id}" style="color:#4f46e5;font-size:13px;text-decoration:none;font-weight:600;">View Full Dashboard &rarr;</a>
      <p style="margin:12px 0 0;font-size:11px;color:#9ca3af;">
        <a href="https://www.spectabas.com/email-reports/unsubscribe/#{data.unsubscribe_token}" style="color:#9ca3af;">Unsubscribe</a>
        from #{freq_label |> String.downcase()} reports for #{esc(data.site.name)}
      </p>
    </td></tr>

    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """
  end

  defp stat_cell(label, current, previous, unit \\ "", invert \\ false) do
    current_val = to_num(current)
    prev_val = to_num(previous)
    display = if unit == "%", do: "#{current_val}#{unit}", else: format_number(current_val)

    delta =
      if prev_val > 0 do
        pct = round((current_val - prev_val) / prev_val * 100)

        color =
          cond do
            pct > 0 && !invert -> "#16a34a"
            pct < 0 && !invert -> "#dc2626"
            pct > 0 && invert -> "#dc2626"
            pct < 0 && invert -> "#16a34a"
            true -> "#6b7280"
          end

        sign = if pct > 0, do: "+", else: ""
        "<span style=\"font-size:11px;color:#{color};\">#{sign}#{pct}%</span>"
      else
        ""
      end

    """
    <td width="33%" style="padding:8px;">
      <div style="background:#f9fafb;border-radius:6px;padding:12px;">
        <div style="font-size:11px;color:#6b7280;text-transform:uppercase;letter-spacing:0.5px;">#{label}</div>
        <div style="font-size:22px;font-weight:700;color:#111827;margin-top:4px;">#{display}</div>
        <div style="margin-top:2px;">#{delta}</div>
      </div>
    </td>
    """
  end

  defp section_table(_title, _headers, []), do: ""

  defp section_table(title, headers, rows) do
    header_html =
      Enum.map_join(headers, "", fn h ->
        align = if h == List.first(headers), do: "left", else: "right"

        "<th style=\"padding:6px 8px;font-size:11px;color:#6b7280;text-transform:uppercase;text-align:#{align};border-bottom:1px solid #e5e7eb;\">#{h}</th>"
      end)

    rows_html =
      Enum.map_join(rows, "", fn cells ->
        cells_html =
          cells
          |> Enum.with_index()
          |> Enum.map_join("", fn {cell, i} ->
            align = if i == 0, do: "left", else: "right"

            style =
              if i == 0,
                do: "font-family:monospace;font-size:12px;color:#4f46e5;",
                else: "font-size:13px;color:#374151;"

            "<td style=\"padding:6px 8px;#{style}text-align:#{align};\">#{cell}</td>"
          end)

        "<tr style=\"border-bottom:1px solid #f3f4f6;\">#{cells_html}</tr>"
      end)

    """
    <tr><td style="padding:16px 32px 0;">
      <h3 style="margin:0 0 8px;font-size:14px;color:#111827;font-weight:600;">#{title}</h3>
      <table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
      <tr>#{header_html}</tr>
      #{rows_html}
      </table>
    </td></tr>
    """
  end

  defp text_body(data) do
    freq_label = frequency_label(data.frequency)
    stats = data.current_stats

    """
    #{freq_label} Report for #{data.site.name}
    #{format_date_range(data.current_range)}

    Pageviews: #{stats["pageviews"] || 0}
    Visitors: #{stats["unique_visitors"] || 0}
    Sessions: #{stats["total_sessions"] || 0}
    Bounce Rate: #{stats["bounce_rate"] || 0}%
    Avg Duration: #{stats["avg_duration"] || 0}s

    Top Pages:
    #{Enum.map_join(data.top_pages, "\n", fn p -> "  #{p["url_path"]} — #{p["pageviews"]} views" end)}

    Top Sources:
    #{Enum.map_join(data.top_sources, "\n", fn s -> "  #{s["referrer_domain"] || "Direct"} — #{s["pageviews"]} views" end)}

    View dashboard: https://www.spectabas.com/dashboard/sites/#{data.site.id}
    Unsubscribe: https://www.spectabas.com/email-reports/unsubscribe/#{data.unsubscribe_token}
    """
  end

  defp frequency_label(:daily), do: "Daily"
  defp frequency_label(:weekly), do: "Weekly"
  defp frequency_label(:monthly), do: "Monthly"
  defp frequency_label(_), do: "Analytics"

  defp format_date_range(%{from: from, to: to}) do
    "#{Calendar.strftime(from, "%b %d, %Y")} — #{Calendar.strftime(to, "%b %d, %Y")}"
  end

  defp esc(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp esc(nil), do: ""
  defp esc(other), do: to_string(other)
end
