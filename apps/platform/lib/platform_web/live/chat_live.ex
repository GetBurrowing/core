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

      messages =
        socket.assigns.messages ++
          [
            %{role: :user, body: message, at: timestamp},
            %{role: :assistant, body: assistant_reply(message), at: timestamp}
          ]

      {:noreply,
       socket
       |> assign(:messages, messages)
       |> assign_form("")}
    end
  end

  defp assign_form(socket, message) do
    assign(socket, :form, to_form(%{"message" => message}, as: :chat))
  end

  defp seed_messages do
    [
      %{
        role: :assistant,
        body:
          "Core is online. This is the first chat surface for the suite: plain, focused, and minimal.",
        at: "Now"
      },
      %{
        role: :assistant,
        body:
          "Tonight's goal is simple: get a working Elixir app running at suite.example.com before we widen the platform.",
        at: "Now"
      }
    ]
  end

  defp assistant_reply(message) do
    cond do
      String.contains?(String.downcase(message), "deploy") ->
        "Deployment is being designed as pull-based operations from Hive through Core Ops, not push-from-GitHub automation."

      String.contains?(String.downcase(message), "task") ->
        "Tasks stays a sibling surface in the architecture, even though Chat is the first surface we are shipping."

      true ->
        "Message received locally. This chat surface is intentionally minimal while the platform and deployment path take shape."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="min-h-screen bg-base-100 text-base-content">
      <div class="mx-auto flex min-h-screen max-w-5xl flex-col px-4 py-6 sm:px-6 lg:px-8">
        <header class="mb-6 rounded-box border border-base-300 bg-base-200/60 p-5 shadow-sm">
          <div class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
            <div>
              <p class="text-sm font-medium uppercase tracking-[0.2em] text-base-content/60">
                Startup Suite
              </p>
              <h1 class="mt-2 text-3xl font-semibold tracking-tight">Core Chat</h1>
              <p class="mt-3 max-w-3xl text-sm leading-6 text-base-content/70">
                The first surface for the suite. Elixir/Phoenix underneath, plain language up top,
                and a deliberately restrained interface while the rest of the platform comes online.
              </p>
            </div>
            <div class="flex flex-wrap gap-2 text-xs font-medium">
              <span class="badge badge-outline">Chat first</span>
              <span class="badge badge-outline">Tasks later</span>
              <span class="badge badge-outline">Shell planned</span>
              <.link href={~p"/auth/logout"} class="badge badge-neutral badge-outline">
                Log out
              </.link>
            </div>
          </div>
        </header>

        <main class="flex flex-1 flex-col gap-4 rounded-box border border-base-300 bg-base-100 shadow-sm">
          <div class="border-b border-base-300 px-5 py-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
                  Conversation
                </h2>
                <p class="mt-1 text-sm text-base-content/70">
                  Minimal local interaction for the first deployable build.
                </p>
              </div>
              <div class="text-xs text-base-content/50">suite.example.com</div>
            </div>
          </div>

          <div class="flex-1 space-y-4 px-5 py-5">
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
            <.form
              for={@form}
              id="chat-form"
              phx-submit="send"
              class="flex flex-col gap-3 md:flex-row"
            >
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
        </main>
      </div>
    </div>
    """
  end

  defp role_label(:assistant), do: "Core"
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
