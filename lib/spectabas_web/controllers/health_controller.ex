defmodule SpectabasWeb.HealthController do
  use SpectabasWeb, :controller

  def show(conn, _params) do
    case Spectabas.Health.check() do
      :ok ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error", reason: reason})
    end
  end
end
