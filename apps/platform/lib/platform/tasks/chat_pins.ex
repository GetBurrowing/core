defmodule Platform.Tasks.ChatPins do
  @moduledoc """
  Context module for task → chat pins (Pin-to-Chat, stage 2, task 019f62a1).

  Pairs with the `Platform.Tasks.ChatPin` schema. A pin marks that a
  specific participant (user or agent) has subscribed to a task's
  execution chat space. Reads back into the `Pinned` rail section in
  `chat_live` for each viewer.

  ## Lazy execution-space materialisation

  `pin/3` calls `Platform.Orchestration.ExecutionSpace.find_or_create/1`
  before writing the pin row. That call is the single-writer chokepoint
  for a task's execution space — whichever caller (this context OR the
  plan engine in `Platform.Orchestration.TaskRouter`) hits it first wins
  the insert; the other returns the pre-existing row.

  Why lazy: most tasks are captured to `backlog` and never picked up.
  Eager creation would leave orphan `chat_spaces` rows for hundreds of
  dead backlog items — reviewed and rejected in v1/v2 planner feedback.

  Regression fence: `Tasks.create_task/1` alone MUST leave zero rows in
  `chat_spaces`. `pin/3` is the earliest point at which a chat_spaces
  row can materialise from user intent.

  ## Idempotency contract

  `pin/3` is idempotent on `(task_id, participant_kind, participant_id)`.
  A repeat call:

    * Reuses the existing execution space (no duplicate `chat_spaces`
      row — `find_or_create/1` handles that).
    * Returns the existing pin row (no duplicate — DB unique index
      enforces).
    * Does NOT re-broadcast `{:task_pin_added, ...}`. The short-circuit
      is explicit at the context layer so downstream callers
      (`Platform.Chat.reinvite_and_pin_mentioned/1` in stage 3) don't have
      to dedupe. Test-observable via `refute_receive`.

  The single-callsite short-circuit is a `Repo.get_by` before insert.
  A rare race between two concurrent pinners hitting the empty pre-check
  is caught by the DB unique index — the loser's `on_conflict: :nothing`
  insert returns `{:ok, _}` and the second broadcast fires. This is
  acceptable because the receiver side (rail invalidation in ChatLive)
  is itself idempotent — the worst case is a redundant re-fetch.

  ## Broadcast shape

  Per-space broadcasts (`{:task_pin_added, payload}` /
  `{:task_pin_removed, payload}`) go out on the global space-lifecycle
  topic (`Platform.Chat.PubSub.broadcast_space_event/1`) so every
  connected `chat_live` session can invalidate its rail without needing
  to subscribe per-task. The rail handler filters by
  `participant_id == current_user`.

  ## Terminal-status cascade

  `unpin_all_for_task/1` is the cascade endpoint the task-done
  transition (stage 3) calls. It removes the pin rows but does NOT
  archive the execution space — plan-engine artifacts, canvases, and
  message history persist for post-mortem access. The rail simply stops
  surfacing the space because the join in
  `list_pinned_task_spaces_for/1` is empty.
  """

  import Ecto.Query

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Space
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks.ChatPin
  alias Platform.Tasks.Task, as: TaskSchema

  @type participant :: %{
          required(:kind) => String.t(),
          required(:id) => String.t()
        }

  @type pin_result :: %{space: Space.t(), pin: ChatPin.t() | nil}

  # ── pin / unpin ────────────────────────────────────────────────────────────

  @doc """
  Pin a task's execution chat space for the given participant.

  Flow:

    1. `ExecutionSpace.find_or_create/1` — returns the existing space
       or materialises a fresh one (this is the lazy-on-pin fence).
    2. Insert a `%ChatPin{}` with `on_conflict: :nothing` against the
       unique index — a duplicate pin returns `{:ok, nil}` from
       `Repo.insert` (no row hit) so we short-circuit the broadcast.
    3. Broadcast `{:task_pin_added, payload}` on the space-lifecycle
       topic ONLY when a new row landed.

  Returns `{:ok, %{space: %Space{}, pin: %ChatPin{} | nil}}`:

    * `pin` is the newly-inserted row on first pin.
    * `pin` is `nil` on a duplicate — the caller can pattern-match on
       that to skip downstream side effects if it needs to.

  Returns `{:error, reason}` if the execution space couldn't be
  materialised (surfaced as-is from `find_or_create/1`) or if the row
  insert fails for reasons other than the idempotency constraint.
  """
  @spec pin(binary(), participant(), String.t()) ::
          {:ok, pin_result()} | {:error, term()}
  def pin(task_id, participant, pinned_by)
      when is_binary(task_id) and is_map(participant) and is_binary(pinned_by) do
    kind = participant_kind(participant)
    id = participant_id(participant)

    with {:ok, %Space{} = space} <- ExecutionSpace.find_or_create(task_id) do
      case get_pin(task_id, kind, id) do
        %ChatPin{} = existing ->
          # Idempotent no-op — same participant re-pinned.
          {:ok, %{space: space, pin: existing}}

        nil ->
          attrs = %{
            task_id: task_id,
            participant_kind: kind,
            participant_id: id,
            pinned_by: pinned_by
          }

          changeset = ChatPin.changeset(%ChatPin{}, attrs)

          case Repo.insert(changeset,
                 on_conflict: :nothing,
                 conflict_target: [:task_id, :participant_kind, :participant_id]
               ) do
            {:ok, %ChatPin{} = pin} ->
              broadcast_pin_added(task_id, space, kind, id)
              {:ok, %{space: space, pin: pin}}

            {:error, _changeset} = err ->
              err
          end
      end
    end
  end

  @doc """
  Unpin a task's execution space for the given participant.

  Deletes the matching pin row (if any) and broadcasts
  `{:task_pin_removed, payload}` on the space-lifecycle topic. Does NOT
  archive the execution space — the plan engine may still own it, and
  post-mortem access is preserved by design.

  Returns:

    * `{:ok, :removed}` — a row was deleted and a broadcast fired.
    * `{:ok, :noop}` — nothing to delete; no broadcast.

  The `_actor` argument is reserved for future audit attribution; not
  currently persisted since the pin row itself carries `pinned_by`.
  """
  @spec unpin(binary(), participant(), String.t() | nil) ::
          {:ok, :removed | :noop}
  def unpin(task_id, participant, _actor \\ nil)
      when is_binary(task_id) and is_map(participant) do
    kind = participant_kind(participant)
    id = participant_id(participant)

    query =
      from(p in ChatPin,
        where:
          p.task_id == ^task_id and p.participant_kind == ^kind and
            p.participant_id == ^id
      )

    case Repo.delete_all(query) do
      {0, _} ->
        {:ok, :noop}

      {_n, _} ->
        broadcast_pin_removed(task_id, kind, id)
        {:ok, :removed}
    end
  end

  @doc """
  Delete every pin row for a task and broadcast the union set.

  Used by the task-done cascade in stage 3 (`transition_task_status/2`
  in `Platform.Tasks`). Emits one `{:task_pin_removed, ...}` per
  removed participant so every affected viewer's rail invalidates
  independently.

  Returns `{:ok, count}` with the number of rows removed. `count` is
  `0` when the task had no pins — no broadcasts fire in that case.

  Note: does NOT archive the execution space. See module doc.
  """
  @spec unpin_all_for_task(binary()) :: {:ok, non_neg_integer()}
  def unpin_all_for_task(task_id) when is_binary(task_id) do
    pins =
      from(p in ChatPin, where: p.task_id == ^task_id)
      |> Repo.all()

    case pins do
      [] ->
        {:ok, 0}

      pins ->
        {n, _} =
          from(p in ChatPin, where: p.task_id == ^task_id)
          |> Repo.delete_all()

        Enum.each(pins, fn %ChatPin{} = pin ->
          broadcast_pin_removed(task_id, pin.participant_kind, pin.participant_id)
        end)

        {:ok, n}
    end
  end

  # ── queries ────────────────────────────────────────────────────────────────

  @doc """
  List every non-archived execution `%Space{}` a participant has pinned.

  Joins `task_chat_pins` → `chat_spaces` via `metadata->>'task_id'`
  (soft join — no FK from pins to spaces since the space is created
  lazily and the pin row is the source of truth for the sidebar
  section). Ordered `desc: inserted_at` so recently-pinned spaces
  bubble up.

  Filters `where: is_nil(space.archived_at)` — archived exec spaces
  don't surface in the rail even if a pin row still points at them.
  """
  @spec list_pinned_task_spaces_for(participant()) :: [Space.t()]
  def list_pinned_task_spaces_for(participant) when is_map(participant) do
    kind = participant_kind(participant)
    id = participant_id(participant)

    # `space.metadata->>'task_id'` is text; `pin.task_id` is uuid. Cast
    # the pin side to text so the equality operator resolves — matching
    # how `ExecutionSpace.find_by_task_id/1` binds a plain string.
    from(pin in ChatPin,
      join: space in Space,
      on:
        space.kind == "execution" and
          fragment("?->>'task_id' = ?::text", space.metadata, pin.task_id),
      where: pin.participant_kind == ^kind and pin.participant_id == ^id,
      where: is_nil(space.archived_at),
      order_by: [desc: pin.inserted_at],
      select: space
    )
    |> Repo.all()
  end

  @doc """
  Whether the given participant has a pin row for this task.

  Hot path — used by the pin-toggle button in `tasks_live` to render
  the solid vs outline map-pin icon on every re-render of the detail
  panel. A single `Repo.exists?` query with the compound index on
  `(task_id, participant_kind, participant_id)`.
  """
  @spec pinned?(binary(), participant()) :: boolean()
  def pinned?(task_id, participant) when is_binary(task_id) and is_map(participant) do
    kind = participant_kind(participant)
    id = participant_id(participant)

    from(p in ChatPin,
      where:
        p.task_id == ^task_id and p.participant_kind == ^kind and
          p.participant_id == ^id
    )
    |> Repo.exists?()
  end

  @doc """
  Return the `task_id`s a participant has pinned as a list of UUID strings.

  Cheap read used by `PlatformWeb.TasksLive` in `mount/3` (and after each
  `:task_pin_added` / `:task_pin_removed` broadcast) to seed the socket-side
  `MapSet` that drives the pin-button state per task detail render. Avoids
  a per-render `pinned?/2` DB round-trip on the detail panel.

  Ordering is unspecified — callers are expected to funnel this straight
  into `MapSet.new/1`. No join into `chat_spaces`; when only the id set
  is needed, `list_pinned_task_spaces_for/1` is unnecessary overhead.
  """
  @spec pinned_task_ids_for(participant()) :: [binary()]
  def pinned_task_ids_for(participant) when is_map(participant) do
    kind = participant_kind(participant)
    id = participant_id(participant)

    from(p in ChatPin,
      where: p.participant_kind == ^kind and p.participant_id == ^id,
      select: p.task_id
    )
    |> Repo.all()
  end

  @doc """
  Return the participants currently pinned to a task as `{kind, id}` tuples.

  Companion reverse-lookup for `list_pinned_task_spaces_for/1`. Used by
  the stage-3 mention-propagation pass to enumerate the existing pin set
  when a sponsor @-mentions a fresh participant, and by consumers that
  need to fan out to every pinned viewer.
  """
  @spec pinned_participants_for_task(binary()) :: [{String.t(), String.t()}]
  def pinned_participants_for_task(task_id) when is_binary(task_id) do
    from(p in ChatPin,
      where: p.task_id == ^task_id,
      select: {p.participant_kind, p.participant_id}
    )
    |> Repo.all()
  end

  @doc """
  Resolve the human-readable label for a pinned task-exec space.

  Rail rows render `space.name`, which for execution spaces is the
  synthesised slug `task-exec-<8-char-id>` — cryptic and
  non-differentiating when a viewer has more than one task pinned
  (Rowan, stage-4 review: "People won't know which one is which if you
  have two"). This helper joins into `tasks` via
  `space.metadata["task_id"]` and returns the task's real title.

  Defensive fallback to `space.name` on any lookup miss (metadata
  missing the `task_id` key, task deleted, non-execution space passed
  in). Keeps the rail render infallible — the label is presentation,
  not a source of truth.

  Kept as an on-demand render helper rather than baked into
  `list_pinned_task_spaces_for/1` so downstream callers of the list
  don't inherit a shape change; only the rail template pays the extra
  round-trip, and only for the small number of pinned rows a single
  user actually has.
  """
  @spec display_name_for_space(Space.t()) :: String.t()
  def display_name_for_space(%Space{metadata: metadata} = space) do
    case metadata do
      %{"task_id" => task_id} when is_binary(task_id) ->
        case Repo.one(from(t in TaskSchema, where: t.id == ^task_id, select: t.title)) do
          title when is_binary(title) and title != "" -> title
          _ -> space.name
        end

      _ ->
        space.name
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Accept both atom-keyed (%{kind: "user", id: "..."}) and string-keyed
  # (%{"kind" => "user", "id" => "..."}) shapes so callers coming in
  # from JSON tool surfaces don't have to normalize first.
  defp participant_kind(%{kind: kind}), do: to_string(kind)
  defp participant_kind(%{"kind" => kind}), do: to_string(kind)

  defp participant_id(%{id: id}), do: to_string(id)
  defp participant_id(%{"id" => id}), do: to_string(id)

  # Compound-index-covered lookup used by both the pin/3 short-circuit
  # and the potential future audit-attribution path.
  defp get_pin(task_id, kind, id) do
    Repo.get_by(ChatPin,
      task_id: task_id,
      participant_kind: kind,
      participant_id: id
    )
  end

  defp broadcast_pin_added(task_id, %Space{} = space, kind, id) do
    ChatPubSub.broadcast_space_event(
      {:task_pin_added,
       %{
         task_id: task_id,
         space_id: space.id,
         participant_kind: kind,
         participant_id: id
       }}
    )
  end

  defp broadcast_pin_removed(task_id, kind, id) do
    ChatPubSub.broadcast_space_event(
      {:task_pin_removed, %{task_id: task_id, participant_kind: kind, participant_id: id}}
    )
  end
end
