defmodule SpectabasWeb.Admin.ASNManagementLive do
  use SpectabasWeb, :live_view

  alias Spectabas.ASNManagement
  alias Spectabas.IPEnricher.ASNBlocklist

  @impl true
  def mount(_params, _session, socket) do
    overrides = ASNManagement.list_overrides(limit: 100)
    {dc_count, vpn_count, tor_count} = blocklist_sizes()

    {:ok,
     socket
     |> assign(:page_title, "ASN Management")
     |> assign(:overrides, overrides)
     |> assign(:dc_count, dc_count)
     |> assign(:vpn_count, vpn_count)
     |> assign(:tor_count, tor_count)
     |> assign(:tab, "active")
     |> assign(:add_form, nil)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    overrides =
      case tab do
        "active" -> ASNManagement.list_overrides(active: true, limit: 100)
        "inactive" -> ASNManagement.list_overrides(active: false, limit: 100)
        "all" -> ASNManagement.list_overrides(limit: 100)
        _ -> ASNManagement.list_overrides(active: true, limit: 100)
      end

    {:noreply, socket |> assign(:tab, tab) |> assign(:overrides, overrides)}
  end

  def handle_event("run_discovery", _params, socket) do
    Oban.insert(Spectabas.Workers.ASNDiscovery.new(%{}))

    {:noreply,
     socket
     |> put_flash(
       :info,
       "ASN discovery scan queued. Results will appear here within a few minutes."
     )}
  end

  def handle_event("show_add_form", _params, socket) do
    {:noreply,
     assign(socket, :add_form, %{asn: "", org: "", classification: "datacenter", reason: ""})}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, :add_form, nil)}
  end

  def handle_event(
        "add_asn",
        %{"asn" => asn_str, "org" => org, "classification" => classification, "reason" => reason},
        socket
      ) do
    case Integer.parse(String.replace(asn_str, ~r/^AS/i, "")) do
      {asn_number, _} ->
        case ASNManagement.add_override(%{
               asn_number: asn_number,
               asn_org: org,
               classification: classification,
               source: "manual",
               reason: "Manual: #{reason}",
               active: true
             }) do
          {:ok, override} ->
            submit_backfill_for(override)
            overrides = ASNManagement.list_overrides(active: true, limit: 100)

            {:noreply,
             socket
             |> assign(:overrides, overrides)
             |> assign(:add_form, nil)
             |> put_flash(
               :info,
               "AS#{asn_number} (#{org}) added as #{classification}. Backfill submitted."
             )}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to add ASN. It may already be tracked.")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid ASN number.")}
    end
  end

  def handle_event("approve", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case ASNManagement.deactivate_override(id) do
      {:ok, old} ->
        case ASNManagement.add_override(%{
               asn_number: old.asn_number,
               asn_org: old.asn_org,
               classification: old.classification,
               source: "manual",
               reason: "Approved from auto-candidate: #{old.reason}",
               auto_evidence: old.auto_evidence,
               active: true
             }) do
          {:ok, override} ->
            submit_backfill_for(override)
            overrides = ASNManagement.list_overrides(limit: 100)

            {:noreply,
             socket
             |> assign(:overrides, overrides)
             |> put_flash(:info, "AS#{old.asn_number} approved and backfill submitted.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to approve.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Override not found.")}
    end
  end

  def handle_event("deactivate", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case ASNManagement.deactivate_override(id) do
      {:ok, override} ->
        overrides = ASNManagement.list_overrides(limit: 100)

        {:noreply,
         socket
         |> assign(:overrides, overrides)
         |> put_flash(:info, "AS#{override.asn_number} deactivated.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Override not found.")}
    end
  end

  defp submit_backfill_for(%ASNManagement.Override{classification: "datacenter"} = override) do
    sql = """
    ALTER TABLE events UPDATE ip_is_datacenter = 1
    WHERE ip_asn = #{Spectabas.ClickHouse.param(override.asn_number)}
      AND ip_is_datacenter = 0
    SETTINGS mutations_sync = 0
    """

    case Spectabas.ClickHouse.execute(sql) do
      :ok -> ASNManagement.mark_backfilled(override.id)
      _ -> :ok
    end
  end

  defp submit_backfill_for(_), do: :ok

  defp blocklist_sizes do
    try do
      ASNBlocklist.sizes()
    rescue
      _ -> {0, 0, 0}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">ASN Management</h1>
          <p class="text-sm text-gray-500 mt-1">
            Auto-discovered and manually managed ASN classifications.
            Blocklist files: {@dc_count} datacenter, {@vpn_count} VPN, {@tor_count} Tor.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="run_discovery"
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
          >
            Run Discovery Scan
          </button>
          <button
            phx-click="show_add_form"
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-gray-700 bg-white hover:bg-gray-50 border border-gray-300 shadow-sm"
          >
            Add ASN Manually
          </button>
        </div>
      </div>

      <%!-- Manual add form --%>
      <div :if={@add_form} class="bg-white rounded-lg shadow p-6 mb-6">
        <h3 class="text-sm font-semibold text-gray-900 mb-4">Add ASN Override</h3>
        <form phx-submit="add_asn" class="flex items-end gap-4">
          <div>
            <label class="block text-xs text-gray-500 mb-1">ASN Number</label>
            <input
              type="text"
              name="asn"
              placeholder="16276 or AS16276"
              class="block w-36 rounded-lg border-gray-300 text-sm"
              required
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Organization</label>
            <input
              type="text"
              name="org"
              placeholder="OVH SAS"
              class="block w-48 rounded-lg border-gray-300 text-sm"
            />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Classification</label>
            <select name="classification" class="block rounded-lg border-gray-300 text-sm">
              <option value="datacenter">Datacenter</option>
              <option value="vpn">VPN</option>
              <option value="privacy_relay">Privacy Relay</option>
              <option value="residential">Residential</option>
            </select>
          </div>
          <div class="flex-1">
            <label class="block text-xs text-gray-500 mb-1">Reason</label>
            <input
              type="text"
              name="reason"
              placeholder="Why is this being added?"
              class="block w-full rounded-lg border-gray-300 text-sm"
              required
            />
          </div>
          <button
            type="submit"
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-green-600 hover:bg-green-700"
          >
            Add
          </button>
          <button
            type="button"
            phx-click="cancel_add"
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-gray-700 bg-gray-100 hover:bg-gray-200"
          >
            Cancel
          </button>
        </form>
      </div>

      <%!-- Tabs --%>
      <nav class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-6 w-fit">
        <button
          :for={
            {id, label, count} <- [
              {"active", "Active", Enum.count(@overrides, & &1.active)},
              {"inactive", "Candidates / Inactive", Enum.count(@overrides, &(not &1.active))},
              {"all", "All", length(@overrides)}
            ]
          }
          phx-click="switch_tab"
          phx-value-tab={id}
          class={[
            "px-4 py-1.5 text-sm font-medium rounded-md",
            if(@tab == id,
              do: "bg-white shadow text-gray-900",
              else: "text-gray-600 hover:text-gray-900"
            )
          ]}
        >
          {label} ({count})
        </button>
      </nav>

      <%!-- Override list --%>
      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">ASN</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Organization
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Classification
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Source</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Evidence
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Date</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={o <- filtered_overrides(@overrides, @tab)} class="hover:bg-gray-50">
              <td class="px-4 py-3 text-sm font-mono text-gray-900">AS{o.asn_number}</td>
              <td class="px-4 py-3 text-sm text-gray-700">{o.asn_org}</td>
              <td class="px-4 py-3">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  classification_color(o.classification)
                ]}>
                  {o.classification}
                </span>
              </td>
              <td class="px-4 py-3">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  source_color(o.source)
                ]}>
                  {o.source}
                </span>
                <span :if={o.backfill_submitted} class="ml-1 text-xs text-green-600">backfilled</span>
              </td>
              <td class="px-4 py-3 text-xs text-gray-500 max-w-xs truncate" title={o.reason}>
                <%= if o.auto_evidence do %>
                  <span class="font-medium">{o.auto_evidence["visitors"] || "?"}</span>
                  visitors,
                  <span class="font-medium">{format_avg(o.auto_evidence["avg_pages"])}</span>
                  avg pgs, <span class="font-medium">{o.auto_evidence["bounce_rate"] || "?"}%</span>
                  bounce
                <% else %>
                  {String.slice(o.reason || "", 0, 60)}
                <% end %>
              </td>
              <td class="px-4 py-3 text-xs text-gray-500">
                {Calendar.strftime(o.inserted_at, "%b %d, %Y")}
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center gap-1">
                  <button
                    :if={not o.active}
                    phx-click="approve"
                    phx-value-id={o.id}
                    class="text-xs text-green-600 hover:text-green-800 font-medium"
                  >
                    Approve
                  </button>
                  <button
                    :if={o.active}
                    phx-click="deactivate"
                    phx-value-id={o.id}
                    data-confirm={"Deactivate AS#{o.asn_number}? This won't undo the ClickHouse backfill."}
                    class="text-xs text-red-600 hover:text-red-800 font-medium"
                  >
                    Deactivate
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={filtered_overrides(@overrides, @tab) == []}
          class="px-6 py-8 text-center text-sm text-gray-500"
        >
          No ASN overrides yet. Run a discovery scan or add one manually.
        </div>
      </div>
    </div>
    """
  end

  defp filtered_overrides(overrides, "active"), do: Enum.filter(overrides, & &1.active)
  defp filtered_overrides(overrides, "inactive"), do: Enum.filter(overrides, &(not &1.active))
  defp filtered_overrides(overrides, _), do: overrides

  defp classification_color("datacenter"), do: "bg-red-100 text-red-800"
  defp classification_color("vpn"), do: "bg-purple-100 text-purple-800"
  defp classification_color("privacy_relay"), do: "bg-blue-100 text-blue-800"
  defp classification_color("residential"), do: "bg-green-100 text-green-800"
  defp classification_color(_), do: "bg-gray-100 text-gray-700"

  defp source_color("auto"), do: "bg-indigo-100 text-indigo-800"
  defp source_color("manual"), do: "bg-amber-100 text-amber-800"
  defp source_color("file"), do: "bg-gray-100 text-gray-700"
  defp source_color(_), do: "bg-gray-100 text-gray-700"

  defp format_avg(nil), do: "?"
  defp format_avg(n) when is_number(n), do: Float.round(n * 1.0, 1)
  defp format_avg(_), do: "?"
end
