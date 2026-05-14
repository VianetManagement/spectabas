defmodule SpectabasWeb.Dashboard.CohortsLive do
  @moduledoc """
  Lists saved cohorts for a site. From here the user can create a new
  cohort (name + segment filters), open one in the detail view, or pick
  two for the comparison view.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Cohorts}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.SegmentComponent

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      # Optional prefill — used by deep-links from other pages
      # (e.g. FormDetail's "Create cohort of abandoners" button).
      prefill_field = params["prefill_field"]
      prefill_value = params["prefill_value"]
      prefill_name = params["prefill_name"]
      prefill_op = params["prefill_op"] || "is"

      prefill_segment =
        if is_binary(prefill_field) and prefill_field != "" and is_binary(prefill_value) and
             prefill_value != "" do
          [%{"field" => prefill_field, "op" => prefill_op, "value" => prefill_value}]
        else
          []
        end

      show_new = prefill_segment != []

      {:ok,
       socket
       |> assign(:page_title, "Cohorts - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:cohorts, Cohorts.list_for_user(site.id, user.id))
       |> assign(:show_new_form, show_new)
       |> assign(:new_segment, prefill_segment)
       |> assign(:new_name, prefill_name || "")
       |> assign(:new_description, "")
       |> assign(:new_visibility, "private")
       |> assign(:compare_a, nil)
       |> assign(:compare_b, nil)}
    end
  end

  @impl true
  def handle_event("show_new", _params, socket) do
    {:noreply, assign(socket, :show_new_form, true)}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_form, false)
     |> assign(:new_segment, [])
     |> assign(:new_name, "")
     |> assign(:new_description, "")}
  end

  def handle_event("update_form", %{"_target" => ["new_name"], "new_name" => v}, socket) do
    {:noreply, assign(socket, :new_name, v)}
  end

  def handle_event(
        "update_form",
        %{"_target" => ["new_description"], "new_description" => v},
        socket
      ) do
    {:noreply, assign(socket, :new_description, v)}
  end

  def handle_event(
        "update_form",
        %{"_target" => ["new_visibility"], "new_visibility" => v},
        socket
      ) do
    {:noreply, assign(socket, :new_visibility, v)}
  end

  def handle_event("update_form", _params, socket), do: {:noreply, socket}

  # Reuse SegmentComponent's update_segment event shape so we don't
  # reinvent the filter-row affordance for the cohort builder.
  def handle_event(
        "update_segment",
        %{"action" => "add", "field" => f, "op" => op, "value" => v},
        socket
      )
      when v != "" do
    seg = socket.assigns.new_segment ++ [%{"field" => f, "op" => op, "value" => v}]
    {:noreply, assign(socket, :new_segment, seg)}
  end

  def handle_event("update_segment", %{"action" => "remove", "index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    seg = List.delete_at(socket.assigns.new_segment, idx)
    {:noreply, assign(socket, :new_segment, seg)}
  end

  def handle_event("update_segment", %{"action" => "clear"}, socket) do
    {:noreply, assign(socket, :new_segment, [])}
  end

  def handle_event("update_segment", _, socket), do: {:noreply, socket}

  def handle_event("create_cohort", _params, socket) do
    if String.trim(socket.assigns.new_name) == "" do
      {:noreply, put_flash(socket, :error, "Name is required.")}
    else
      attrs = %{
        "name" => socket.assigns.new_name,
        "description" => socket.assigns.new_description,
        "visibility" => socket.assigns.new_visibility,
        "filters" => socket.assigns.new_segment
      }

      case Cohorts.create(socket.assigns.site.id, socket.assigns.user.id, attrs) do
        {:ok, _cohort} ->
          {:noreply,
           socket
           |> put_flash(:info, "Cohort created.")
           |> assign(:show_new_form, false)
           |> assign(:new_segment, [])
           |> assign(:new_name, "")
           |> assign(:new_description, "")
           |> assign(
             :cohorts,
             Cohorts.list_for_user(socket.assigns.site.id, socket.assigns.user.id)
           )}

        {:error, changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Couldn't save: #{inspect(changeset.errors) |> String.slice(0, 200)}"
           )}
      end
    end
  end

  def handle_event("delete_cohort", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    case Cohorts.delete(socket.assigns.site.id, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cohort deleted.")
         |> assign(
           :cohorts,
           Cohorts.list_for_user(socket.assigns.site.id, socket.assigns.user.id)
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't delete.")}
    end
  end

  def handle_event("pick_compare", %{"slot" => slot, "id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    {:noreply, assign(socket, String.to_atom("compare_#{slot}"), id)}
  end

  def handle_event("start_compare", _params, socket) do
    if socket.assigns.compare_a && socket.assigns.compare_b &&
         socket.assigns.compare_a != socket.assigns.compare_b do
      {:noreply,
       push_navigate(socket,
         to:
           ~p"/dashboard/sites/#{socket.assigns.site.id}/cohorts/compare?a=#{socket.assigns.compare_a}&b=#{socket.assigns.compare_b}"
       )}
    else
      {:noreply, put_flash(socket, :error, "Pick two different cohorts to compare.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Cohorts"
      page_description="Saved visitor segments. Compare any two side-by-side."
      active="cohorts"
      live_visitors={0}
    >
      <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Cohorts</h1>
            <p class="text-sm text-gray-500 mt-1">
              Named visitor segments. Define once, reuse + compare. Filter language matches the Segment bar elsewhere.
            </p>
          </div>
          <button
            :if={!@show_new_form}
            phx-click="show_new"
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
          >
            New cohort
          </button>
        </div>

        <%!-- Create form --%>
        <div :if={@show_new_form} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-sm font-semibold text-gray-900 mb-4">New cohort</h2>
          <form phx-change="update_form" phx-submit="create_cohort">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <div>
                <label class="block text-xs text-gray-500 mb-1">Name *</label>
                <input
                  type="text"
                  name="new_name"
                  value={@new_name}
                  required
                  maxlength="100"
                  class="w-full text-sm rounded border-gray-300"
                  placeholder="e.g. Mobile visitors from Reddit"
                />
              </div>
              <div class="md:col-span-2">
                <label class="block text-xs text-gray-500 mb-1">Description</label>
                <input
                  type="text"
                  name="new_description"
                  value={@new_description}
                  maxlength="200"
                  class="w-full text-sm rounded border-gray-300"
                  placeholder="Optional context for teammates"
                />
              </div>
            </div>
            <div class="mb-4">
              <label class="block text-xs text-gray-500 mb-1">Visibility</label>
              <select name="new_visibility" class="text-sm rounded border-gray-300">
                <option value="private" selected={@new_visibility == "private"}>
                  Private — only me
                </option>
                <option value="site" selected={@new_visibility == "site"}>
                  Site — everyone on the team
                </option>
              </select>
            </div>
            <div class="mb-4">
              <label class="block text-xs text-gray-500 mb-1">Filters</label>
              <.segment_filter
                segment={@new_segment}
                on_change="update_segment"
                saved_segments={[]}
                show_save_input={false}
                filter_options={%{}}
                segment_field=""
              />
            </div>
            <div class="flex gap-2">
              <button
                type="submit"
                class="px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create
              </button>
              <button
                type="button"
                phx-click="cancel_new"
                class="px-4 py-2 text-sm font-medium rounded-lg text-gray-700 bg-white hover:bg-gray-50 border border-gray-300"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>

        <%!-- Compare picker --%>
        <div :if={@cohorts != [] && length(@cohorts) >= 2} class="bg-white rounded-lg shadow p-4 mb-6">
          <h2 class="text-sm font-semibold text-gray-900 mb-3">Compare two cohorts</h2>
          <div class="flex items-center gap-3 flex-wrap">
            <span class="text-xs text-gray-500">A:</span>
            <select
              class="text-sm rounded border-gray-300"
              phx-change="pick_compare"
              name="id"
            >
              <option value="">— pick —</option>
              <option
                :for={c <- @cohorts}
                value={c.id}
                selected={@compare_a == c.id}
                phx-value-slot="a"
              >
                {c.name}
              </option>
            </select>
            <span class="text-xs text-gray-500">vs B:</span>
            <select class="text-sm rounded border-gray-300" phx-change="pick_compare" name="id">
              <option value="">— pick —</option>
              <option
                :for={c <- @cohorts}
                value={c.id}
                selected={@compare_b == c.id}
                phx-value-slot="b"
              >
                {c.name}
              </option>
            </select>
            <button
              phx-click="start_compare"
              class="ml-2 px-3 py-1.5 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Compare →
            </button>
          </div>
        </div>

        <%!-- Cohort list --%>
        <div
          :if={@cohorts == []}
          class="bg-white rounded-lg shadow p-10 text-center text-sm text-gray-500"
        >
          No cohorts yet. Click "New cohort" to define your first.
        </div>

        <div :if={@cohorts != []} class="bg-white rounded-lg shadow overflow-hidden">
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
                <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visibility
                </th>
                <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Filters
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={c <- @cohorts} class="hover:bg-gray-50">
                <td class="px-5 py-3">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/cohorts/#{c.id}"}
                    class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
                  >
                    {c.name}
                  </.link>
                  <p :if={c.description} class="text-xs text-gray-500 mt-0.5">{c.description}</p>
                </td>
                <td class="px-5 py-3 text-xs text-gray-600 capitalize">{c.visibility}</td>
                <td class="px-5 py-3 text-xs text-gray-600">
                  {length(Spectabas.Cohorts.Cohort.filters_list(c))} filter(s)
                </td>
                <td class="px-5 py-3 text-right">
                  <button
                    phx-click="delete_cohort"
                    phx-value-id={c.id}
                    data-confirm={"Delete cohort \"#{c.name}\"?"}
                    class="text-xs text-red-600 hover:text-red-800"
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
end
