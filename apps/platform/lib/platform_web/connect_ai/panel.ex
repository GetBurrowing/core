defmodule PlatformWeb.ConnectAi.Panel do
  @moduledoc """
  Connect AI for one agent (task 01a1b84b): the provider picker and both
  sign-in flows of `/setup/connect-ai` (the #106 steps,
  `PlatformWeb.ConnectAi.Steps`), as a LiveComponent keyed by agent, for the
  character builder's AI step and the agent page.

  Attrs:

    * `id` (required): the component id;
    * `target`: an `%Agent{}`, or `:burrow` for the install's Burrow agent;
    * `current_user`: the signed-in user;
    * `prefix`: the DOM id prefix, default `"connect-ai"`;
    * `order`: the providers offered, default `PlatformWeb.ConnectAiLive.choices/0`
      (the experiment surface's `provider_order`).

  ## Each agent signs in on its own

  There is no shared or master connection. Picking a provider runs
  `Platform.Agents.AiConnect.prepare/3` for THIS agent (adopting a builder
  agent first), and the sign-in that follows is this agent's own. A new agent
  is not connected, whatever Burrow's state, and the connected view reads only
  this agent's `metadata["ai_login"]` (`NativeAgents.ai_login/1`).

  ## Process

  The pending Claude login is bound to the process that starts it. A
  LiveComponent runs in its LiveView's process and has no `handle_info`, so the
  start and the submit are scheduled with `send_update/3` to this component
  (`update(%{action: ...})`): they run in the LiveView's process, after the
  render that shows the waiting line. The wrapped code travels only in that
  message and is never assigned.

  The host LiveView subscribes to `Platform.AgentHost.subscribe/0` and calls
  `refresh/1` on each `{:agent_host_status, _}`, so the panel turns connected
  by itself.

  ## Who can act

  Only a user `NativeAgents.can_manage?/2` accepts gets the sign-in controls;
  for an agent that is not native yet, one `NativeAgents.may_adopt?/2`
  accepts gets the picker. Everyone else sees the state only. Every event is
  checked again before anything runs, so a forged event is refused before it
  reaches the agent host, and an event this panel does not handle is refused
  with only its name logged.

  ChatGPT has no host logout, so a ChatGPT agent gets no Disconnect.
  """
  use PlatformWeb, :live_component

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.AgentHost
  alias Platform.AgentHost.LoginCode
  alias Platform.Agents.{Agent, AiConnect, Burrow, NativeAgents, NativeLogin}
  alias Platform.Tenancy
  alias PlatformWeb.ConnectAi.Steps
  alias PlatformWeb.ConnectAiLive

  @events ~w(select claude_opened claude_submit claude_retry_link claude_disconnect)
  @labels %{codex: "ChatGPT", claude_subscription: "Claude"}

  @doc "Re-read the agent's state (the host LiveView calls this on agent-host status)."
  @spec refresh(String.t()) :: :ok
  def refresh(id) do
    send_update(__MODULE__, id: id, action: :refresh)
    :ok
  end

  @doc "The events the panel handles (anything else is refused)."
  def events, do: @events

  @impl true
  def update(%{action: action}, socket), do: {:ok, run(action, socket)}

  def update(assigns, socket) do
    target = Map.get(assigns, :target, :burrow)

    reinit? =
      not Map.has_key?(socket.assigns, :claude) or socket.assigns.target_key != key(target)

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:current_user, assigns.current_user)
      |> assign(:prefix, Map.get(assigns, :prefix, "connect-ai"))
      |> assign(:order, Map.get(assigns, :order) || ConnectAiLive.choices())
      |> assign(:target, target)
      |> assign(:target_key, key(target))

    socket =
      if reinit? do
        agent = resolve(target)

        socket
        |> assign(:agent, agent)
        |> assign(:claude, Steps.idle())
        |> assign(:failure, nil)
        |> assign(:selected, initial_selection(agent))
        |> refresh_state()
        |> maybe_start_claude()
      else
        socket
      end

    {:ok, socket}
  end

  defp key(:burrow), do: :burrow
  defp key(%Agent{id: id}), do: id

  defp resolve(:burrow), do: Burrow.get()
  defp resolve(%Agent{} = agent), do: agent

  # A native agent that is up shows its own provider; anything else starts at
  # the picker, with nothing chosen.
  defp initial_selection(agent) do
    with %{harness: harness} <- NativeAgents.get_managed_runtime(agent),
         true <- NativeAgents.live?(AgentHost.status(agent)) do
      if harness == "codex", do: :codex, else: :claude_subscription
    else
      _ -> nil
    end
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("claude_submit", params, socket) do
    # Cleared in the browser whatever happens.
    socket = push_event(socket, "connect-ai-clear-code", %{})

    if allowed?("claude_submit", socket) do
      {claude, action} = Steps.submit(socket.assigns.claude, params)
      {:noreply, socket |> assign(:claude, claude) |> schedule(action)}
    else
      {:noreply, refuse(socket, "claude_submit")}
    end
  end

  def handle_event(event, params, socket) when event in @events do
    if allowed?(event, socket),
      do: {:noreply, handle(event, params, socket)},
      else: {:noreply, refuse(socket, event)}
  end

  # Any event this panel does not handle is refused here, and only its NAME is
  # logged (ConnectAiLive's rule): a code sent to a made-up event never lands
  # in the log.
  def handle_event(event, _params, socket) do
    Logger.warning("[ConnectAi.Panel] refused unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  defp refuse(socket, event) do
    Logger.warning("[ConnectAi.Panel] refused #{inspect(event)}: not allowed")
    socket
  end

  # Read fresh on every event, never from the assigns the page rendered.
  defp allowed?("select", socket), do: may_act?(socket.assigns.current_user, current(socket))

  defp allowed?(_claude_event, socket) do
    agent = current(socket)
    NativeAgents.managed?(agent) and NativeAgents.can_manage?(socket.assigns.current_user, agent)
  end

  defp may_act?(user, agent) do
    cond do
      is_nil(user) -> false
      NativeAgents.managed?(agent) -> NativeAgents.can_manage?(user, agent)
      match?(%Agent{}, agent) -> NativeAgents.may_adopt?(user, agent)
      true -> false
    end
  end

  # Burrow before it exists is the Burrow target: the root admin sets it up.
  defp may_act_on_target?(%{target: :burrow, agent: nil, current_user: user}),
    do: Tenancy.root_admin?(user)

  defp may_act_on_target?(%{target: :burrow, current_user: user} = assigns),
    do: Tenancy.root_admin?(user) and may_act?(user, assigns.agent)

  defp may_act_on_target?(%{current_user: user, agent: agent}), do: may_act?(user, agent)

  # The agent as it stands now (an adopt changes its row).
  defp current(%{assigns: %{target: :burrow, agent: nil}}), do: nil
  defp current(%{assigns: %{agent: %Agent{id: id}}}), do: reload(id)
  defp current(_socket), do: nil

  defp reload(id), do: Platform.Repo.one(from(a in Agent, where: a.id == ^id))

  defp handle("select", %{"provider" => provider}, socket) do
    case Enum.find(socket.assigns.order, &(Atom.to_string(&1) == provider)) do
      nil ->
        socket

      option ->
        socket
        |> assign(:selected, option)
        |> assign(:claude, Steps.idle())
        |> prepare(option)
        |> maybe_start_claude()
    end
  end

  defp handle("select", _params, socket), do: socket

  defp handle("claude_opened", _params, socket),
    do: assign(socket, :claude, Steps.opened(socket.assigns.claude))

  defp handle("claude_retry_link", _params, socket) do
    {claude, action} = Steps.retry_link(socket.assigns.claude)
    socket |> assign(:claude, claude) |> schedule(action)
  end

  defp handle("claude_disconnect", _params, socket) do
    case AgentHost.claude_logout(socket.assigns.current_user, current(socket)) do
      :ok ->
        socket
        |> assign(:claude, Steps.idle())
        |> refresh_state()
        |> maybe_start_claude()

      {:error, _reason} ->
        claude = socket.assigns.claude
        assign(socket, :claude, %{claude | status: {:failed, :server}})
    end
  end

  defp prepare(socket, option) do
    target = if socket.assigns.target == :burrow, do: :burrow, else: current(socket)

    case AiConnect.prepare(socket.assigns.current_user, target, option) do
      {:ok, agent} -> socket |> assign(:agent, agent) |> assign(:failure, nil) |> refresh_state()
      {:error, _reason} -> assign(socket, :failure, :not_created)
    end
  end

  # ── Work run from the LiveView's process, after a render ────────────

  defp schedule(socket, nil), do: socket

  defp schedule(socket, action) do
    send_update(__MODULE__, id: socket.assigns.id, action: action)
    socket
  end

  defp run(:refresh, socket) do
    socket = refresh_state(socket)

    # An agent that came up since (started elsewhere) shows its own provider.
    socket =
      if is_nil(socket.assigns.selected),
        do: assign(socket, :selected, initial_selection(socket.assigns.agent)),
        else: socket

    maybe_start_claude(socket)
  end

  defp run(:claude_login_start, %{assigns: %{selected: :claude_subscription}} = socket) do
    agent = current(socket)

    if agent,
      do:
        assign(
          socket,
          :claude,
          Steps.start(socket.assigns.current_user, agent, socket.assigns.claude)
        ),
      else: socket
  end

  defp run(
         {:claude_submit, %LoginCode{} = code},
         %{assigns: %{selected: :claude_subscription}} = socket
       ) do
    agent = current(socket)

    case agent &&
           Steps.finish_submit(socket.assigns.current_user, agent, socket.assigns.claude, code) do
      nil -> socket
      {claude, nil} -> socket |> assign(:claude, claude) |> refresh_state()
      {claude, action} -> socket |> assign(:claude, claude) |> schedule(action)
    end
  end

  defp run(_action, socket), do: socket

  # Ask for a Claude sign-in link when the Claude steps are showing, the agent
  # is not running, no link has been asked for, and this user may manage it.
  defp maybe_start_claude(
         %{
           assigns: %{
             selected: :claude_subscription,
             running?: false,
             can_manage?: true,
             login: %{kind: :claude_subscription},
             claude: %{link: :idle} = claude
           }
         } = socket
       ) do
    if connected?(socket),
      do: socket |> assign(:claude, Steps.loading(claude)) |> schedule(:claude_login_start),
      else: socket
  end

  defp maybe_start_claude(socket), do: socket

  # Everything the panel shows about the agent, read fresh.
  defp refresh_state(socket) do
    agent = socket.assigns.agent && reload(socket.assigns.agent.id)
    runtime = NativeAgents.get_managed_runtime(agent)
    observed = runtime && AgentHost.status(agent)
    running? = match?(%{state: :running}, observed)
    _ = AiConnect.note_observed(agent, observed)
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:agent, agent)
      |> assign(:harness, runtime && runtime.harness)
      |> assign(:observed, observed)
      |> assign(:running?, running?)
      |> assign(:ai_login, NativeAgents.ai_login(agent))
      |> assign(:can_manage?, not is_nil(runtime) and NativeAgents.can_manage?(user, agent))
      |> assign(:login, runtime && NativeLogin.login_view(agent, socket.assigns.claude.login))

    assign(socket, :can_act?, may_act_on_target?(socket.assigns))
  end

  # ── Markup ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:agent_name, (assigns.agent && assigns.agent.name) || Burrow.name())
      |> assign(:connected?, assigns.running? or assigns.claude.status == :connected)

    ~H"""
    <div
      id={"#{@prefix}-panel"}
      data-agent-id={@agent && @agent.id}
      data-connected={to_string(@connected?)}
      class="space-y-4"
    >
      <div :if={@connected?} id={"#{@prefix}-connected"}>
        <Steps.claude_connected
          :if={@harness == "claude_code"}
          prefix={@prefix}
          target={@myself}
          login={connected_login(@claude, @ai_login)}
          disconnect?={@can_manage?}
        />
        <p
          :if={@harness == "codex"}
          id={"#{@prefix}-codex-connected"}
          class="flex items-center gap-2 text-base"
        >
          <span class="hero-check-circle size-5 shrink-0 text-success" />
          <span class="font-medium text-success">Connected to ChatGPT</span>
        </p>
      </div>

      <div :if={!@connected?} class="space-y-4">
        <form
          :if={@can_act?}
          id={"#{@prefix}-options"}
          phx-change="select"
          phx-target={@myself}
          class="space-y-3"
        >
          <label
            :for={option <- @order}
            id={"#{@prefix}-option-#{option}"}
            data-provider={option}
            class={[
              "flex min-h-11 cursor-pointer items-center gap-3 rounded-box border bg-base-100 p-4 text-base text-base-content",
              if(@selected == option,
                do: "border-primary ring-2 ring-primary",
                else: "border-edge"
              )
            ]}
          >
            <input
              type="radio"
              name="provider"
              value={option}
              checked={@selected == option}
              class="radio radio-primary"
            />
            <span>{label(option)}</span>
          </label>
        </form>

        <p
          :if={!@can_act?}
          id={"#{@prefix}-not-connected"}
          class="text-base text-subtle"
        >
          {@agent_name} is not connected to an AI yet.
        </p>

        <p :if={@failure} id={"#{@prefix}-failed"} class="text-sm text-error">
          {@agent_name} couldn't be set up. Try again.
        </p>

        <section
          :if={@can_manage? and @selected == :codex and match?(%{kind: :device_code}, @login)}
          id={"#{@prefix}-provider-codex"}
        >
          <Steps.codex_card
            prefix={@prefix}
            login={@login}
            running?={@running?}
            agent_name={@agent_name}
          />
        </section>

        <section
          :if={@can_manage? and @selected == :claude_subscription}
          id={"#{@prefix}-provider-claude_subscription"}
        >
          <%= case @login do %>
            <% %{kind: :claude_subscription} -> %>
              <Steps.claude_card prefix={@prefix} target={@myself} claude={@claude} />
            <% :api_key -> %>
              <p id={"#{@prefix}-claude-uses-key"} class="text-base text-base-content">
                {@agent_name} is using an API key, so it doesn't need your Claude plan.
              </p>
            <% :subscription_terminal_only -> %>
              <p id={"#{@prefix}-claude-operator"} class="text-base text-base-content">
                The person who runs this server connects Claude Pro or Max for this install.
              </p>
            <% _ -> %>
              <p id={"#{@prefix}-claude-preparing"} class="text-sm text-subtle">
                Getting {@agent_name} ready...
              </p>
          <% end %>
        </section>
      </div>
    </div>
    """
  end

  @doc "A provider's name on the picker."
  def label(option), do: Map.fetch!(@labels, option)

  # The submit's own reply first, else this agent's stored summary; with no
  # account, "Connected to Claude".
  defp connected_login(%{login: %{} = login}, _ai_login), do: login

  defp connected_login(_claude, %{"provider" => "claude"} = ai_login),
    do: %{account: ai_login["account"], plan: ai_login["plan"]}

  defp connected_login(_claude, _ai_login), do: nil
end
