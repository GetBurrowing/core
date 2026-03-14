defmodule PlatformWeb.ChatLive do
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Core Chat")
     |> assign(:messages, seed_messages())
     |> assign_form("")}
  end

  @impl true
  def handle_event("send", %{"chat" => %{"message" => message}}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      timestamp = Calendar.strftime(DateTime.utc_now(), "%I:%M %p UTC")

      # Add user message immediately
      messages =
        socket.assigns.messages ++
          [%{role: :user, body: message, at: timestamp}]

      # Build conversation history for the API (last 20 messages)
      history =
        messages
        |> Enum.filter(&(&1.role in [:user, :assistant]))
        |> Enum.take(-20)
        |> Enum.map(fn msg ->
          %{"role" => to_string(msg.role), "content" => msg.body}
        end)

      # Add thinking indicator
      messages =
        messages ++ [%{role: :assistant, body: "Thinking...", at: timestamp, thinking: true}]

      # Fire async API call
      lv = self()

      Task.start(fn ->
        case Platform.Agents.QuickAgent.chat(message, history: Enum.drop(history, -1)) do
          {:ok, %{content: content}} ->
            send(lv, {:agent_response, content})

          {:error, reason} ->
            send(lv, {:agent_response, "⚠️ Agent error: #{reason}"})
        end
      end)

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> assign_form("")}
    end
  end

  @impl true
  def handle_info({:agent_response, content}, socket) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%I:%M %p UTC")

    # Replace the "Thinking..." message with the real response
    messages =
      socket.assigns.messages
      |> Enum.reject(&Map.get(&1, :thinking, false))
      |> Kernel.++([%{role: :assistant, body: content, at: timestamp}])

    {:noreply, assign(socket, :messages, messages)}
  end

  defp assign_form(socket, message) do
    assign(socket, :form, to_form(%{"message" => message}, as: :chat))
  end

  defp seed_messages do
    [
      %{
        role: :assistant,
        body:
          "⚡ Agent online. Workspace loaded from .openclaw folder — personality, identity, and context active. Say something.",
        at: "Now"
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="border-b border-base-300 px-5 py-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <p class="text-sm font-medium uppercase tracking-[0.2em] text-base-content/60">
              Startup Suite
            </p>
            <h1 class="mt-1 text-xl font-semibold tracking-tight">Core Chat</h1>
            <p class="mt-1 max-w-3xl text-sm leading-6 text-base-content/70">
              The first surface for the suite. Elixir/Phoenix underneath, plain language up top,
              and a deliberately restrained interface while the rest of the platform comes online.
            </p>
          </div>
          <div class="flex flex-wrap gap-2 text-xs font-medium">
            <span class="badge badge-outline">Chat first</span>
            <span class="badge badge-outline">Tasks later</span>
            <span class="badge badge-outline">Shell planned</span>
          </div>
        </div>
      </div>

      <div class="flex-1 space-y-4 overflow-y-auto px-5 py-5">
        <div :for={message <- @messages} class={message_row_class(message.role)}>
          <div class={message_bubble_class(message.role)}>
            <div class="mb-2 flex items-center justify-between gap-4 text-xs uppercase tracking-wide text-base-content/50">
              <span>{role_label(message.role)}</span>
              <span>{message.at}</span>
            </div>
            <p class="text-sm leading-6">{message.body}</p>
          </div>
        </div>
      </div>

      <div class="border-t border-base-300 px-5 py-4">
        <div class="mb-2 text-xs text-base-content/50">suite.example.com</div>
        <.form for={@form} id="chat-form" phx-submit="send" class="flex flex-col gap-3 md:flex-row">
          <.input
            field={@form[:message]}
            type="text"
            placeholder="Type a message"
            autocomplete="off"
            class="w-full"
          />
          <button type="submit" class="btn btn-neutral md:self-end">Send</button>
        </.form>
      </div>
    </div>
    """
  end

  defp role_label(:assistant), do: "⚡ Zip"
  defp role_label(:user), do: "You"

  defp message_row_class(:assistant), do: "flex justify-start"
  defp message_row_class(:user), do: "flex justify-end"

  defp message_bubble_class(:assistant) do
    "w-full max-w-3xl rounded-box border border-base-300 bg-base-200 px-4 py-3"
  end

  defp message_bubble_class(:user) do
    "w-full max-w-3xl rounded-box border border-neutral/20 bg-neutral text-neutral-content px-4 py-3"
  end
end
