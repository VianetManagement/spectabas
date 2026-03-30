defmodule SpectabasWeb.Dashboard.CampaignsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Campaign management with UTM URL builder."

  alias Spectabas.{Accounts, Sites, Campaigns}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      campaigns = Campaigns.list_campaigns(site)

      {:ok,
       socket
       |> assign(:page_title, "Campaigns - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:campaigns, campaigns)
       |> assign(:show_form, false)
       |> assign(:form, to_form(campaign_changeset()))}
    end
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("create_campaign", %{"campaign" => params}, socket) do
    case Campaigns.create_campaign(socket.assigns.site, params) do
      {:ok, _campaign} ->
        campaigns = Campaigns.list_campaigns(socket.assigns.site)

        {:noreply,
         socket
         |> put_flash(:info, "Campaign created.")
         |> assign(:campaigns, campaigns)
         |> assign(:show_form, false)
         |> assign(:form, to_form(campaign_changeset()))}

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

  defp campaign_changeset do
    Campaigns.Campaign.changeset(%Campaigns.Campaign{}, %{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      active="campaigns"
      page_title="Campaigns"
      page_description="Create and manage UTM campaign URLs. Track which marketing campaigns drive traffic to your site by tagging links with UTM parameters."
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <%!-- UTM Guide --%>
        <div class="bg-indigo-50 border border-indigo-100 rounded-lg p-5 mb-6">
          <h3 class="text-sm font-semibold text-indigo-900 mb-2">How UTM Campaign Tracking Works</h3>
          <p class="text-sm text-indigo-800 mb-3">
            UTM parameters are tags added to your URLs that tell Spectabas where traffic came from.
            When someone clicks a tagged link, the parameters are captured automatically.
          </p>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs">
            <div>
              <p class="font-semibold text-indigo-900 mb-1">UTM Parameters</p>
              <dl class="space-y-1 text-indigo-800">
                <div>
                  <dt class="font-medium inline">utm_source</dt>
                  — Where the traffic comes from (google, newsletter, facebook)
                </div>
                <div>
                  <dt class="font-medium inline">utm_medium</dt>
                  — The marketing medium (cpc, email, social, banner)
                </div>
                <div>
                  <dt class="font-medium inline">utm_campaign</dt>
                  — The campaign name (spring_sale, product_launch)
                </div>
                <div>
                  <dt class="font-medium inline">utm_term</dt>
                  — Paid search keywords (optional)
                </div>
                <div>
                  <dt class="font-medium inline">utm_content</dt>
                  — Differentiates similar content (optional)
                </div>
              </dl>
            </div>
            <div>
              <p class="font-semibold text-indigo-900 mb-1">Example Tagged URL</p>
              <code class="block bg-indigo-100 rounded p-2 text-indigo-900 break-all text-[11px] leading-relaxed">
                https://example.com/pricing<br />
                ?utm_source=<span class="font-bold">google</span><br />
                &amp;utm_medium=<span class="font-bold">cpc</span><br />
                &amp;utm_campaign=<span class="font-bold">spring_sale</span>
              </code>
              <p class="text-indigo-700 mt-2">
                This tells Spectabas that the visitor came from a Google paid ad as part of the "spring_sale" campaign.
              </p>
            </div>
          </div>
        </div>

        <%!-- Create button --%>
        <div class="flex justify-end mb-4">
          <button
            phx-click="toggle_form"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            {if @show_form, do: "Cancel", else: "+ New Campaign"}
          </button>
        </div>

        <%!-- Campaign form --%>
        <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">UTM Campaign Builder</h2>
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  placeholder="https://example.com/landing-page"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  UTM Source <span class="text-red-500">*</span>
                </label>
                <input
                  type="text"
                  name="campaign[utm_source]"
                  value={@form[:utm_source].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  placeholder="google, newsletter, facebook"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  UTM Medium <span class="text-red-500">*</span>
                </label>
                <input
                  type="text"
                  name="campaign[utm_medium]"
                  value={@form[:utm_medium].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  placeholder="cpc, email, social, banner"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">UTM Campaign</label>
                <input
                  type="text"
                  name="campaign[utm_campaign]"
                  value={@form[:utm_campaign].value}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  placeholder="header_banner, sidebar_cta"
                />
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create Campaign
              </button>
            </div>
          </.form>
        </div>

        <%!-- Campaigns list --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Medium
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Status
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Tagged URL
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@campaigns == []}>
                <td colspan="5" class="px-6 py-8 text-center text-gray-500">
                  No campaigns yet. Create one above to start tracking your marketing efforts.
                </td>
              </tr>
              <tr :for={c <- @campaigns} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900">{c.name}</td>
                <td class="px-6 py-4 text-sm text-gray-500">{c.utm_source}</td>
                <td class="px-6 py-4 text-sm text-gray-500">{c.utm_medium}</td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(c.active, do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-800")
                  ]}>
                    {if c.active, do: "Active", else: "Inactive"}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 truncate max-w-xs font-mono text-xs">
                  {Campaigns.build_url(c)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
