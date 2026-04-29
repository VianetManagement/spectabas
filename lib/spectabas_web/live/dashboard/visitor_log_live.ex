defmodule SpectabasWeb.Dashboard.VisitorLogLive do
  use SpectabasWeb, :live_view

  @moduledoc "Visitor log — browsable session list with filtering."

  alias Spectabas.{Accounts, Sites, Analytics, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @per_page 30
  @sortable_cols ~w(last_seen first_seen pageviews duration)

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      # Accept filter from URL (e.g., from network page ASN click)
      segment =
        case {params["filter_field"], params["filter_value"]} do
          {f, v} when is_binary(f) and is_binary(v) and f != "" and v != "" ->
            [%{"field" => f, "op" => "is", "value" => v}]

          _ ->
            []
        end

      ip_search = params["ip"] || ""

      socket =
        socket
        |> assign(:page_title, "Visitor Log - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:cursor, nil)
        |> assign(:cursor_stack, [])
        |> assign(:page_num, 0)
        |> assign(:sort_by, "last_seen")
        |> assign(:sort_dir, "desc")
        |> assign(:segment, segment)
        |> assign(:search_query, ip_search)
        |> assign(:ip_search, ip_search)
        |> assign(:ip_results, nil)
        |> assign(:ip_info, nil)
        |> assign(:visitor_results, nil)
        |> assign(:loading, true)
        |> assign(:visitors, [])
        |> assign(:next_cursor, nil)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:date_range, range)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> assign(:page_num, 0)
     |> assign(:loading, true)}
  end

  def handle_event("sort", %{"col" => col}, socket) when col in @sortable_cols do
    # Clicking the current sort column toggles direction; clicking a different
    # one switches to it with the "most useful" default (desc for all columns
    # — top pageviews, most recent last_seen, longest duration, etc.).
    new_dir =
      cond do
        col == socket.assigns.sort_by and socket.assigns.sort_dir == "desc" -> "asc"
        col == socket.assigns.sort_by -> "desc"
        true -> "desc"
      end

    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:sort_by, col)
     |> assign(:sort_dir, new_dir)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> assign(:page_num, 0)
     |> assign(:loading, true)}
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("next_page", _params, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:cursor_stack, [socket.assigns.cursor | socket.assigns.cursor_stack])
     |> assign(:cursor, socket.assigns.next_cursor)
     |> assign(:page_num, socket.assigns.page_num + 1)
     |> assign(:loading, true)}
  end

  def handle_event("prev_page", _params, socket) do
    {prev_cursor, rest} =
      case socket.assigns.cursor_stack do
        [head | tail] -> {head, tail}
        [] -> {nil, []}
      end

    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:cursor, prev_cursor)
     |> assign(:cursor_stack, rest)
     |> assign(:page_num, max(socket.assigns.page_num - 1, 0))
     |> assign(:loading, true)}
  end

  # Unified search: accepts IP, email, visitor UUID, or partial email/user_id/cookie_id.
  # Auto-detects from the input shape.
  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q)

    cond do
      q == "" ->
        {:noreply, clear_search(socket)}

      uuid?(q) ->
        # Direct hit on a visitor profile.
        case Visitors.search(socket.assigns.site.id, q) do
          [visitor | _] ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/dashboard/sites/#{socket.assigns.site.id}/visitors/#{visitor.id}"
             )}

          [] ->
            {:noreply,
             socket
             |> assign(:search_query, q)
             |> clear_search_results()
             |> assign(:visitor_results, [])
             |> put_flash(:error, "No visitor with that ID on this site.")}
        end

      ip?(q) ->
        socket = handle_ip_search(socket, q)
        {:noreply, assign(socket, :search_query, q)}

      true ->
        results = Visitors.search(socket.assigns.site.id, q)

        {:noreply,
         socket
         |> assign(:search_query, q)
         |> clear_search_results()
         |> assign(:visitor_results, results)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, clear_search(socket)}
  end

  defp clear_search(socket) do
    socket
    |> assign(:search_query, "")
    |> clear_search_results()
  end

  defp clear_search_results(socket) do
    socket
    |> assign(:ip_search, "")
    |> assign(:ip_results, nil)
    |> assign(:ip_info, nil)
    |> assign(:visitor_results, nil)
  end

  defp handle_ip_search(socket, ip) do
    results =
      case Analytics.visitors_by_ip(socket.assigns.site, ip) do
        {:ok, rows} -> rows
        _ -> []
      end

    ip_info =
      case Analytics.ip_details(socket.assigns.site, ip) do
        {:ok, info} -> info
        _ -> nil
      end

    socket
    |> assign(:ip_search, ip)
    |> assign(:ip_results, results)
    |> assign(:ip_info, ip_info)
    |> assign(:visitor_results, nil)
  end

  defp uuid?(s),
    do:
      Regex.match?(
        ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
        s
      )

  defp ip?(s) do
    case :inet.parse_address(String.to_charlist(s)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp load_data(socket) do
    %{
      site: site,
      user: user,
      date_range: range,
      cursor: cursor,
      sort_by: sort_by,
      sort_dir: sort_dir,
      segment: segment
    } = socket.assigns

    {visitors, next_cursor} =
      case Analytics.visitor_log(site, user, range_to_period(range),
             cursor: cursor,
             per_page: @per_page,
             sort_by: sort_by,
             sort_dir: sort_dir,
             segment: segment
           ) do
        {:ok, rows, nc} -> {rows, nc}
        _ -> {[], nil}
      end

    # Enrich with emails from Postgres
    email_map = Visitors.emails_for_visitor_ids(Enum.map(visitors, & &1["visitor_id"]))

    visitors =
      Enum.map(visitors, fn v ->
        case Map.get(email_map, v["visitor_id"]) do
          %{email: email} -> Map.put(v, "email", email)
          _ -> v
        end
      end)

    socket
    |> assign(:visitors, visitors)
    |> assign(:next_cursor, next_cursor)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Visitor Log"
      page_description="Browse individual visitor sessions with location, device, and traffic source."
      active="visitor-log"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Log</h1>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}]}
              phx-click="change_range"
              phx-value-range={elem(r, 0)}
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-md",
                if(@date_range == elem(r, 0),
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {elem(r, 1)}
            </button>
          </nav>
        </div>

        <%!-- Unified Visitor Search (IP, email, or UUID) --%>
        <div class="bg-white rounded-lg shadow p-4 mb-6">
          <form phx-submit="search" class="flex flex-wrap items-center gap-3">
            <label class="text-sm font-medium text-gray-700">Find visitor</label>
            <input
              type="text"
              name="q"
              value={@search_query}
              placeholder="IP, email, or visitor UUID"
              class="rounded-lg border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500 py-2 px-3 w-full sm:w-80"
              autocomplete="off"
            />
            <button
              type="submit"
              class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
            >
              Search
            </button>
            <button
              :if={@search_query != ""}
              type="button"
              phx-click="clear_search"
              class="text-sm text-gray-500 hover:text-gray-700"
            >
              Clear
            </button>
            <p class="basis-full text-xs text-gray-500 mt-1">
              Pasting a UUID jumps straight to that visitor's profile. Email or partial match returns identified visitors. IP shows everyone who used that address.
            </p>
          </form>
        </div>

        <%!-- Email / UUID search results --%>
        <div :if={@visitor_results != nil} class="bg-white rounded-lg shadow overflow-x-auto mb-6">
          <div class="px-6 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">
              {length(@visitor_results)} visitor{if length(@visitor_results) == 1, do: "", else: "s"} matching
              <span class="font-mono text-indigo-600">{@search_query}</span>
            </h3>
          </div>
          <div :if={@visitor_results == []} class="px-6 py-8 text-center text-sm text-gray-500">
            No visitors matching that email or ID on this site.
          </div>
          <table :if={@visitor_results != []} class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Email
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Seen
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Status
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={v <- @visitor_results} class="hover:bg-gray-50">
                <td class="px-6 py-3 text-sm">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v.id}"}
                    class="font-mono text-indigo-600 hover:text-indigo-800 hover:underline"
                  >
                    {String.slice(v.id, 0, 12)}...
                  </.link>
                </td>
                <td class="px-6 py-3 text-sm text-gray-700">
                  <span :if={v.email}>{v.email}</span>
                  <span :if={!v.email && v.user_id} class="text-gray-500">{v.user_id}</span>
                  <span :if={!v.email && !v.user_id} class="text-gray-400">—</span>
                </td>
                <td class="px-6 py-3 text-xs text-gray-500 whitespace-nowrap">
                  {v.last_seen_at && Calendar.strftime(v.last_seen_at, "%Y-%m-%d %H:%M")}
                </td>
                <td class="px-6 py-3 text-xs">
                  <span
                    :if={v.scraper_whitelisted}
                    class="inline-flex items-center px-2 py-0.5 rounded bg-emerald-100 text-emerald-800 font-semibold"
                  >
                    Whitelisted
                  </span>
                  <span
                    :if={!v.scraper_whitelisted && v.scraper_manual_flag}
                    class="inline-flex items-center px-2 py-0.5 rounded bg-red-100 text-red-800 font-semibold"
                  >
                    Manual scraper
                  </span>
                  <span
                    :if={
                      !v.scraper_whitelisted && !v.scraper_manual_flag && v.scraper_webhook_sent_at
                    }
                    class="inline-flex items-center px-2 py-0.5 rounded bg-amber-100 text-amber-800"
                  >
                    Flagged (auto)
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- IP Search Results --%>
        <div :if={@ip_results != nil} class="bg-white rounded-lg shadow overflow-x-auto mb-6">
          <div class="px-6 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">
              IP:
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/ip/#{@ip_search}"}
                class="font-mono text-indigo-600 hover:text-indigo-800 hover:underline"
              >
                {@ip_search}
              </.link>
            </h3>
            <div :if={@ip_info} class="flex flex-wrap gap-3 mt-2 text-sm text-gray-600">
              <span :if={@ip_info["city"] && @ip_info["city"] != ""}>
                {[@ip_info["city"], @ip_info["region"], @ip_info["country"]]
                |> Enum.reject(&(&1 == "" || is_nil(&1)))
                |> Enum.join(", ")}
              </span>
              <span :if={@ip_info["org"] && @ip_info["org"] != ""} class="text-xs text-gray-500">
                {@ip_info["org"]}
              </span>
              <span
                :if={@ip_info["is_datacenter"] == "1"}
                class="text-xs bg-orange-100 text-orange-700 px-1.5 py-0.5 rounded"
              >
                Datacenter
              </span>
              <span
                :if={@ip_info["is_vpn"] == "1"}
                class="text-xs bg-yellow-100 text-yellow-700 px-1.5 py-0.5 rounded"
              >
                VPN
              </span>
              <span
                :if={@ip_info["is_bot"] == "1"}
                class="text-xs bg-red-100 text-red-700 px-1.5 py-0.5 rounded"
              >
                Bot
              </span>
            </div>
            <p class="text-xs text-gray-500 mt-1">{length(@ip_results)} visitor(s) found</p>
          </div>
          <table :if={@ip_results != []} class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  First Seen
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Seen
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Browser / OS
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={v <- @ip_results} class="hover:bg-gray-50">
                <td class="px-6 py-3 text-sm">
                  <.link
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}?ip=#{@ip_search}"
                    }
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {String.slice(v["visitor_id"] || "", 0, 12)}...
                  </.link>
                </td>
                <td class="px-6 py-3 text-sm text-gray-500">{v["first_seen"]}</td>
                <td class="px-6 py-3 text-sm text-gray-500">{v["last_seen"]}</td>
                <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(v["pageviews"]))}
                </td>
                <td class="px-6 py-3 text-sm text-gray-500">
                  {v["browser"]} / {v["os"]}
                </td>
              </tr>
            </tbody>
          </table>
          <div :if={@ip_results == []} class="px-6 py-8 text-center text-gray-500 text-sm">
            No visitors found for this IP address.
          </div>
        </div>

        <%!-- Main Visitor Log --%>
        <div :if={@loading} class="flex items-center justify-center py-12 text-gray-400">
          <.death_star_spinner class="w-8 h-8" />
        </div>

        <div :if={!@loading}>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Visitor
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden sm:table-cell">
                    Intent
                  </th>
                  <th
                    class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-700 select-none"
                    phx-click="sort"
                    phx-value-col="pageviews"
                  >
                    Pages {sort_arrow("pageviews", @sort_by, @sort_dir)}
                  </th>
                  <th
                    class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-700 select-none hidden sm:table-cell"
                    phx-click="sort"
                    phx-value-col="duration"
                  >
                    Duration {sort_arrow("duration", @sort_by, @sort_dir)}
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Location
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                    Device
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden lg:table-cell">
                    Source
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                    Entry
                  </th>
                  <th
                    class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-700 select-none"
                    phx-click="sort"
                    phx-value-col="last_seen"
                  >
                    Last Seen {sort_arrow("last_seen", @sort_by, @sort_dir)}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@visitors == []}>
                  <td colspan="9" class="px-4 py-8 text-center text-gray-500">
                    No visitors for this period.
                  </td>
                </tr>
                <tr :for={v <- @visitors} class="hover:bg-gray-50">
                  <td class="px-4 py-3 text-sm">
                    <.link
                      navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                      class="text-indigo-600 hover:text-indigo-800 text-xs"
                    >
                      <span :if={v["email"]} class="font-medium">{v["email"]}</span>
                      <span :if={!v["email"]} class="font-mono">
                        {String.slice(v["visitor_id"] || "", 0, 8)}...
                      </span>
                    </.link>
                  </td>
                  <td class="px-4 py-3 hidden sm:table-cell">
                    <.link
                      :if={v["intent"] && v["intent"] != ""}
                      navigate={
                        ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=visitor_intent&filter_value=#{v["intent"]}"
                      }
                      class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                        intent_pill(v["intent"])
                      ]}
                    >
                      {v["intent"]}
                    </.link>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 tabular-nums">
                    {format_number(to_num(v["pageviews"]))}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-500 tabular-nums hidden sm:table-cell">
                    {format_duration(to_int(v["duration"]))}
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <.link
                      :if={v["country"] && v["country"] != ""}
                      navigate={~p"/dashboard/sites/#{@site.id}/geo"}
                      class="text-indigo-600 hover:text-indigo-800"
                    >
                      {[v["city"], v["region"], v["country"]]
                      |> Enum.reject(&(&1 == "" || is_nil(&1)))
                      |> Enum.join(", ")}
                    </.link>
                    <span :if={!v["country"] || v["country"] == ""} class="text-gray-500">-</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-500 hidden md:table-cell">
                    {[v["browser"], v["os"]]
                    |> Enum.reject(&(&1 == "" || is_nil(&1)))
                    |> Enum.join(" / ")}
                  </td>
                  <td class="px-4 py-3 text-sm truncate max-w-[120px] hidden lg:table-cell">
                    <.link
                      :if={v["referrer"] && v["referrer"] != ""}
                      navigate={
                        ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=referrer_domain&filter_value=#{v["referrer"]}"
                      }
                      class="text-indigo-600 hover:text-indigo-800"
                    >
                      {v["referrer"]}
                    </.link>
                    <span :if={!v["referrer"] || v["referrer"] == ""} class="text-gray-500">
                      Direct
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm truncate max-w-[150px] hidden md:table-cell">
                    <.link
                      :if={v["entry_page"] && v["entry_page"] != ""}
                      navigate={~p"/dashboard/sites/#{@site.id}/transitions?page=#{v["entry_page"]}"}
                      class="text-indigo-600 hover:text-indigo-800 font-mono"
                    >
                      {v["entry_page"]}
                    </.link>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-500 whitespace-nowrap">
                    {v["last_seen"]}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="flex items-center justify-between mt-4">
            <button
              :if={@page_num > 0}
              phx-click="prev_page"
              class="px-3 py-1.5 text-sm bg-white border border-gray-300 rounded-md hover:bg-gray-50"
            >
              &larr; Previous
            </button>
            <span :if={@page_num == 0}></span>
            <span class="text-xs text-gray-500">Page {@page_num + 1}</span>
            <button
              :if={@next_cursor != nil}
              phx-click="next_page"
              class="px-3 py-1.5 text-sm bg-white border border-gray-300 rounded-md hover:bg-gray-50"
            >
              Next &rarr;
            </button>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp intent_pill("buying"), do: "bg-green-100 text-green-800"
  defp intent_pill("researching"), do: "bg-blue-100 text-blue-800"
  defp intent_pill("comparing"), do: "bg-purple-100 text-purple-800"
  defp intent_pill("support"), do: "bg-yellow-100 text-yellow-800"
  defp intent_pill("returning"), do: "bg-indigo-100 text-indigo-800"
  defp intent_pill("browsing"), do: "bg-gray-100 text-gray-700"
  defp intent_pill("bot"), do: "bg-red-100 text-red-800"
  defp intent_pill(_), do: "bg-gray-100 text-gray-700"
end
