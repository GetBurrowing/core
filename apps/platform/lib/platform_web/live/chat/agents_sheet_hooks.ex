defmodule PlatformWeb.ChatLive.AgentsSheetHooks do
  @moduledoc """
  Lifecycle hook module for the Agents sheet in `PlatformWeb.ChatLive`
  (task 01a1557a-8f80 stage 2). It replaces the header agent eye.

  Owns:

    * Assigns: `:agents_sheet_open`, `:agent_attention` (`Chat.agent_attention_state/1`
      for the space on screen, or nil)
    * Events:  `"agents_open"`, `"agents_close"`, `"agents_awake_toggle"`,
      `"agent_silence_toggle"` (`participant_id`), `"agent_policy_set"` (`policy`)
    * Info:    `{:agent_attention_changed, space_id}` (re-reads the state for
      the space on screen) and `{:active_agent_changed, space_id, participant_id}`
      (the mutex broadcast, halted here; nothing renders the mutex any more)

  Every write goes through the stage-1 writers in `Platform.Chat`, which
  compose `SpaceAccess.authorize_writer/2`. The space id is ALWAYS
  `socket.assigns.active_space.id`, never a client param: a forged
  `participant_id` from another space is the writer's `:not_found`.

  ## The master switch and the mutex

  `Chat.set_agents_awake/3` only persists the column (and clears the mutex
  when it goes off). Going back on is today's "arm": `resolve_armable/2`'s
  target, if one exists, takes the mutex. The master switch never rewrites
  per-agent `silenced` values.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.AgentsSheetHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket =
        PlatformWeb.ChatLive.AgentsSheetHooks.resolve_for_space(
          socket, space.id, participants
        )
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore

  @refused "Could not change that"

  @doc "Attach the Agents sheet handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:agents_sheet_open, false)
    |> assign(:agent_attention, nil)
    |> attach_hook(:agents_sheet_events, :handle_event, &handle_event/3)
    |> attach_hook(:agents_sheet_info, :handle_info, &handle_info/2)
  end

  @doc """
  Load the space's agent attention state and shut the sheet. Called on every
  space entry; `participants` is unused since the eye went and is kept so the
  two call sites in `ChatLive` read unchanged.
  """
  @spec resolve_for_space(Phoenix.LiveView.Socket.t(), binary(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def resolve_for_space(socket, space_id, _participants) do
    socket
    |> assign(:agents_sheet_open, false)
    |> assign(:agent_attention, Chat.agent_attention_state(space_id))
  end

  @doc """
  Resolve which agent the master switch arms when it goes back on.

  Pure — takes the space id and the space's agent roster and returns
  `{:ok, participant_id}` or `:none`. Rules, in order:

    1. The space's remembered last agent (`ActiveAgentStore.get_last_agent/1`),
       *if it is still an agent participant of the space*. This is the resume
       case: waking the space puts back whoever you were just talking to.
    2. Otherwise, if the space has exactly one agent participant, that agent.
    3. Otherwise `:none` — several agents and no usable history has no
       defensible answer, so the mutex only opens via an `@mention`.

  A silenced agent is mention-only (stage 1), so it is never a target.

  Rule 1's liveness check is load-bearing. The store retains its row on
  release, and `clear_if_match/2` leaves the id of a *deleted* agent sitting in
  `last`, so `get_last_agent/1` can name a participant that no longer exists.
  Without the guard the switch would arm a ghost.
  """
  @spec resolve_armable(binary(), [map()] | nil) :: {:ok, binary()} | :none
  def resolve_armable(space_id, participants) do
    agents = Enum.filter(participants || [], &agent_participant?/1)

    case ActiveAgentStore.get_last_agent(space_id) do
      last when is_binary(last) ->
        if Enum.any?(agents, &(&1.id == last)),
          do: {:ok, last},
          else: sole_agent(agents)

      _none ->
        sole_agent(agents)
    end
  end

  defp agent_participant?(%{participant_type: "agent", silenced: true}), do: false
  defp agent_participant?(%{participant_type: "agent"}), do: true
  defp agent_participant?(_participant), do: false

  defp sole_agent([%{id: id}]), do: {:ok, id}
  defp sole_agent(_agents), do: :none

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("agents_open", _params, socket) do
    case socket.assigns[:active_space] do
      %{kind: kind, id: space_id} when kind != "dm" ->
        {:halt,
         socket
         |> assign(:agent_attention, Chat.agent_attention_state(space_id))
         |> assign(:agents_sheet_open, true)}

      _other ->
        {:halt, socket}
    end
  end

  defp handle_event("agents_close", _params, socket),
    do: {:halt, assign(socket, :agents_sheet_open, false)}

  defp handle_event("agents_awake_toggle", _params, socket) do
    with_space(socket, fn space_id, state ->
      awake = !state.agents_awake

      case Chat.set_agents_awake(actor(socket), space_id, awake) do
        {:ok, _space} ->
          if awake, do: arm(space_id, state.agents)
          {:ok, if(awake, do: "Agents armed", else: "Agents cleared")}

        _refused ->
          :error
      end
    end)
  end

  defp handle_event("agent_silence_toggle", %{"participant_id" => participant_id}, socket)
       when is_binary(participant_id) do
    with_space(socket, fn space_id, state ->
      # Not in this space's roster: send `true` and let the writer answer
      # `:not_found`, so the refusal comes from the one choke point.
      agent = Enum.find(state.agents, &(&1.participant_id == participant_id))
      silenced = if agent, do: !agent.silenced, else: true

      case Chat.set_agent_silenced(actor(socket), space_id, participant_id, silenced) do
        {:ok, _participant} ->
          {:ok, "#{agent.name} #{if silenced, do: "silenced", else: "awake"}"}

        _refused ->
          :error
      end
    end)
  end

  defp handle_event("agent_policy_set", %{"policy" => policy}, socket) when is_binary(policy) do
    with_space(socket, fn space_id, _state ->
      case Chat.set_agent_attention_policy(actor(socket), space_id, policy) do
        {:ok, _space} -> {:ok, "Policy: " <> policy_word(policy)}
        _refused -> :error
      end
    end)
  end

  defp handle_event(event, _params, socket)
       when event in ["agent_silence_toggle", "agent_policy_set"],
       do: {:halt, put_flash(socket, :info, @refused)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:agent_attention_changed, space_id}, socket) do
    socket =
      case socket.assigns[:active_space] do
        %{id: ^space_id} -> assign(socket, :agent_attention, Chat.agent_attention_state(space_id))
        _other -> socket
      end

    {:halt, socket}
  end

  defp handle_info({:active_agent_changed, _space_id, _participant_id}, socket),
    do: {:halt, socket}

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Helpers ───────────────────────────────────────────────────────────

  # Runs `fun.(space_id, state)` for the space on screen; `fun` answers
  # `{:ok, toast}` or `:error`. The state is re-read after the write, so the
  # sheet never shows a value the database does not hold.
  defp with_space(socket, fun) do
    with %{id: space_id} <- socket.assigns[:active_space],
         %{} = state <- Chat.agent_attention_state(space_id) do
      flash =
        case fun.(space_id, state) do
          {:ok, toast} -> toast
          :error -> @refused
        end

      {:halt,
       socket
       |> assign(:agent_attention, Chat.agent_attention_state(space_id))
       |> put_flash(:info, flash)}
    else
      _none -> {:halt, put_flash(socket, :info, @refused)}
    end
  end

  # The roster comes from the state just read, not from the LiveView's
  # participant list, so a silence made in another window is honoured.
  defp arm(space_id, agents) do
    roster =
      Enum.map(
        agents,
        &%{id: &1.participant_id, participant_type: "agent", silenced: &1.silenced}
      )

    case resolve_armable(space_id, roster) do
      # Fresh 15-minute TTL, same as arm-by-mention.
      {:ok, participant_id} -> ActiveAgentStore.set_active(space_id, participant_id)
      :none -> :ok
    end
  end

  defp actor(socket), do: {:user, socket.assigns.user_id}

  @doc "The masters' lowercase policy word, e.g. `\"on-mention\"`."
  @spec policy_word(String.t()) :: String.t()
  def policy_word("on_mention"), do: "on-mention"
  def policy_word("directed"), do: "directed"
  def policy_word("collaborative"), do: "collaborative"
end
