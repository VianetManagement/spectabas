defmodule SpectabasWeb.Dashboard.ChatComponent do
  use SpectabasWeb, :live_component

  alias Spectabas.AI.HelpChat

  @max_messages 40

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:messages, [])
     |> assign(:loading, false)
     |> assign(:input, "")}
  end

  @impl true
  def update(%{ai_response: {:ok, text}}, socket) do
    messages = socket.assigns.messages ++ [%{role: :assistant, content: text}]
    {:ok, assign(socket, messages: messages, loading: false)}
  end

  def update(%{ai_response: {:error, _reason}}, socket) do
    messages =
      socket.assigns.messages ++
        [%{role: :assistant, content: "Sorry, I couldn't process that. Please try again."}]

    {:ok, assign(socket, messages: messages, loading: false)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, id: assigns.id)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, :open, !socket.assigns.open)}
  end

  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" or socket.assigns.loading do
      {:noreply, socket}
    else
      messages = socket.assigns.messages ++ [%{role: :user, content: message}]
      messages = Enum.take(messages, -@max_messages)

      pid = self()
      component_id = socket.assigns.id

      Task.start(fn ->
        result = HelpChat.generate(messages)
        send_update(pid, __MODULE__, id: component_id, ai_response: result)
      end)

      {:noreply, assign(socket, messages: messages, loading: true, input: "")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%!-- Floating button --%>
      <button
        :if={!@open}
        phx-click="toggle"
        phx-target={@myself}
        class="fixed bottom-5 right-5 z-40 w-12 h-12 bg-indigo-600 hover:bg-indigo-700 text-white rounded-full shadow-lg flex items-center justify-center transition-transform hover:scale-105"
        aria-label="Open help chat"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="w-6 h-6"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M8.625 12a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0H8.25m4.125 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0H12m4.125 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0h-.375M21 12c0 4.556-4.03 8.25-9 8.25a9.764 9.764 0 0 1-2.555-.337A5.972 5.972 0 0 1 5.41 20.97a5.969 5.969 0 0 1-.474-.065 4.48 4.48 0 0 0 .978-2.025c.09-.457-.133-.901-.467-1.226C3.93 16.178 3 14.189 3 12c0-4.556 4.03-8.25 9-8.25s9 3.694 9 8.25Z"
          />
        </svg>
      </button>

      <%!-- Chat panel --%>
      <div
        :if={@open}
        class="fixed bottom-5 right-5 z-40 w-96 h-[32rem] bg-white rounded-xl shadow-2xl border border-gray-200 flex flex-col overflow-hidden"
      >
        <%!-- Header --%>
        <div class="flex items-center justify-between px-4 py-3 bg-indigo-600 text-white shrink-0">
          <div class="flex items-center gap-2">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-5 h-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M9.813 15.904 9 18.75l-.813-2.846a4.5 4.5 0 0 0-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 0 0 3.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 0 0 3.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 0 0-3.09 3.09ZM18.259 8.715 18 9.75l-.259-1.035a3.375 3.375 0 0 0-2.455-2.456L14.25 6l1.036-.259a3.375 3.375 0 0 0 2.455-2.456L18 2.25l.259 1.035a3.375 3.375 0 0 0 2.455 2.456L21.75 6l-1.036.259a3.375 3.375 0 0 0-2.455 2.456Z"
              />
            </svg>
            <span class="font-semibold text-sm">Help</span>
          </div>
          <button
            phx-click="toggle"
            phx-target={@myself}
            class="hover:bg-indigo-500 rounded p-1 transition-colors"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-4 h-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <%!-- Messages --%>
        <div
          id="chat-messages"
          phx-hook="ChatScroll"
          class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
        >
          <div :if={@messages == []} class="text-center text-gray-400 text-sm mt-8">
            <p class="font-medium text-gray-500 mb-1">Ask me anything about Spectabas</p>
            <p>
              How to set up tracking, create goals, read your dashboard, configure integrations...
            </p>
          </div>
          <div
            :for={msg <- @messages}
            class={[
              "max-w-[85%] px-3 py-2 rounded-lg text-sm",
              if(msg.role == :user,
                do: "ml-auto bg-indigo-600 text-white",
                else: "bg-gray-100 text-gray-800"
              )
            ]}
          >
            <div
              :if={msg.role == :assistant}
              class="prose prose-sm prose-gray max-w-none [&>p]:my-1 [&>ul]:my-1 [&>ol]:my-1 [&>pre]:my-1"
            >
              {raw(render_markdown(msg.content))}
            </div>
            <span :if={msg.role == :user}>{msg.content}</span>
          </div>
          <div :if={@loading} class="flex items-center gap-1.5 px-3 py-2">
            <span class="w-2 h-2 bg-gray-400 rounded-full animate-bounce [animation-delay:0ms]">
            </span>
            <span class="w-2 h-2 bg-gray-400 rounded-full animate-bounce [animation-delay:150ms]">
            </span>
            <span class="w-2 h-2 bg-gray-400 rounded-full animate-bounce [animation-delay:300ms]">
            </span>
          </div>
        </div>

        <%!-- Input --%>
        <form
          phx-submit="send"
          phx-target={@myself}
          class="shrink-0 border-t border-gray-200 px-3 py-2 flex gap-2"
        >
          <input
            type="text"
            name="message"
            value={@input}
            placeholder={if @loading, do: "Thinking...", else: "Ask a question..."}
            disabled={@loading}
            autocomplete="off"
            class="flex-1 text-sm rounded-lg border-gray-300 focus:border-indigo-500 focus:ring-indigo-500 disabled:bg-gray-50 disabled:text-gray-400"
          />
          <button
            type="submit"
            disabled={@loading}
            class="px-3 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp render_markdown(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/`(.+?)`/, "<code class=\"bg-gray-200 px-1 rounded text-xs\">\\1</code>")
    |> String.replace(~r/\n- /, "\n<br/>&#8226; ")
    |> String.replace(~r/\n\d+\. /, fn m -> "\n<br/>" <> String.trim(m) <> " " end)
    |> String.replace("\n\n", "<br/><br/>")
    |> String.replace("\n", "<br/>")
  end
end
