defmodule SpectabasWeb.Dashboard.CampaignsLive do
  use SpectabasWeb, :live_view

  @moduledoc """
  Campaign performance + UTM URL builder.

  The list is built primarily from actual UTM-tagged events in ClickHouse —
  every unique (utm_campaign, utm_source, utm_medium) triple seen in the
  selected date range is a row, regardless of whether it was pre-created via
  the UTM builder. Rows that match a saved Campaigns.Campaign record get a
  "nice name" and destination URL; detected-but-unsaved rows show a "Save to
  Builder" button that one-click promotes them.

  Saved campaigns with no traffic in the range are still shown (grayed) so the
  user knows what they've set up.
  """

  alias Spectabas.{Accounts, Sites, Campaigns, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @ranges ~w(7d 30d 90d)
  @write_events ~w(create_campaign save_detected)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        if !Accounts.can_write?(user) do
          attach_hook(socket, :viewer_guard, :handle_event, fn
            event, _params, sock when event in @write_events ->
              {:halt, put_flash(sock, :error, "Viewers have read-only access.")}

            _event, _params, sock ->
              {:cont, sock}
          end)
        else
          socket
        end

      {:ok,
       socket
       |> assign(:page_title, "Campaigns - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:range, "30d")
       |> assign(:show_form, false)
       |> assign(:form, to_form(blank_changeset()))
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => r}, socket) when r in @ranges do
    {:noreply, socket |> assign(:range, r) |> load_data()}
  end

  def handle_event("change_range", _, socket), do: {:noreply, socket}

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("create_campaign", %{"campaign" => params}, socket) do
    case Campaigns.create_campaign(socket.assigns.site, params) do
      {:ok, _campaign} ->
        {:noreply,
         socket
         |> put_flash(:info, "Campaign saved.")
         |> assign(:show_form, false)
         |> assign(:form, to_form(blank_changeset()))
         |> load_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("validate_campaign", %{"campaign" => params}, socket) do
    changeset =
      %Campaigns.Campaign{}
      |> Campaigns.Campaign.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  # One-click save of a detected campaign into the builder. Name defaults to
  # the utm_campaign value; user can edit later from the form if needed.
  def handle_event(
        "save_detected",
        %{"campaign" => utm_campaign, "source" => source, "medium" => medium},
        socket
      ) do
    attrs = %{
      name: utm_campaign,
      utm_campaign: utm_campaign,
      utm_source: source,
      utm_medium: medium,
      active: true
    }

    case Campaigns.create_campaign(socket.assigns.site, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved \"#{utm_campaign}\" to the Builder.")
         |> load_data()}

      {:error, cs} ->
        msg =
          cs.errors
          |> Enum.map(fn {k, {m, _}} -> "#{k}: #{m}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "Couldn't save: #{msg}")}
    end
  end

  # ---------------- Data merge ----------------

  defp load_data(socket) do
    site = socket.assigns.site
    user = socket.assigns.user
    saved = Campaigns.list_campaigns(site)

    detected =
      case Analytics.campaign_performance(site, user, range_to_period(socket.assigns.range)) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Map (campaign, source, medium) → saved record when present.
    saved_by_triple =
      Map.new(saved, fn c ->
        {{norm(c.utm_campaign), norm(c.utm_source), norm(c.utm_medium)}, c}
      end)

    # Detected rows, annotated with saved record when the triple matches.
    detected_rows =
      Enum.map(detected, fn r ->
        triple =
          {norm(r["campaign"]), norm(r["source"]), norm(r["medium"])}

        %{
          source: :detected,
          campaign: r["campaign"],
          utm_source: r["source"],
          utm_medium: r["medium"],
          visitors: to_num(r["visitors"]),
          sessions: to_num(r["sessions"]),
          bounce_rate: r["bounce_rate"],
          pageviews: to_num(r["pageviews"]),
          saved: Map.get(saved_by_triple, triple)
        }
      end)

    # Saved campaigns that have NO matching traffic — still display (grayed).
    detected_triples =
      MapSet.new(detected_rows, fn r ->
        {norm(r.campaign), norm(r.utm_source), norm(r.utm_medium)}
      end)

    empty_saved_rows =
      saved
      |> Enum.reject(fn c ->
        MapSet.member?(
          detected_triples,
          {norm(c.utm_campaign), norm(c.utm_source), norm(c.utm_medium)}
        )
      end)
      |> Enum.map(fn c ->
        %{
          source: :saved_only,
          campaign: c.utm_campaign || "",
          utm_source: c.utm_source || "",
          utm_medium: c.utm_medium || "",
          visitors: 0,
          sessions: 0,
          bounce_rate: nil,
          pageviews: 0,
          saved: c
        }
      end)

    rows = detected_rows ++ empty_saved_rows

    socket
    |> assign(:rows, rows)
    |> assign(:detected_count, length(detected_rows))
    |> assign(:saved_count, length(saved))
    |> assign(:total_visitors, Enum.reduce(rows, 0, &(&1.visitors + &2)))
  end

  defp norm(nil), do: ""
  defp norm(s) when is_binary(s), do: String.downcase(s)
  defp norm(s), do: to_string(s)

  defp blank_changeset do
    Campaigns.Campaign.changeset(%Campaigns.Campaign{}, %{})
  end

  defp range_to_period("7d"), do: :"7d"
  defp range_to_period("30d"), do: :"30d"
  defp range_to_period("90d"), do: :"90d"
  defp range_to_period(_), do: :"30d"

  # ---------------- Render ----------------

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      active="campaigns"
      page_title="Campaigns"
      page_description="All UTM-tagged traffic, auto-detected from events. Pre-create campaigns in the builder to generate tagged URLs and give them nicer names."
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div class="flex items-center justify-between mb-6">
          <div class="text-sm text-gray-600">
            <span class="font-medium text-gray-900">{@detected_count}</span>
            detected &middot; <span class="font-medium text-gray-900">{@saved_count}</span>
            saved in Builder &middot;
            <span class="font-medium text-gray-900">
              {format_number(@total_visitors)}
            </span>
            visitors in range
          </div>
          <div class="flex items-center gap-3">
            <div class="flex rounded-lg border border-gray-300 overflow-hidden">
              <%= for r <- ~w(7d 30d 90d) do %>
                <button
                  phx-click="change_range"
                  phx-value-range={r}
                  class={"px-3 py-1.5 text-sm font-medium " <>
                    if(@range == r, do: "bg-indigo-600 text-white", else: "bg-white text-gray-700 hover:bg-gray-50")}
                >
                  {r}
                </button>
              <% end %>
            </div>
            <button
              phx-click="toggle_form"
              class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              {if @show_form, do: "Cancel", else: "+ Build URL"}
            </button>
          </div>
        </div>

        <%!-- UTM URL builder form --%>
        <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">UTM Campaign Builder</h2>
          <p class="text-xs text-gray-500 mb-4">
            Use this to pre-define a campaign and generate a tagged destination URL. Any traffic
            matching these UTM parameters will be auto-grouped under this saved campaign's name.
          </p>
          <.form
            for={@form}
            phx-submit="create_campaign"
            phx-change="validate_campaign"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Campaign Name</label>
                <input
                  type="text"
                  name="campaign[name]"
                  value={@form[:name].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="e.g. Spring Sale 2026"
                  required
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Destination URL</label>
                <input
                  type="url"
                  name="campaign[destination_url]"
                  value={@form[:destination_url].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="https://example.com/landing-page"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">UTM Source</label>
                <input
                  type="text"
                  name="campaign[utm_source]"
                  value={@form[:utm_source].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="google, newsletter, facebook"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">UTM Medium</label>
                <input
                  type="text"
                  name="campaign[utm_medium]"
                  value={@form[:utm_medium].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="cpc, email, social, banner"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">UTM Campaign</label>
                <input
                  type="text"
                  name="campaign[utm_campaign]"
                  value={@form[:utm_campaign].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="spring_sale, product_launch"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  UTM Term <span class="text-gray-500">(optional)</span>
                </label>
                <input
                  type="text"
                  name="campaign[utm_term]"
                  value={@form[:utm_term].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="paid search keywords"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  UTM Content <span class="text-gray-500">(optional)</span>
                </label>
                <input
                  type="text"
                  name="campaign[utm_content]"
                  value={@form[:utm_content].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm sm:text-sm"
                  placeholder="header_banner, sidebar_cta"
                />
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Save Campaign
              </button>
            </div>
          </.form>
        </div>

        <%!-- Campaign list --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Campaign
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source / Medium
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Sessions
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Bounce
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase"></th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-100">
              <tr :if={@rows == []}>
                <td colspan="6" class="px-6 py-12 text-center text-gray-500">
                  No UTM-tagged traffic in this range, and no saved campaigns. Tag your links with
                  utm_source / utm_medium / utm_campaign to see them here — or use the Build URL
                  button above to generate a tagged URL.
                </td>
              </tr>
              <tr
                :for={row <- @rows}
                class={if(row.source == :saved_only, do: "opacity-60", else: "hover:bg-gray-50")}
              >
                <td class="px-6 py-3 text-sm">
                  <div class="font-medium text-gray-900 truncate max-w-xs">
                    <%= if row.saved do %>
                      {row.saved.name}
                      <span class="text-xs text-gray-500 font-normal">({row.campaign})</span>
                    <% else %>
                      {row.campaign}
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-3 text-sm text-gray-600">
                  {row.utm_source} / {row.utm_medium}
                </td>
                <td class="px-6 py-3 text-right text-sm text-gray-900 tabular-nums">
                  {format_number(row.visitors)}
                </td>
                <td class="px-6 py-3 text-right text-sm text-gray-600 tabular-nums">
                  {format_number(row.sessions)}
                </td>
                <td class="px-6 py-3 text-right text-sm text-gray-600 tabular-nums">
                  {if row.bounce_rate, do: "#{row.bounce_rate}%", else: "—"}
                </td>
                <td class="px-6 py-3 text-right text-sm">
                  <%= cond do %>
                    <% row.source == :saved_only -> %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-700">
                        No traffic
                      </span>
                    <% row.saved -> %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
                        Saved
                      </span>
                    <% true -> %>
                      <button
                        phx-click="save_detected"
                        phx-value-campaign={row.campaign}
                        phx-value-source={row.utm_source}
                        phx-value-medium={row.utm_medium}
                        class="inline-flex items-center px-2 py-1 rounded text-xs font-medium bg-indigo-50 text-indigo-700 hover:bg-indigo-100"
                      >
                        + Save to Builder
                      </button>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Help --%>
        <div class="mt-6 bg-indigo-50 border border-indigo-100 rounded-lg p-5 text-sm text-indigo-900">
          <p class="font-semibold mb-2">How it works</p>
          <p class="mb-2">
            Every session with <code class="bg-white px-1 rounded">utm_campaign</code> is grouped
            above automatically. You don't need to create campaigns ahead of time — tag your links
            and they'll appear.
          </p>
          <p>
            Use <strong>Build URL</strong>
            to pre-define a campaign and generate a pre-tagged destination
            URL. Saved campaigns get a "nice name" in place of the raw utm value and stay visible
            here even when they have no traffic yet.
          </p>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
