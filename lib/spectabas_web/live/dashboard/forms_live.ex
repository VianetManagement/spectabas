defmodule SpectabasWeb.Dashboard.FormsLive do
  @moduledoc """
  Forms dashboard. Auto-tracked HTML `<form>` interactions: view (form
  in DOM at pageview), start (first focus inside), submit, abandon
  (started but left without submitting). Click a row to see which
  field is the abandonment funnel breakpoint for that form.
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
        |> assign(:selected_form_id, nil)
        |> assign(:selected_form_name, nil)
        |> assign(:field_dropoff, [])
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:date_range, range)
     |> assign(:loading, true)
     |> assign(:selected_form_id, nil)
     |> assign(:field_dropoff, [])}
  end

  def handle_event(
        "select_form",
        %{"form_id" => form_id, "form_name" => form_name},
        socket
      ) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    dropoff =
      case Analytics.form_field_dropoff(site, user, form_id, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:selected_form_id, form_id)
     |> assign(:selected_form_name, form_name)
     |> assign(:field_dropoff, dropoff)}
  end

  def handle_event("clear_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_form_id, nil)
     |> assign(:selected_form_name, nil)
     |> assign(:field_dropoff, [])}
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Forms"
      page_description="Form views, starts, submits, and per-field abandonment auto-tracked from your site's `<form>` tags."
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
                {format_number(to_num(@summary["forms_tracked"] || 0))} distinct forms
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
                Submit rate {to_num(@summary["submit_rate"] || 0)}%
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
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Form
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Views
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Starts
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Submits
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Abandons
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Submit %
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Abandon %
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@forms == []}>
                  <td colspan="7" class="px-6 py-8 text-center text-gray-500">
                    No form interactions found in this range. Forms are auto-tracked from &lt;form&gt; tags on your site.
                  </td>
                </tr>
                <tr
                  :for={f <- @forms}
                  phx-click="select_form"
                  phx-value-form_id={f["form_id"]}
                  phx-value-form_name={display_form_label(f)}
                  class={[
                    "cursor-pointer hover:bg-indigo-50",
                    if(@selected_form_id == f["form_id"], do: "bg-indigo-50", else: "")
                  ]}
                >
                  <td class="px-6 py-3 text-sm">
                    <div class="font-medium text-gray-900 truncate max-w-xs">
                      {display_form_label(f)}
                    </div>
                    <div
                      :if={f["form_action"] && f["form_action"] != ""}
                      class="text-xs text-gray-500 font-mono truncate max-w-xs"
                    >
                      {f["form_action"]}
                    </div>
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

          <div :if={@selected_form_id} class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-100 flex items-center justify-between">
              <div>
                <h2 class="text-sm font-semibold text-gray-700">
                  Per-field drop-off: <span class="font-mono">{@selected_form_name}</span>
                </h2>
                <p class="text-[10px] text-gray-400 mt-0.5">
                  Starts here = visitors whose first focus was this field. Abandons = visitors who left the form with this field as their last touch. The field with the most abandons is the funnel breakpoint.
                </p>
              </div>
              <button
                phx-click="clear_form"
                class="text-xs text-gray-500 hover:text-gray-700"
              >
                Close ✕
              </button>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Field
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Starts here
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Abandons
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@field_dropoff == []}>
                  <td colspan="3" class="px-5 py-3 text-center text-gray-400 text-xs">
                    No field-level data for this form in this range.
                  </td>
                </tr>
                <tr :for={r <- @field_dropoff}>
                  <td class="px-5 py-2 font-mono text-xs">{r["field_name"]}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["starts_here"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs text-amber-700">
                    {format_number(to_num(r["abandons"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
