defmodule SpectabasWeb.Dashboard.SidebarComponent do
  @moduledoc """
  Shared sidebar navigation for all site dashboard pages.
  Includes optional date controls and page descriptions.
  """
  use SpectabasWeb, :html

  attr :site, :map, required: true
  attr :active, :string, default: "overview"
  attr :live_visitors, :integer, default: 0
  attr :preset, :string, default: nil
  attr :date_from, :any, default: nil
  attr :date_to, :any, default: nil
  attr :compare, :boolean, default: false
  attr :page_title, :string, default: nil
  attr :page_description, :string, default: nil
  attr :flash, :map, default: %{}
  slot :inner_block, required: true

  def dashboard_layout(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-48px)] sm:min-h-[calc(100vh-56px)]">
      <%!-- Sidebar --%>
      <aside class="hidden lg:flex lg:flex-col lg:w-60 bg-white border-r border-gray-200 flex-shrink-0">
        <%!-- Site header --%>
        <div class="p-4 border-b border-gray-200">
          <.link navigate={~p"/dashboard"} class="text-xs text-gray-500 hover:text-indigo-600">
            &larr; All Sites
          </.link>
          <h2 class="text-sm font-semibold text-gray-900 mt-1 truncate">{@site.name}</h2>
          <p class="text-xs text-gray-500 truncate">{@site.domain}</p>
          <div :if={@live_visitors > 0} class="flex items-center gap-1.5 mt-2">
            <span class="w-1.5 h-1.5 bg-green-500 rounded-full animate-pulse"></span>
            <span class="text-xs text-green-700 font-medium">{@live_visitors} online</span>
          </div>
        </div>

        <%!-- Date Controls (only on pages with date state) --%>
        <div :if={@preset} class="p-3 border-b border-gray-200">
          <p class="px-1 text-[10px] font-semibold uppercase tracking-wider text-gray-400 mb-2">
            Time Period
          </p>
          <div class="flex flex-wrap gap-1 mb-2">
            <button
              :for={
                {id, label} <- [
                  {"24h", "24h"},
                  {"7d", "7d"},
                  {"30d", "30d"},
                  {"90d", "90d"},
                  {"12m", "12m"}
                ]
              }
              phx-click="preset"
              phx-value-range={id}
              class={[
                "px-2 py-1 text-xs font-medium rounded",
                if(@preset == id,
                  do: "bg-indigo-600 text-white",
                  else: "text-gray-600 bg-gray-100 hover:bg-gray-200"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <div :if={@date_from && @date_to} class="text-xs text-gray-500 px-1 mb-2">
            {Calendar.strftime(@date_from, "%b %d")} - {Calendar.strftime(@date_to, "%b %d, %Y")}
          </div>
          <button
            phx-click="toggle_compare"
            class={[
              "w-full px-2 py-1.5 text-xs font-medium rounded flex items-center gap-1.5",
              if(@compare,
                do: "bg-indigo-50 text-indigo-700 border border-indigo-200",
                else: "text-gray-500 bg-gray-50 hover:bg-gray-100 border border-gray-200"
              )
            ]}
          >
            <span class={[
              "w-3 h-3 rounded-sm border flex items-center justify-center",
              if(@compare,
                do: "bg-indigo-600 border-indigo-600",
                else: "border-gray-300 bg-white"
              )
            ]}>
              <span :if={@compare} class="text-white text-[8px]">&#10003;</span>
            </span>
            Compare to previous period
          </button>
        </div>

        <%!-- Navigation --%>
        <nav class="flex-1 p-3 space-y-0.5 overflow-y-auto">
          <.nav_section label="Overview" color="text-indigo-500">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}"}
              label="Dashboard"
              active={@active == "overview"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/insights"}
              label="Insights"
              active={@active == "insights"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/journeys"}
              label="Journeys"
              active={@active == "journeys"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/realtime"}
              label="Realtime"
              active={@active == "realtime"}
            />
          </.nav_section>

          <.nav_section label="Behavior" color="text-blue-500">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/pages"}
              label="Pages"
              active={@active == "pages"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/entry-exit"}
              label="Entry / Exit"
              active={@active == "entry-exit"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/transitions"}
              label="Transitions"
              active={@active == "transitions"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/search"}
              label="Site Search"
              active={@active == "search"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/outbound-links"}
              label="Outbound Links"
              active={@active == "outbound-links"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/downloads"}
              label="Downloads"
              active={@active == "downloads"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/events"}
              label="Events"
              active={@active == "events"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/performance"}
              label="Performance"
              active={@active == "performance"}
            />
          </.nav_section>

          <.nav_section label="Acquisition" color="text-emerald-500">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/channels"}
              label="All Channels"
              active={@active == "channels"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/sources"}
              label="Sources"
              active={@active == "sources"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/attribution"}
              label="Attribution"
              active={@active == "attribution"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/campaigns"}
              label="Campaigns"
              active={@active == "campaigns"}
            />
          </.nav_section>

          <.nav_section label="Audience" color="text-amber-500">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/geo"}
              label="Geography"
              active={@active == "geo"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/map"}
              label="Visitor Map"
              active={@active == "map"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/devices"}
              label="Devices"
              active={@active == "devices"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/network"}
              label="Network"
              active={@active == "network"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/bot-traffic"}
              label="Bot Traffic"
              active={@active == "bot-traffic"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/visitor-log"}
              label="Visitor Log"
              active={@active == "visitor-log"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/cohort"}
              label="Retention"
              active={@active == "cohort"}
            />
          </.nav_section>

          <.nav_section label="Conversions" color="text-rose-500">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/goals"}
              label="Goals"
              active={@active == "goals"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/funnels"}
              label="Funnels"
              active={@active == "funnels"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/ecommerce"}
              label="Ecommerce"
              active={@active == "ecommerce"}
            />
          </.nav_section>

          <.nav_section label="Tools">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/reports"}
              label="Reports"
              active={@active == "reports"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/email-reports"}
              label="Email Reports"
              active={@active == "email-reports"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/exports"}
              label="Exports"
              active={@active == "exports"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/settings"}
              label="Settings"
              active={@active == "settings"}
            />
          </.nav_section>
        </nav>
      </aside>

      <%!-- Main content area --%>
      <div class="flex-1 flex flex-col min-w-0">
        <%!-- Page header with title + description --%>
        <div :if={@page_title} class="hidden lg:block bg-white border-b border-gray-200 px-6 py-4">
          <h1 class="text-xl font-bold text-gray-900">{@page_title}</h1>
          <p :if={@page_description} class="text-sm text-gray-500 mt-1 max-w-3xl">
            {@page_description}
          </p>
        </div>

        <%!-- Mobile header + navigation --%>
        <div class="lg:hidden">
          <div class="bg-white border-b border-gray-200 px-4 py-2.5 flex items-center justify-between">
            <div class="flex items-center gap-2 min-w-0">
              <.link navigate={~p"/dashboard"} class="text-gray-500 hover:text-gray-700 shrink-0">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15 19l-7-7 7-7"
                  />
                </svg>
              </.link>
              <span class="text-sm font-medium text-gray-900 truncate">{@page_title || @active}</span>
            </div>
            <%!-- Mobile quick-nav links --%>
            <div class="flex items-center gap-0.5 shrink-0 overflow-x-auto">
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}"}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <> if(@active == "overview", do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600")}
              >
                Home
              </.link>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/pages"}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <> if(@active == "pages", do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600")}
              >
                Pages
              </.link>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/sources"}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <> if(@active == "sources", do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600")}
              >
                Sources
              </.link>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/visitor-log"}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <> if(@active == "visitor-log", do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600")}
              >
                Visitors
              </.link>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/geo"}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <> if(@active == "geo", do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600")}
              >
                Geo
              </.link>
            </div>
          </div>
          <%!-- Mobile: scrollable secondary nav with scroll indicator --%>
          <div class="relative">
            <div
              class="bg-gray-50 border-b border-gray-200 px-3 py-1 overflow-x-auto flex gap-1"
              role="navigation"
              aria-label="Dashboard pages"
            >
              <.link
                :for={{path, label} <- mobile_nav_items(@site.id)}
                navigate={path}
                class={"px-2.5 py-2 sm:px-2 sm:py-1 text-xs rounded whitespace-nowrap " <>
                  if(String.ends_with?(path, "/" <> @active) || (@active == "overview" && String.ends_with?(path, to_string(@site.id))),
                    do: "bg-indigo-100 text-indigo-700 font-medium",
                    else: "text-gray-600 hover:text-gray-700"
                  )}
              >
                {label}
              </.link>
            </div>
            <div class="absolute right-0 top-0 bottom-0 w-8 bg-gradient-to-l from-gray-50 pointer-events-none lg:hidden">
            </div>
          </div>
        </div>

        <main class="flex-1 overflow-y-auto bg-gray-50">
          <div
            :if={@flash["info"]}
            id="flash-info"
            class="mx-4 mt-4 rounded-lg bg-green-50 border border-green-200 p-4 text-sm text-green-800 flex items-center justify-between transition-opacity duration-500"
            phx-click={
              Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: "info"})
              |> Phoenix.LiveView.JS.hide(to: "#flash-info")
            }
            phx-hook="AutoDismiss"
          >
            <span>{@flash["info"]}</span>
            <button type="button" class="text-green-600 hover:text-green-800 ml-4">&times;</button>
          </div>
          <div
            :if={@flash["error"]}
            id="flash-error"
            class="mx-4 mt-4 rounded-lg bg-red-50 border border-red-200 p-4 text-sm text-red-800 flex items-center justify-between"
            phx-click={
              Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: "error"})
              |> Phoenix.LiveView.JS.hide(to: "#flash-error")
            }
          >
            <span>{@flash["error"]}</span>
            <button type="button" class="text-red-600 hover:text-red-800 ml-4">&times;</button>
          </div>
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  defp mobile_nav_items(site_id) do
    [
      {~p"/dashboard/sites/#{site_id}", "Dashboard"},
      {~p"/dashboard/sites/#{site_id}/insights", "Insights"},
      {~p"/dashboard/sites/#{site_id}/journeys", "Journeys"},
      {~p"/dashboard/sites/#{site_id}/realtime", "Realtime"},
      {~p"/dashboard/sites/#{site_id}/pages", "Pages"},
      {~p"/dashboard/sites/#{site_id}/entry-exit", "Entry/Exit"},
      {~p"/dashboard/sites/#{site_id}/transitions", "Transitions"},
      {~p"/dashboard/sites/#{site_id}/search", "Search"},
      {~p"/dashboard/sites/#{site_id}/outbound-links", "Outbound Links"},
      {~p"/dashboard/sites/#{site_id}/downloads", "Downloads"},
      {~p"/dashboard/sites/#{site_id}/events", "Events"},
      {~p"/dashboard/sites/#{site_id}/performance", "Performance"},
      {~p"/dashboard/sites/#{site_id}/channels", "Channels"},
      {~p"/dashboard/sites/#{site_id}/sources", "Sources"},
      {~p"/dashboard/sites/#{site_id}/attribution", "Attribution"},
      {~p"/dashboard/sites/#{site_id}/campaigns", "Campaigns"},
      {~p"/dashboard/sites/#{site_id}/geo", "Geography"},
      {~p"/dashboard/sites/#{site_id}/map", "Map"},
      {~p"/dashboard/sites/#{site_id}/devices", "Devices"},
      {~p"/dashboard/sites/#{site_id}/network", "Network"},
      {~p"/dashboard/sites/#{site_id}/bot-traffic", "Bots"},
      {~p"/dashboard/sites/#{site_id}/visitor-log", "Visitors"},
      {~p"/dashboard/sites/#{site_id}/cohort", "Retention"},
      {~p"/dashboard/sites/#{site_id}/goals", "Goals"},
      {~p"/dashboard/sites/#{site_id}/funnels", "Funnels"},
      {~p"/dashboard/sites/#{site_id}/ecommerce", "Ecommerce"},
      {~p"/dashboard/sites/#{site_id}/email-reports", "Email Reports"},
      {~p"/dashboard/sites/#{site_id}/settings", "Settings"}
    ]
  end

  defp nav_section(assigns) do
    assigns = Map.put_new(assigns, :color, "text-gray-400")

    ~H"""
    <div class="pt-4 first:pt-0">
      <p class={["px-2 text-[10px] font-bold uppercase tracking-wider mb-1", @color]}>
        {@label}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "flex items-center px-2 py-1.5 text-sm rounded-md transition-colors",
        if(@active,
          do: "bg-indigo-50 text-indigo-700 font-medium",
          else: "text-gray-600 hover:text-gray-900 hover:bg-gray-50"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end
end
