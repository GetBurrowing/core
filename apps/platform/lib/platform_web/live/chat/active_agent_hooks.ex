defmodule PlatformWeb.ChatLive.ActiveAgentHooks do
  @moduledoc """
  Lifecycle hook module for the Active Agent indicator in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Owns:

    * Assigns: `:active_agent_participant_id`, `:active_agent_name`,
      `:active_agent_armable_id`, `:active_agent_armable_name`
    * Events:  `"active_agent_clear"`, `"active_agent_arm"`
    * Info:    `{:active_agent_changed, space_id, agent_participant_id}`

  ## Both directions of the mutex toggle live here

  This hook owns opening *and* closing the agent mutex for a space. The
  eye control closes it via `"active_agent_clear"` and opens it via
  `"active_agent_arm"`, which resolves its target through
  `resolve_armable/2`. There is no separate coordinator handler on the
  parent LiveView — a click on the indicator is fully served here.

  `:active_agent_armable_id` / `:active_agent_armable_name` are kept in
  sync with the store so the template can render the not-open-but-
  clickable state (and its tooltip) without re-deriving any of this
  logic in heex. When `:active_agent_armable_id` is `nil` there is no
  defensible agent to arm and the control is inert.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.ActiveAgentHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket =
        PlatformWeb.ChatLive.ActiveAgentHooks.resolve_for_space(
          socket, space.id, participants
        )
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Repo

  @doc "Attach ActiveAgent handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:active_agent_participant_id, nil)
    |> assign(:active_agent_name, nil)
    |> assign(:active_agent_armable_id, nil)
    |> assign(:active_agent_armable_name, nil)
    |> attach_hook(:active_agent_events, :handle_event, &handle_event/3)
    |> attach_hook(:active_agent_info, :handle_info, &handle_info/2)
  end

  @doc "Resolve the active agent for a space from `ActiveAgentStore` + space participants."
  @spec resolve_for_space(Phoenix.LiveView.Socket.t(), binary(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def resolve_for_space(socket, space_id, participants) do
    {participant_id, name} =
      case ActiveAgentStore.get_active(space_id) do
        nil -> {nil, nil}
        pid -> {pid, resolve_agent_name(pid, participants)}
      end

    socket
    |> assign(:active_agent_participant_id, participant_id)
    |> assign(:active_agent_name, name)
    |> assign_armable(space_id, participants)
  end

  @doc """
  Resolve which agent an `"active_agent_arm"` click should open the mutex for.

  Pure — takes the space id and the LiveView's participant roster and returns
  `{:ok, participant_id}` or `:none`. Rules, in order:

    1. The space's remembered last agent (`ActiveAgentStore.get_last_agent/1`),
       *if it is still an agent participant of the space*. This is the resume
       case: re-opening the eye puts back whoever you were just talking to.
    2. Otherwise, if the space has exactly one agent participant, that agent.
    3. Otherwise `:none` — several agents and no usable history has no
       defensible answer, so the eye only opens via an `@mention`.

  Rule 1's liveness check is load-bearing. The store retains its row on
  release, and `clear_if_match/2` leaves the id of a *deleted* agent sitting in
  `last`, so `get_last_agent/1` can name a participant that no longer exists.
  Without the guard such a space would offer an eye that arms a ghost.

  This lives in the hook rather than in `ActiveAgentStore` because rule 2 needs
  the space participant roster — LiveView-side state (`:space_participants`,
  assigned by `PresenceHooks`). Pushing that Repo query into the ETS GenServer
  would serialise it behind the mutex writer.
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

  defp agent_participant?(%{participant_type: "agent"}), do: true
  defp agent_participant?(_participant), do: false

  defp sole_agent([%{id: id}]), do: {:ok, id}
  defp sole_agent(_agents), do: :none

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("active_agent_clear", _params, socket) do
    if space = socket.assigns[:active_space] do
      ActiveAgentStore.clear_active(space.id)
    end

    {:halt, socket}
  end

  defp handle_event("active_agent_arm", _params, socket) do
    with %{kind: kind, id: space_id} when kind != "dm" <- socket.assigns[:active_space],
         {:ok, participant_id} <-
           resolve_armable(space_id, socket.assigns[:space_participants]) do
      # Fresh 15-minute TTL, same as arm-by-mention; the broadcast re-renders
      # every connected client.
      ActiveAgentStore.set_active(space_id, participant_id)
    end

    # `:none` is inert by design — no flash, nothing to say.
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:active_agent_changed, space_id, agent_participant_id}, socket) do
    participants = socket.assigns[:space_participants] || []
    name = resolve_agent_name(agent_participant_id, participants)

    {:halt,
     socket
     |> assign(:active_agent_participant_id, agent_participant_id)
     |> assign(:active_agent_name, name)
     |> assign_armable(space_id, participants)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Armable resolution ──────────────────────────────────────────────

  defp assign_armable(socket, space_id, participants) do
    {armable_id, armable_name} =
      case resolve_armable(space_id, participants) do
        {:ok, participant_id} ->
          {participant_id, resolve_agent_name(participant_id, participants)}

        :none ->
          {nil, nil}
      end

    socket
    |> assign(:active_agent_armable_id, armable_id)
    |> assign(:active_agent_armable_name, armable_name)
  end

  # ── Name resolution ─────────────────────────────────────────────────

  defp resolve_agent_name(nil, _participants), do: nil

  defp resolve_agent_name(participant_id, participants) do
    case Enum.find(participants, &(&1.id == participant_id)) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_by_agent_id(agent_id)
      nil -> resolve_by_lookup(participant_id)
    end
  end

  defp resolve_by_agent_id(agent_id) do
    case Repo.get(Platform.Agents.Agent, agent_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Agent"
    end
  end

  defp resolve_by_lookup(participant_id) do
    case Chat.get_participant(participant_id) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      %{participant_id: agent_id} -> resolve_by_agent_id(agent_id)
      _ -> "Agent"
    end
  end
end
