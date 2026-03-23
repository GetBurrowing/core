defmodule Platform.Orchestration.ExecutionSpace do
  @moduledoc """
  Manages execution spaces for task orchestration.

  Each active task assignment gets a dedicated chat space (kind: "execution")
  where the TaskRouter posts log messages (visible but not routed to agents)
  and engagement messages (routed to the assigned agent via AttentionRouter).
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  @system_display_name "TaskRouter"

  @doc """
  Find or create an execution space for the given task.

  Idempotent — returns the existing space if one already exists for this task.
  The space is identified by metadata `task_id`.
  """
  @spec find_or_create(String.t()) :: {:ok, Space.t()} | {:error, term()}
  def find_or_create(task_id) do
    case find_by_task_id(task_id) do
      %Space{} = space ->
        {:ok, space}

      nil ->
        short_id = String.slice(task_id, 0, 8)
        name = "task-exec-#{short_id}"

        Chat.create_space(%{
          name: name,
          slug: name,
          kind: "execution",
          metadata: %{"task_id" => task_id}
        })
    end
  end

  @doc """
  Archive the execution space for the given task.
  """
  @spec archive(String.t()) :: {:ok, Space.t()} | {:error, term()}
  def archive(task_id) do
    case find_by_task_id(task_id) do
      %Space{} = space -> Chat.archive_space(space)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Ensure an agent is a participant in the execution space.
  """
  @spec add_participant(binary(), binary()) :: {:ok, Participant.t()} | {:error, term()}
  def add_participant(space_id, agent_id) do
    Chat.ensure_agent_participant(space_id, agent_id, attention_mode: "all")
  end

  @doc """
  Ensure a system participant exists in the space for TaskRouter messages.

  Uses a deterministic participant_id derived from the space_id so the same
  system participant is reused across router restarts.
  """
  @spec ensure_system_participant(binary()) :: {:ok, Participant.t()} | {:error, term()}
  def ensure_system_participant(space_id) do
    # Use a deterministic ID so we find the same participant on restart
    system_id = system_participant_id(space_id)

    case Repo.get_by(Participant,
           space_id: space_id,
           participant_type: "agent",
           participant_id: system_id
         ) do
      %Participant{left_at: nil} = p ->
        {:ok, p}

      %Participant{} = p ->
        Chat.update_participant(p, %{left_at: nil})

      nil ->
        Chat.add_participant(space_id, %{
          participant_type: "agent",
          participant_id: system_id,
          display_name: @system_display_name,
          attention_mode: "mention",
          joined_at: DateTime.utc_now()
        })
    end
  end

  @doc """
  Post a log-only message to the execution space.

  Log-only messages are persisted and broadcast to LiveView but do NOT
  trigger attention routing to agents.
  """
  @spec post_log(binary(), String.t()) :: {:ok, struct()} | {:error, term()}
  def post_log(space_id, content) do
    with {:ok, participant} <- ensure_system_participant(space_id) do
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: content,
        log_only: true,
        metadata: %{"source" => "task_router", "log_only" => true}
      })
    end
  end

  @doc """
  Post an engagement message to the execution space.

  Engagement messages are persisted AND trigger attention routing to the
  assigned agent via the existing AttentionRouter → AgentResponder path.
  """
  @spec post_engagement(binary(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def post_engagement(space_id, content, opts \\ []) do
    with {:ok, participant} <- ensure_system_participant(space_id) do
      metadata =
        %{"source" => "task_router"}
        |> Map.merge(Keyword.get(opts, :metadata, %{}))

      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "text",
        content: content,
        log_only: false,
        metadata: metadata
      })
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp find_by_task_id(task_id) do
    from(s in Space,
      where: s.kind == "execution" and fragment("?->>'task_id' = ?", s.metadata, ^task_id),
      where: is_nil(s.archived_at),
      limit: 1
    )
    |> Repo.one()
  end

  defp system_participant_id(space_id) do
    # Deterministic UUID-like ID for system participant per space
    :crypto.hash(:sha256, "task_router_system:#{space_id}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
    |> then(fn hex ->
      # Format as UUID: 8-4-4-4-12
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), rest::binary>> =
        hex

      "#{a}-#{b}-#{c}-#{d}-#{rest}"
    end)
  end
end
