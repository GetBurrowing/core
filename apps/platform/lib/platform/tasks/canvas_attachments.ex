defmodule Platform.Tasks.CanvasAttachments do
  @moduledoc """
  Context module for task → canvas attachments (task_attach_canvas, stage 2).

  Pairs with the `Platform.Tasks.CanvasAttachment` schema (stage 1). Kept as a
  dedicated submodule rather than bolted onto `Platform.Tasks` because that
  parent module is already 2000+ lines and the attachment boundary is crisp:
  the MCP tool surface (stage 3), the dispatch bundler (stage 4), and the
  LiveView (stage 5) all consume this surface and nothing else from `Tasks`
  to do their work.

  ## Soft-reference invariant

  `canvas_id` is a soft reference — there is **no** FK from
  `task_canvas_attachments.canvas_id` to `chat_canvases.id`. Soft-deleting a
  canvas leaves the attachment row stale (not broken), which matches how
  downstream consumers degrade: a missing canvas surfaces as `canvas: nil`
  in `list_task_canvases/1` so the caller can choose to detach it rather
  than failing loud.

  The flip side is that `attach_canvas/4` validates canvas existence
  (and `is_nil(deleted_at)`) **before** insert, so creating a dangling
  attachment from an MCP tool call surfaces loud at attach time, not
  silently later in a downstream consumer.

  ## Idempotent re-attach

  `attach_canvas/4` is idempotent on `(task_id, canvas_id)`. A second call
  with the same pair updates `note` + `attached_by_*` + bumps `updated_at`
  on the existing row, returning the same `id`. This matches how the MCP
  tool will be invoked when an agent attaches the same evidence canvas
  multiple times across a multi-stage task — re-attach is a no-op rather
  than a duplicate row or a unique-constraint surface.

  ## Both writes are gated on the TASK as well as on the canvas

  `attach_canvas/4` and `detach_canvas/3` are the two functions that mutate
  the grant graph, so each runs `ensure_task_touchable/3` before it touches a
  row. Two INDEPENDENT conjuncts: attaching requires the caller to be able to
  WRITE the task AND to be able to READ the canvas. Neither implies the
  other, which is why the denials are named separately — `:task_forbidden`
  and `:canvas_forbidden`.

  The task check runs FIRST. A caller who may not write the task learns that
  before learning anything about the canvas, so the attach surface is not an
  existence oracle for canvases belonging to spaces the caller is nowhere
  near.

  ## The task gate is `tasks.write`, the same rule as `task_update`

  Task 01a1559a stage 1 deleted the old six-path task-binding module and its
  rule (assignee, phase assignee, execution-space participant, sponsor,
  project-org member, `:system`) with the rule every other Tasks write
  already uses: `Platform.Access.task_target(scope, {:task, task_id},
  "tasks.write")` — the org fence plus the role permission. The read
  `task_list_canvases` uses the same call with `"tasks.read"`. Agents and
  users go through the one rule; an agent no longer has to be bound to the
  task to attach to it.

  Every function here takes a `%Platform.Access.Scope{}` FIRST, in place of
  the old `{:user, id} | {:agent, id} | :system` actor triple, so the
  principal and the scope it is judged by cannot disagree. Platform-initiated
  work passes `Platform.Access.Scope.system/0` explicitly. A `nil` scope (or
  anything that is not a Scope) is NO PRINCIPAL and is refused with
  `:task_forbidden`; it is never promoted to `system/0`, because a silent
  bypass on an authorization path is worse than an outage.

  Gate order, each step deliberate:

    1. the task is loaded with `deleted_at: nil` (and a
       `Platform.UUID.valid?/1` guard on the raw id). A malformed, absent or
       SOFT-DELETED task is `:task_not_found` for everyone.
       `Platform.Access.TaskTarget.resolve/1` checks existence only, so this
       load is what keeps the soft-deleted case a not-found;
    2. `task_target/3` decides. A refusal emits
       `[:platform, :tasks, :access_denied]` (registered in
       `Platform.Audit.TelemetryHandler`) and returns `:task_forbidden`.
       Grants are not audited, and a not-found emits nothing, so the audit
       stream is not an existence oracle;
    3. (attach only) the canvas exists, is not soft-deleted, and the scope's
       principal may read it (`Platform.Chat.CanvasAccess`, with
       `access_scope: scope`).

  ### Consequence, recorded: a root-org-owned runtime is unfenced

  The fence for an agent runtime is its OWNER's (`owner_cap`), exactly as for
  `task_update`. An agent runtime whose owner is a root-org member is
  therefore unfenced, and may attach a canvas it can read onto a task in
  ANOTHER org. Attaching grants that org `:task_reader` on the canvas
  (`Platform.Chat.CanvasAccess`), so this is a cross-org disclosure path that
  exists on purpose. What bounds it is the canvas conjunct above: the
  attacher must already read the canvas, so nobody can confer a read they do
  not hold.

  ## Stack attach and detach (task 01a1559a stage 2)

  `attach_canvas_to_stack/4` and `detach_canvas_from_stack/3` apply the same
  `tasks.write` rule to a stack: to the stack itself and to EVERY member,
  all-or-nothing, so one refused member writes nothing. They differ from the
  single-task pair in two deliberate ways. Stack attach inserts with
  `on_conflict: :nothing`, so a member that already carries the canvas keeps
  its row (note, attribution, timestamps) and is counted as skipped. And
  stack attach never runs the ADR-0046 design-step settle, so attaching a
  canvas to a stack moves no member and dispatches nothing.
  `list_stack_canvases/1` and `stack_coverage/2` are scope-less reads for
  the stack view, for the reason given below for `list_task_canvases/1`.

  ## `list_task_canvases/1` takes no scope, and the read gate lives upstream

  Most of its callers are in-process platform code with no principal to
  authorize: `Platform.Tasks.ContextHydrator` and
  `Platform.Orchestration.ContextAssembler` assemble dispatch payloads,
  `Platform.Responsibilities.Handlers.DesignTaskDirection` assembles a
  responsibility's context, and the Tasks LiveView renders a board whose
  session is already authorized. Giving this function a required scope would
  mint `Scope.system/0` call sites where a real principal belonged; the gate
  would read as enforcement while enforcing nothing.

  The MCP `task_list_canvases` tool is the caller holding a principal, and
  that is where the read gate sits: `ensure_task_touchable/3` with
  `permission: "tasks.read"`, so the read uses the same door and the same
  denial taxonomy as the two writes.

  ### Why the attachment read DENIES rather than returning an empty list

  An empty list leaks less in the abstract. It was rejected twice over
  (task 019fb581 stage 4, carried here when its old module was deleted).

  It is indistinguishable from a task that genuinely has no attachments, so
  a caller refused an attach one call earlier reads `[]` and concludes the
  write silently failed. And it makes the tool's own `returns` contract
  false: a caller handed `canvases: []` for a task carrying three
  attachments has been given a wrong answer rather than a withheld one. A
  refusal that lies is worse than a refusal that is legible.

  The usual argument for the empty list, that a refusal is an existence
  oracle, does not hold while `task_get` is open, because the same caller
  learns existence there in one call, for free, from the same capability
  bundle. The denial hands over nothing a `task_get` would not.

  That is a REAL coupling rather than a rhetorical one: gate `task_get` and
  this reasoning expires. `tool_surface_test.exs` pins it with a test
  asserting the caller `task_list_canvases` denies still gets `{:ok, _}`
  from `task_get` for the same id, so whoever closes the read hole is made to
  re-read this section instead of discovering the coupling afterwards.
  `task_get` and `task_list` being ungated is itself a decision, filed as
  Burrow task `019fbe15-fa42-7486-a85c-1c4af5f1a504`.
  """

  import Ecto.Query

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasAccess
  alias Platform.Repo
  alias Platform.Tasks.{CanvasAttachment, Stack, Stacks, Task}

  @denial_event [:platform, :tasks, :access_denied]

  @type attached_by :: %{kind: String.t(), id: binary()}
  @type attach_opts :: [{:note, String.t() | nil} | {:attached_by, attached_by()}]

  @type list_entry :: %{
          attachment: %CanvasAttachment{},
          canvas:
            %{id: binary(), title: String.t() | nil, kind: String.t() | nil, deleted_at: any()}
            | nil
        }

  @type task_entry :: %{
          attachment: %CanvasAttachment{},
          task:
            %{
              id: binary(),
              title: String.t() | nil,
              status: String.t() | nil,
              project_id: binary() | nil
            }
            | nil
        }

  # ── attach ────────────────────────────────────────────────────────────────

  @doc """
  Attach a canvas to a task, on behalf of the principal behind `scope`.

  Validates that `scope` may `tasks.write` the task, that the canvas exists
  and is not soft-deleted, and that the principal may READ the canvas,
  before insert.
  Idempotent on `(task_id, canvas_id)` via upsert — a second call updates
  `note` + attribution + bumps `updated_at` and returns the same row id.

  ## Why the attacher is authorized against the task

  Attaching is a WRITE to the task, and it is the write that mints the
  `:task_reader` grant described below. Before task 019fb581 stage 3 this
  function checked only that the task existed, so any principal holding a
  canvas could staple it to any task in the system. The task gate
  (`ensure_task_touchable/3`, `tasks.write` through
  `Platform.Access.task_target/3` since task 01a1559a) is the first step of
  the chain.

  ## Why the attacher is authorized against the canvas

  `Platform.Chat.CanvasAccess`'s `:task_reader` grant says: you may read a
  canvas if it is attached to a task whose project org you belong to. An
  unauthorized attach is therefore a self-service grant — staple a stranger's
  canvas id onto a task in your own org and the whole org can read it.

  So attaching requires already holding a read grant on the canvas. You cannot
  confer a read you do not have. The `t:Platform.Chat.CanvasAccess.actor/0`
  viewer is derived from `scope.actor` (a runtime reads as `{:agent,
  agent_id}`, a user as `{:user, id}`, `Scope.system/0` as `:system`) and
  the scope itself is passed as `:access_scope`; the read is resolved with
  `audit: false`, since an authorization probe is not a read of the document.

  **`:attached_by` is attribution, not authorization.** It records who to show
  in the UI and is caller-supplied; it is never the subject of this check.
  `attached_by` and `scope` legitimately differ — see
  `Platform.Responsibilities.Handlers.DesignTaskDirection`, which attaches
  with `Scope.system/0` while attributing the canvas to the responsible
  designer.

  There is deliberately no defaulting arity for the scope: a caller that
  forgets it should fail to compile, not silently bypass the gate.

  ## Options

    * `:note` — optional human note (string).
    * `:attached_by` — `%{kind: "agent" | "user", id: <uuid>}`. Required.

  ## Returns

    * `{:ok, %CanvasAttachment{}}` on success (insert or upsert).
    * `{:error, :task_not_found}` if the task id is malformed, doesn't
      resolve, or resolves to a soft-deleted row.
    * `{:error, :task_forbidden}` if `scope` may not `tasks.write` the task,
      or is not a Scope at all.
    * `{:error, :canvas_not_found}` if the canvas id doesn't resolve, or the
      canvas is soft-deleted.
    * `{:error, :canvas_forbidden}` if the principal may not read the canvas.
    * `{:error, %Ecto.Changeset{}}` if the inputs fail changeset validation
      (missing `attached_by`, bad `kind`, etc.).
  """
  @spec attach_canvas(Scope.t() | nil, binary(), binary(), attach_opts()) ::
          {:ok, %CanvasAttachment{}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :task_not_found}
          | {:error, :task_forbidden}
          | {:error, :canvas_not_found}
          | {:error, :canvas_forbidden}
  def attach_canvas(scope, task_id, canvas_id, opts \\ [])
      when is_binary(task_id) and is_binary(canvas_id) and is_list(opts) do
    with :ok <-
           ensure_task_touchable(scope, task_id,
             permission: "tasks.write",
             tool: "task_attach_canvas"
           ),
         :ok <- ensure_canvas_attachable(canvas_id),
         :ok <- ensure_canvas_readable(canvas_id, scope) do
      attached_by = Keyword.get(opts, :attached_by, %{})
      kind = attached_by[:kind] || attached_by["kind"]
      id = attached_by[:id] || attached_by["id"]

      attrs = %{
        task_id: task_id,
        canvas_id: canvas_id,
        note: Keyword.get(opts, :note),
        attached_by_kind: kind,
        attached_by_id: id
      }

      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)

      Repo.insert(changeset,
        on_conflict: {:replace, [:note, :attached_by_kind, :attached_by_id, :updated_at]},
        conflict_target: [:task_id, :canvas_id],
        returning: true
      )
      |> tap_settle_design_step()
    end
  end

  # ADR-0046 member 7 stage 4. A canvas landing on a task is the completion
  # signal for the pre-plan design step: the canvas IS the deliverable, so the
  # deliverable arriving is the honest signal — and unlike a dedicated "I'm
  # done" MCP tool it also works when a human attaches the canvas by hand, and
  # cannot be forgotten in a way that is indistinguishable from stalling.
  #
  # `Platform.Design.PreplanStep.settle/2` is a no-op unless the task's cursor
  # is `"designing"` or its design step is recorded `"failed"`, so this is inert
  # for every other attachment in the system.
  #
  # Side-effect only, twice over: the `{:ok, _}` tuple is returned verbatim, and
  # the whole call is wrapped so a settler that raises cannot turn a successful
  # attach into an error or a crash. Asserted in `canvas_attachments_test.exs`
  # with a deliberately raising stub injected through the seam below.
  defp tap_settle_design_step({:ok, %CanvasAttachment{} = attachment} = result) do
    {mod, fun} =
      Application.get_env(
        :platform,
        :design_preplan_settler,
        {Platform.Design.PreplanStep, :settle}
      )

    _ =
      try do
        apply(mod, fun, [attachment.task_id, attachment])
      rescue
        e ->
          require Logger

          Logger.warning(
            "[task_attach_canvas] design settle hook raised for task=" <>
              "#{attachment.task_id}: #{Exception.message(e)}"
          )

          :error
      catch
        :exit, reason ->
          require Logger

          Logger.warning(
            "[task_attach_canvas] design settle hook exited for task=" <>
              "#{attachment.task_id}: #{inspect(reason)}"
          )

          :error
      end

    result
  end

  defp tap_settle_design_step(other), do: other

  # ── detach ────────────────────────────────────────────────────────────────

  @doc """
  Detach a canvas from a task, on behalf of the principal behind `scope`.

  Returns `:ok` if exactly one row was deleted; `{:error, :not_found}` if
  no matching pair existed. Safe to call on a pair whose canvas was
  soft-deleted upstream — the attachment row is keyed independently.

  Gated on the TASK only (`tasks.write`, as for `attach_canvas/4`).
  Detaching removes a `:task_reader` grant rather than conferring one, so
  there is no canvas-side conjunct to satisfy: a caller who may write the
  task may clean up its stale rows even for a
  canvas they cannot read. That asymmetry with `attach_canvas/4` is the
  point — you cannot confer a read you do not hold, but you may always
  revoke one you handed out.

  As with `attach_canvas/4` there is deliberately no defaulting arity: a
  caller that forgets the scope should fail to compile, not silently
  bypass the gate.

  ## Returns

    * `:ok` when a row was deleted.
    * `{:error, :not_found}` when no `(task_id, canvas_id)` pair existed.
    * `{:error, :task_not_found}` when the task id is malformed, absent, or
      soft-deleted.
    * `{:error, :task_forbidden}` when `scope` may not `tasks.write` the
      task, or is not a Scope at all.
  """
  @spec detach_canvas(Scope.t() | nil, binary(), binary()) ::
          :ok
          | {:error, :not_found}
          | {:error, :task_not_found}
          | {:error, :task_forbidden}
  def detach_canvas(scope, task_id, canvas_id)
      when is_binary(task_id) and is_binary(canvas_id) do
    with :ok <-
           ensure_task_touchable(scope, task_id,
             permission: "tasks.write",
             tool: "task_detach_canvas"
           ) do
      query =
        from(a in CanvasAttachment,
          where: a.task_id == ^task_id and a.canvas_id == ^canvas_id
        )

      case Repo.delete_all(query) do
        {0, _} -> {:error, :not_found}
        {n, _} when n >= 1 -> :ok
      end
    end
  end

  # ── list ──────────────────────────────────────────────────────────────────

  @doc """
  List attachments for a task with their canvas envelope.

  Returns rows in `inserted_at` ASC order. Each entry is
  `%{attachment: %CanvasAttachment{}, canvas: ... | nil}`. The `canvas`
  envelope is a thin map (`id`, `title`, `kind`, `deleted_at`) so callers
  don't drag the full document graph around when they're just rendering a
  list.

  When the underlying canvas is missing or soft-deleted, `canvas` is `nil`
  rather than dropped — so the caller sees the stale attachment exists and
  can choose to detach it.

  Implementation is a single batched query: load the attachments, then ONE
  `Repo.all` over the unique canvas ids. Not N+1.
  """
  @spec list_task_canvases(binary()) :: [list_entry()]
  def list_task_canvases(task_id) when is_binary(task_id) do
    attachments =
      from(a in CanvasAttachment,
        where: a.task_id == ^task_id,
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()

    canvas_ids =
      attachments
      |> Enum.map(& &1.canvas_id)
      |> Enum.uniq()

    canvases_by_id =
      case canvas_ids do
        [] ->
          %{}

        ids ->
          from(c in Canvas, where: c.id in ^ids)
          |> Repo.all()
          |> Map.new(fn c -> {c.id, c} end)
      end

    Enum.map(attachments, fn attachment ->
      %{
        attachment: attachment,
        canvas: canvas_envelope(Map.get(canvases_by_id, attachment.canvas_id))
      }
    end)
  end

  @doc """
  Reverse of `list_task_canvases/1`: list the tasks a canvas is attached to.

  Returns rows in `inserted_at` ASC order. Each entry is
  `%{attachment: %CanvasAttachment{}, task: ... | nil}`, where the `task`
  envelope is a thin map (`id`, `title`, `status`, `project_id`) for symmetry
  with the forward lookup — callers authorize or render off the envelope
  without dragging the full 60-field task row around.

  `task_id` carries a real FK (`on_delete: :delete_all`), so an attachment
  whose task vanished cannot exist. `deleted_at` is a different matter: tasks
  soft-delete, and a soft-deleted task surfaces as `task: nil` — the same
  "stale attachment, not broken attachment" degradation `list_task_canvases/1`
  applies to a soft-deleted canvas. `Platform.Chat.CanvasAccess` depends on
  that: a `:task_reader` grant must not survive the deletion of the only task
  that conferred it.

  Single LEFT JOIN — not N+1, and not the two-query batch its sibling needs
  (that one joins across a soft reference with no FK, so it cannot join).
  """
  @spec list_canvas_tasks(binary()) :: [task_entry()]
  def list_canvas_tasks(canvas_id) when is_binary(canvas_id) do
    if Platform.UUID.valid?(canvas_id) do
      from(a in CanvasAttachment,
        left_join: t in Task,
        on: t.id == a.task_id,
        where: a.canvas_id == ^canvas_id,
        order_by: [asc: a.inserted_at],
        select: {a, t}
      )
      |> Repo.all()
      |> Enum.map(fn {attachment, task} ->
        %{attachment: attachment, task: task_envelope(task)}
      end)
    else
      []
    end
  end

  # ── stack attach / detach (task 01a1559a stage 2) ─────────────────────────

  @doc """
  Attach a canvas to every member of a stack, on behalf of the principal
  behind `scope`.

  ## The gate is all-or-nothing

  The stack must exist (`Platform.Tasks.Stacks.get_stack/1`), `scope` must
  hold `tasks.write` on the stack through `Platform.Access.task_target/3`
  (`{:stack, id}`), and then on EVERY non-deleted member
  (`Platform.Tasks.Stacks.members/1`) through the same call with
  `{:task, id}`. One refused member refuses the whole call with
  `:task_forbidden` and nothing is written. The canvas conjunct (exists, not
  soft-deleted, readable by the principal) runs once, after the task gate,
  exactly as in `attach_canvas/4`.

  ## Idempotent, and existing rows are NOT touched

  The write is ONE `Repo.insert_all/3` with `on_conflict: :nothing` on
  `(task_id, canvas_id)`, inside a transaction. A member that already
  carries the canvas keeps its row exactly as it was: its `note`,
  `attached_by_*` and timestamps survive. This deliberately differs from the
  single-task upsert in `attach_canvas/4`, because `skipped` must mean
  skipped: a bulk attach that rewrote attribution on rows it reports as
  untouched would make the count a lie.

  `attached_task_ids` are the ids the insert returned; `skipped_task_ids` are
  the members minus those. An empty stack returns zeros.

  ## No design-step settle

  Stack attach does NOT call the ADR-0046 design-step hook that
  `attach_canvas/4` runs. A bulk attach is organisation, not a designer's
  per-task deliverable: settling would close each member's design step,
  move its planning cursor to `planning` and release the planner, so a stack
  attach would dispatch work. It moves no member: no status, assignee,
  phase assignee or planning step changes, and no lease or dispatch event is
  created.

  ## Returns

    * `{:ok, %{stack_id, canvas_id, member_count, attached_count,
      skipped_count, attached_task_ids, skipped_task_ids}}`
    * `{:error, :stack_not_found}` — malformed or absent stack id.
    * `{:error, :task_forbidden}` — `scope` may not `tasks.write` the stack
      or one of its members, or is not a Scope at all.
    * `{:error, :canvas_not_found}` / `{:error, :canvas_forbidden}` — as
      `attach_canvas/4`.
    * `{:error, %Ecto.Changeset{}}` — `:attached_by` fails validation.
  """
  @spec attach_canvas_to_stack(Scope.t() | nil, binary(), binary(), attach_opts()) ::
          {:ok, map()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :stack_not_found}
          | {:error, :task_forbidden}
          | {:error, :canvas_not_found}
          | {:error, :canvas_forbidden}
  def attach_canvas_to_stack(scope, stack_id, canvas_id, opts \\ [])
      when is_binary(stack_id) and is_binary(canvas_id) and is_list(opts) do
    with {:ok, stack, members} <-
           ensure_stack_touchable(scope, stack_id, "stack_attach_canvas"),
         :ok <- ensure_canvas_attachable(canvas_id),
         :ok <- ensure_canvas_readable(canvas_id, scope),
         {:ok, rows} <- stack_attach_rows(members, canvas_id, opts) do
      member_ids = Enum.map(members, & &1.id)

      {:ok, attached_ids} =
        Repo.transaction(fn ->
          case rows do
            [] ->
              []

            rows ->
              {_count, returned} =
                Repo.insert_all(CanvasAttachment, rows,
                  on_conflict: :nothing,
                  conflict_target: [:task_id, :canvas_id],
                  returning: [:task_id]
                )

              Enum.map(returned, & &1.task_id)
          end
        end)

      {attached, skipped} = split_by_membership(member_ids, attached_ids)

      {:ok,
       %{
         stack_id: stack.id,
         canvas_id: canvas_id,
         member_count: length(member_ids),
         attached_count: length(attached),
         skipped_count: length(skipped),
         attached_task_ids: attached,
         skipped_task_ids: skipped
       }}
    end
  end

  @doc """
  Detach a canvas from every member of a stack, on behalf of the principal
  behind `scope`.

  Same all-or-nothing gate as `attach_canvas_to_stack/4` (the stack and
  every member, `tasks.write`), and, as with `detach_canvas/3`, no canvas-side
  conjunct: revoking a grant needs no read of the canvas. One `delete_all`
  over the member ids. A malformed `canvas_id` names no row, so it detaches
  nothing and reports every member as skipped.

  ## Returns

    * `{:ok, %{stack_id, canvas_id, member_count, detached_count,
      skipped_count, detached_task_ids, skipped_task_ids}}`
    * `{:error, :stack_not_found}` / `{:error, :task_forbidden}` — as
      `attach_canvas_to_stack/4`.
  """
  @spec detach_canvas_from_stack(Scope.t() | nil, binary(), binary()) ::
          {:ok, map()} | {:error, :stack_not_found} | {:error, :task_forbidden}
  def detach_canvas_from_stack(scope, stack_id, canvas_id)
      when is_binary(stack_id) and is_binary(canvas_id) do
    with {:ok, stack, members} <-
           ensure_stack_touchable(scope, stack_id, "stack_detach_canvas") do
      member_ids = Enum.map(members, & &1.id)

      detached_ids =
        if member_ids != [] and Platform.UUID.valid?(canvas_id) do
          {_count, returned} =
            from(a in CanvasAttachment,
              where: a.task_id in ^member_ids and a.canvas_id == ^canvas_id,
              select: a.task_id
            )
            |> Repo.delete_all()

          returned
        else
          []
        end

      {detached, skipped} = split_by_membership(member_ids, detached_ids)

      {:ok,
       %{
         stack_id: stack.id,
         canvas_id: canvas_id,
         member_count: length(member_ids),
         detached_count: length(detached),
         skipped_count: length(skipped),
         detached_task_ids: detached,
         skipped_task_ids: skipped
       }}
    end
  end

  @doc """
  The canvases attached to any non-deleted member of a stack, for the stack
  view.

  One grouped query over the attachments joined to the members, then ONE
  query for the canvas envelopes. Each entry is `%{canvas_id, canvas,
  attached_task_ids, attached_count, member_count}`; `canvas` is the same
  thin envelope `list_task_canvases/1` returns, `nil` when the canvas is
  missing or soft-deleted. `attached_task_ids` follow stack position.
  Ordered by first attachment. Takes no scope: like `list_task_canvases/1`,
  its read gate lives with the caller. A malformed stack id returns `[]`.
  """
  @spec list_stack_canvases(binary()) :: [map()]
  def list_stack_canvases(stack_id) when is_binary(stack_id) do
    if Platform.UUID.valid?(stack_id) do
      member_count = stack_member_count(stack_id)

      grouped =
        from(a in CanvasAttachment,
          join: t in Task,
          on: t.id == a.task_id,
          where: t.stack_id == ^stack_id and is_nil(t.deleted_at),
          group_by: a.canvas_id,
          order_by: [asc: min(a.inserted_at), asc: a.canvas_id],
          select: {
            a.canvas_id,
            type(
              fragment("array_agg(? ORDER BY ?, ?)", a.task_id, t.stack_position, t.id),
              {:array, Ecto.UUID}
            )
          }
        )
        |> Repo.all()

      canvases_by_id =
        case Enum.map(grouped, &elem(&1, 0)) do
          [] ->
            %{}

          ids ->
            from(c in Canvas, where: c.id in ^ids)
            |> Repo.all()
            |> Map.new(fn c -> {c.id, c} end)
        end

      Enum.map(grouped, fn {canvas_id, task_ids} ->
        %{
          canvas_id: canvas_id,
          canvas: canvas_envelope(Map.get(canvases_by_id, canvas_id)),
          attached_task_ids: task_ids,
          attached_count: length(task_ids),
          member_count: member_count
        }
      end)
    else
      []
    end
  end

  @doc """
  How a stack attach of `canvas_id` would land: `%{member_count,
  already_count, to_attach_count}` over the non-deleted members. A read for
  the stack view's confirm line; it authorizes nothing and writes nothing.
  """
  @spec stack_coverage(binary(), binary()) :: %{
          member_count: non_neg_integer(),
          already_count: non_neg_integer(),
          to_attach_count: non_neg_integer()
        }
  def stack_coverage(stack_id, canvas_id) when is_binary(stack_id) and is_binary(canvas_id) do
    if Platform.UUID.valid?(stack_id) do
      member_count = stack_member_count(stack_id)

      already =
        if Platform.UUID.valid?(canvas_id) do
          from(a in CanvasAttachment,
            join: t in Task,
            on: t.id == a.task_id,
            where: t.stack_id == ^stack_id and is_nil(t.deleted_at) and a.canvas_id == ^canvas_id,
            select: count(a.id)
          )
          |> Repo.one()
        else
          0
        end

      %{
        member_count: member_count,
        already_count: already,
        to_attach_count: member_count - already
      }
    else
      %{member_count: 0, already_count: 0, to_attach_count: 0}
    end
  end

  # The stack door: the stack exists, then `tasks.write` on the stack and on
  # every member, all-or-nothing. A refusal emits the same
  # `[:platform, :tasks, :access_denied]` event the task door does, naming
  # the refused target.
  defp ensure_stack_touchable(scope, stack_id, tool) do
    case Stacks.get_stack(stack_id) do
      nil ->
        {:error, :stack_not_found}

      %Stack{} = stack ->
        members = Stacks.members(stack.id)

        refused =
          if stack_permitted?(scope, stack),
            do: Enum.find(members, &(not task_permitted?(scope, &1, "tasks.write"))),
            else: stack

        case refused do
          nil ->
            {:ok, stack, members}

          target ->
            emit_denial(target, scope, tool)
            {:error, :task_forbidden}
        end
    end
  end

  defp stack_permitted?(%Scope{} = scope, %Stack{id: id}),
    do: match?({:ok, _typed}, Access.task_target(scope, {:stack, id}, "tasks.write"))

  defp stack_permitted?(_scope, _stack), do: false

  # Rows for `insert_all/3`, validated through the same changeset the
  # single attach uses so a bad `attached_by` is the same changeset error.
  # `insert_all` runs no autogenerate, so the id and both timestamps are set
  # here.
  defp stack_attach_rows(members, canvas_id, opts) do
    attached_by = Keyword.get(opts, :attached_by, %{})
    now = DateTime.utc_now()

    Enum.reduce_while(members, {:ok, []}, fn %Task{id: task_id}, {:ok, acc} ->
      attrs = %{
        task_id: task_id,
        canvas_id: canvas_id,
        note: Keyword.get(opts, :note),
        attached_by_kind: attached_by[:kind] || attached_by["kind"],
        attached_by_id: attached_by[:id] || attached_by["id"]
      }

      case CanvasAttachment.changeset(%CanvasAttachment{}, attrs) do
        %Ecto.Changeset{valid?: true} = changeset ->
          row =
            changeset
            |> Ecto.Changeset.apply_changes()
            |> Map.take([:task_id, :canvas_id, :note, :attached_by_kind, :attached_by_id])
            |> Map.merge(%{
              id: Platform.Types.UUIDv7.generate(),
              inserted_at: now,
              updated_at: now
            })

          {:cont, {:ok, [row | acc]}}

        changeset ->
          {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  # Member ids in stack order, split by whether `hit_ids` names them.
  defp split_by_membership(member_ids, hit_ids) do
    hits = MapSet.new(hit_ids)
    Enum.split_with(member_ids, &MapSet.member?(hits, &1))
  end

  defp stack_member_count(stack_id) do
    from(t in Task,
      where: t.stack_id == ^stack_id and is_nil(t.deleted_at),
      select: count(t.id)
    )
    |> Repo.one()
  end

  # ── the task door ─────────────────────────────────────────────────────────

  @doc """
  The task door for canvas-attachment surfaces, in this module's taxonomy.

  `scope` is a `%Platform.Access.Scope{}`; anything else (including `nil`)
  is no principal and returns `{:error, :task_forbidden}` once the task is
  known to exist. The decision is `Platform.Access.task_target(scope,
  {:task, task_id}, permission)`: the org fence plus the role permission,
  the same rule `task_update` is held to. See the moduledoc for the order
  and the root-org consequence.

  Public because three surfaces need the same answer: both writes here, and
  the MCP `task_list_canvases` clause in `Platform.Federation.ToolSurface`,
  whose read gate is the only place a principal reaches
  `list_task_canvases/1`.

  ## Options

    * `:permission` — `"tasks.write"` (default) or `"tasks.read"`.
    * `:tool` — the tool name recorded on the denial event. A telemetry
      label only, never an input to the decision.

  ## Returns

    * `:ok`
    * `{:error, :task_not_found}` — malformed id, no row, or soft-deleted.
      Emits nothing.
    * `{:error, :task_forbidden}` — the task is live and `scope` may not
      act on it. Emits `[:platform, :tasks, :access_denied]`.
  """
  @spec ensure_task_touchable(Scope.t() | nil, binary(), keyword()) ::
          :ok | {:error, :task_forbidden} | {:error, :task_not_found}
  def ensure_task_touchable(scope, task_id, opts \\ []) when is_list(opts) do
    permission = Keyword.get(opts, :permission, "tasks.write")

    case load_live_task(task_id) do
      nil ->
        {:error, :task_not_found}

      %Task{} = task ->
        if task_permitted?(scope, task, permission) do
          :ok
        else
          emit_denial(task, scope, Keyword.get(opts, :tool))
          {:error, :task_forbidden}
        end
    end
  end

  # `task_id` is a raw MCP tool argument. `Platform.UUID.valid?/1`, not a bare
  # `Ecto.UUID.cast/1`: a bare cast accepts any 16-byte binary, and a
  # 16-character slug would clear it and make `Repo.get/2` raise.
  defp load_live_task(task_id) when is_binary(task_id) do
    with true <- Platform.UUID.valid?(task_id),
         %Task{deleted_at: nil} = task <- Repo.get(Task, task_id) do
      task
    else
      _ -> nil
    end
  end

  defp load_live_task(_task_id), do: nil

  defp task_permitted?(%Scope{} = scope, %Task{id: task_id}, permission)
       when permission in ["tasks.write", "tasks.read"] do
    match?({:ok, _typed}, Access.task_target(scope, {:task, task_id}, permission))
  end

  defp task_permitted?(_scope, _task, _permission), do: false

  # `target` is the refused task, or the refused stack (task 01a1559a stage
  # 2); both carry `id` and `project_id`, and `resource_type` names which.
  defp emit_denial(target, scope, tool) do
    {actor_type, actor_id} = audit_actor(scope)

    :telemetry.execute(
      @denial_event,
      %{system_time: System.system_time()},
      %{
        actor_id: actor_id,
        actor_type: actor_type,
        resource_type: denial_resource_type(target),
        resource_id: target.id,
        action: "denied",
        project_id: target.project_id,
        tool: tool
      }
    )

    :ok
  end

  defp denial_resource_type(%Stack{}), do: "stack"
  defp denial_resource_type(%Task{}), do: "task"

  # `"anonymous"` is the audit taxonomy's value for a request with no
  # principal (a nil scope, or a scope whose actor is not a user or runtime).
  defp audit_actor(%Scope{actor: %AgentRuntime{agent_id: id}}) when is_binary(id),
    do: {"agent", id}

  defp audit_actor(%Scope{actor: %AgentRuntime{}}), do: {"anonymous", nil}
  defp audit_actor(%Scope{actor: %{id: id}}) when is_binary(id), do: {"user", id}
  defp audit_actor(_scope), do: {"anonymous", nil}

  # The `Platform.Chat.CanvasAccess` viewer for the principal behind `scope`.
  defp canvas_viewer(%Scope{actor: :system}), do: :system

  defp canvas_viewer(%Scope{actor: %AgentRuntime{agent_id: id}}) when is_binary(id),
    do: {:agent, id}

  defp canvas_viewer(%Scope{actor: %AgentRuntime{}}), do: nil
  defp canvas_viewer(%Scope{actor: %{id: id}}) when is_binary(id), do: {:user, id}
  defp canvas_viewer(_scope), do: nil

  # ── internals ─────────────────────────────────────────────────────────────

  # `canvas_id` is a raw `task_attach_canvas` MCP tool argument. Malformed
  # folds into the existing not-found error. Platform.UUID.valid?/1, not a
  # bare Ecto.UUID.cast/1 — a bare cast accepts any 16-byte binary.
  defp ensure_canvas_attachable(canvas_id) do
    if not Platform.UUID.valid?(canvas_id) do
      {:error, :canvas_not_found}
    else
      case Repo.get(Canvas, canvas_id) do
        nil -> {:error, :canvas_not_found}
        %Canvas{deleted_at: nil} -> :ok
        %Canvas{} -> {:error, :canvas_not_found}
      end
    end
  end

  # The attach-time authorization gate (task 019e2c4b stage 2).
  #
  # Runs AFTER `ensure_canvas_attachable/1` so a caller attaching a canvas that
  # simply does not exist hears "not found" rather than "forbidden" — the
  # denial must not become an existence oracle richer than the read door
  # already is.
  #
  # `Scope.system/0` is the explicit opt-out for platform-initiated attaches,
  # which have no principal to authorize; it reads as the `:system` viewer.
  # `CanvasAccess` resolves it; there is no bypass here that `CanvasAccess`
  # does not also know about.
  defp ensure_canvas_readable(canvas_id, scope) do
    opts =
      case scope do
        %Scope{} -> [audit: false, access_scope: scope]
        _ -> [audit: false]
      end

    case CanvasAccess.fetch_for_viewer(canvas_id, canvas_viewer(scope), opts) do
      {:ok, _canvas, _level} -> :ok
      {:error, :not_found} -> {:error, :canvas_not_found}
      {:error, :forbidden} -> {:error, :canvas_forbidden}
    end
  end

  # Surface a soft-deleted or absent canvas as `nil` so list_task_canvases/1
  # callers can detach the stale row rather than failing loud. Live canvases
  # collapse to a minimal envelope so we don't drag the whole document graph
  # into list responses.
  defp canvas_envelope(nil), do: nil
  defp canvas_envelope(%Canvas{deleted_at: %DateTime{}}), do: nil

  defp canvas_envelope(%Canvas{} = canvas) do
    %{
      id: canvas.id,
      title: canvas.title,
      kind: extract_kind(canvas.document),
      deleted_at: canvas.deleted_at
    }
  end

  # Symmetric with `canvas_envelope/1`: a missing (FK-impossible) or
  # soft-deleted task collapses to `nil` so the caller sees a stale
  # attachment rather than a phantom grant. See `list_canvas_tasks/1`.
  defp task_envelope(nil), do: nil
  defp task_envelope(%Task{deleted_at: %DateTime{}}), do: nil

  defp task_envelope(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      project_id: task.project_id
    }
  end

  # Mirror `Platform.Chat.CanvasDocument.root_kind/1` but keep the dependency
  # local + tolerant: any non-binary root type collapses to `nil`. The kind
  # field is informational (UI hint), not load-bearing for any consumer in
  # stages 3/4/5.
  defp extract_kind(%{"root" => %{"type" => t}}) when is_binary(t), do: t
  defp extract_kind(_), do: nil
end
