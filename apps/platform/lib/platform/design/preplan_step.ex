defmodule Platform.Design.PreplanStep do
  @moduledoc """
  The pre-plan design step (ADR-0046 stack member 7, task `019f9b29-5ecd`
  stage 4).

  Stage 1 built the classifier (`Platform.Design.UiSurface.ui_task?/1`), stage 2
  the brand escalation (`Platform.Design.Brand.escalate_once/2`), stage 3 the
  responsibility and its handler
  (`Platform.Responsibilities.Handlers.DesignTaskDirection`). This module is the
  state machine that decides whether the design step runs at all, fires it, and
  records what happened. Stage 5 holds the planner while it is open.

  ## The one mapping

  Fire results are mapped onto ADR-0046's `complete | not_applicable | failed`
  vocabulary in exactly one place — `Platform.Responsibilities.outcome/1`
  (member 1) — and are written by exactly one writer,
  `Platform.Tasks.record_planning_step/3` (member 4). This module holds NO copy
  of that mapping and never calls `outcome/1`. It hands a fire result to the
  writer and then READS BACK the persisted
  `planning_step_outcomes["design"]["outcome"]` to decide what to do next.

  Everything below branches on the persisted OUTCOME, never on the shape of a
  fire result. The three fire-result tuples that appear in this file are
  `@no_designer_fire`, `@design_delivered_fire` and the `{:error, _}` timeout —
  all of them CONSTRUCTED and handed to the writer, none of them matched. See
  `preplan_step_test.exs`, "no second mapping", for the guards that keep that
  true.

  ## Why a successful fire records nothing

  `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
  defines `complete` as "dispatch returned AND output was
  captured". At fire time only the first half has happened: the deployed
  designer is a Suite agent, reached through `dispatch_native/4`, so its output
  arrives minutes later as an attached canvas. Recording `complete` on a
  successful dispatch would make every subsequent timeout indistinguishable
  from a success — the precise conflation this ADR exists to close.

  So the step stays OPEN. `record_terminal_only/2` still hands EVERY fire result
  to the writer (that is how the mapping stays single-sourced), but it does so
  inside a `Repo.transaction/1` and calls `Repo.rollback/1` when the value it
  reads back is `:complete`. Member 4 documents that transaction participation
  as a contract: "if the surrounding work rolls back, the step genuinely did not
  happen". Nothing is ever committed for a successful dispatch. The step is
  closed later by `settle/2` (the canvas landed) or `expire/2` (it did not).

  The rollback is also why `fire_designer/2` re-issues
  `Tasks.set_planning_step(task, :designing)` afterwards: `record_planning_step/3`
  broadcasts `{:task_updated, _}` from inside the transaction, and a broadcast is
  not rolled back. The re-issue is idempotent on the cursor and re-broadcasts the
  true, post-rollback row, so member 8's card cannot be left rendering a
  `complete` that was never written.

  ## Two skips, one outcome, two reasons

  `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`
  defines `not_applicable` as "no agent in the role, OR no UI
  surface (design)" — the ADR already merged these, so passing
  `@no_designer_fire` for the no-UI case encodes its decision rather than
  inventing a second mapping. But collapsing them in the RECORD would recreate
  exactly the invisibility this task is written against, so `reason`
  distinguishes them: `"no_ui_surface"` (the classifier said no; nothing was
  fired) versus `"no_designer"` (it fired and nobody holds the responsibility).

  `failed` is reserved for a step that fired and died — a dispatch error or a
  timeout. A step that never applied is never `failed`; see
  `Platform.Tasks.failed_planning_steps/1`, which only ever reports `"failed"`
  and is what gates the merge.

  ## The false-negative audit

  Stage 1's classifier is budgeted for zero false negatives, but a budget is not
  a proof. `audit_ui_prediction/2` runs at `plan_create` time — the first moment
  in the lifecycle when stage DESCRIPTIONS exist, which is the real subject of
  `Platform.Tasks.PlanEngine.ui_touching?/1` — and re-checks a `"no_ui_surface"`
  verdict against them. A contradiction emits
  `[:platform, :design, :ui_heuristic, :false_negative]` and annotates the entry
  `"no_ui_surface_contradicted"`.

  It deliberately does NOT flip the outcome to `failed`. The step genuinely did
  not apply at the time it ran, and flipping it would block a merge through
  member 4's `planning_gate_failed?/1` over a heuristic miss the designer was
  never asked about. The annotation is queryable and renderable; the gate stays
  clean.

  ## Everything here degrades

  `start/1` is called from a LEVEL-TRIGGERED router guard on every dispatch tick,
  so it is idempotent by construction (steps 1 and 2 of `start/1`) and every
  side effect is enveloped. The brand escalation's return value is logged and
  never branched on — that is the mechanical guarantee that an unanswered brand
  question cannot stall a backend-heavy stack. Design must degrade, never block
  planning.
  """

  require Logger

  alias Platform.Design.{Brand, UiSurface}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Tasks
  alias Platform.Tasks.{CanvasAttachment, PlanEngine, Task}

  @responsibility_key "design.task_direction"
  @step :design
  @step_key "design"

  @designing :designing
  @designing_value "designing"
  @planning :planning

  # Annotation reasons. Named rather than inlined so the guards and member 8's
  # renderer can assert against the shipped constants.
  @reason_no_ui_surface "no_ui_surface"
  @reason_no_designer "no_designer"
  @reason_canvas_attached "canvas_attached"
  @reason_contradicted "no_ui_surface_contradicted"
  @reason_timeout "design_timeout"

  # CONSTRUCTED fire results, handed to `Tasks.record_planning_step/3` so member
  # 1's mapping is the only thing that turns them into an outcome. Never matched
  # on — see the "no second mapping" guards.
  @no_designer_fire {:ok, :unfilled}
  @design_delivered_fire {:ok, :dispatched}

  @false_negative_event [:platform, :design, :ui_heuristic, :false_negative]

  @typedoc "Everything `start/1` can return."
  @type start_result ::
          {:ok, :already_settled | :already_open | :open | :not_applicable | :failed}
          | {:error, term()}

  @doc "Canonical responsibility key this step fires."
  @spec responsibility_key() :: String.t()
  def responsibility_key, do: @responsibility_key

  @doc "The telemetry event emitted when `audit_ui_prediction/2` catches a miss."
  @spec false_negative_event() :: [atom()]
  def false_negative_event, do: @false_negative_event

  @doc """
  The annotation reasons this module writes, keyed by the situation.

  Exposed so tests and member 8's renderer assert against the shipped strings
  rather than restated copies.
  """
  @spec reasons() :: %{atom() => String.t()}
  def reasons do
    %{
      no_ui_surface: @reason_no_ui_surface,
      no_designer: @reason_no_designer,
      canvas_attached: @reason_canvas_attached,
      contradicted: @reason_contradicted,
      timeout: @reason_timeout
    }
  end

  # ── start ─────────────────────────────────────────────────────────────────

  @doc """
  Run the design step for a task, if it has not run already.

  Safe to call on every router dispatch tick: a task whose design entry is
  already recorded returns `{:ok, :already_settled}` and a task whose cursor is
  already `"designing"` returns `{:ok, :already_open}`, both without a fire.

  Returns:

    * `{:ok, :already_settled}` / `{:ok, :already_open}` — nothing done.
    * `{:ok, :not_applicable}` — recorded, with `reason` `"no_ui_surface"`
      (not a UI task; nothing fired) or `"no_designer"` (fired, nobody holds
      the responsibility). Cursor is `"planning"`.
    * `{:ok, :failed}` — fired and the dispatch failed. Cursor is `"planning"`.
    * `{:ok, :open}` — fired and dispatched. NOTHING is recorded and the cursor
      stays `"designing"` until `settle/2` or `expire/2`.
    * `{:error, term}` — the step could not be recorded. The cursor is returned
      to `"planning"` regardless, so a persistence fault cannot strand a task.
  """
  @spec start(Task.t() | binary()) :: start_result()
  def start(task_or_id) do
    case resolve_task(task_or_id) do
      nil ->
        {:error, :task_not_found}

      %Task{} = task ->
        cond do
          settled?(task) -> {:ok, :already_settled}
          open?(task) -> {:ok, :already_open}
          true -> classify(task)
        end
    end
  end

  defp classify(%Task{} = task) do
    case UiSurface.ui_task?(task) do
      false -> skip_no_ui_surface(task)
      {true, evidence} -> fire_designer(task, evidence)
    end
  end

  # No UI surface: no fire at all. `@no_designer_fire` is handed to the writer
  # because both skips are merged onto `not_applicable` by
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`;
  # `reason` is what keeps them apart downstream.
  defp skip_no_ui_surface(%Task{} = task) do
    finish(task, @no_designer_fire, %{"reason" => @reason_no_ui_surface})
  end

  defp fire_designer(%Task{} = task, evidence) do
    # Logged, never branched on. A brand question that nobody answers must not
    # be able to hold the design step, let alone the planner behind it.
    log_brand_escalation(task, safe_escalate_brand(task))

    _ = move_cursor(task, @designing)

    # `classify/1` destructured the verdict to get here, so the tuple is
    # reconstructed at the point of use. `evidence_annotations/1` matches the
    # whole `UiSurface.verdict()` deliberately — see the note on its clause.
    annotations =
      Map.merge(evidence_annotations({true, evidence}), %{"reason" => @reason_no_designer})

    case record_terminal_only(task, fire(task)) do
      {:ok, {:complete, _updated}} ->
        # Unreachable: `record_terminal_only/2` rolls `:complete` back rather
        # than returning it. Kept so a future change to that helper surfaces
        # here as a clause, not as a silently committed `complete`.
        stay_open(task)

      {:ok, {outcome, updated}} ->
        _ = annotate(updated, @step, annotations_for(outcome, annotations))
        _ = move_cursor(updated, @planning)
        {:ok, outcome}

      {:error, :step_open} ->
        stay_open(task)

      {:error, reason} ->
        # The write failed. Fall open: return the cursor so nothing is stranded,
        # and leave the key ABSENT rather than guessing at an outcome.
        Logger.error(
          "[design.preplan] design step unrecorded task=#{task.id} reason=#{inspect(reason)}"
        )

        _ = move_cursor(task, @planning)
        {:error, reason}
    end
  end

  # The dispatch was accepted but the output has not arrived. Re-issue the
  # cursor write: it is idempotent, and it re-broadcasts the true post-rollback
  # row over the `{:task_updated, _}` that the rolled-back write emitted.
  defp stay_open(%Task{} = task) do
    _ = move_cursor(task, @designing)
    {:ok, :open}
  end

  # `"no_designer"` only makes sense for a fire that found nobody. A fire that
  # found somebody and failed carries its reason in member 4's `detail`.
  defp annotations_for(:not_applicable, annotations), do: annotations
  defp annotations_for(_other, annotations), do: Map.delete(annotations, "reason")

  # ── settle ────────────────────────────────────────────────────────────────

  @doc """
  Close an open design step because the designer's canvas landed.

  Hooked into `Platform.Tasks.CanvasAttachments.attach_canvas/3`'s success
  path. The canvas IS the deliverable, so the deliverable landing is the honest
  completion signal — and unlike a dedicated "I'm done" tool call it also works
  when a human attaches the canvas by hand.

  A no-op unless the cursor is `"designing"` OR the recorded design outcome is
  `:failed`. The second condition is the late-arrival upgrade: work that lands
  after the deadline should clear the merge-time warning, not leave a permanent
  scar.

  Never raises and never returns anything the caller should branch on.
  """
  @spec settle(binary() | Task.t(), CanvasAttachment.t() | binary() | nil) ::
          {:ok, :complete | :noop} | {:error, term()}
  def settle(task_or_id, attachment \\ nil) do
    case resolve_task(task_or_id) do
      nil ->
        {:ok, :noop}

      %Task{} = task ->
        if open?(task) or persisted_outcome(task) == :failed do
          do_settle(task, attachment)
        else
          {:ok, :noop}
        end
    end
  rescue
    e ->
      Logger.warning("[design.preplan] settle raised: #{Exception.message(e)}")
      {:error, :settle_raised}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] settle exited: #{inspect(reason)}")
      {:error, :settle_exited}
  end

  defp do_settle(%Task{} = task, attachment) do
    annotations =
      task
      |> UiSurface.ui_task?()
      |> evidence_annotations()
      |> Map.put("reason", @reason_canvas_attached)
      |> put_canvas_id(canvas_id_of(attachment))

    finish(task, @design_delivered_fire, annotations)
  end

  # ── expire ────────────────────────────────────────────────────────────────

  @doc """
  Close an open design step because it ran out of time.

  Called by the router's `:design_deadline` (stage 5). Records `failed` with the
  timeout in member 4's `detail`, returns the cursor to `"planning"` so the
  planner proceeds, and surfaces at merge time through
  `Platform.Tasks.planning_gate_failed?/1`. ADR-0046 decision 7: failure falls
  open, visibly.

  A no-op unless the cursor is `"designing"` — a step that already settled must
  not be re-opened as a failure by a late timer.
  """
  @spec expire(binary() | Task.t(), non_neg_integer() | nil) ::
          {:ok, :failed | :noop} | {:error, term()}
  def expire(task_or_id, timeout_ms \\ nil) do
    case resolve_task(task_or_id) do
      nil ->
        {:ok, :noop}

      %Task{} = task ->
        if open?(task) do
          # A SEPARATE defect from the `fire_designer/2` call site above: this
          # path never called `evidence_annotations/1` at all, so no shape
          # mismatch could reach it. Built the way `do_settle/2` builds it, so
          # the failure a human most wants explained — the designer fired and
          # never delivered — carries the same audit trail as the success.
          # Byte-identical to the old literal for a non-UI task: `false` yields
          # `%{}`, and `expire/2` is a no-op unless the cursor is `"designing"`,
          # which is only reachable after a fire on a UI task.
          annotations =
            task
            |> UiSurface.ui_task?()
            |> evidence_annotations()
            |> Map.put("reason", @reason_timeout)

          finish(task, {:error, {:design_timeout, timeout_ms}}, annotations)
        else
          {:ok, :noop}
        end
    end
  rescue
    e ->
      Logger.warning("[design.preplan] expire raised: #{Exception.message(e)}")
      {:error, :expire_raised}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] expire exited: #{inspect(reason)}")
      {:error, :expire_exited}
  end

  # ── the false-negative audit ──────────────────────────────────────────────

  @doc """
  Re-check a `"no_ui_surface"` verdict against the stage descriptions a planner
  actually produced.

  A no-op unless the design entry's `reason` is exactly `"no_ui_surface"` — a
  step that ran, or that skipped for `"no_designer"`, has nothing to contradict.

  `stages` may be `%Platform.Tasks.Stage{}` structs or plain maps with
  `name`/`description` (string or atom keys). Never raises; never changes the
  recorded outcome.
  """
  @spec audit_ui_prediction(binary() | Task.t(), list()) ::
          {:ok, :contradicted | :consistent | :noop} | {:error, term()}
  def audit_ui_prediction(task_or_id, stages) when is_list(stages) do
    with %Task{} = task <- resolve_task(task_or_id),
         %{"reason" => @reason_no_ui_surface} <- design_entry(task) do
      case Enum.filter(stages, &ui_touching_stage?/1) do
        [] ->
          {:ok, :consistent}

        offenders ->
          names = Enum.map(offenders, &stage_name/1)

          :telemetry.execute(
            @false_negative_event,
            %{system_time: System.system_time()},
            %{task_id: task.id, stages: names}
          )

          Logger.warning(
            "[design.preplan] UI heuristic false negative task=#{task.id} " <>
              "stages=#{inspect(names)} — the design step was skipped as no_ui_surface " <>
              "but the plan describes UI work"
          )

          _ =
            annotate(task, @step, %{
              "reason" => @reason_contradicted,
              "contradicted_by" => names
            })

          {:ok, :contradicted}
      end
    else
      _ -> {:ok, :noop}
    end
  rescue
    e ->
      Logger.warning("[design.preplan] audit_ui_prediction raised: #{Exception.message(e)}")
      {:error, :audit_raised}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] audit_ui_prediction exited: #{inspect(reason)}")
      {:error, :audit_exited}
  end

  def audit_ui_prediction(_task_or_id, _stages), do: {:ok, :noop}

  defp ui_touching_stage?(stage),
    do: stage |> stage_field(:description) |> PlanEngine.ui_touching?()

  defp stage_name(stage), do: stage_field(stage, :name)

  defp stage_field(stage, key) when is_map(stage) do
    case Map.get(stage, key, Map.get(stage, to_string(key))) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp stage_field(_stage, _key), do: nil

  # ── annotate ──────────────────────────────────────────────────────────────

  @doc """
  Merge extra keys into a recorded planning-step entry.

  `"outcome"` is DROPPED, always. Member 4's
  `Platform.Tasks.Task.planning_step_changeset/2` pins the outer keys and the
  `"outcome"` value and permits everything else; this function is what writes
  the everything-else, and it must never be a second way to set an outcome.

  A no-op when no entry exists for `step` — there is nothing to annotate, and
  fabricating an entry here would create one without an outcome, which the
  changeset rejects anyway.
  """
  @spec annotate(binary() | Task.t(), :design | :architecture, map()) ::
          {:ok, Task.t()} | {:error, term()}
  def annotate(task_or_id, step, attrs)
      when step in [:design, :architecture] and is_map(attrs) do
    key = to_string(step)
    safe = attrs |> Map.drop([:outcome, "outcome"]) |> stringify_keys()

    case resolve_task(task_or_id) do
      nil ->
        {:error, :task_not_found}

      %Task{} = task ->
        outcomes = task.planning_step_outcomes || %{}

        case Map.get(outcomes, key) do
          %{} = entry ->
            merged = Map.put(outcomes, key, Map.merge(entry, safe))

            task
            |> Task.planning_step_changeset(%{planning_step_outcomes: merged})
            |> Repo.update()

          _absent ->
            {:error, :no_such_step}
        end
    end
  end

  # ── shared internals ──────────────────────────────────────────────────────

  # Record a TERMINAL fire result, annotate it, and return the cursor. Used by
  # the three closing paths — the no-UI skip, `settle/2` and `expire/2` — where
  # whatever member 1's mapping yields is the truth and commits unconditionally.
  defp finish(%Task{} = task, fire_result, annotations) do
    case record_and_read_back(task, fire_result) do
      {:ok, {outcome, updated}} ->
        _ = annotate(updated, @step, annotations)
        _ = move_cursor(updated, @planning)
        {:ok, outcome}

      {:error, reason} ->
        Logger.error(
          "[design.preplan] design step unrecorded task=#{task.id} reason=#{inspect(reason)}"
        )

        _ = move_cursor(task, @planning)
        {:error, reason}
    end
  end

  # Hand the fire result to member 4's writer — that is how member 1's mapping
  # stays the only mapping — and read back what it persisted.
  defp record_and_read_back(%Task{} = task, fire_result) do
    case Tasks.record_planning_step(task, @step, fire_result) do
      {:ok, updated} ->
        case persisted_outcome(updated) do
          nil -> {:error, :unreadable_outcome}
          outcome -> {:ok, {outcome, updated}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[design.preplan] record raised: #{Exception.message(e)}")
      {:error, :record_raised}
  catch
    :exit, reason ->
      Logger.error("[design.preplan] record exited: #{inspect(reason)}")
      {:error, :record_exited}
  end

  # The fire path. Same single writer, same read-back — but wrapped in a
  # transaction that ROLLS BACK when the value read back is `:complete`.
  #
  # This is the reconciliation between "hand every fire result to the one
  # writer" and
  # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`.
  # `:complete` means the dispatch was accepted; the
  # output has not been captured, so the step is not complete. Member 4
  # documents the transaction participation as a contract — "if the surrounding
  # work rolls back, the step genuinely did not happen" — so nothing is ever
  # committed and the key stays ABSENT, distinguishable from all three
  # outcomes, rather than holding a `complete` that a later timeout could not
  # be told apart from.
  #
  # Note this branches on the persisted OUTCOME, never on the shape of the fire
  # result. `{:ok, :dispatched}` is never matched here; it is only ever handed
  # over.
  defp record_terminal_only(%Task{} = task, fire_result) do
    # `Repo.rollback/1` inside a NESTED transaction aborts the whole stack, so
    # a future caller wrapping `start/1` in its own transaction would have its
    # work silently discarded. `mode: :savepoint` confines the rollback to this
    # block. Only passed when already nested: Postgres has no savepoint outside
    # a transaction, so the top-level call (the router's dispatch tick, which
    # owns no transaction) must open a real one.
    opts = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

    Repo.transaction(
      fn ->
        case Tasks.record_planning_step(task, @step, fire_result) do
          {:ok, updated} ->
            case persisted_outcome(updated) do
              :complete -> Repo.rollback(:step_open)
              nil -> Repo.rollback(:unreadable_outcome)
              outcome -> {outcome, updated}
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      opts
    )
  rescue
    e ->
      Logger.error("[design.preplan] record raised: #{Exception.message(e)}")
      {:error, :record_raised}
  catch
    :exit, reason ->
      Logger.error("[design.preplan] record exited: #{inspect(reason)}")
      {:error, :record_exited}
  end

  # Fires the responsibility. Wrapped for the same reason
  # `Platform.Tasks.fire_architecture_review_plan/1` is: the Router's own
  # envelope covers the dispatch, this one covers everything around it, and a
  # designer that blows up must read as `failed` rather than take the router
  # tick down with it.
  defp fire(%Task{} = task) do
    Responsibilities.fire(@responsibility_key, trigger_meta(task))
  rescue
    e ->
      Logger.warning("[design.preplan] #{@responsibility_key} crashed: #{Exception.message(e)}")

      {:error, :designer_crashed}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] #{@responsibility_key} exited: #{inspect(reason)}")

      {:error, :designer_crashed}
  end

  defp trigger_meta(%Task{} = task) do
    %{task_id: task.id, kind: :event_topic}
    |> maybe_put(:project_id, task.project_id)
    |> maybe_put(:space_id, execution_space_id(task.id))
  end

  defp execution_space_id(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: id} -> id
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_escalate_brand(%Task{} = task), do: Brand.escalate_once(task)

  defp log_brand_escalation(%Task{} = task, result) do
    Logger.info("[design.preplan] brand escalation task=#{task.id} result=#{inspect(result)}")
  end

  defp move_cursor(%Task{} = task, step) do
    Tasks.set_planning_step(task, step)
  rescue
    e ->
      Logger.warning("[design.preplan] cursor move failed: #{Exception.message(e)}")
      {:error, :cursor_unmoved}
  catch
    :exit, reason ->
      Logger.warning("[design.preplan] cursor move exited: #{inspect(reason)}")
      {:error, :cursor_unmoved}
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc """
  The recorded design outcome as an atom, or `nil` when nothing is recorded.

  Derived from what member 4 PERSISTED, with the domain read from
  `Platform.Tasks.Task.planning_step_outcomes/0` rather than restated here.
  """
  @spec persisted_outcome(Task.t()) :: :complete | :not_applicable | :failed | nil
  def persisted_outcome(%Task{} = task) do
    with %{"outcome" => outcome} <- design_entry(task),
         true <- is_binary(outcome) and outcome in Task.planning_step_outcomes() do
      String.to_existing_atom(outcome)
    else
      _ -> nil
    end
  end

  @doc "The raw recorded design entry, or `nil`."
  @spec design_entry(Task.t()) :: map() | nil
  def design_entry(%Task{planning_step_outcomes: outcomes}) when is_map(outcomes) do
    case Map.get(outcomes, @step_key) do
      %{} = entry -> entry
      _other -> nil
    end
  end

  def design_entry(_task), do: nil

  @doc "True when the design step has a recorded outcome."
  @spec settled?(Task.t()) :: boolean()
  def settled?(%Task{} = task), do: not is_nil(design_entry(task))

  @doc """
  True when the design step is open — the cursor IS the state, so stage 5's
  hold and this module read the same field and there is no second source of
  truth.
  """
  @spec open?(Task.t()) :: boolean()
  def open?(%Task{planning_step: @designing_value}), do: true
  def open?(_task), do: false

  # ── small helpers ─────────────────────────────────────────────────────────

  # Stage 1's `matched` payload is the audit trail for whether a fire was
  # justified. Carried into the record rather than discarded.
  #
  # Matches the whole `UiSurface.verdict()` on purpose. A bare-map clause would
  # make both shapes work, but the tuple IS the unit of currency here
  # (`ui_surface.ex`'s `@type verdict`) and a function that silently accepts
  # either shape cannot catch the next caller that unwraps it — which is exactly
  # how `fire_designer/2` came to drop the evidence on every terminal record it
  # writes.
  defp evidence_annotations({true, %{layer: layer, matched: matched}}) do
    %{"layer" => to_string(layer), "matched" => Enum.map(matched, &to_string/1)}
  end

  defp evidence_annotations(_verdict), do: %{}

  defp canvas_id_of(%CanvasAttachment{canvas_id: id}), do: id
  defp canvas_id_of(id) when is_binary(id), do: id
  defp canvas_id_of(%{canvas_id: id}) when is_binary(id), do: id
  defp canvas_id_of(_other), do: nil

  defp put_canvas_id(map, nil), do: map
  defp put_canvas_id(map, id), do: Map.put(map, "canvas_id", id)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_task(%Task{id: id}), do: Repo.get(Task, id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
