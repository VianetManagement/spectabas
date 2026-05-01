defmodule SpectabasWeb.Dashboard.ConversionsLive do
  @moduledoc """
  Conversion actions CRUD + match-rate visibility for server-side
  conversion tracking. See `docs/conversions.md`.
  """

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Conversions, Sites}
  alias Spectabas.Conversions.ConversionAction
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      since = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

      socket =
        socket
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:page_title, "Conversions - #{site.name}")
        |> assign(:actions, Conversions.list_actions(site))
        |> assign(:summary, Conversions.site_summary(site.id, since))
        |> assign_form(params, socket.assigns[:live_action])

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_form(socket, params, socket.assigns.live_action)}
  end

  defp assign_form(socket, params, :edit) do
    action = Conversions.get_action!(socket.assigns.site, params["id"])

    socket
    |> assign(:editing, action)
    |> assign(:form, to_form(ConversionAction.changeset(action, %{})))
  end

  defp assign_form(socket, _params, :new) do
    socket
    |> assign(:editing, %ConversionAction{site_id: socket.assigns.site.id})
    |> assign(
      :form,
      to_form(
        ConversionAction.changeset(%ConversionAction{}, %{
          "site_id" => socket.assigns.site.id,
          "active" => true,
          "kind" => "purchase",
          "detection_type" => "stripe_payment",
          "value_strategy" => "from_payment",
          "attribution_window_days" => 90,
          "attribution_model" => "first_click",
          "max_scraper_score" => 40
        })
      )
    )
  end

  defp assign_form(socket, _params, _) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"conversion_action" => attrs}, socket) do
    cs =
      socket.assigns.editing
      |> ConversionAction.changeset(Map.put(attrs, "site_id", socket.assigns.site.id))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(cs))}
  end

  def handle_event("save", %{"conversion_action" => attrs}, socket) do
    site = socket.assigns.site
    attrs = Map.put(attrs, "site_id", site.id)

    save_result =
      case socket.assigns.editing do
        %ConversionAction{id: nil} ->
          Conversions.create_action(site, attrs)

        action ->
          Conversions.update_action(action, attrs)
      end

    case save_result do
      {:ok, _action} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversion action saved.")
         |> push_patch(to: ~p"/dashboard/sites/#{site.id}/conversions")
         |> assign(:actions, Conversions.list_actions(site))}

      {:error, cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    site = socket.assigns.site
    action = Conversions.get_action!(site, id)
    {:ok, _} = Conversions.delete_action(action)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted.")
     |> assign(:actions, Conversions.list_actions(site))}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    site = socket.assigns.site
    action = Conversions.get_action!(site, id)
    {:ok, _} = Conversions.update_action(action, %{"active" => !action.active})

    {:noreply, assign(socket, :actions, Conversions.list_actions(site))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Conversions"
      page_description="Server-side conversion tracking for Google Ads + Microsoft Ads."
      active="conversions"
      live_visitors={0}
    >
      <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <%!-- Summary cards (last 7 days) --%>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs text-gray-500">Pending</div>
            <div class="text-2xl font-bold text-amber-700">
              {Map.get(@summary, "pending", 0)}
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs text-gray-500">Uploaded (Google)</div>
            <div class="text-2xl font-bold text-emerald-700">
              {Map.get(@summary, "uploaded_google", 0) + Map.get(@summary, "uploaded_both", 0)}
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs text-gray-500">Uploaded (Microsoft)</div>
            <div class="text-2xl font-bold text-emerald-700">
              {Map.get(@summary, "uploaded_microsoft", 0) + Map.get(@summary, "uploaded_both", 0)}
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs text-gray-500">Failed</div>
            <div class="text-2xl font-bold text-red-700">
              {Map.get(@summary, "failed", 0) + Map.get(@summary, "skipped_no_click", 0) +
                Map.get(@summary, "skipped_quality", 0)}
            </div>
          </div>
        </div>

        <div class="flex items-center justify-between mb-4">
          <h1 class="text-xl font-bold text-gray-900">Conversion Actions</h1>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/conversions/new"}
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            New Conversion Action
          </.link>
        </div>

        <%!-- Edit/new form --%>
        <div :if={@form} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-base font-semibold text-gray-900 mb-3">
            {if @editing.id, do: "Edit", else: "New"} Conversion Action
          </h2>
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.input field={@form[:name]} label="Name" placeholder="Membership Purchase" required />
              <.input
                field={@form[:kind]}
                type="select"
                label="Kind"
                options={Enum.map(ConversionAction.kinds(), &{String.capitalize(&1), &1})}
              />
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.input
                field={@form[:detection_type]}
                type="select"
                label="Detect via"
                options={[
                  {"Stripe payment", "stripe_payment"},
                  {"URL pattern", "url_pattern"},
                  {"Click element", "click_element"},
                  {"Custom event", "custom_event"}
                ]}
              />
              <.input
                field={@form[:value_strategy]}
                type="select"
                label="Value strategy"
                options={[
                  {"Count only", "count_only"},
                  {"From payment (Stripe)", "from_payment"},
                  {"Fixed value", "fixed"}
                ]}
              />
            </div>

            <%!-- Detection-config field — single text input keyed by detection_type --%>
            <% detection_type = Phoenix.HTML.Form.input_value(@form, :detection_type) %>
            <div :if={detection_type in ["url_pattern", "click_element", "custom_event"]}>
              <label class="block text-sm font-medium text-gray-700 mb-1">
                {detection_label(detection_type)}
              </label>
              <input
                type="text"
                name="conversion_action[detection_config][#{detection_config_key(detection_type)}]"
                value={detection_config_value(@form, detection_type)}
                placeholder={detection_placeholder(detection_type)}
                class="w-full rounded-lg border-gray-300 shadow-sm sm:text-sm"
              />
              <p class="mt-1 text-xs text-gray-500">{detection_help(detection_type)}</p>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.input
                field={@form[:google_conversion_action_id]}
                label="Google Ads conversion action ID"
                placeholder="e.g. 891234567"
              />
              <.input
                field={@form[:google_account_timezone]}
                label="Google Ads account timezone"
                placeholder="America/Chicago"
              />
            </div>
            <.input
              field={@form[:microsoft_conversion_name]}
              label="Microsoft Ads offline conversion name"
              placeholder="e.g. Membership Purchase"
            />

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <.input
                field={@form[:attribution_window_days]}
                type="number"
                label="Attribution window (days)"
                min="1"
                max="90"
              />
              <.input
                field={@form[:attribution_model]}
                type="select"
                label="Attribution model"
                options={[{"First click", "first_click"}, {"Last click", "last_click"}]}
              />
              <.input
                field={@form[:max_scraper_score]}
                type="number"
                label="Skip if scraper score >="
                min="0"
                max="100"
              />
            </div>

            <.input field={@form[:active]} type="checkbox" label="Active" />

            <div class="flex items-center gap-3">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Save
              </button>
              <.link
                patch={~p"/dashboard/sites/#{@site.id}/conversions"}
                class="text-sm text-gray-600 hover:text-gray-900"
              >
                Cancel
              </.link>
            </div>
          </.form>
        </div>

        <%!-- List --%>
        <div class="bg-white rounded-lg shadow overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Name
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Detection
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Google ID
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Microsoft
                </th>
                <th class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                  Active
                </th>
                <th class="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-100">
              <tr :if={@actions == []}>
                <td colspan="6" class="px-6 py-8 text-center text-gray-500">
                  No conversion actions yet. Click "New Conversion Action" to add one.
                </td>
              </tr>
              <tr :for={a <- @actions} class="hover:bg-gray-50">
                <td class="px-4 py-3">
                  <div class="font-medium text-gray-900 text-sm">{a.name}</div>
                  <div class="text-xs text-gray-500">{a.kind}</div>
                </td>
                <td class="px-4 py-3 text-sm text-gray-700">
                  <span class="font-mono text-xs">{a.detection_type}</span>
                  <div
                    :if={a.detection_config != %{}}
                    class="text-xs text-gray-400 truncate max-w-[200px]"
                  >
                    {detection_config_summary(a)}
                  </div>
                </td>
                <td class="px-4 py-3 text-xs text-gray-600 font-mono">
                  {a.google_conversion_action_id || "—"}
                </td>
                <td class="px-4 py-3 text-xs text-gray-600">
                  {a.microsoft_conversion_name || "—"}
                </td>
                <td class="px-4 py-3 text-center">
                  <button
                    phx-click="toggle_active"
                    phx-value-id={a.id}
                    class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      if(a.active,
                        do: "bg-emerald-100 text-emerald-800",
                        else: "bg-gray-100 text-gray-600"
                      )
                    ]}
                  >
                    {if a.active, do: "Active", else: "Off"}
                  </button>
                </td>
                <td class="px-4 py-3 text-right text-sm">
                  <.link
                    patch={~p"/dashboard/sites/#{@site.id}/conversions/#{a.id}/edit"}
                    class="text-indigo-600 hover:text-indigo-800 mr-3"
                  >
                    Edit
                  </.link>
                  <button
                    phx-click="delete"
                    phx-value-id={a.id}
                    data-confirm="Delete this conversion action?"
                    class="text-red-600 hover:text-red-800"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp detection_label("url_pattern"), do: "URL pattern (use * as wildcard)"
  defp detection_label("click_element"), do: "Element selector"
  defp detection_label("custom_event"), do: "Custom event name"
  defp detection_label(_), do: "Detection config"

  defp detection_config_key("url_pattern"), do: "url_pattern"
  defp detection_config_key("click_element"), do: "selector"
  defp detection_config_key("custom_event"), do: "event_name"
  defp detection_config_key(_), do: "value"

  defp detection_placeholder("url_pattern"), do: "/welcome*"
  defp detection_placeholder("click_element"), do: "#publish-listing  or  text:Publish"
  defp detection_placeholder("custom_event"), do: "signup_complete"
  defp detection_placeholder(_), do: ""

  defp detection_help("url_pattern"),
    do: "Fires once per visitor when they visit a matching URL."

  defp detection_help("click_element"),
    do: "Fires once per visitor when they click a matching button or link."

  defp detection_help("custom_event"),
    do: "Fires once per visitor when your tracker sends Spectabas.track('event_name', ...)."

  defp detection_help(_), do: ""

  defp detection_config_value(form, type) do
    config = Phoenix.HTML.Form.input_value(form, :detection_config) || %{}
    Map.get(config, detection_config_key(type), "")
  end

  defp detection_config_summary(%ConversionAction{
         detection_type: "url_pattern",
         detection_config: %{"url_pattern" => p}
       }),
       do: p

  defp detection_config_summary(%ConversionAction{
         detection_type: "click_element",
         detection_config: %{"selector" => s}
       }),
       do: s

  defp detection_config_summary(%ConversionAction{
         detection_type: "custom_event",
         detection_config: %{"event_name" => n}
       }),
       do: n

  defp detection_config_summary(_), do: ""
end
