defmodule PlatformWeb.TerminalLive do
  @moduledoc """
  The owner's remote terminal at `/terminal/:runtime_id` (task 01a17b17
  stage 3; direction canvas 01a17b18-3989).

  A shell as the owner, on the owner's own machine, in the tmux session the
  agent runs in. This page draws the chrome: header, mode switch, connection
  state, honest copy, refusal panels. The `TerminalHost` hook owns the terminal,
  the socket to `/terminal/ws` and the WebCrypto session; core only relays
  sealed frames (stage 2), and this LiveView never sees one.

  ## Hook events

    * `terminal_token` (with a reply): `%{token}`, a 60 second
      `PlatformWeb.TerminalSocket` token for the viewer. Asked for on EVERY
      connect and reconnect, so a long-lived page never holds a stale one.
      Minted for any signed-in viewer: the channel's owner check is the gate,
      and a refusal is audited there.
    * `terminal_state` `%{state, reason}`: `connecting | connected |
      reconnecting | offline | refused | unsupported`.
    * `terminal_cwd` `%{cwd}`: the starting folder, decrypted in the browser.
    * `terminal_mode` `%{mode}`: the mode core confirmed. The page never
      shows "Can type" on a click alone.

  ## Entry gate

  The mode switch and the key row are drawn only when
  `Platform.Federation.RemoteAccess` allows the viewer's kind for this runtime.
  The server-side refusal is the channel's; this is only what is drawn.
  """
  use PlatformWeb, :live_view

  alias Platform.Agents.Agent
  alias Platform.Audit.Event
  alias Platform.Federation
  alias Platform.Repo
  alias PlatformWeb.TerminalPanel
  alias PlatformWeb.TerminalSocket

  import Ecto.Query

  @states ~w(connecting connected reconnecting offline refused unsupported)
  @max_folder_bytes 512

  @impl true
  def mount(%{"runtime_id" => runtime_id}, _session, socket) do
    user = socket.assigns[:current_user_record]
    runtime = Federation.get_runtime_by_runtime_id(runtime_id)
    offer? = user != nil and TerminalPanel.offer?(runtime, user.id)
    agent = offer? && Repo.get_by(Agent, runtime_id: runtime.id)

    {:ok,
     socket
     |> assign(:page_title, "Terminal")
     |> assign(:runtime_id, runtime_id)
     |> assign(:user, user)
     |> assign(:offer?, offer?)
     |> assign(:agent_name, (agent && agent.name) || "Agent")
     |> assign(:agent_slug, agent && agent.slug)
     |> assign(:state, :connecting)
     |> assign(:ever_connected?, false)
     |> assign(:reason, nil)
     |> assign(:mode, "ro")
     |> assign(:folder, nil)
     |> assign(:first_use?, offer? and first_use?(user))}
  end

  defp first_use?(user) do
    not Repo.exists?(
      from(e in Event,
        where: e.actor_id == ^user.id and e.event_type == "terminal.session.opened"
      )
    )
  end

  @impl true
  def handle_event("terminal_token", _params, %{assigns: %{user: %{id: id}}} = socket) do
    {:reply, %{token: TerminalSocket.mint_token(id)}, socket}
  end

  def handle_event("terminal_token", _params, socket), do: {:reply, %{token: nil}, socket}

  def handle_event("terminal_state", %{"state" => state} = params, socket)
      when state in @states do
    reason = if is_binary(params["reason"]), do: params["reason"], else: nil

    new_state = String.to_existing_atom(state)

    {:noreply,
     socket
     |> assign(:state, new_state)
     |> assign(:reason, reason)
     |> assign(:ever_connected?, socket.assigns.ever_connected? or new_state == :connected)}
  end

  def handle_event("terminal_cwd", %{"cwd" => cwd}, socket)
      when is_binary(cwd) and byte_size(cwd) <= @max_folder_bytes do
    {:noreply, assign(socket, :folder, cwd)}
  end

  def handle_event("terminal_mode", %{"mode" => mode}, socket) when mode in ["ro", "rw"] do
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("set_mode", %{"mode" => mode}, %{assigns: %{offer?: true}} = socket)
      when mode in ["ro", "rw"] do
    {:noreply, push_event(socket, "terminal:set_mode", %{mode: mode})}
  end

  # Closing detaches: leaving the page tears the hook down, which leaves the
  # channel. Nothing here can end the agent's session.
  def handle_event("detach", _params, socket) do
    to =
      if socket.assigns.agent_slug, do: "/control/" <> socket.assigns.agent_slug, else: "/control"

    {:noreply, push_navigate(socket, to: to)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A session that was live and then lost its machine keeps its output on screen,
  # dimmed under the "Reconnecting" banner. The "isn't connected" panel is only
  # for a terminal that never connected; it would otherwise hide what was there.
  defp shown(%{state: :offline, ever_connected?: true}), do: :reconnecting
  defp shown(%{state: state}), do: state

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shown, shown(assigns))

    ~H"""
    <Layouts.app flash={@flash} embedded={true}>
      <div
        id="terminal-screen"
        class="clears-tab-bar flex h-full min-h-0 flex-col bg-base-100 text-base-content"
      >
        <header
          id="terminal-header"
          class="flex-none border-b border-edge bg-base-200 text-base-content"
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2">
            <span
              id="terminal-title"
              class="min-w-0 flex-1 truncate text-sm font-semibold lg:flex-none"
            >
              {@agent_name} · terminal
            </span>
            <div class="order-3 w-full lg:order-2 lg:w-auto">
              <.mode_switch :if={@offer?} mode={@mode} />
            </div>
            <div class="order-2 flex items-center gap-3 lg:order-3 lg:ml-auto">
              <span id="terminal-conn" class="flex items-center gap-1.5 text-xs text-muted">
                <span class="inline-block h-2 w-2 rounded-full bg-base-content" aria-hidden="true" />
                {conn_text(@shown)}
              </span>
              <button
                id="terminal-detach"
                type="button"
                phx-click="detach"
                aria-label="Detach"
                class="rounded-md p-1.5 text-base-content lg:hover:bg-base-300"
              >
                <span class="hero-x-mark h-5 w-5" />
              </button>
            </div>
          </div>
          <p :if={@offer?} id="terminal-copy" class="px-4 pb-2 text-[13px] text-muted">
            {copy_line(@mode, @folder)}
          </p>
        </header>

        <p
          :if={@first_use? and @shown not in [:refused, :unsupported]}
          id="terminal-first-use"
          class="flex-none border-b border-edge bg-base-200 px-4 py-2 text-xs text-muted"
        >
          Closing this detaches; your session keeps running.
        </p>

        <p
          :if={@shown == :reconnecting}
          id="terminal-banner"
          role="status"
          class="flex-none border-b border-edge bg-base-200 px-4 py-2 text-xs text-base-content"
        >
          Reconnecting
        </p>

        <div
          id="terminal-root"
          phx-hook="TerminalHost"
          data-runtime-id={@runtime_id}
          class="relative flex min-h-0 flex-1 flex-col"
        >
          <div
            id="terminal-host"
            phx-update="ignore"
            data-dimmed={to_string(@shown == :reconnecting)}
            class={[
              "terminal-ground min-h-0 flex-1 overflow-hidden px-2 py-1",
              @shown in [:refused, :unsupported, :offline] && "hidden"
            ]}
          />

          <div
            :if={@shown == :connecting}
            id="terminal-connecting"
            class="terminal-ground pointer-events-none absolute inset-0 grid place-items-center text-sm"
          >
            Connecting to your machine…
          </div>

          <div
            :if={@shown == :offline}
            id="terminal-offline"
            class="flex-1 p-6 text-sm text-base-content"
          >
            Your machine isn't connected right now. It will reconnect when burrow-cli is back.
          </div>

          <div
            :if={@shown == :refused and @reason == "flag_off"}
            id="terminal-flag-off"
            class="flex-1 p-6 text-sm text-base-content"
          >
            <p>
              Remote terminal is off for this agent. Start it with
              <code class="font-mono">`burrow claude --remote-terminal`</code>
            </p>
            <button
              id="terminal-copy-command"
              type="button"
              phx-hook="CopyToClipboard"
              data-clipboard-text="burrow claude --remote-terminal"
              class="mt-3 rounded-md border border-edge px-3 py-1.5 text-sm text-base-content lg:hover:bg-base-200"
            >
              Copy
            </button>
          </div>

          <div
            :if={@shown == :refused and @reason != "flag_off"}
            id="terminal-refused"
            class="flex-1 p-6 text-sm text-base-content"
          >
            {refusal_text(@reason)}
          </div>

          <div
            :if={@shown == :unsupported}
            id="terminal-unsupported"
            class="flex-1 p-6 text-sm text-base-content"
          >
            This browser can't open the terminal. It needs X25519 in WebCrypto, so update your browser and open this page again.
          </div>
        </div>

        <div
          :if={@offer? and @mode == "rw"}
          id="terminal-keys"
          class="flex flex-none gap-1 border-t border-edge bg-base-200 px-2 py-2 lg:hidden"
        >
          <button
            :for={{label, key} <- keys()}
            type="button"
            data-terminal-key={key}
            aria-pressed={if key == "ctrl", do: "false"}
            class="min-w-0 flex-1 rounded-md border border-edge px-2 py-2 text-sm text-base-content aria-pressed:ring-2 aria-pressed:ring-primary"
          >
            {label}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:mode, :string, required: true)

  defp mode_switch(assigns) do
    ~H"""
    <div id="terminal-mode" role="group" aria-label="Terminal mode" class="flex items-center gap-2">
      <div class="flex rounded-lg bg-base-300 p-0.5">
        <button
          type="button"
          id="terminal-mode-ro"
          phx-click="set_mode"
          phx-value-mode="ro"
          aria-pressed={to_string(@mode == "ro")}
          class="whitespace-nowrap rounded-md px-3 py-1 text-xs text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring aria-pressed:bg-base-100 aria-pressed:font-semibold aria-pressed:ring-1 aria-pressed:ring-inset aria-pressed:ring-base-content"
        >
          View only
        </button>
        <button
          type="button"
          id="terminal-mode-rw"
          phx-click="set_mode"
          phx-value-mode="rw"
          aria-pressed={to_string(@mode == "rw")}
          class="whitespace-nowrap rounded-md px-3 py-1 text-xs text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring aria-pressed:bg-base-100 aria-pressed:font-semibold aria-pressed:ring-1 aria-pressed:ring-inset aria-pressed:ring-base-content"
        >
          Can type
        </button>
      </div>
      <span
        :if={@mode == "rw"}
        id="terminal-rw-dot"
        class="inline-block h-2 w-2 rounded-full bg-primary"
        aria-hidden="true"
      />
    </div>
    """
  end

  defp keys do
    [
      {"Esc", "esc"},
      {"Tab", "tab"},
      {"Ctrl", "ctrl"},
      {"↑", "up"},
      {"↓", "down"},
      {"←", "left"},
      {"→", "right"}
    ]
  end

  defp conn_text(:connected), do: "Connected"
  defp conn_text(:reconnecting), do: "Reconnecting"
  defp conn_text(:offline), do: "Reconnecting"
  defp conn_text(:connecting), do: "Connecting"
  defp conn_text(_), do: "Not connected"

  defp copy_line("rw", _folder), do: "Typing goes to your terminal"

  defp copy_line(_ro, folder) when is_binary(folder) and folder != "",
    do: "A shell as you, starting in #{folder}."

  defp copy_line(_ro, _folder), do: "A shell as you."

  defp refusal_text("forbidden"),
    do: "This terminal belongs to someone else, so it can't be opened here."

  defp refusal_text(_), do: "The terminal couldn't be opened."
end
