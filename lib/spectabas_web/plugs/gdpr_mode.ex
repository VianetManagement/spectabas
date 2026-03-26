defmodule SpectabasWeb.Plugs.GdprMode do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns do
      %{site: %{gdpr_mode: mode}} ->
        gdpr_mode = if mode == "on", do: :on, else: :off
        id_strategy = if gdpr_mode == :on, do: :fingerprint, else: :cookie

        conn
        |> assign(:gdpr_mode, gdpr_mode)
        |> assign(:id_strategy, id_strategy)

      _ ->
        conn
        |> assign(:gdpr_mode, :on)
        |> assign(:id_strategy, :fingerprint)
    end
  end
end
