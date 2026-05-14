defmodule SpectabasWeb.Dashboard.FormsLive do
  @moduledoc """
  Forms dashboard. Two kinds of form-like surfaces are tracked:
  - `<form>` tags (most reliable — submit detected from the browser's
    native submit event).
  - Input clusters: groups of ≥2 `<input>`/`<select>`/`<textarea>`
    elements sharing an identifiable ancestor container, with no
    wrapping `<form>` — common in React/Next.js apps that submit via
    `fetch`. Submits are inferred from clicks on buttons whose text
    matches submit-like verbs, and only fire if the user previously
    focused an input in that cluster.

  Events: `_form_view` (form present in DOM at pageview / cluster
  detected), `_form_start` (first input focus), `_form_submit`,
  `_form_abandon` (started but visibilitychange-hidden / pagehide
  without submit). All carry `_form_id`, `_form_kind` (`"form"` or
  `"cluster"`), and field metadata where relevant. Click a row to
  see which field is the abandonment funnel breakpoint for that
  form.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Forms - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:summary, %{})
        |> assign(:forms, [])
        |> assign(:sort_by, "views")
        |> assign(:sort_dir, :desc)
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    dir =
      cond do
        socket.assigns.sort_by != col -> default_dir_for(col)
        socket.assigns.sort_dir == :asc -> :desc
        true -> :asc
      end

    {:noreply, socket |> assign(:sort_by, col) |> assign(:sort_dir, dir)}
  end

  # Numeric columns start descending (biggest first); text columns ascending.
  defp default_dir_for(col)
       when col in ~w(views starts submits abandons submit_rate abandon_rate),
       do: :desc

  defp default_dir_for(_), do: :asc

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    summary =
      case Analytics.form_analytics_summary(site, user, period) do
        {:ok, [row]} -> row
        _ -> %{}
      end

    forms =
      case Analytics.top_forms(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    socket
    |> assign(:summary, summary)
    |> assign(:forms, forms)
  end

  defp display_form_label(form) do
    name = form["form_name"]
    id = form["form_id"]
    if name && name != "", do: name, else: id
  end

  defp sorted_forms(forms, sort_by, sort_dir) do
    Enum.sort_by(forms, &sort_key(&1, sort_by), sort_dir)
  end

  defp sort_key(row, "form"), do: row |> display_form_label() |> String.downcase()
  defp sort_key(row, "form_kind"), do: row["form_kind"] || ""

  defp sort_key(row, col)
       when col in ~w(views starts submits abandons submit_rate abandon_rate),
       do: to_num(row[col])

  defp sort_key(row, col), do: row[col] || 0

  defp sort_indicator(col, sort_by, sort_dir) do
    cond do
      col != sort_by -> " "
      sort_dir == :asc -> " ↑"
      true -> " ↓"
    end
  end

  defp kind_label("cluster"), do: "Cluster"
  defp kind_label("form"), do: "Form"
  defp kind_label(_), do: "—"

  defp kind_badge_class("cluster"),
    do: "inline-block px-1.5 py-0.5 rounded bg-indigo-100 text-indigo-800 font-medium"

  defp kind_badge_class("form"),
    do: "inline-block px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-800 font-medium"

  defp kind_badge_class(_),
    do: "inline-block px-1.5 py-0.5 rounded bg-gray-100 text-gray-600 font-medium"

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Forms"
      page_description="Form views, starts, submits, and per-field abandonment auto-tracked from both `<form>` tags and input clusters (groups of inputs without a wrapping form, common in React/Next.js apps)."
      active="forms"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Forms</h1>
            <p class="text-sm text-gray-500 mt-1">
              Auto-tracked &lt;form&gt; interactions. Submit rate = submits / views. Abandon rate = abandons / starts. Click a row to see which field most often loses visitors.
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}]}
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

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg class="animate-spin h-5 w-5 text-indigo-600" viewBox="0 0 24 24" fill="none">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span class="text-sm">Loading...</span>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Form views</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@summary["total_views"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                {format_number(to_num(@summary["native_forms_tracked"] || 0))} &lt;form&gt; · {format_number(
                  to_num(@summary["clusters_tracked"] || 0)
                )} clusters
              </p>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Starts</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@summary["total_starts"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">first-field focus</p>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Submits</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@summary["total_submits"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Submit rate {to_num(@summary["submit_rate"] || 0)}% · {format_number(
                  to_num(@summary["heuristic_submits"] || 0)
                )} heuristic
              </p>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Abandons</p>
              <p class="text-2xl font-bold text-amber-700">
                {format_number(to_num(@summary["total_abandons"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Abandon rate {to_num(@summary["abandon_rate"] || 0)}%
              </p>
            </div>
          </div>

          <div class="bg-white rounded-lg shadow overflow-x-auto mb-6">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th
                    phx-click="sort"
                    phx-value-col="form"
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Form{sort_indicator("form", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="form_kind"
                    class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Kind{sort_indicator("form_kind", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="views"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Views{sort_indicator("views", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="starts"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Starts{sort_indicator("starts", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="submits"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Submits{sort_indicator("submits", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="abandons"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Abandons{sort_indicator("abandons", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="submit_rate"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Submit %{sort_indicator("submit_rate", @sort_by, @sort_dir)}
                  </th>
                  <th
                    phx-click="sort"
                    phx-value-col="abandon_rate"
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-gray-700"
                  >
                    Abandon %{sort_indicator("abandon_rate", @sort_by, @sort_dir)}
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@forms == []}>
                  <td colspan="8" class="px-6 py-8 text-center text-gray-500">
                    No form interactions found in this range. The tracker auto-detects both &lt;form&gt; tags and input clusters (groups of inputs without a wrapping form).
                  </td>
                </tr>
                <tr
                  :for={f <- sorted_forms(@forms, @sort_by, @sort_dir)}
                  onclick={"window.location.href='/dashboard/sites/#{@site.id}/forms/#{URI.encode_www_form(f["form_id"] || "")}'"}
                  class="cursor-pointer hover:bg-indigo-50"
                >
                  <td class="px-6 py-3 text-sm">
                    <.link
                      navigate={~p"/dashboard/sites/#{@site.id}/forms/#{f["form_id"]}"}
                      class="font-medium text-gray-900 hover:text-indigo-700 truncate max-w-xs block"
                    >
                      {display_form_label(f)}
                    </.link>
                    <div
                      :if={f["form_action"] && f["form_action"] != ""}
                      class="text-xs text-gray-500 font-mono truncate max-w-xs"
                    >
                      {f["form_action"]}
                    </div>
                  </td>
                  <td class="px-6 py-3 text-xs">
                    <span class={kind_badge_class(f["form_kind"])}>
                      {kind_label(f["form_kind"])}
                    </span>
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(f["views"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(f["starts"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums font-medium">
                    {format_number(to_num(f["submits"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-amber-700 text-right tabular-nums">
                    {format_number(to_num(f["abandons"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {to_num(f["submit_rate"])}%
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {to_num(f["abandon_rate"])}%
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@forms != []} class="text-xs text-gray-500 mb-6 leading-relaxed">
            <strong>Kind:</strong>
            <span class="inline-block px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-800 font-medium">
              Form
            </span>
            = HTML &lt;form&gt; tag — submits detected from the browser's native event (most reliable).
            <span class="inline-block px-1.5 py-0.5 rounded bg-indigo-100 text-indigo-800 font-medium">
              Cluster
            </span>
            = group of ≥2 inputs sharing an identifiable container with no wrapping &lt;form&gt; (common in React / Next.js apps). Submits are inferred from clicks on buttons whose text matches submit verbs (submit, send, sign up, continue, save, checkout, etc.), only counted if the user previously focused an input in the cluster. The "heuristic" count in the summary card above is just the cluster submits — keep an eye on it as a quality check.
          </p>

          <p :if={@forms != []} class="text-xs text-gray-400">
            Click any form to open its detail page — funnel, per-field drop-off, time-to-submit, validation errors, breakdowns by device/country/language/source, recent activity, and more.
          </p>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
