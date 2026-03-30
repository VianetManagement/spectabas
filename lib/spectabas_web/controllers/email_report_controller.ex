defmodule SpectabasWeb.EmailReportController do
  use SpectabasWeb, :controller

  def unsubscribe(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "email_report_unsub", token, max_age: 30 * 86400) do
      {:ok, subscription_id} ->
        Spectabas.Reports.unsubscribe(subscription_id)

        conn
        |> put_flash(:info, "You have been unsubscribed from email reports.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid or expired unsubscribe link.")
        |> redirect(to: ~p"/")
    end
  end
end
