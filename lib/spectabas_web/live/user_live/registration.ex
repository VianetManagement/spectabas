defmodule SpectabasWeb.UserLive.Registration do
  use SpectabasWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> put_flash(:info, "Public registration is disabled. Contact your administrator.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div></div>
    """
  end
end
