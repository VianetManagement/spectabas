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
  slot :inner_block, required: true

  def dashboard_layout(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <%!-- Sidebar --%>
      <aside class="hidden lg:flex lg:flex-col lg:w-60 bg-slate-800 flex-shrink-0">
        <%!-- Site header --%>
        <div class="p-4 border-b border-slate-700">
          <.link navigate={~p"/dashboard"} class="text-xs text-slate-400 hover:text-white">
            &larr; All Sites
          </.link>
          <h2 class="text-sm font-semibold text-white mt-1 truncate">{@site.name}</h2>
          <p class="text-xs text-slate-400 truncate">{@site.domain}</p>
          <div :if={@live_visitors > 0} class="flex items-center gap-1.5 mt-2">
            <span class="w-1.5 h-1.5 bg-green-400 rounded-full animate-pulse"></span>
            <span class="text-xs text-green-300 font-medium">{@live_visitors} online</span>
          </div>
        </div>

        <%!-- Date Controls (only on pages with date state) --%>
        <div :if={@preset} class="p-3 border-b border-slate-700">
          <p class="px-1 text-[10px] font-semibold uppercase tracking-wider text-slate-400 mb-2">
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
                  else: "text-slate-300 bg-slate-700 hover:bg-slate-600"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <div :if={@date_from && @date_to} class="text-xs text-slate-400 px-1 mb-2">
            {Calendar.strftime(@date_from, "%b %d")} - {Calendar.strftime(@date_to, "%b %d, %Y")}
          </div>
          <button
            phx-click="toggle_compare"
            class={[
              "w-full px-2 py-1 text-xs font-medium rounded flex items-center gap-1.5",
              if(@compare,
                do: "bg-indigo-600/20 text-indigo-300 border border-indigo-500/30",
                else: "text-slate-400 bg-slate-700 hover:bg-slate-600"
              )
            ]}
          >
            <span class={[
              "w-3 h-3 rounded-sm border flex items-center justify-center",
              if(@compare,
                do: "bg-indigo-500 border-indigo-500",
                else: "border-slate-500"
              )
            ]}>
              <span :if={@compare} class="text-white text-[8px]">&#10003;</span>
            </span>
            Compare to previous period
          </button>
        </div>

        <%!-- Navigation --%>
        <nav class="flex-1 p-3 space-y-0.5 overflow-y-auto">
          <.nav_section label="Overview">
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}"}
              label="Dashboard"
              active={@active == "overview"}
            />
            <.nav_item
              to={~p"/dashboard/sites/#{@site.id}/realtime"}
              label="Realtime"
              active={@active == "realtime"}
            />
          </.nav_section>

          <.nav_section label="Behavior">
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
          </.nav_section>

          <.nav_section label="Acquisition">
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

          <.nav_section label="Audience">
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

          <.nav_section label="Conversions">
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
        <div :if={@page_title} class="bg-white border-b border-gray-200 px-6 py-4">
          <h1 class="text-xl font-bold text-gray-900">{@page_title}</h1>
          <p :if={@page_description} class="text-sm text-gray-500 mt-1 max-w-3xl">
            {@page_description}
          </p>
        </div>

        <%!-- Mobile breadcrumb --%>
        <div class="lg:hidden bg-white border-b border-gray-200 px-4 py-2 flex items-center gap-3 overflow-x-auto">
          <.link navigate={~p"/dashboard"} class="text-xs text-gray-500 whitespace-nowrap">
            Sites
          </.link>
          <span class="text-gray-300">/</span>
          <span class="text-xs text-gray-700 font-medium whitespace-nowrap">{@site.name}</span>
          <span class="text-gray-300">/</span>
          <span class="text-xs text-indigo-600 font-medium whitespace-nowrap">
            {@page_title || @active}
          </span>
        </div>

        <main class="flex-1 overflow-y-auto bg-gray-50">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  defp nav_section(assigns) do
    ~H"""
    <div class="pt-3 first:pt-0">
      <p class="px-2 text-[10px] font-semibold uppercase tracking-wider text-slate-400 mb-1">
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
          do: "bg-indigo-600 text-white font-medium",
          else: "text-slate-300 hover:text-white hover:bg-slate-700"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end
end
