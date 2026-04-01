defmodule SpectabasWeb.Dashboard.RealtimeLive do
  use SpectabasWeb, :live_view

  @moduledoc "Realtime visitor dashboard with live event feed."

  alias Spectabas.{Accounts, Sites, Analytics, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @refresh_ms 5_000

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Spectabas.PubSub, "site:#{site.id}")
        schedule_refresh()
      end

      {:ok,
       socket
       |> assign(:page_title, "Realtime - #{site.name}")
       |> assign(:site, site)
       |> assign(:view, "visitors")
       |> load_data()}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_data(socket)}
  end

  def handle_info({:new_event, _event}, socket) do
    # Don't re-query ClickHouse on every PubSub message — the 5-second
    # refresh timer handles periodic updates. Just increment a local counter.
    count = Map.get(socket.assigns, :pending_events, 0) + 1
    {:noreply, assign(socket, :pending_events, count)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :view, view)}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load_data(socket) do
    site = socket.assigns.site

    tasks = [
      Task.async(fn -> Analytics.realtime_visitors(site) end),
      Task.async(fn -> Analytics.realtime_visitors_grouped(site) end),
      Task.async(fn -> Analytics.realtime_events(site) end)
    ]

    results =
      tasks
      |> Task.yield_many(10_000)
      |> Enum.map(fn {task, result} ->
        case result do
          {:ok, val} ->
            val

          nil ->
            Task.shutdown(task, :brutal_kill)
            :error
        end
      end)

    active_count =
      case Enum.at(results, 0) do
        {:ok, count} -> count
        _ -> 0
      end

    grouped =
      case Enum.at(results, 1) do
        {:ok, rows} -> rows
        _ -> []
      end

    raw_events =
      case Enum.at(results, 2) do
        {:ok, events} -> events
        _ -> []
      end

    # Enrich with emails from Postgres
    all_vids =
      (Enum.map(grouped, & &1["visitor_id"]) ++ Enum.map(raw_events, & &1["visitor_id"]))
      |> Enum.uniq()

    email_map = Visitors.emails_for_visitor_ids(all_vids)

    grouped =
      Enum.map(grouped, fn v ->
        case Map.get(email_map, v["visitor_id"]) do
          %{email: email} -> Map.put(v, "email", email)
          _ -> v
        end
      end)

    raw_events =
      Enum.map(raw_events, fn e ->
        case Map.get(email_map, e["visitor_id"]) do
          %{email: email} -> Map.put(e, "email", email)
          _ -> e
        end
      end)

    # Enrich with ecommerce data (if ecommerce enabled)
    ecom_map =
      case Analytics.ecommerce_for_visitors(site, Enum.map(grouped, & &1["visitor_id"])) do
        {:ok, map} -> map
        _ -> %{}
      end

    grouped =
      Enum.map(grouped, fn v ->
        case Map.get(ecom_map, v["visitor_id"]) do
          %{orders: orders, revenue: revenue} ->
            v |> Map.put("ecom_orders", orders) |> Map.put("ecom_revenue", revenue)

          _ ->
            v
        end
      end)

    socket
    |> assign(:active_count, active_count)
    |> assign(:grouped, grouped)
    |> assign(:raw_events, raw_events)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Realtime"
      page_description="Live visitor activity — updates every 5 seconds."
      active="realtime"
      live_visitors={@active_count}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <%!-- Active count --%>
        <div class="bg-white rounded-lg shadow p-6 mb-6 text-center">
          <div class="flex items-center justify-center gap-3">
            <span class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></span>
            <span class="text-5xl font-bold text-gray-900">{format_number(@active_count)}</span>
          </div>
          <p class="text-gray-500 mt-2">visitors online right now</p>
        </div>

        <%!-- View toggle --%>
        <div class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-4 w-fit">
          <button
            :for={{id, label} <- [{"visitors", "Active Visitors"}, {"events", "Event Feed"}]}
            phx-click="toggle_view"
            phx-value-view={id}
            class={[
              "px-3 py-1.5 text-sm font-medium rounded-md",
              if(@view == id,
                do: "bg-white shadow text-gray-900",
                else: "text-gray-600 hover:text-gray-900"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <%!-- Active Visitors (grouped) --%>
        <div :if={@view == "visitors"} class="bg-white rounded-lg shadow overflow-x-auto">
          <div :if={@grouped == []} class="px-5 py-8 text-center text-gray-500">
            No active visitors right now.
          </div>
          <table :if={@grouped != []} class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Current Page
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Pages
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Location
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Device
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Intent
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Active
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={v <- @grouped} class="hover:bg-gray-50">
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
                  <span
                    :if={v["ecom_orders"] && v["ecom_orders"] > 0}
                    class="ml-1.5 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-green-100 text-green-700"
                    title={"#{v["ecom_orders"]} order(s) — #{@site.currency} #{format_revenue(v["ecom_revenue"])}"}
                  >
                    Customer
                  </span>
                </td>
                <td class="px-4 py-3 text-sm">
                  <.link
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/transitions?page=#{v["current_page"] || "/"}"
                    }
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs truncate max-w-[200px] block"
                  >
                    {v["current_page"] || "/"}
                  </.link>
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(v["pageviews"]))}
                </td>
                <td class="px-4 py-3 text-sm text-gray-500">
                  {[v["city"], v["country"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")}
                </td>
                <td class="px-4 py-3 text-sm text-gray-500">
                  {[v["browser"], v["os"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(" / ")}
                </td>
                <td class="px-4 py-3 text-sm text-gray-500 truncate max-w-[100px]">
                  {v["referrer"] || "Direct"}
                </td>
                <td class="px-4 py-3">
                  <span
                    :if={v["intent"] && v["intent"] != ""}
                    class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      intent_pill(v["intent"])
                    ]}
                  >
                    {v["intent"]}
                  </span>
                </td>
                <td class="px-4 py-3 text-xs text-gray-500">
                  {time_ago(v["last_activity"])}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Raw Event Feed --%>
        <div :if={@view == "events"} class="bg-white rounded-lg shadow overflow-hidden">
          <div :if={@raw_events == []} class="px-5 py-8 text-center text-gray-500">
            Waiting for events...
          </div>
          <div class="divide-y divide-gray-50">
            <div :for={event <- @raw_events} class="px-5 py-3">
              <div class="flex items-center justify-between mb-1">
                <div class="flex items-center gap-2 min-w-0">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0",
                    event_type_class(event["event_type"])
                  ]}>
                    {event["event_type"]}
                  </span>
                  <.link
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/transitions?page=#{event["url_path"] || "/"}"
                    }
                    class="text-sm text-indigo-600 hover:text-indigo-800 font-mono truncate"
                  >
                    {event["url_path"] || "/"}
                  </.link>
                </div>
                <span class="text-xs text-gray-500 shrink-0 ml-3">{event["timestamp"]}</span>
              </div>
              <div class="flex items-center gap-3 text-xs text-gray-500 mt-1 flex-wrap">
                <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{event["visitor_id"]}"}
                  class="text-indigo-500 hover:text-indigo-700"
                >
                  <span :if={event["email"]} class="text-xs font-medium">
                    {event["email"]}
                  </span>
                  <span :if={!event["email"]} class="font-mono text-xs">
                    {String.slice(event["visitor_id"] || "", 0, 8)}
                  </span>
                </.link>
                <span :if={event["ip_country"] && event["ip_country"] != ""}>
                  {event["ip_country"]}
                </span>
                <span :if={event["browser"] && event["browser"] != ""}>
                  {event["browser"]}
                </span>
                <span
                  :if={event["referrer_domain"] && event["referrer_domain"] != ""}
                  class="text-gray-500"
                >
                  via {event["referrer_domain"]}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class("duration"), do: "bg-gray-100 text-gray-600"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"

  defp format_revenue(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> "0.00"
    end
  end

  defp format_revenue(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp format_revenue(_), do: "0.00"

  defp intent_pill("buying"), do: "bg-green-100 text-green-800"
  defp intent_pill("researching"), do: "bg-blue-100 text-blue-800"
  defp intent_pill("comparing"), do: "bg-purple-100 text-purple-800"
  defp intent_pill("support"), do: "bg-yellow-100 text-yellow-800"
  defp intent_pill("returning"), do: "bg-indigo-100 text-indigo-800"
  defp intent_pill("browsing"), do: "bg-gray-100 text-gray-700"
  defp intent_pill("bot"), do: "bg-red-100 text-red-800"
  defp intent_pill(_), do: "bg-gray-100 text-gray-700"

  defp time_ago(nil), do: "-"

  defp time_ago(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(String.replace(timestamp, " ", "T")) do
      {:ok, ndt} ->
        diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), ndt, :second)

        cond do
          diff < 10 -> "just now"
          diff < 60 -> "#{diff}s ago"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          true -> timestamp
        end

      _ ->
        timestamp
    end
  end

  defp time_ago(_), do: "-"
end
