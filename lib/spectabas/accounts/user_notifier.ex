defmodule Spectabas.Accounts.UserNotifier do
  import Swoosh.Email

  alias Spectabas.Mailer
  alias Spectabas.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Spectabas", "noreply@spectabas.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver an invitation email to a new user.
  """
  def deliver_invitation(%{email: email, token: token, role: role}) do
    url = "https://www.spectabas.com/invitations/#{token}"

    deliver(email, "You've been invited to Spectabas", """

    ==============================

    Hi,

    You've been invited to join Spectabas as a #{role}.

    Accept your invitation by visiting the URL below:

    #{url}

    This invitation expires in 48 hours.

    ==============================
    """)
  end

  @doc """
  Deliver an anomaly alert email (traffic drop or spike).
  """
  def deliver_anomaly_alert(email, %{site_name: site_name, alert_type: alert_type, data: data}) do
    subject =
      case alert_type do
        :traffic_drop -> "[Spectabas] Traffic drop detected on #{site_name}"
        :traffic_spike -> "[Spectabas] Traffic spike detected on #{site_name}"
        _ -> "[Spectabas] Alert on #{site_name}"
      end

    body = """

    ==============================

    Alert: #{format_alert_type(alert_type)}

    Site: #{site_name}

    Details:
    #{format_alert_data(data)}

    View your dashboard at https://www.spectabas.com

    ==============================
    """

    deliver(email, subject, body)
  end

  @doc """
  Deliver an export-ready notification.
  """
  def deliver_export_ready(email, site_name, export_path) do
    deliver(email, "[Spectabas] Your data export is ready", """

    ==============================

    Hi,

    Your data export for #{site_name} is ready for download.

    File: #{export_path}

    Please download it within 24 hours, after which it will be deleted.

    ==============================
    """)
  end

  @doc """
  Deliver a weekly/scheduled report summary.
  """
  def deliver_weekly_report(email, %{site_name: site_name, report_name: report_name, data: data}) do
    deliver(email, "[Spectabas] #{report_name} for #{site_name}", """

    ==============================

    Report: #{report_name}
    Site: #{site_name}

    #{format_report_data(data)}

    View full details at https://www.spectabas.com

    ==============================
    """)
  end

  defp format_alert_type(:traffic_drop), do: "Significant traffic drop detected"
  defp format_alert_type(:traffic_spike), do: "Unusual traffic spike detected"
  defp format_alert_type(other), do: "Alert: #{other}"

  defp format_alert_data(data) when is_map(data) do
    Enum.map_join(data, "\n", fn {k, v} -> "  #{k}: #{v}" end)
  end

  defp format_alert_data(_), do: ""

  defp format_report_data(data) when is_map(data) do
    Enum.map_join(data, "\n", fn {k, v} -> "  #{k}: #{v}" end)
  end

  defp format_report_data(_), do: "No data available."
end
