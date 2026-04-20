defmodule SpectabasWeb.Components.Spinner do
  use Phoenix.Component

  @doc "Death Star spinner — inline SVG with CSS rotation animation."
  attr :class, :string, default: "w-4 h-4"

  def death_star_spinner(assigns) do
    ~H"""
    <svg
      class={["animate-spin", @class]}
      viewBox="0 0 32 32"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <%!-- Main body --%>
      <circle cx="16" cy="16" r="14" fill="currentColor" opacity="0.15" />
      <circle cx="16" cy="16" r="14" stroke="currentColor" stroke-width="1.5" opacity="0.6" />
      <%!-- Equatorial trench --%>
      <line x1="2" y1="16" x2="30" y2="16" stroke="currentColor" stroke-width="0.8" opacity="0.5" />
      <%!-- Superlaser dish --%>
      <circle
        cx="12"
        cy="10"
        r="4.5"
        stroke="currentColor"
        stroke-width="1.2"
        opacity="0.7"
        fill="currentColor"
        fill-opacity="0.1"
      />
      <circle cx="12" cy="10" r="1.5" fill="currentColor" opacity="0.5" />
      <%!-- Surface detail lines --%>
      <line x1="5" y1="20" x2="27" y2="20" stroke="currentColor" stroke-width="0.4" opacity="0.3" />
      <line x1="7" y1="23" x2="25" y2="23" stroke="currentColor" stroke-width="0.4" opacity="0.3" />
      <line x1="16" y1="2" x2="16" y2="14" stroke="currentColor" stroke-width="0.4" opacity="0.2" />
    </svg>
    """
  end
end
