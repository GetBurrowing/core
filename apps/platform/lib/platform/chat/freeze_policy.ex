defmodule Platform.Chat.FreezePolicy do
  @moduledoc """
  Policy 2 freeze coordination for editable messages
  (editable-messages contract Section f, Policy 2; task
  `019e1e80-4230-7a79-ac73-c157975b3999`).

  Encapsulates "given a task transitioning to `:in_progress`, freeze every
  non-frozen message in its execution space" so the Tasks domain doesn't
  reach into Chat schemas directly. The actual per-message freeze lives
  on `Platform.Chat.MessageVersions.freeze/2`; this module owns the
  resolution + iteration + broadcast wiring.

  Intended call sites:

    * `Platform.Tasks.transition_task/2` — when status moves to
      `:in_progress`, call `freeze_messages_for_task/1` inside the same
      `Repo.transaction` as the status flip so a freeze error rolls back
      atomically.
    * `Platform.Tasks.approve_plan/2` (via `apply_dispatch_gate/1`) —
      when plan approval auto-dispatches a task into `:in_progress`,
      same atomicity contract applies inside the approve_plan transaction.

  After the surrounding transaction commits, callers invoke
  `broadcast_frozen/2` to notify the chat space topic so connected
  LiveView sockets refresh the `(edited)` affordance state.
  """

  require Logger

  import Ecto.Query

  alias Platform.Chat.Message
  alias Platform.Chat.MessageVersions
  alias Platform.Chat.Participant
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Space
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks.Task, as: TaskRecord

  @doc """
  Freeze every non-frozen, non-deleted message in the given task's
  execution space.

  Intended to be called inside a `Repo.transaction/1` so a freeze failure
  can roll back the surrounding writes. Returns `{:ok, [frozen_message]}`
  on success (the caller can then use `broadcast_frozen/2` post-commit) or
  `{:error, changeset}` on the first freeze that fails.

  Graceful-skip paths (return `{:ok, []}`):

    * No execution space exists for this task yet.
    * Execution space exists but the task assignee is not yet a
      participant (e.g. assignee was just set and hasn't been provisioned
      as a chat participant). A warning is logged.

  Both paths intentionally do NOT block the surrounding transaction —
  Policy 2 freeze is defence-in-depth, and stranding a task transition
  because no participant resolved would be worse than skipping the freeze.
  """
  @spec freeze_messages_for_task(TaskRecord.t()) ::
          {:ok, [Message.t()]} | {:error, term()}
  def freeze_messages_for_task(%TaskRecord{} = task) do
    case ExecutionSpace.find_by_task_id(task.id) do
      nil ->
        {:ok, []}

      %Space{} = space ->
        case resolve_actor(space, task) do
          nil ->
            Logger.warning("[Policy 2] no resolvable freeze actor for task=#{task.id}")
            {:ok, []}

          participant_id ->
            freeze_unfrozen_in_space(space.id, participant_id)
        end
    end
  end

  @doc """
  Broadcast `{:messages_frozen, message_ids, meta}` on the chat space
  topic of the frozen messages.

  Called by the surrounding domain AFTER the transaction commits, so
  subscribers never see a stale event for a transaction that later rolled
  back. No-op on empty input.
  """
  @spec broadcast_frozen([Message.t()], map()) :: :ok
  def broadcast_frozen([], _meta), do: :ok

  def broadcast_frozen([%Message{space_id: space_id} | _] = frozen, %{} = meta)
      when is_binary(space_id) do
    ids = Enum.map(frozen, & &1.id)
    ChatPubSub.broadcast(space_id, {:messages_frozen, ids, meta})
    :ok
  end

  def broadcast_frozen(_frozen, _meta), do: :ok

  @doc """
  Freeze a known set of message ids inside its own `Repo.transaction`.

  Used by the ad-hoc freeze path (Stage 4 — `AdHocFreezeListener`) which
  receives an already-resolved set of in-context message ids from
  `Platform.Chat.in_context_message_ids_for_agent/2`. Distinct from
  `freeze_messages_for_task/1` which is task-scoped (and which is
  called inside the caller's existing transaction).

  Filters out already-frozen and deleted messages before iterating. All
  freezes share one transaction so any error rolls back the whole batch.
  Returns `{:ok, [frozen_message]}` or `{:error, reason}`. Empty input
  short-circuits to `{:ok, []}` without opening a transaction.
  """
  @spec freeze_message_ids(Enumerable.t(), binary()) ::
          {:ok, [Message.t()]} | {:error, term()}
  def freeze_message_ids(message_ids, participant_id) when is_binary(participant_id) do
    ids =
      case message_ids do
        %MapSet{} = ms -> MapSet.to_list(ms)
        list when is_list(list) -> list
        nil -> []
      end

    case ids do
      [] ->
        {:ok, []}

      _ ->
        Repo.transaction(fn ->
          msgs =
            from(m in Message,
              where: m.id in ^ids and is_nil(m.deleted_at) and is_nil(m.frozen_at)
            )
            |> Repo.all()

          Enum.reduce_while(msgs, {:ok, []}, fn msg, {:ok, acc} ->
            case MessageVersions.freeze(msg, participant_id) do
              {:ok, frozen} -> {:cont, {:ok, [frozen | acc]}}
              {:error, changeset} -> {:halt, {:error, changeset}}
            end
          end)
          |> case do
            {:ok, frozen} -> frozen
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp freeze_unfrozen_in_space(space_id, participant_id) do
    msgs =
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.deleted_at) and is_nil(m.frozen_at)
      )
      |> Repo.all()

    Enum.reduce_while(msgs, {:ok, []}, fn msg, {:ok, acc} ->
      case MessageVersions.freeze(msg, participant_id) do
        {:ok, frozen} -> {:cont, {:ok, [frozen | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp resolve_actor(%Space{id: space_id}, %TaskRecord{assignee_id: assignee_id})
       when is_binary(assignee_id) do
    case Repo.get_by(Participant, space_id: space_id, participant_id: assignee_id) do
      %Participant{id: pid} -> pid
      nil -> nil
    end
  end

  defp resolve_actor(_space, _task), do: nil
end
