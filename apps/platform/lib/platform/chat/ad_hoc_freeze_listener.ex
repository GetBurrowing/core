defmodule Platform.Chat.AdHocFreezeListener do
  @moduledoc """
  Consumer side of Decision D-6 from the editable-messages contract
  (task `019e1e80-4230-7a79-ac73-c157975b3999` Stage 4).

  Subscribes to the `"chat:agent_runtime"` Phoenix.PubSub topic and reacts
  to `{:agent_first_state_op, agent_participant_id, space_id}` signals by:

    1. Resolving the in-context message set via
       `Platform.Chat.in_context_message_ids_for_agent/2`.
    2. Atomically freezing every matched non-frozen message inside one
       `Repo.transaction` (via `Platform.Chat.FreezePolicy.freeze_message_ids/2`).
    3. On commit, broadcasting `{:messages_frozen, ids, %{reason:
       :agent_first_state_op, agent_participant_id, space_id}}` on the
       chat space topic so connected LiveView sockets refresh the
       `(edited)` affordance state.

  ## Scope split (D-6)

  The emitter side — state-changing-tool detection in the Suite MCP
  dispatcher / agent runtime — is OUT OF SCOPE for this task and filed
  separately. Without an emitter wired up, this listener sits idle in
  production: no message ever fires `:agent_first_state_op` because
  nothing currently broadcasts it. The consumer correctness contract is
  still verifiable in tests by broadcasting the signal directly from the
  test process.

  ## Topic

  `"chat:agent_runtime"` is also where future planning-time / state-op
  agent runtime signals will live. This listener ignores anything that
  isn't a literal `{:agent_first_state_op, _, _}` tuple — planning-time
  reads (e.g. `{:agent_read_op, ...}`) MUST NOT trigger a freeze.
  """

  use GenServer

  require Logger

  alias Platform.Chat.FreezePolicy

  @topic "chat:agent_runtime"

  @doc "Topic this listener subscribes to. Public so tests/emitters can target it."
  def topic, do: @topic

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:agent_first_state_op, agent_participant_id, space_id},
        state
      )
      when is_binary(agent_participant_id) and is_binary(space_id) do
    handle_first_state_op(agent_participant_id, space_id)
    {:noreply, state}
  end

  # Planning-time / non-state-changing signals: explicit no-op. Policy 2
  # only fires on state-changing first ops.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_first_state_op(agent_participant_id, space_id) do
    ids = Platform.Chat.in_context_message_ids_for_agent(agent_participant_id, space_id)

    case FreezePolicy.freeze_message_ids(ids, agent_participant_id) do
      {:ok, frozen} ->
        FreezePolicy.broadcast_frozen(frozen, %{
          reason: :agent_first_state_op,
          agent_participant_id: agent_participant_id,
          space_id: space_id
        })

      {:error, reason} ->
        Logger.warning(
          "[Policy 2 ad-hoc freeze] freeze rolled back agent=#{agent_participant_id} space=#{space_id} reason=#{inspect(reason)}"
        )
    end
  end
end
