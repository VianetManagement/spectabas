defmodule Spectabas.Workers.AIWeeklyEmail do
  @moduledoc """
  Sends weekly AI-generated insight emails for sites with AI configured.
  Runs Monday at 9am UTC via Oban cron.
  """

  use Oban.Worker, queue: :mailer, max_attempts: 2

  require Logger

  alias Spectabas.{Repo, Sites}
  alias Spectabas.AI.{Config, Completion, InsightsPrompt, InsightsCache}
  alias Spectabas.Reports
  import Ecto.Query

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(_job) do
    # Sites with AI configured AND auto_generate enabled. The cron only
    # touches sites that have explicitly opted in via Settings → Content.
    sites =
      Repo.all(from(s in Sites.Site, where: not is_nil(s.ai_config_encrypted)))
      |> Enum.filter(&Config.auto_generate?/1)

    Enum.each(sites, fn site ->
      try do
        run_for_site(site)
      rescue
        e ->
          Logger.error("[AIWeeklyEmail] Failed for site #{site.id}: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp run_for_site(site) do
    # Always regenerate on the schedule — the cache exists for ad-hoc views,
    # but the weekly run is the user's signal that they want fresh analysis.
    case generate_analysis(site) do
      nil ->
        Logger.warning("[AIWeeklyEmail] No analysis generated for site #{site.id}")

      analysis ->
        if Config.email_enabled?(site) do
          email_subscribers(site, analysis)
        else
          Logger.info(
            "[AIWeeklyEmail] Generated for site #{site.id}, email disabled — cache only"
          )
        end
    end
  end

  defp email_subscribers(site, analysis) do
    subscribers = Reports.weekly_subscribers(site.id)

    if subscribers == [] do
      Logger.info("[AIWeeklyEmail] No subscribers for site #{site.id}")
    else
      Enum.each(subscribers, fn user -> send_email(user, site, analysis) end)
      Logger.info("[AIWeeklyEmail] Sent to #{length(subscribers)} users for site #{site.id}")
    end
  end

  defp generate_analysis(site) do
    user = find_site_admin(site)

    if user do
      prompt = InsightsPrompt.build(site, user)
      system = InsightsPrompt.system_prompt()

      case Completion.generate(site, system, prompt, max_tokens: 8192) do
        {:ok, text} ->
          {provider, _key, model} = Config.credentials(site)
          InsightsCache.put(site.id, text, provider, model)
          text

        {:error, reason} ->
          Logger.warning("[AIWeeklyEmail] AI generation failed: #{reason}")
          nil
      end
    else
      Logger.warning("[AIWeeklyEmail] No admin user found for site #{site.id}")
      nil
    end
  end

  defp find_site_admin(site) do
    Repo.one(
      from(u in Spectabas.Accounts.User,
        where: u.account_id == ^site.account_id and u.role in [:superadmin, :platform_admin],
        limit: 1
      )
    )
  end

  defp send_email(user, site, analysis) do
    subject = "#{site.name} — Weekly AI Insights"

    html = render_html(site, analysis)
    text = render_text(site, analysis)

    Spectabas.Accounts.UserNotifier.deliver_report_email(
      user.email,
      subject,
      html,
      text
    )
  end

  defp render_html(site, analysis) do
    # Convert markdown to simple HTML
    body_html =
      analysis
      |> String.split("\n")
      |> Enum.map(fn line ->
        line = String.trim_trailing(line)

        cond do
          String.starts_with?(line, "## ") ->
            "<h2 style=\"color:#1f2937;font-size:18px;margin:20px 0 8px;border-bottom:1px solid #e5e7eb;padding-bottom:6px;\">#{esc(String.trim_leading(line, "## "))}</h2>"

          String.starts_with?(line, "# ") ->
            "<h1 style=\"color:#1f2937;font-size:22px;margin:16px 0 8px;\">#{esc(String.trim_leading(line, "# "))}</h1>"

          String.match?(line, ~r/^\d+\.\s/) ->
            "<p style=\"color:#374151;font-size:14px;margin:4px 0 4px 16px;\">#{bold(esc(line))}</p>"

          String.starts_with?(line, "- ") ->
            "<p style=\"color:#374151;font-size:14px;margin:4px 0 4px 16px;\">&bull; #{bold(esc(String.trim_leading(line, "- ")))}</p>"

          line == "" ->
            ""

          true ->
            "<p style=\"color:#374151;font-size:14px;margin:6px 0;\">#{bold(esc(line))}</p>"
        end
      end)
      |> Enum.join("\n")

    """
    <div style="max-width:600px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;padding:20px;">
      <div style="background:#4f46e5;color:white;padding:20px;border-radius:8px 8px 0 0;">
        <h1 style="margin:0;font-size:20px;">Weekly AI Insights</h1>
        <p style="margin:4px 0 0;opacity:0.9;font-size:14px;">#{esc(site.name)}</p>
      </div>
      <div style="background:white;padding:24px;border:1px solid #e5e7eb;border-top:none;border-radius:0 0 8px 8px;">
        #{body_html}
        <div style="margin-top:24px;padding-top:16px;border-top:1px solid #e5e7eb;">
          <a href="https://www.spectabas.com/dashboard/sites/#{site.id}/insights"
             style="display:inline-block;background:#4f46e5;color:white;padding:8px 16px;border-radius:6px;text-decoration:none;font-size:14px;">
            View Full Insights
          </a>
        </div>
      </div>
      <p style="color:#9ca3af;font-size:12px;margin-top:16px;text-align:center;">
        Powered by AI analysis of your Spectabas analytics data.
      </p>
    </div>
    """
  end

  defp render_text(site, analysis) do
    "#{site.name} — Weekly AI Insights\n\n#{analysis}\n\nView full insights: https://www.spectabas.com/dashboard/sites/#{site.id}/insights"
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp bold(text) do
    String.replace(text, ~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
  end
end
