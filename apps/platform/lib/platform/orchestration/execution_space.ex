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
  alias Platform.Chat.{Attachment, Message, Participant, Space}
  alias Platform.Repo

  @system_display_name "TaskRouter"

  @doc """
  Find or create an execution space for the given task.

  Idempotent — returns the existing space if one already exists for this task.
  The space is identified by metadata `task_id`.

  If the resolved space is archived it is REVIVED (see the comment on the
  matching clause) — this function promises a *usable* space, not merely a row.
  """
  @spec find_or_create(String.t()) :: {:ok, Space.t()} | {:error, term()}
  def find_or_create(task_id) do
    case find_by_task_id(task_id) do
      %Space{archived_at: archived_at} = space when not is_nil(archived_at) ->
        # `find_by_task_id/1` deliberately falls back to archived spaces so a
        # completed task still renders its execution log. That read behaviour
        # is correct and stays. But every caller of `find_or_create/1` is a
        # WRITE path about to attach live state, and the read side (e.g.
        # `Platform.Tasks.ChatPins.list_pinned_task_spaces_for/1`) filters on
        # `is_nil(archived_at)` — so a row written against an archived space
        # persists and can never render, while the user is told it worked.
        #
        # We revive rather than return `{:error, :archived}` ON PURPOSE. This
        # is not an accidental un-archive: no current caller has a sensible
        # recovery from an error tuple. `ChatPins.pin/3` would have to either
        # refuse a pin the user is legitimately entitled to (worse than the
        # silent success it replaces) or duplicate this unarchive itself,
        # splitting the single-writer chokepoint its moduledoc relies on.
        # Reviving keeps the function name honest.
        Logger.warning(
          "ExecutionSpace.find_or_create: reviving archived execution space for " <>
            "task_id=#{inspect(task_id)} space_id=#{inspect(space.id)} " <>
            "(a write path resolved a tombstone; archived_at=#{inspect(archived_at)})"
        )

        Chat.unarchive_space(space)

      %Space{} = space ->
        {:ok, space}

      nil ->
        # The slug is a BIJECTION of the task id: the whole UUID, dashes
        # stripped, all 32 hex characters. Two distinct tasks cannot produce
        # one slug, because the task primary key already guarantees they
        # cannot produce one id.
        #
        # That property is load-bearing. This row is written against
        # `chat_spaces_unique_org_slug` (`(org_id, slug)`), and there
        # is deliberately NO retry here: no rescue of `Ecto.ConstraintError`,
        # no second slug minted from an `{:error, changeset}`, no
        # `on_conflict:`. A retry would let the derivation stay deterministic
        # in a quantity that is not unique, and every later caller would
        # inherit both. So the derivation has to be collision-free on its own.
        #
        # Prior widths were NOT. Rows were minted at 8 hex, then 12; both are
        # a prefix of a UUIDv7 (`Platform.Tasks.Task` `@primary_key`), whose
        # leading 48 bits (exactly 12 hex) are the creation millisecond and
        # nothing else. Any front slice is therefore pure timestamp carrying
        # zero entropy from the random half, and two tasks created in one org
        # in the same millisecond collided; widening the slice only takes more
        # timestamp, so it collides identically.
        #
        # Materialisation is lazy (`ChatPins.pin/3`, `TaskRouter`,
        # `ContextAssembler`, the MCP tool surface), so such a pair stayed
        # primed until the second one was first opened, possibly days later.
        #
        # Existing 8- and 12-character rows keep their slugs and are never
        # re-minted: `find_or_create/1` resolves through `metadata->>'task_id'`
        # (see `find_by_task_id/1`), which is also how every other resolver in
        # the codebase finds an execution space. No backfill is needed.
        name = "task-exec-#{String.replace(task_id, "-", "")}"
        org_id = resolve_task_org_id(task_id)

        if is_nil(org_id) do
          Logger.warning(
            "ExecutionSpace.find_or_create: no org_id resolvable for task_id=#{inspect(task_id)} (task missing project or project missing org); creating exec space with org_id: nil"
          )
        end

        Chat.create_space(%{
          name: name,
          slug: name,
          kind: "execution",
          org_id: org_id,
          metadata: %{"task_id" => task_id}
        })
    end
  end

  # Resolve a task's owning org via `task → project.org_id`. Returns the
  # org UUID, or `nil` when the task has no project OR the project has no
  # org (legacy pre-ADR-0042 rows). Callers stamp the returned value onto
  # the exec-space row so post-ADR-0042 org-scoped slug lookups
  # (`Chat.get_space_by_slug/2`) can resolve it for viewers inside an org.
  @spec resolve_task_org_id(String.t()) :: binary() | nil
  defp resolve_task_org_id(task_id) do
    from(t in Platform.Tasks.Task,
      join: p in Platform.Tasks.Project,
      on: p.id == t.project_id,
      where: t.id == ^task_id,
      select: p.org_id
    )
    |> Repo.one()
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

  # `add_participant/2` lived here and is DELETED (task 019fb90f stage 3).
  #
  # It had zero production call sites — the only reference in the repo was its
  # own test — so the thing it claimed to do was never actually happening on
  # the dispatch path. `Platform.Chat.DispatchMembership` now owns the rule,
  # including this function's `attention_mode: "all"`, which survives as the
  # per-kind policy for `kind == "execution"`, and the TaskRouter's dispatch
  # goes through it via `Platform.Federation.AttentionDispatch`.
  #
  # Leaving it in place would have been two mechanisms saying one thing with
  # only one of them wired up: either could be deleted with the suite green,
  # which is the mutual-masking shape that lets a policy drift silently. If you
  # need an agent in an execution space, call
  # `DispatchMembership.ensure_writable(space_id, agent_id, source: :task_router)`.

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
           participant_type: "system",
           participant_id: system_id
         ) do
      %Participant{} = p ->
        {:ok, p}

      nil ->
        Chat.add_participant(space_id, %{
          participant_type: "system",
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

  `opts[:metadata]` is merged OVER the fixed
  `%{"source" => "task_router", "kind" => "log", "log_only" => true}` map,
  mirroring `post_engagement/3` (task 01a0e266 stage 2). With no option the
  metadata is exactly the fixed map, as it was for every `post_log/2`
  caller.
  """
  @spec post_log(binary(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def post_log(space_id, content, opts \\ []) do
    with {:ok, participant} <- ensure_system_participant(space_id) do
      metadata =
        %{"source" => "task_router", "kind" => "log", "log_only" => true}
        |> Map.merge(Keyword.get(opts, :metadata, %{}))

      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: content,
        log_only: true,
        metadata: metadata
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
        %{"source" => "task_router", "kind" => "engagement", "log_only" => false}
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

  # ── Queries ──────────────────────────────────────────────────────────────

  @doc """
  Look up the execution space for a task by its `task_id`.

  Returns the `Space` struct or `nil` if no execution space exists.
  Checks active spaces first, then falls back to archived ones so that
  completed tasks still show their execution log.
  """
  @spec find_by_task_id(String.t()) :: Space.t() | nil
  def find_by_task_id(task_id) do
    # Active space first
    active =
      from(s in Space,
        where: s.kind == "execution" and fragment("?->>'task_id' = ?", s.metadata, ^task_id),
        where: is_nil(s.archived_at),
        limit: 1
      )
      |> Repo.one()

    case active do
      %Space{} = s ->
        s

      nil ->
        # Fall back to archived space (task completed)
        from(s in Space,
          where: s.kind == "execution" and fragment("?->>'task_id' = ?", s.metadata, ^task_id),
          where: not is_nil(s.archived_at),
          order_by: [desc: s.archived_at],
          limit: 1
        )
        |> Repo.one()
    end
  end

  @doc """
  The task id an execution space belongs to, read from its `metadata`
  `task_id` (the key `find_by_task_id/1` resolves through), or `nil` for any
  space that is not `kind: "execution"` or carries no valid id.
  """
  @spec task_id(Space.t() | map()) :: binary() | nil
  def task_id(%{kind: "execution", metadata: %{"task_id" => task_id}}) when is_binary(task_id) do
    if Platform.UUID.valid?(task_id), do: task_id
  end

  def task_id(_space), do: nil

  @doc """
  `%{space_id => task_title}` for every execution space in `spaces` whose task
  is live (not soft-deleted). One query. Spaces of any other kind, and
  execution spaces whose task is gone, are absent from the map.

  The task canvas picker (task 01a1559a stage 3) shows this title in place of
  an execution space's name, which is the same opaque `task-exec-<hex>` for
  every one of them.
  """
  @spec task_titles([Space.t() | map()]) :: %{binary() => String.t()}
  def task_titles(spaces) when is_list(spaces) do
    # A task can own more than one execution space (an archived one and its
    # successor), so each task id maps to a LIST of space ids.
    by_task =
      spaces
      |> Enum.filter(&task_id/1)
      |> Enum.group_by(&task_id/1, & &1.id)

    case Map.keys(by_task) do
      [] ->
        %{}

      task_ids ->
        from(t in Platform.Tasks.Task,
          where: t.id in ^task_ids and is_nil(t.deleted_at),
          select: {t.id, t.title}
        )
        |> Repo.all()
        |> Enum.flat_map(fn {task_id, title} ->
          for space_id <- Map.fetch!(by_task, task_id), do: {space_id, title}
        end)
        |> Map.new()
    end
  end

  @doc """
  List messages in an execution space with participant info joined.

  Returns a list of maps ordered chronologically (oldest first) with keys:
  `id`, `content`, `content_type`, `log_only`, `inserted_at`, `metadata`,
  `sender_name`, `sender_type`, and `attachments` (list of attachment maps).
  """
  @spec list_messages_with_participants(binary(), keyword()) :: [map()]
  def list_messages_with_participants(space_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    messages =
      from(m in Message,
        join: p in Participant,
        on: p.id == m.participant_id,
        where: m.space_id == ^space_id and is_nil(m.deleted_at),
        order_by: [asc: m.inserted_at],
        limit: ^limit,
        select: %{
          id: m.id,
          content: m.content,
          content_type: m.content_type,
          log_only: m.log_only,
          inserted_at: m.inserted_at,
          metadata: m.metadata,
          sender_name: coalesce(p.display_name, p.participant_type),
          sender_type: p.participant_type
        }
      )
      |> Repo.all()

    # Batch-load attachments for all messages
    message_ids = Enum.map(messages, & &1.id)

    attachments_by_message =
      if message_ids == [] do
        %{}
      else
        from(a in Attachment,
          where: a.message_id in ^message_ids,
          select: %{
            message_id: a.message_id,
            id: a.id,
            filename: a.filename,
            content_type: a.content_type,
            byte_size: a.byte_size,
            storage_key: a.storage_key
          }
        )
        |> Repo.all()
        |> Enum.group_by(& &1.message_id)
      end

    Enum.map(messages, fn msg ->
      Map.put(msg, :attachments, Map.get(attachments_by_message, msg.id, []))
    end)
  end

  @doc """
  The log-only messages in `space_id` whose `metadata` CONTAINS `match`
  (jsonb `@>`: every key of `match` present with that value), newest first
  (`inserted_at` DESC, then `id` DESC: ids are UUIDv7, so the tiebreak is
  time order too). Deleted rows are excluded; `opts[:limit]` defaults to 50.

  This is the public read for anything that records structured notes on a
  task with `post_log/3` and its `:metadata` option, so no caller outside
  this context queries `chat_messages` itself.

  Returns maps with `:id`, `:content`, `:metadata` and `:inserted_at`.
  """
  @spec list_logs_by_metadata(binary(), map(), keyword()) :: [map()]
  def list_logs_by_metadata(space_id, match, opts \\ []) when is_map(match) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      where: m.space_id == ^space_id and is_nil(m.deleted_at) and m.log_only == true,
      where: fragment("? @> ?", m.metadata, type(^match, :map)),
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit,
      select: %{id: m.id, content: m.content, metadata: m.metadata, inserted_at: m.inserted_at}
    )
    |> Repo.all()
  end

  @doc """
  Return the newest engagement the TaskRouter posted into `space_id`, or `nil`.

  "Engagement" here is narrower than "not log-only": the row must carry BOTH
  `metadata["kind"] == "engagement"` and `metadata["source"] == "task_router"`.
  Both halves are load-bearing for the caller this exists for, a guard that
  reads the last dispatch back off the space. `post_log/2` writes
  `"kind" => "log"` under the same `"source"`, and a human or another agent
  can post a plain message into an execution space with no `kind` at all;
  either one matching would let a short status line stand in for the dispatch
  prompt the guard is trying to compare against.

  Ordering is `inserted_at` DESC then `id` DESC. The tiebreak is not
  decoration: `inserted_at` is `:utc_datetime_usec` and two posts inside the
  same microsecond would otherwise return in whatever order Postgres felt
  like. Message ids are UUIDv7 (`Platform.Chat.Message`), so their byte order
  is time order and the second key resolves the tie the same way the first
  one would have.

  Returns a map with `:id`, `:content`, `:content_type`, `:log_only`,
  `:metadata` and `:inserted_at`.
  """
  @spec latest_engagement(binary()) :: map() | nil
  def latest_engagement(space_id) do
    from(m in Message,
      where: m.space_id == ^space_id and is_nil(m.deleted_at),
      where: fragment("?->>'kind' = ?", m.metadata, "engagement"),
      where: fragment("?->>'source' = ?", m.metadata, "task_router"),
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1,
      select: %{
        id: m.id,
        content: m.content,
        content_type: m.content_type,
        log_only: m.log_only,
        metadata: m.metadata,
        inserted_at: m.inserted_at
      }
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
