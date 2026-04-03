defmodule Spectabas.Notifications do
  @moduledoc """
  Notification dispatcher. Looks up relevant users for a site and
  sends alerts or reports via the UserNotifier.
  """

  require Logger
  import Ecto.Query, warn: false

  alias Spectabas.Accounts
  alias Spectabas.Accounts.UserNotifier

  @doc """
  Send an alert about a site anomaly or event.
  Looks up site admins/owners and sends each an alert email.
  """
  def send_alert(site, alert_type, data) do
    recipients = site_admin_emails(site)

    if recipients == [] do
      Logger.warning("[Notifications] No recipients for alert #{alert_type} on site #{site.id}")
      :ok
    else
      Enum.each(recipients, fn email ->
        UserNotifier.deliver_anomaly_alert(email, %{
          site_name: site.name,
          site_domain: site.domain,
          alert_type: alert_type,
          data: data
        })
      end)

      :ok
    end
  end

  @doc """
  Deliver a scheduled report to its recipients.
  """
  def deliver_report(site, report, data) do
    recipients = report.recipients || []

    Enum.each(recipients, fn email ->
      UserNotifier.deliver_weekly_report(email, %{
        site_name: site.name,
        site_domain: site.domain,
        report_name: report.name,
        data: data
      })
    end)

    :ok
  end

  defp site_admin_emails(site) do
    permissions = Accounts.list_site_permissions(site)

    admin_emails =
      permissions
      |> Enum.filter(fn p -> p.role in [:admin, :analyst] end)
      |> Enum.map(fn p -> p.user.email end)

    # Also include superadmins from the site's account
    superadmin_emails =
      Spectabas.Repo.all(
        Ecto.Query.from(u in Spectabas.Accounts.User,
          where: u.account_id == ^site.account_id and u.role == :superadmin
        )
      )
      |> Enum.map(fn u -> u.email end)

    Enum.uniq(admin_emails ++ superadmin_emails)
  end
end
