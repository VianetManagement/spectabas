defmodule SpectabasWeb.Dashboard.CampaignsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Campaigns}

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
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Back to {@site.name}
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Campaigns</h1>
        </div>
        <button
          phx-click="toggle_form"
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
        >
          {if @show_form, do: "Cancel", else: "New Campaign"}
        </button>
      </div>

      <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-8">
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
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">UTM Source</label>
              <input
                type="text"
                name="campaign[utm_source]"
                value={@form[:utm_source].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                placeholder="e.g. google, newsletter"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">UTM Medium</label>
              <input
                type="text"
                name="campaign[utm_medium]"
                value={@form[:utm_medium].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                placeholder="e.g. cpc, email"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">UTM Campaign</label>
              <input
                type="text"
                name="campaign[utm_campaign]"
                value={@form[:utm_campaign].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                placeholder="e.g. spring_sale"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">UTM Term</label>
              <input
                type="text"
                name="campaign[utm_term]"
                value={@form[:utm_term].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">UTM Content</label>
              <input
                type="text"
                name="campaign[utm_content]"
                value={@form[:utm_content].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Source
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Medium
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                URL
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :if={@campaigns == []}>
              <td colspan="5" class="px-6 py-8 text-center text-gray-500">No campaigns yet.</td>
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
              <td class="px-6 py-4 text-sm text-gray-500 truncate max-w-xs">
                {Campaigns.build_url(c)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
