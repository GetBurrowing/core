defmodule Platform.Meetings.Triage do
  @moduledoc """
  Filing surface for the meeting → tasks pipeline (M5a).

  Sits between the triage-officer agent runtime and `Platform.Tasks`. The
  agent parses a meeting canvas into structured `action_items` and hands
  the list here; this module decides — per item — whether to open a task
  or note the canvas that we skipped a near-duplicate.

  ## Boundary vs stack member D

  Stack member D (meeting-triage-officer skill + `dispatch.triage_dispatch`
  template) owns the transcript → action_item extraction and the prompt
  that produces the input to `file_tasks_from_canvas/2`. This module owns
  the filing step: dedup gate, canvas note on skip, per-canvas cap,
  telemetry emission, and the batch-junk rollback.

  If D lands a slightly different action_item shape (e.g. a `:body` field
  in place of `:description`), the stack rollup rewires — do not block on
  D landing first.

  ## Reconcile, do not re-create (task 01a03fda)

  Since `Platform.Meetings.CandidateSweeper` shipped, tasks are also
  filed DURING the meeting, by `Platform.Meetings.Candidates.graduate/2`,
  from the same utterances this pass later reads out of the transcript.
  This module is therefore a **reconciliation pass over what the live
  path already did**, not a second competing filer.

  The reconciliation is by IDENTITY — an action item that names the
  `candidate_id` it came from — and never by resemblance. The fuzzy
  dedup gate below does not absorb the live path's tasks and cannot be
  made to: `graduate/2` titles its task with the VERBATIM utterance
  while an action item is a normalised imperative, and on merged code
  three live cards plus four re-parsed action items produced seven
  tasks with zero fuzzy skips.

  See the `Identity reconciliation` section further down for what this
  does NOT yet close — no producer emits `:candidate_id` today.

  ## Public surface

    * `file_tasks_from_canvas/2` — reconcile each action_item against
      the meeting's candidate store when it names a `candidate_id`,
      then file it unless its title fuzzy-matches an already-open task
      in the same project. Files an action_row on the canvas so a
      reviewer can roll the whole batch back with one click (stage 5).
    * `junk_batch/2` — soft-delete every task the meeting filed, by
      either path: this canvas's triage filings AND the live card
      path's (task 01a04d9f).
      Idempotent (second call is a no-op returning `{:ok, 0}`); writes
      an audit row (`event_type: "meetings.triage.batch_junked"`) and
      appends a note to the source canvas.

  Stages 2–5 of task 019f5e2b-8d29 extend the file path with the
  `needs_promotion` flag, the per-canvas cap, telemetry, and the
  batch-junk rollback.
  """

  import Ecto.Query

  alias Platform.Audit
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  require Logger

  # Triage notes are written by the triage run itself, not on behalf of a
  # caller — there is no identity in scope at any of these call sites. Stated
  # explicitly rather than left to `apply_patches/3`'s empty-map default,
  # which records `unknown`: a write nobody performed and a write whose author
  # we failed to record must not look the same in version history (019fed8d).
  @system_attribution %{"type" => "system"}

  @type action_item :: %{optional(atom() | binary()) => any()}

  @type filing_outcome ::
          {:filed, Task.t()}
          | {:skipped, existing_task_id :: binary()}
          | {:error, term()}

  @type filing_result :: %{
          filed: [Task.t()],
          skipped: [
            %{
              :existing_task_id => binary() | nil,
              :title => binary(),
              :reason => :similar_title | :already_filed_live | :closed_in_meeting,
              optional(:candidate_id) => binary(),
              optional(:closed_reason) => atom()
            }
          ],
          errors: [%{title: binary() | nil, reason: term()}],
          capped?: boolean(),
          cap_dropped: non_neg_integer()
        }

  @doc """
  File tasks from a parsed meeting canvas.

  ## Arguments

    * `canvas` — either a `%Platform.Chat.Canvas{}` struct or a canvas id
      (binary). The canvas is the source of truth for the parent-canvas
      note appended on skip.
    * `opts` — keyword list. Required keys:
      * `:project_id` — the project every filed task belongs to.
      * `:action_items` — a list of maps with at minimum a `:title`
        (or `"title"`) key. Extra fields (`:description`, `:priority`,
        `:assignee`, …) pass through into the created task.

    Optional keys:
      * `:meeting_id` — the meeting this canvas came out of. Supplying
        it turns on identity reconciliation against that meeting's
        `meeting_candidates` rows; omitting it leaves behaviour exactly
        as it was before task 01a03fda.
      * `:threshold` — float passed through to
        `Platform.Tasks.similar_open_titles/3` to override the default
        dedup threshold.
      * `:source` — string recorded in `task.metadata["source"]`.
        Defaults to `"meetings.triage"`.
      * `:extra_metadata` — map merged into every filed task's metadata.

  ## Behavior

  Iterates `opts[:action_items]` in order. For each item:

    * If the item names a `:candidate_id` and `:meeting_id` was given,
      reconcile against that meeting's candidate store FIRST: skip with
      `reason: :already_filed_live` when that candidate already
      graduated to a live (non-soft-deleted) task, and with
      `reason: :closed_in_meeting` when the meeting closed it as
      retracted / duplicate / vetoed / dismissed. An item with no
      `:candidate_id` skips this step entirely.
    * If a fuzzy match (`Tasks.similar_open_titles/3`) exists in the
      project's open-task set, emit a `canvas_event` on the source canvas
      of shape `%{type: "triage_task_skipped", existing_task_id: id,
      candidate_title: title}` and record the skip in the result.
    * Otherwise call `Tasks.create_task/1` with the item's fields plus
      `project_id`, `status: "backlog"`, and a merged `metadata` map
      carrying `"source"` (default `"meetings.triage"`) and
      `"source_canvas_id"`.

  Returns `{:ok, %{filed: [...], skipped: [...], errors: [...]}}`.
  Individual `create_task` errors do NOT abort the batch — they land in
  the `:errors` list so the agent can surface partial progress.
  """
  @spec file_tasks_from_canvas(binary() | map(), keyword()) ::
          {:ok, filing_result()} | {:error, term()}
  def file_tasks_from_canvas(canvas_or_id, opts) when is_list(opts) do
    with {:ok, canvas} <- resolve_canvas(canvas_or_id),
         {:ok, project_id} <- fetch_project_id(opts),
         {:ok, items} <- fetch_action_items(opts) do
      source = Keyword.get(opts, :source, "meetings.triage")
      extra_metadata = Keyword.get(opts, :extra_metadata, %{}) |> stringify_map()
      threshold_opts = Keyword.take(opts, [:threshold])

      # Snapshot the pre-existing triage-source count for this project so
      # we can decide, per newly-filed task, whether it fits under the
      # backlog cap and therefore lands with `needs_promotion: true`.
      # Recomputed once per batch — filing within a batch bumps a local
      # counter so a mass-fire of 15 items into an empty project still
      # promotes only the first N per the cap.
      backlog_cap = triage_backlog_cap(opts)
      existing_triage_count = existing_triage_count(project_id, source)

      # Per-canvas hard cap (stage 4). Counts non-deleted tasks whose
      # `metadata["source_canvas_id"]` matches THIS canvas — the number
      # of triage tasks ever filed from this source meeting canvas
      # across all invocations. Loop halts (not skip-and-continue) when
      # `per_canvas_count + filed_in_this_batch >= cap` so we don't
      # keep re-consulting the dedup gate on items we will never file.
      per_canvas_cap = per_canvas_cap(opts)
      per_canvas_count = existing_per_canvas_count(canvas.id)
      meeting_id = Keyword.get(opts, :meeting_id)

      # Fire the dispatch-entry telemetry once per batch. Consumers
      # (audit stream, dashboards) key off `canvas_id` as the natural
      # anchor for the source meeting. `agent_id` + `meeting_id` are
      # optional passthroughs so the M4 triage-officer skill can enrich
      # without this module inventing values it doesn't have.
      :telemetry.execute(
        [:platform, :meetings, :triage_dispatch],
        %{action_item_count: length(items)},
        %{
          canvas_id: canvas.id,
          project_id: project_id,
          agent_id: Keyword.get(opts, :agent_id),
          meeting_id: meeting_id,
          dispatched_at: DateTime.utc_now()
        }
      )

      ctx = %{
        canvas: canvas,
        project_id: project_id,
        source: source,
        extra_metadata: extra_metadata,
        threshold_opts: threshold_opts,
        backlog_cap: backlog_cap,
        per_canvas_cap: per_canvas_cap,
        meeting_id: meeting_id,
        transcript_id: Keyword.get(opts, :transcript_id),
        reconciliation: build_reconciliation(meeting_id)
      }

      state = %{
        filed: [],
        skipped: [],
        errors: [],
        triage_count: existing_triage_count,
        per_canvas_count: per_canvas_count,
        capped?: false,
        cap_dropped: 0
      }

      result =
        items
        |> Enum.with_index()
        |> Enum.reduce(state, fn {item, index}, acc ->
          cond do
            acc.capped? ->
              # Once capped, subsequent items are silently ignored —
              # `cap_dropped` was already set to the full remaining
              # count when we first hit the cap, so incrementing again
              # here would double-count.
              acc

            acc.per_canvas_count >= ctx.per_canvas_cap ->
              # Hit the cap on THIS item — mark capped, record how many
              # items would still have been attempted (including this
              # one), fire telemetry + append a note, then bail on the
              # rest of the batch.
              remaining = length(items) - index
              record_cap_hit(ctx, length(items), remaining)
              %{acc | capped?: true, cap_dropped: remaining}

            true ->
              file_one(item, ctx, acc)
          end
        end)

      # Stage 5: surface a "Junk this batch" action row on the source
      # canvas whenever we actually filed something in this call. Idempotent
      # only in the sense that we never emit more than one per successful
      # invocation — the canvas can accumulate multiple over time if the
      # triage-officer re-fires. Skipped on empty-batch invocations so
      # dry-run parses don't spam the canvas.
      if result.filed != [] do
        append_junk_batch_action_row(ctx.canvas)
      end

      {:ok,
       %{
         filed: Enum.reverse(result.filed),
         skipped: Enum.reverse(result.skipped),
         errors: Enum.reverse(result.errors),
         capped?: result.capped?,
         cap_dropped: result.cap_dropped
       }}
    end
  end

  # ── Junk-batch rollback (stage 5 + M5b stage 4) ─────────────────────────

  @doc """
  Cheap preview of what `junk_batch/2` would soft-delete for a canvas.

  Backs the M5b Stage 4 confirmation modal — the `chat_live.ex` opener
  calls this to know whether to show the count-bearing body or the
  empty-state (`Nothing to roll back`) branch. A pure count via
  `Repo.aggregate/3` over the SAME `junk_scope_query/1` the delete runs,
  so we don't materialize the row set for a UI decision that only needs
  `N`. Sharing the query is load-bearing rather than tidy: a preview
  that undercounts the delete is the exact failure — a bulk delete that
  takes more than the operator was shown — this is meant to prevent.

  Returns `%{canvas_id: id, surviving_task_count: n}` on success. On a
  bad id (canvas not found or invalid), returns
  `{:error, :canvas_not_found}` — mirrors `junk_batch/2`'s contract so
  callers can share the resolve-then-decide guard.
  """
  @spec preview_batch(binary() | map()) ::
          {:ok, %{canvas_id: binary(), surviving_task_count: non_neg_integer()}}
          | {:error, term()}
  def preview_batch(canvas_or_id) do
    with {:ok, canvas} <- resolve_canvas(canvas_or_id) do
      count = Repo.aggregate(junk_scope_query(canvas), :count)

      {:ok, %{canvas_id: canvas.id, surviving_task_count: count}}
    end
  end

  @doc """
  Soft-delete every non-deleted task this meeting filed, by either path.

  Loads all tasks whose `metadata["source_canvas_id"]` matches the given
  canvas OR whose `metadata["meeting_id"]` names a meeting whose chat
  space is this canvas's space, sets `deleted_at` in a single
  `Repo.update_all/2` transaction, writes an audit row of type
  `"meetings.triage.batch_junked"` carrying the `task_ids` + `actor_id`,
  and appends a note to the source canvas.

  Idempotent: a second invocation on the same canvas finds zero
  non-deleted rows and returns `{:ok, 0}` without writing a duplicate
  audit row or a duplicate canvas note.

  ## Options

    * `:actor_id` — the user_id performing the rollback. Recorded on
      the audit row so post-hoc review can attribute the action.
    * `:actor_type` — defaults to `"user"`; can be `"agent"` or
      `"system"` for programmatic callers.

  ## Return

    * `{:ok, count}` — number of tasks soft-deleted (0 on the
      idempotent second call, N on the first)
    * `{:error, :canvas_not_found}` — canvas id doesn't resolve
    * `{:error, term}` — Ecto/transaction failure

  ## Why two selectors and not one (task 01a04d9f)

  `file_tasks_from_canvas/2` stamps `source_canvas_id`;
  `Platform.Meetings.Candidates.graduate/2` — the live card path, given
  a production caller by `CandidateSweeper` in task 01a03fba — stamps
  `meeting_id` and no canvas at all. The two paths share no metadata
  key, so a single selector reaches exactly half a meeting's tasks.
  Keying on `meeting_id` ALONE would drop every triage-filed task.

  The meeting is resolved from the canvas via
  `chat_canvases.space_id == meetings.chat_space_id`, the join
  `Platform.Meetings.Archive` documents as the only meeting↔task link.

  ## What this takes that the canvas-only form did not

  A bulk delete that takes more than the operator expected is worse than
  one that takes less, so the widening is stated rather than implied:

    * the meeting's live-path tasks — the point of the change;
    * live-path tasks minted AFTER the triage batch ran. The canvas form
      could only ever reach what a `file_tasks_from_canvas/2` invocation
      had already stamped;
    * **every triage canvas in the meeting's space now sweeps the whole
      meeting's live-path tasks.** If a re-parse produced a second
      summary canvas, junking either one takes all of them (each still
      takes only its OWN triage filings). This is the widening most
      likely to surprise;
    * live-path tasks in a different project, if a triage run was
      pointed at a `:project_id` other than the meeting's. Neither form
      has ever filtered by project;
    * if two meetings are ever pointed at one chat space, both meetings'
      live-path tasks. `meetings.chat_space_id` carries only a plain
      index (`20260514120000_create_meetings.exs`), so nothing in the
      schema forbids it; `create_meeting/1` mints a dedicated space per
      meeting, and `create_guest_chat_space/2` mints separate ones
      rather than reusing, so this does not arise on the normal path.

  `preview_batch/1` shares this query precisely so the confirmation
  modal shows the widened number before the operator commits. A canvas
  in a plain channel resolves to no meeting and behaves exactly as
  before.
  """
  @spec junk_batch(binary() | map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def junk_batch(canvas_or_id, opts \\ [])

  def junk_batch(canvas_or_id, opts) do
    with {:ok, canvas} <- resolve_canvas(canvas_or_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_type = Keyword.get(opts, :actor_type, "user")

      task_ids = task_ids_for_canvas(canvas)

      case task_ids do
        [] ->
          # Idempotent branch — no non-deleted rows found. Do NOT write
          # an audit row or a canvas note; the FIRST junk already did.
          {:ok, 0}

        ids ->
          now = DateTime.utc_now()

          case Repo.update_all(
                 from(t in Task, where: t.id in ^ids),
                 set: [deleted_at: now, updated_at: now]
               ) do
            {count, _} when is_integer(count) ->
              record_junk_audit(canvas, ids, actor_id, actor_type)
              append_junk_note(canvas, count, now)
              broadcast_batch_deleted(canvas.id, ids, count, now)
              {:ok, count}

            other ->
              {:error, other}
          end
      end
    end
  end

  # M5b (task 019f6e2c) stage 5: kanban live-refresh hook. Emit ONE
  # `{:tasks_batch_deleted, ids, meta}` on the `Tasks` board topic per
  # `junk_batch/2` invocation so open TasksLive sockets can drop N cards
  # in a single `refresh_board/1` (rather than N sequential broadcasts,
  # one per soft-deleted row). Defensive: skip when the id list is empty
  # so the always-idempotent contract of `junk_batch/2` doesn't leak a
  # zero-count event to subscribers.
  defp broadcast_batch_deleted(_canvas_id, [], _count, _now), do: :ok

  defp broadcast_batch_deleted(canvas_id, ids, count, now) do
    Platform.Tasks.broadcast_board(
      {:tasks_batch_deleted, ids,
       %{
         canvas_id: canvas_id,
         count: count,
         soft_deleted_at: now
       }}
    )

    :ok
  end

  defp task_ids_for_canvas(canvas) do
    canvas
    |> junk_scope_query()
    |> select([t], t.id)
    |> Repo.all()
  end

  # Everything one meeting filed, by EITHER path (task 01a04d9f).
  #
  # The two filing paths share no metadata key:
  #
  #   * `file_tasks_from_canvas/2` stamps `metadata["source_canvas_id"]`
  #     (see `build_task_attrs/6`) and never a `meeting_id` — `:meeting_id`
  #     is an opt it forwards into telemetry and into reconciliation, not
  #     into the task;
  #   * `Platform.Meetings.Candidates.graduate/2` — the live card path,
  #     which got its first production caller in `CandidateSweeper` (task
  #     01a03fba) — has no canvas in scope and stamps
  #     `metadata["meeting_id"]` + `metadata["candidate_id"]` instead.
  #
  # So this is a UNION of two selectors, not a widening of one. Keying on
  # `meeting_id` alone would silently stop sweeping every triage-filed
  # task, which is the behaviour the batch-junk button has always had.
  #
  # `metadata["source"]` is deliberately NOT a selector here. Task
  # 01a03fda chose `"meetings.candidate"` over `"meetings.triage"` for the
  # live path precisely so a live-filed task cannot consume triage's
  # `needs_promotion` backlog budget; sweeping by provenance rather than
  # by source string leaves that distinction intact. For the same reason
  # `existing_per_canvas_count/1` — the FILING cap — is untouched: it
  # counts what triage may still file, which is a different question from
  # what a rollback should take back.
  defp junk_scope_query(canvas) do
    base = from(t in Task, where: is_nil(t.deleted_at))

    case meeting_ids_for_canvas(canvas) do
      [] ->
        where(
          base,
          [t],
          fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas.id)
        )

      meeting_ids ->
        where(
          base,
          [t],
          fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas.id) or
            fragment("(? ->> 'meeting_id')", t.metadata) in ^meeting_ids
        )
    end
  end

  # A canvas has no FK to a meeting. The link is the one
  # `Platform.Meetings.Archive` documents and already joins on —
  # `chat_canvases.space_id == meetings.chat_space_id` — because
  # `Platform.Meetings.create_meeting/1` mints a dedicated
  # `meeting-<id>` space per meeting.
  #
  # OVER-SWEEP, stated plainly: there is no unique index on
  # `meetings.chat_space_id` (see `create_meetings`, which only indexes
  # it), so if two meetings are ever pointed at one space this returns
  # both and the rollback takes the live-path tasks of both. A canvas in
  # a plain channel resolves to `[]` and the sweep stays exactly as it
  # was.
  defp meeting_ids_for_canvas(canvas) do
    case Map.get(canvas, :space_id) do
      space_id when is_binary(space_id) ->
        Repo.all(from(m in Meeting, where: m.chat_space_id == ^space_id, select: m.id))

      _ ->
        []
    end
  end

  defp record_junk_audit(canvas, task_ids, actor_id, actor_type) do
    _ =
      Audit.record(%{
        event_type: "meetings.triage.batch_junked",
        actor_id: actor_id,
        actor_type: actor_type,
        resource_type: "meetings",
        resource_id: canvas.id,
        action: "junk_batch",
        metadata: %{
          "canvas_id" => canvas.id,
          "task_ids" => task_ids,
          "count" => length(task_ids)
        }
      })

    :ok
  end

  # Mirrors `append_skip_note/3` / `append_cap_note/3` — advisory patch,
  # log-and-move-on if the canvas GenServer or describe/apply_patches
  # declines. The audit row is the authoritative record.
  #
  # M5b (task 019f6e2c) stage 5: the note now carries an ISO8601 UTC
  # timestamp so an auditor reading a canvas revision later can pin the
  # rollback to a wall-clock moment without hitting the audit table.
  # Format chosen (per Saru stage-1 design direction) is unambiguous
  # `"N tasks soft-deleted at 2026-07-18T04:12:33Z"` — relative-time is
  # a downstream polish concern, not a source-of-truth format.
  defp append_junk_note(canvas, count, %DateTime{} = at) do
    text_value =
      "#{count} #{if count == 1, do: "task", else: "tasks"} soft-deleted at #{DateTime.to_iso8601(at)}"

    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: revision, document: document}} ->
        parent_id = CanvasDocument.root_kind(document) && root_id(document)

        if is_binary(parent_id) do
          node = %{
            "id" => "triage-junk-#{Ecto.UUID.generate()}",
            "type" => "text",
            "props" => %{"value" => text_value, "size" => "sm"}
          }

          case CanvasServer.apply_patches(
                 canvas.id,
                 [{:append_child, parent_id, node}],
                 revision,
                 @system_attribution
               ) do
            {:ok, _new_revision} ->
              :ok

            other ->
              Logger.debug(
                "meetings.triage: append_junk_note patch declined for canvas=#{canvas.id} " <>
                  "reason=#{inspect(other)}"
              )

              :ok
          end
        else
          :ok
        end

      {:error, reason} ->
        Logger.debug(
          "meetings.triage: describe failed for junk-note on #{canvas.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # "Junk this batch" action_row appended alongside filed tasks. The
  # `value` embeds the canvas id so the click handler (canvas_hooks.ex)
  # can extract it deterministically without needing to inspect the
  # active canvas. Semantic `danger` variant renders as `btn-error`.
  defp append_junk_batch_action_row(canvas) do
    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: revision, document: document}} ->
        parent_id = CanvasDocument.root_kind(document) && root_id(document)

        if is_binary(parent_id) do
          node = %{
            "id" => "triage-junk-actions-#{Ecto.UUID.generate()}",
            "type" => "action_row",
            "props" => %{
              "label" => "Meeting triage",
              "actions" => [
                %{
                  "label" => "Junk this batch",
                  "value" => "junk_batch:#{canvas.id}",
                  "variant" => "danger"
                }
              ]
            }
          }

          case CanvasServer.apply_patches(
                 canvas.id,
                 [{:append_child, parent_id, node}],
                 revision,
                 @system_attribution
               ) do
            {:ok, _new_revision} ->
              :ok

            other ->
              Logger.debug(
                "meetings.triage: append_junk_action_row patch declined for canvas=#{canvas.id} " <>
                  "reason=#{inspect(other)}"
              )

              :ok
          end
        else
          :ok
        end

      {:error, reason} ->
        Logger.debug(
          "meetings.triage: describe failed for action_row on #{canvas.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp triage_backlog_cap(opts) do
    Keyword.get(
      opts,
      :backlog_cap,
      Application.get_env(:platform, :meetings_triage_backlog_cap, 10)
    )
  end

  # Count non-deleted tasks in this project whose `metadata["source"]`
  # equals the configured source string. This is the baseline the cap
  # gates against — filed-under-cap tasks pick up `needs_promotion:
  # true` so Rowan can review the backlog burst without letting it grow
  # unbounded.
  defp existing_triage_count(project_id, source) do
    Repo.aggregate(
      from(t in Task,
        where: t.project_id == ^project_id,
        where: is_nil(t.deleted_at),
        where: fragment("(? ->> 'source') = ?", t.metadata, ^source)
      ),
      :count
    )
  end

  # Per-source-meeting-canvas hard cap (stage 4). Reads either the
  # explicit `:per_canvas_cap` opt or the app-env override, defaulting
  # to 20. Config lives in `config/config.exs` under
  # `:meetings_triage_per_canvas_cap` so ops can dial without a release.
  defp per_canvas_cap(opts) do
    Keyword.get(
      opts,
      :per_canvas_cap,
      Application.get_env(:platform, :meetings_triage_per_canvas_cap, 20)
    )
  end

  # Count non-deleted tasks whose `metadata["source_canvas_id"]` equals
  # this canvas — every task ever filed from this source meeting canvas
  # across all invocations. `source_canvas_id` is the natural anchor
  # because the triage-officer skill may re-fire with a re-parsed set
  # of action items after a transcript edit.
  defp existing_per_canvas_count(canvas_id) do
    Repo.aggregate(
      from(t in Task,
        where: is_nil(t.deleted_at),
        where: fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas_id)
      ),
      :count
    )
  end

  # Emit the cap-hit telemetry event and append a note to the source
  # canvas so the reviewer can see why the batch stopped short.
  # Measurements carry the exact cap value (not the config default) so
  # a per-call override surfaces truthfully. `attempted` is the
  # incoming batch size — this lets a dashboard compute the
  # `dropped = attempted - filed_before_cap` even when the emitter
  # doesn't itself know how many landed under the cap.
  defp record_cap_hit(ctx, attempted, dropped) do
    :telemetry.execute(
      [:platform, :meetings, :triage_cap_hit],
      %{cap: ctx.per_canvas_cap, attempted: attempted, dropped: dropped},
      %{
        canvas_id: ctx.canvas.id,
        project_id: ctx.project_id,
        meeting_id: ctx.meeting_id
      }
    )

    append_cap_note(ctx.canvas, ctx.per_canvas_cap, dropped)
  end

  # ── Identity reconciliation (task 01a03fda) ─────────────────────────────
  #
  # The live card board files tasks DURING the meeting, from the same
  # utterances this pass will later read out of the transcript. Both
  # paths would then file the same work — measured, on merged code, as
  # three live tasks plus four re-filed action items where the fuzzy
  # gate absorbed none of them, because `Candidates.graduate/2` titles
  # its task with the VERBATIM utterance while an action item is a
  # normalised imperative, and those two strings do not score above the
  # dedup threshold.
  #
  # So the join is by IDENTITY, never by resemblance. An action item
  # that names the `candidate_id` it was derived from is reconciled
  # against the candidate store; one that does not is left to the
  # pre-existing path completely unchanged. There is deliberately no
  # fallback that tries to GUESS the candidate from the title: a
  # reconciler that guesses is the fuzzy gate again, one layer up, and
  # it would be wrong in both directions exactly as that gate is.
  #
  # ## What this does NOT yet close
  #
  # Nothing in `lib/` produces an action item carrying `:candidate_id`.
  # The scribe-completion canvas the triage-officer parses records
  # `owner`, `project_hint`, `priority`, `due_hint` and
  # `source_transcript_id` per checklist item — no candidate id and no
  # transcript CHUNK id, and `meeting_candidates` has no `dedupe_key`
  # column to join on either (the classifier's `dedupe_key` is a
  # SHA-256 of the raw chunk text, held only in the meeting-lifetime
  # intent queue). Until the producer emits the id, this pass reconciles
  # nothing and the collision above stands. That is a gap in the
  # producer, not a reason to match on text here.

  # Built once per batch, and ONLY when the caller named a meeting —
  # `file_tasks_from_canvas/2` is also called for canvases with no
  # meeting behind them at all, and those must keep their old
  # behaviour exactly.
  defp build_reconciliation(meeting_id) when is_binary(meeting_id) do
    # `:meeting_id` has always been an OPTIONAL passthrough on this
    # surface, enriched by the triage-officer runtime and forwarded
    # straight into telemetry, so it has never had to be a real id —
    # `triage_test.exs` passes the literal `"mtg-stage4"`. Feeding that
    # to a `:binary_id` query raises `Ecto.Query.CastError`, which is
    # the exact defect `Platform.RepoLookupBoundaryTest` exists over. An
    # unusable id reconciles NOTHING rather than raising: the pass then
    # behaves as it did before this feature, which is the safe direction
    # — it may re-file, it cannot crash the batch.
    if Platform.UUID.valid?(meeting_id) do
      reconciliation_for(meeting_id)
    else
      nil
    end
  end

  defp build_reconciliation(_), do: nil

  defp reconciliation_for(meeting_id) do
    rows =
      from(c in MeetingCandidate,
        where: c.meeting_id == ^meeting_id,
        select: {c.id, c.task_id, c.state, c.closed_reason}
      )
      |> Repo.all()

    live_ids = live_task_ids(for {_id, task_id, _s, _r} <- rows, is_binary(task_id), do: task_id)

    filed_live =
      for {id, task_id, _state, _reason} <- rows,
          task_id in live_ids,
          into: %{},
          do: {id, task_id}

    # `:done` is NOT in this set. `:done` is what `graduate/2` writes on
    # a card that FILED — it belongs to `filed_live` above, and reading
    # it as a rejection would suppress the very task the live path
    # created without telling anyone which one.
    closed_against =
      for {id, _task_id, :closed, reason} <- rows,
          reason in [:retracted, :duplicate, :vetoed, :dismissed],
          into: %{},
          do: {id, reason}

    %{filed_live: filed_live, closed_against: closed_against}
  end

  # A live-filed task that has since been soft-deleted — by
  # `junk_batch/2`, or by a human clearing a bad meeting — must NOT
  # suppress the triage filing. The rollback is the bulk undo for a bad
  # meeting, and a reconciler that kept honouring rolled-back rows would
  # make it impossible to re-file anything that meeting produced.
  #
  # One statement for the whole meeting rather than one per graduated
  # candidate: this runs once per batch on a path that already reads
  # every candidate row, and a per-candidate `exists?` would put an N+1
  # in front of every triage pass.
  defp live_task_ids([]), do: MapSet.new()

  defp live_task_ids(task_ids) do
    from(t in Task,
      where: t.id in ^task_ids,
      where: is_nil(t.deleted_at),
      select: t.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp reconcile(_item, %{reconciliation: nil}), do: nil

  defp reconcile(item, %{reconciliation: reconciliation}) do
    case fetch_candidate_id(item) do
      nil ->
        nil

      candidate_id ->
        cond do
          task_id = Map.get(reconciliation.filed_live, candidate_id) ->
            {:already_filed_live, candidate_id, task_id}

          reason = Map.get(reconciliation.closed_against, candidate_id) ->
            {:closed_in_meeting, candidate_id, reason}

          true ->
            nil
        end
    end
  end

  defp fetch_candidate_id(item) when is_map(item) do
    case Map.get(item, :candidate_id) || Map.get(item, "candidate_id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp fetch_candidate_id(_), do: nil

  defp record_reconciled({:already_filed_live, candidate_id, task_id}, title, ctx, acc) do
    emit_reconciled_event(ctx, title, :already_filed_live, candidate_id, task_id)

    %{
      acc
      | skipped: [
          %{
            existing_task_id: task_id,
            title: title,
            reason: :already_filed_live,
            candidate_id: candidate_id
          }
          | acc.skipped
        ]
    }
  end

  defp record_reconciled({:closed_in_meeting, candidate_id, closed_reason}, title, ctx, acc) do
    emit_reconciled_event(ctx, title, :closed_in_meeting, candidate_id, nil)

    # `existing_task_id` is nil and that is the truth: the meeting
    # decided this one was not work, so there is no task to point at.
    %{
      acc
      | skipped: [
          %{
            existing_task_id: nil,
            title: title,
            reason: :closed_in_meeting,
            candidate_id: candidate_id,
            closed_reason: closed_reason
          }
          | acc.skipped
        ]
    }
  end

  defp emit_reconciled_event(ctx, title, reason, candidate_id, task_id) do
    :telemetry.execute(
      [:platform, :meetings, :triage_reconciled],
      %{count: 1},
      %{
        canvas_id: ctx.canvas.id,
        project_id: ctx.project_id,
        meeting_id: ctx.meeting_id,
        candidate_id: candidate_id,
        existing_task_id: task_id,
        reason: reason,
        title: title
      }
    )
  end

  # ── Per-item filing ─────────────────────────────────────────────────────

  defp file_one(item, ctx, acc) do
    title = fetch_title(item)

    cond do
      not is_binary(title) or title == "" ->
        %{acc | errors: [%{title: title, reason: :missing_title} | acc.errors]}

      verdict = reconcile(item, ctx) ->
        record_reconciled(verdict, title, ctx, acc)

      match = first_similar(ctx.project_id, title, ctx.threshold_opts) ->
        emit_skip_event(ctx.canvas, title, match)
        append_skip_note(ctx.canvas, title, match)

        %{
          acc
          | skipped: [
              %{existing_task_id: match.id, title: title, reason: :similar_title} | acc.skipped
            ]
        }

      true ->
        needs_promotion? = acc.triage_count < ctx.backlog_cap

        attrs =
          build_task_attrs(item, ctx.canvas, ctx.project_id, ctx.source, ctx.extra_metadata,
            needs_promotion: needs_promotion?
          )

        case Tasks.create_task(attrs) do
          {:ok, task} ->
            emit_task_created_event(task, ctx)

            %{
              acc
              | filed: [task | acc.filed],
                triage_count: acc.triage_count + 1,
                per_canvas_count: acc.per_canvas_count + 1
            }

          {:error, reason} ->
            Logger.warning(
              "meetings.triage: create_task failed for #{inspect(title)}: #{inspect(reason)}"
            )

            %{acc | errors: [%{title: title, reason: reason} | acc.errors]}
        end
    end
  end

  # Per-task creation telemetry. Measurements = `{count: 1}` so the
  # audit stream can sum-aggregate across a batch. Metadata carries
  # the natural join keys (task_id, canvas_id, transcript_id) so
  # downstream tools can pivot without a Repo hit.
  defp emit_task_created_event(%Task{id: task_id} = task, ctx) do
    :telemetry.execute(
      [:platform, :meetings, :tasks_created_from_meeting],
      %{count: 1},
      %{
        task_id: task_id,
        canvas_id: ctx.canvas.id,
        project_id: ctx.project_id,
        meeting_id: ctx.meeting_id,
        transcript_id: ctx.transcript_id,
        needs_promotion: task.needs_promotion,
        source: ctx.source
      }
    )
  end

  defp first_similar(project_id, title, threshold_opts) do
    case Tasks.similar_open_titles(project_id, title, threshold_opts) do
      [%Task{} = match | _] -> match
      _ -> nil
    end
  end

  # ── Canvas-side effects ────────────────────────────────────────────────

  defp emit_skip_event(canvas, candidate_title, %Task{id: existing_id}) do
    CanvasServer.emit_event(canvas.id, %{
      type: "triage_task_skipped",
      existing_task_id: existing_id,
      candidate_title: candidate_title
    })
  end

  # Append a text node to the source canvas noting the skip. Uses
  # `append_child` on `"root"` (the top-level stack node in the canonical
  # document shape). Failure to patch is advisory — logged but not fatal —
  # so a transient conflict does not lose the underlying task-skip signal.
  defp append_skip_note(canvas, candidate_title, %Task{id: existing_id}) do
    text_value = "skipped (existing task #{existing_id}): #{candidate_title}"

    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: revision, document: document}} ->
        parent_id = CanvasDocument.root_kind(document) && root_id(document)

        if is_binary(parent_id) do
          node = %{
            "id" => "triage-skip-#{Ecto.UUID.generate()}",
            "type" => "text",
            "props" => %{"value" => text_value, "size" => "sm"}
          }

          case CanvasServer.apply_patches(
                 canvas.id,
                 [{:append_child, parent_id, node}],
                 revision,
                 @system_attribution
               ) do
            {:ok, _new_revision} ->
              :ok

            other ->
              Logger.debug(
                "meetings.triage: append_skip_note patch declined for canvas=#{canvas.id} " <>
                  "reason=#{inspect(other)}"
              )

              :ok
          end
        else
          :ok
        end

      {:error, reason} ->
        Logger.debug("meetings.triage: describe failed for #{canvas.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp root_id(%{"root" => %{"id" => id}}) when is_binary(id), do: id
  defp root_id(_), do: nil

  # Cap-note append — same rebase-or-tolerate contract as
  # `append_skip_note/3`, different text. Failure to patch is advisory:
  # the telemetry event carries the authoritative record.
  defp append_cap_note(canvas, cap, dropped) do
    text_value = "triage capped at #{cap} tasks — #{dropped} action items skipped"

    case CanvasServer.describe(canvas.id) do
      {:ok, %{revision: revision, document: document}} ->
        parent_id = CanvasDocument.root_kind(document) && root_id(document)

        if is_binary(parent_id) do
          node = %{
            "id" => "triage-cap-#{Ecto.UUID.generate()}",
            "type" => "text",
            "props" => %{"value" => text_value, "size" => "sm"}
          }

          case CanvasServer.apply_patches(
                 canvas.id,
                 [{:append_child, parent_id, node}],
                 revision,
                 @system_attribution
               ) do
            {:ok, _new_revision} ->
              :ok

            other ->
              Logger.debug(
                "meetings.triage: append_cap_note patch declined for canvas=#{canvas.id} " <>
                  "reason=#{inspect(other)}"
              )

              :ok
          end
        else
          :ok
        end

      {:error, reason} ->
        Logger.debug(
          "meetings.triage: describe failed for cap-note on #{canvas.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ── Attribute plumbing ─────────────────────────────────────────────────

  defp build_task_attrs(item, canvas, project_id, source, extra_metadata, opts) do
    base_metadata =
      extra_metadata
      |> Map.put("source", source)
      |> Map.put("source_canvas_id", canvas.id)

    passthrough =
      item
      |> stringify_map()
      |> Map.take(~w(description priority assignee_type assignee_id epic_id))

    passthrough
    |> Map.put("project_id", project_id)
    |> Map.put("title", fetch_title(item))
    |> Map.put("status", "backlog")
    |> Map.put("needs_promotion", Keyword.get(opts, :needs_promotion, false))
    |> Map.put("metadata", Map.merge(item_metadata(item), base_metadata))
  end

  defp item_metadata(item) do
    case fetch_field(item, [:metadata, "metadata"]) do
      %{} = m -> stringify_map(m)
      _ -> %{}
    end
  end

  defp fetch_title(item), do: fetch_field(item, [:title, "title"])

  defp fetch_field(item, keys) when is_map(item) do
    Enum.find_value(keys, fn key -> Map.get(item, key) end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_map(_), do: %{}

  # ── Argument resolution ────────────────────────────────────────────────

  defp resolve_canvas(%_{} = canvas) do
    if Map.has_key?(canvas, :id) and is_binary(canvas.id) do
      {:ok, canvas}
    else
      {:error, :invalid_canvas}
    end
  end

  defp resolve_canvas(id) when is_binary(id) do
    case Chat.get_canvas(id) do
      nil -> {:error, :canvas_not_found}
      canvas -> {:ok, canvas}
    end
  end

  defp resolve_canvas(_), do: {:error, :invalid_canvas}

  defp fetch_project_id(opts) do
    case Keyword.get(opts, :project_id) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_project_id}
    end
  end

  defp fetch_action_items(opts) do
    case Keyword.get(opts, :action_items) do
      items when is_list(items) -> {:ok, items}
      _ -> {:error, :missing_action_items}
    end
  end
end
