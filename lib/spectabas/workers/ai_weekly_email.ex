defmodule Spectabas.Workers.AIWeeklyEmail do
  @moduledoc """
  Generates and emails the weekly AI insights for sites that have opted in.
  Runs Monday at 9am UTC via Oban cron.

  Modes:
  - no args → meta-job: enqueue a per-site job for every site with
    auto_generate enabled
  - `%{"site_id" => N}` → per-site job: generate the analysis, cache it,
    and (if email_enabled) send to every weekly subscriber

  Per-site jobs let one slow site (AI generation can take 60-120s) not
  block the others.
  """

  use Oban.Worker, queue: :mailer, max_attempts: 2

  require Logger

  alias Spectabas.{Repo, Sites}
  alias Spectabas.AI.{Config, Completion, InsightsPrompt, InsightsCache}
  alias Spectabas.Reports
  import Ecto.Query

  # AI generation alone can take 60-120s; add prompt-building (CH queries) on
  # top, plus email sending. 10 minutes is a generous safety margin.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(600)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    case Sites.get_site(site_id) do
      nil ->
        :ok

      site ->
        if Config.auto_generate?(site) do
          run_for_site(site)
        else
          # auto_generate was toggled off between meta-job and per-site job
          :ok
        end
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    sites_with_auto_generate()
    |> Enum.each(fn site ->
      __MODULE__.new(%{"site_id" => site.id}) |> Oban.insert()
    end)

    :ok
  end

  defp sites_with_auto_generate do
    Repo.all(from(s in Sites.Site, where: not is_nil(s.ai_config_encrypted)))
    |> Enum.filter(&Config.auto_generate?/1)
  end

  defp run_for_site(site) do
    Logger.notice("[AIWeeklyEmail] Starting site=#{site.id}")

    case generate_analysis(site) do
      nil ->
        Logger.warning("[AIWeeklyEmail] No analysis generated for site=#{site.id}")
        {:error, :no_analysis}

      analysis ->
        if Config.email_enabled?(site) do
          email_subscribers(site, analysis)
        else
          Logger.notice("[AIWeeklyEmail] Generated site=#{site.id}, email disabled — cache only")
        end

        :ok
    end
  end

  defp email_subscribers(site, analysis) do
    subscribers = Reports.weekly_subscribers(site.id)

    if subscribers == [] do
      Logger.notice("[AIWeeklyEmail] No subscribers for site=#{site.id}")
    else
      Enum.each(subscribers, fn user -> send_email(user, site, analysis) end)
      Logger.notice("[AIWeeklyEmail] Sent site=#{site.id} to #{length(subscribers)} users")
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
          Logger.warning("[AIWeeklyEmail] AI generation failed site=#{site.id}: #{reason}")
          nil
      end
    else
      Logger.warning("[AIWeeklyEmail] No admin user found for site=#{site.id}")
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
    body_html = Spectabas.AI.MarkdownEmail.render(analysis)

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
end
