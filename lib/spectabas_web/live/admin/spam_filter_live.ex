defmodule SpectabasWeb.Admin.SpamFilterLive do
  @moduledoc "Admin page for managing the referrer spam domain blocklist."

  use SpectabasWeb, :live_view

  alias Spectabas.Analytics.SpamFilter

  @impl true
  def mount(_params, _session, socket) do
    domains = SpamFilter.list_domains()
    candidates = safe_detect_candidates()

    {:ok,
     socket
     |> assign(:page_title, "Spam Filter")
     |> assign(:domains, domains)
     |> assign(:candidates, candidates)
     |> assign(:domain_input, "")
     |> assign(:flash_msg, nil)}
  end

  @impl true
  def handle_event("add_domain", %{"domain" => domain}, socket) do
    domain = String.trim(domain)

    if domain == "" do
      {:noreply, put_flash(socket, :error, "Domain cannot be empty")}
    else
      case SpamFilter.add_domain(domain, "manual") do
        {:ok, _record} ->
          {:noreply,
           socket
           |> assign(:domains, SpamFilter.list_domains())
           |> assign(:domain_input, "")
           |> put_flash(:info, "Added #{domain} to spam blocklist")}

        {:error, changeset} ->
          msg = error_message(changeset)
          {:noreply, put_flash(socket, :error, "Failed to add domain: #{msg}")}
      end
    end
  end

  def handle_event("approve_candidate", %{"domain" => domain}, socket) do
    case SpamFilter.add_domain(domain, "auto") do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(:domains, SpamFilter.list_domains())
         |> assign(:candidates, safe_detect_candidates())
         |> put_flash(:info, "Added #{domain} to spam blocklist")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add #{domain}")}
    end
  end

  def handle_event("remove_domain", %{"domain" => domain}, socket) do
    case SpamFilter.remove_domain(domain) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:domains, SpamFilter.list_domains())
         |> put_flash(:info, "Removed #{domain} from blocklist")}

      {:error, :builtin_domain} ->
        {:noreply, put_flash(socket, :error, "Cannot remove builtin domains")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Domain not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove domain")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Admin Dashboard
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Spam Filter</h1>
        <p class="text-sm text-gray-500 mt-1">
          Manage referrer spam domains blocked from analytics
        </p>
      </div>

      <%!-- Add Domain --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Add Domain</h2>
        <form phx-submit="add_domain" class="flex gap-3">
          <input
            type="text"
            name="domain"
            value={@domain_input}
            placeholder="spammy-domain.com"
            class="flex-1 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
          />
          <button
            type="submit"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
          >
            Add
          </button>
        </form>
      </div>

      <%!-- Spam Candidates --%>
      <div :if={@candidates != []} class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">
          Spam Candidates
          <span class="text-sm font-normal text-gray-500">
            &mdash; auto-detected suspicious domains
          </span>
        </h2>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Domain
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Hits
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Sites
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Bot %
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Action
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :for={c <- @candidates}>
                <td class="px-4 py-3 text-sm text-gray-900">{c.domain}</td>
                <td class="px-4 py-3 text-sm text-gray-600 text-right">
                  {format_number(c.hits)}
                </td>
                <td class="px-4 py-3 text-sm text-gray-600 text-right">{c.sites_affected}</td>
                <td class="px-4 py-3 text-sm text-right">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                    if(c.bot_pct > 75,
                      do: "bg-red-100 text-red-800",
                      else: "bg-amber-100 text-amber-800"
                    )
                  ]}>
                    {c.bot_pct}%
                  </span>
                </td>
                <td class="px-4 py-3 text-sm text-right">
                  <button
                    phx-click="approve_candidate"
                    phx-value-domain={c.domain}
                    class="text-indigo-600 hover:text-indigo-800 text-sm font-medium"
                  >
                    Add to blocklist
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Active Blocklist --%>
      <div class="bg-white rounded-lg shadow p-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">
          Active Blocklist
          <span class="text-sm font-normal text-gray-500">
            &mdash; {@domains |> length()} domains
          </span>
        </h2>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Domain
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Hits (30d)
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Seen
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :for={d <- @domains}>
                <td class="px-4 py-3 text-sm text-gray-900">{d.domain}</td>
                <td class="px-4 py-3 text-sm">
                  <span class={source_pill_class(d.source)}>{d.source}</span>
                </td>
                <td class="px-4 py-3 text-sm text-gray-600 text-right">
                  {format_number(d.hits_total)}
                </td>
                <td class="px-4 py-3 text-sm text-gray-500">
                  {format_last_seen(d.last_seen_at)}
                </td>
                <td class="px-4 py-3 text-sm text-right">
                  <button
                    :if={d.source != "builtin"}
                    phx-click="remove_domain"
                    phx-value-domain={d.domain}
                    class="text-red-600 hover:text-red-800 text-sm font-medium"
                    data-confirm={"Remove #{d.domain} from blocklist?"}
                  >
                    Remove
                  </button>
                  <span :if={d.source == "builtin"} class="text-gray-400 text-xs">builtin</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp source_pill_class("builtin"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-700"

  defp source_pill_class("manual"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-700"

  defp source_pill_class("auto"),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 text-amber-700"

  defp source_pill_class(_),
    do:
      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-600"

  defp format_number(n) when is_integer(n) and n >= 1000 do
    n |> Integer.to_string() |> add_commas()
  end

  defp format_number(n), do: "#{n}"

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_last_seen(nil), do: "-"

  defp format_last_seen(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_last_seen(_), do: "-"

  defp safe_detect_candidates do
    SpamFilter.detect_spam_candidates()
  rescue
    _ -> []
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end

  defp error_message(_), do: "unknown error"
end
