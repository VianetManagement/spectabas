defmodule SpectabasWeb.Dashboard.SegmentComponent do
  @moduledoc """
  Reusable segment filter component for analytics pages.
  Renders a filter bar that emits segment filter lists.
  """
  use Phoenix.Component

  alias Spectabas.Analytics.Segment

  attr :segment, :list, default: []
  attr :on_change, :string, default: "update_segment"

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

        <form phx-submit={@on_change} class="flex items-center gap-1">
          <input type="hidden" name="action" value="add" />
          <select name="field" class="text-xs rounded border-gray-300 py-1 pr-8">
            <option :for={f <- @fields} value={f.field}>{f.label}</option>
          </select>
          <select name="op" class="text-xs rounded border-gray-300 py-1 pr-8">
            <option value="is">is</option>
            <option value="is_not">is not</option>
            <option value="contains">contains</option>
            <option value="not_contains">not contains</option>
          </select>
          <input
            type="text"
            name="value"
            placeholder="value"
            class="text-xs rounded border-gray-300 py-1 w-32"
          />
          <button
            type="submit"
            class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
          >
            Add
          </button>
        </form>

        <button
          :if={@segment != []}
          phx-click={@on_change}
          phx-value-action="clear"
          class="text-xs text-gray-400 hover:text-gray-600 ml-2"
        >
          Clear all
        </button>
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
