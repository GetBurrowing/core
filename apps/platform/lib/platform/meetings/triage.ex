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

  ## Public surface

    * `file_tasks_from_canvas/2` — file each action_item, skipping any
      whose title fuzzy-matches an already-open task in the same project.
      Files an action_row on the canvas so a reviewer can roll the whole
      batch back with one click (stage 5).
    * `junk_batch/2` — soft-delete every task filed from a given canvas.
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
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  require Logger

  @type action_item :: %{optional(atom() | binary()) => any()}

  @type filing_outcome ::
          {:filed, Task.t()}
          | {:skipped, existing_task_id :: binary()}
          | {:error, term()}

  @type filing_result :: %{
          filed: [Task.t()],
          skipped: [%{existing_task_id: binary(), title: binary()}],
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
      * `:threshold` — float passed through to
        `Platform.Tasks.similar_open_titles/3` to override the default
        dedup threshold.
      * `:source` — string recorded in `task.metadata["source"]`.
        Defaults to `"meetings.triage"`.
      * `:extra_metadata` — map merged into every filed task's metadata.

  ## Behavior

  Iterates `opts[:action_items]` in order. For each item:

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
        transcript_id: Keyword.get(opts, :transcript_id)
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
  `Repo.aggregate/3` — same filter as `task_ids_for_canvas/1` — so we
  don't materialize the row set for a UI decision that only needs `N`.

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
      count =
        Repo.aggregate(
          from(t in Task,
            where: is_nil(t.deleted_at),
            where: fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas.id)
          ),
          :count
        )

      {:ok, %{canvas_id: canvas.id, surviving_task_count: count}}
    end
  end

  @doc """
  Soft-delete every non-deleted task filed from `canvas_id`.

  Loads all tasks whose `metadata["source_canvas_id"]` matches the
  given canvas, sets `deleted_at` in a single `Repo.update_all/2`
  transaction, writes an audit row of type
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
  """
  @spec junk_batch(binary() | map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def junk_batch(canvas_or_id, opts \\ [])

  def junk_batch(canvas_or_id, opts) do
    with {:ok, canvas} <- resolve_canvas(canvas_or_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_type = Keyword.get(opts, :actor_type, "user")

      task_ids = task_ids_for_canvas(canvas.id)

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

  defp task_ids_for_canvas(canvas_id) do
    from(t in Task,
      where: is_nil(t.deleted_at),
      where: fragment("(? ->> 'source_canvas_id') = ?", t.metadata, ^canvas_id),
      select: t.id
    )
    |> Repo.all()
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

          case CanvasServer.apply_patches(canvas.id, [{:append_child, parent_id, node}], revision) do
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

          case CanvasServer.apply_patches(canvas.id, [{:append_child, parent_id, node}], revision) do
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

  # ── Per-item filing ─────────────────────────────────────────────────────

  defp file_one(item, ctx, acc) do
    title = fetch_title(item)

    cond do
      not is_binary(title) or title == "" ->
        %{acc | errors: [%{title: title, reason: :missing_title} | acc.errors]}

      match = first_similar(ctx.project_id, title, ctx.threshold_opts) ->
        emit_skip_event(ctx.canvas, title, match)
        append_skip_note(ctx.canvas, title, match)
        %{acc | skipped: [%{existing_task_id: match.id, title: title} | acc.skipped]}

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

          case CanvasServer.apply_patches(canvas.id, [{:append_child, parent_id, node}], revision) do
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

          case CanvasServer.apply_patches(canvas.id, [{:append_child, parent_id, node}], revision) do
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
