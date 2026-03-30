defmodule SpectabasWeb.Dashboard.SegmentComponent do
  @moduledoc """
  Reusable segment filter component for analytics pages.
  Renders a filter bar that emits segment filter lists.
  Supports saving, loading, and deleting segment presets.
  """
  use Phoenix.Component

  alias Spectabas.Analytics.Segment

  attr :segment, :list, default: []
  attr :on_change, :string, default: "update_segment"
  attr :saved_segments, :list, default: []
  attr :show_save_input, :boolean, default: false

  def segment_filter(assigns) do
    assigns = assign(assigns, :fields, Segment.available_fields())

    ~H"""
    <div class="bg-white rounded-lg shadow p-4 mb-6">
      <div class="flex items-center gap-2 flex-wrap">
        <span class="text-xs font-medium text-gray-500 uppercase">Filters</span>

        <div
          :for={{filter, idx} <- Enum.with_index(@segment)}
          class="flex items-center gap-1 bg-indigo-50 border border-indigo-200 rounded-md px-2 py-1"
        >
          <span class="text-xs text-indigo-700">
            {filter["field"]} {op_label(filter["op"])} "{filter["value"]}"
          </span>
          <button
            phx-click={@on_change}
            phx-value-action="remove"
            phx-value-index={idx}
            class="text-indigo-400 hover:text-indigo-600 ml-1"
          >
            &times;
          </button>
        </div>

        <form phx-submit={@on_change} class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-1">
          <input type="hidden" name="action" value="add" />
          <select name="field" class="text-sm sm:text-xs rounded border-gray-300 py-2 sm:py-1 pr-8">
            <option :for={f <- @fields} value={f.field}>{f.label}</option>
          </select>
          <select name="op" class="text-sm sm:text-xs rounded border-gray-300 py-2 sm:py-1 pr-8">
            <option value="is">is</option>
            <option value="is_not">is not</option>
            <option value="contains">contains</option>
            <option value="not_contains">not contains</option>
          </select>
          <input
            type="text"
            name="value"
            placeholder="value"
            class="text-sm sm:text-xs rounded border-gray-300 py-2 sm:py-1 w-full sm:w-32"
          />
          <button
            type="submit"
            class="text-sm sm:text-xs bg-indigo-600 text-white px-3 py-2 sm:px-2 sm:py-1 rounded hover:bg-indigo-700"
          >
            Add
          </button>
        </form>

        <button
          :if={@segment != []}
          phx-click={@on_change}
          phx-value-action="clear"
          class="text-xs text-gray-500 hover:text-gray-600 ml-2"
        >
          Clear all
        </button>
      </div>

      <%!-- Saved segments bar --%>
      <div class="flex items-center gap-2 flex-wrap mt-3 pt-3 border-t border-gray-100">
        <span class="text-xs font-medium text-gray-500 uppercase">Saved</span>

        <%!-- Saved segment pills --%>
        <div
          :for={saved <- @saved_segments}
          class="flex items-center gap-1 bg-gray-50 border border-gray-200 rounded-md px-2 py-1"
        >
          <button
            phx-click={@on_change}
            phx-value-action="load"
            phx-value-segment_id={saved.id}
            class="text-xs text-gray-700 hover:text-indigo-600"
          >
            {saved.name}
          </button>
          <button
            phx-click={@on_change}
            phx-value-action="delete_saved"
            phx-value-segment_id={saved.id}
            class="text-gray-400 hover:text-red-500 ml-1 text-xs"
            data-confirm="Delete this saved segment?"
          >
            &times;
          </button>
        </div>

        <%!-- Save button / input --%>
        <div :if={@segment != [] && !@show_save_input}>
          <button
            phx-click={@on_change}
            phx-value-action="show_save"
            class="text-xs bg-gray-100 text-gray-600 px-2 py-1 rounded hover:bg-gray-200"
          >
            Save current
          </button>
        </div>

        <form
          :if={@show_save_input}
          phx-submit={@on_change}
          class="flex items-center gap-1"
        >
          <input type="hidden" name="action" value="save" />
          <input
            type="text"
            name="segment_name"
            placeholder="Segment name"
            autofocus
            class="text-xs rounded border-gray-300 py-1 px-2 w-32"
          />
          <button
            type="submit"
            class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
          >
            Save
          </button>
          <button
            type="button"
            phx-click={@on_change}
            phx-value-action="hide_save"
            class="text-xs text-gray-400 hover:text-gray-600"
          >
            Cancel
          </button>
        </form>

        <span :if={@saved_segments == [] && @segment == []} class="text-xs text-gray-400">
          No saved segments yet. Add filters and click Save.
        </span>
      </div>
    </div>
    """
  end

  defp op_label("is"), do: "="
  defp op_label("is_not"), do: "!="
  defp op_label("contains"), do: "~"
  defp op_label("not_contains"), do: "!~"
  defp op_label(op), do: op
end
