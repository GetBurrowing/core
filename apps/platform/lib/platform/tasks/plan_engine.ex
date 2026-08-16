defmodule Platform.Tasks.PlanEngine do
  @moduledoc """
  Deterministic plan engine — drives stage progression without LLM involvement.

  ## Stage Progression

      pending ──[start_stage]──► running
      running ──[all validations passed]──► passed
      running ──[any validation failed]──► failed
      failed  ──[retry]──► running
      any     ──[skip]──► skipped

  ## Key functions

  - `advance/1`            — check current stage validations, move to next or complete plan
  - `evaluate_validation/2` — record a pass/fail result, auto-advance if last pending
  - `start_stage/1`        — transition stage from pending to running

  All transitions emit telemetry events for observability.
  """

  import Ecto.Query

  alias Platform.Repo
  require Logger

  alias Platform.Architecture.StageAudit
  alias Platform.Tasks
  alias Platform.Tasks.PlanCompletion

  alias Platform.Tasks.{DeployStageBuilder, Plan, Stacks, Stage, StackDeployer, Task, Validation}

  @valid_stage_transitions %{
    "pending" => ~w(running skipped),
    "running" => ~w(passed failed),
    "failed" => ~w(running skipped),
    "passed" => [],
    "skipped" => []
  }

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Start a stage by transitioning it from `pending` to `running`.

  Returns `{:error, :invalid_transition}` if the stage is not in `pending` status.
  """
  @spec start_stage(Ecto.UUID.t()) :: {:ok, Stage.t()} | {:error, term()}
  def start_stage(stage_id) do
    with {:ok, stage} <- fetch_stage(stage_id) do
      transition_stage(stage, "running")
    end
  end

  @doc """
  Reopen a failed manual-approval validation so review can be attempted again.

  If the owning stage is failed, it is moved back to `running` and the failed
  validation is reset to `pending` with cleared evaluation metadata.
  """
  @spec reopen_manual_approval(Ecto.UUID.t()) :: {:ok, Validation.t()} | {:error, term()}
  def reopen_manual_approval(validation_id) do
    deferring_broadcasts(fn ->
      Repo.transaction(fn ->
        # `validation_id` is an agent-supplied MCP tool argument. The bang form's
        # contract is `Ecto.NoResultsError` on a miss, so a malformed id raises
        # THAT rather than `Ecto.Query.CastError` — otherwise this one lookup
        # raises two different ways depending on how the agent typo'd.
        Platform.UUID.valid?(validation_id) ||
          raise(Ecto.NoResultsError, queryable: Validation)

        validation = Repo.get!(Validation, validation_id)

        if validation.kind != "manual_approval" do
          Repo.rollback(:not_manual_approval)
        end

        stage = Repo.get!(Stage, validation.stage_id)

        cond do
          validation.status == "passed" ->
            Repo.rollback(:already_passed)

          stage.status == "failed" ->
            {:ok, _stage} = transition_stage(stage, "running")

          stage.status in ["running", "pending"] ->
            :ok

          true ->
            Repo.rollback(:invalid_stage_state)
        end

        {:ok, updated} =
          validation
          |> Validation.changeset(%{
            status: "pending",
            evidence: archive_ruling(validation),
            evaluated_by: nil,
            evaluated_at: nil
          })
          |> Repo.update()

        updated
      end)
    end)
    |> case do
      {:ok, validation} -> {:ok, validation}
      {:error, reason} -> {:error, reason}
    end
  end

  # A reopen must leave the gate reading as un-evaluated (`pending`, no
  # evaluator) while still preserving what the human said. Those two are only
  # compatible if the old ruling moves somewhere that is plainly not the
  # current one: `evidence["prior_rulings"]`, oldest first. Every other
  # top-level evidence key belonged to the ruling being cleared and goes with
  # it. Keys are strings because this round-trips through JSONB.
  @prior_rulings_limit 20

  defp archive_ruling(validation) do
    prior =
      case validation.evidence do
        %{"prior_rulings" => rulings} when is_list(rulings) -> rulings
        _ -> []
      end

    current =
      case validation.evidence do
        map when is_map(map) -> Map.delete(map, "prior_rulings")
        _ -> %{}
      end

    if current == %{} and is_nil(validation.evaluated_by) do
      # Nothing was ruled, so there is nothing to remember. Reopening a blank
      # row repeatedly must not accumulate empty history entries.
      if prior == [], do: %{}, else: %{"prior_rulings" => prior}
    else
      entry = %{
        "status" => validation.status,
        "evidence" => current,
        "evaluated_by" => validation.evaluated_by,
        "evaluated_at" => iso8601_or_nil(validation.evaluated_at),
        "reopened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      %{"prior_rulings" => Enum.take(prior ++ [entry], -@prior_rulings_limit)}
    end
  end

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601_or_nil(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  # Task 01a006e7. The name of the stage synthesized by
  # `open_remediation_stage/2`.
  #
  # The wording is FUNCTIONAL, not cosmetic: `e2e_host_stage_name?/1` is a
  # case-insensitive substring match on stage NAME, so a remediation stage
  # called "Fix the failed review" would be adopted by the engine as the
  # e2e host the next time a plan is built. `plan_engine_remediation_test.exs`
  # asserts this constant against that same predicate rather than a copied
  # regex, so the two cannot drift.
  @remediation_stage_name "Address the failed behavioural gate"

  @doc "The stage name `open_remediation_stage/2` synthesizes."
  @spec remediation_stage_name() :: String.t()
  def remediation_stage_name, do: @remediation_stage_name

  @doc """
  Open a fresh remediation stage in front of a failed behavioural gate.

  A failed `e2e_behavior` gate bounces its task back to `in_progress`, but
  that transition touches no stage: the plan is left with nothing `pending`
  or `running`, so the router withholds every dispatch and a human has to
  spawn the fixing executor by hand (task 01a006e7).

  This gives the bounce something to dispatch. It SYNTHESIZES a new stage
  rather than reopening the last implementation stage, for two reasons:

    * a passed implementation stage has all its validations `passed`, so
      `advance_stage/1` reads `:all_passed` the moment anything reopens it
      and immediately re-passes and re-advances — reopening a stage whose
      validations are already satisfied does not create a unit of work; and
    * a behavioural finding routinely spans several stages, so naming one
      blames a stage that is not wrong and makes the plan's record false.

  The new stage lands AT the gate's position (the gate and everything after
  it shift by +1) so the gate still re-runs afterwards, carries the gate
  agent's finding verbatim as its description, and gets the ordinary
  `test_pass` + `lint_pass` validations so it can pass by the normal route.

  The failed gate validations are reset to `pending` with their ruling
  ARCHIVED into `evidence["prior_rulings"]` by the same `archive_ruling/1`
  `reopen_manual_approval/1` uses. Blanking a gate agent's observation is
  the defect PR #752 fixed for manual gates; it is not reintroduced here.

  The gate may fail up to `Tasks.max_review_rounds/0` times before the router
  supersedes the plan entirely. The ROUNDS are bounded there; the STAGES are
  bounded here (task 01a006e7 stage 5): if the plan already carries a
  remediation stage in any status but `skipped` — INCLUDING `passed`, which is
  the status it is always in when the gate fails a second time — that row is
  REUSED: the new finding is appended to its description under a round marker,
  the stage is reopened to `pending`, and its own validations are re-pended.
  A plan therefore never carries more than one remediation stage.
  Reuse deliberately APPENDS: discarding the new finding would dispatch the
  executor against stale feedback, which is worse than a duplicate stage.

  Returns `{:ok, stage}` with the inserted-or-reused stage.
  """
  @spec open_remediation_stage(Stage.t() | Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Stage.t()} | {:error, term()}
  def open_remediation_stage(gate_stage, feedback \\ nil)

  def open_remediation_stage(%Stage{id: id}, feedback),
    do: open_remediation_stage(id, feedback)

  def open_remediation_stage(gate_stage_id, feedback) when is_binary(gate_stage_id) do
    deferring_broadcasts(fn ->
      Repo.transaction(fn ->
        gate =
          if Platform.UUID.valid?(gate_stage_id),
            do: Repo.get(Stage, gate_stage_id)

        gate || Repo.rollback(:stage_not_found)

        failed =
          Repo.all(
            from(v in Validation,
              where: v.stage_id == ^gate.id and v.kind == "e2e_behavior" and v.status == "failed",
              order_by: [asc: v.inserted_at]
            )
          )

        if failed == [], do: Repo.rollback(:no_failed_gate_validations)

        stage =
          case open_remediation_stage_for(gate.plan_id) do
            nil -> insert_remediation_stage(gate, failed, feedback)
            existing -> reuse_remediation_stage(existing, gate, failed, feedback)
          end

        Enum.each(failed, fn validation ->
          validation
          |> Validation.changeset(%{
            status: "pending",
            evidence: archive_ruling(validation),
            evaluated_by: nil,
            evaluated_at: nil
          })
          |> Repo.update!()
        end)

        reset_gate_stage(gate)

        stage
      end)
    end)
  end

  # The single remediation stage a plan is allowed to carry. `passed` IS in the
  # set, and that is the whole correction: the predicate originally excluded it
  # on the reasoning that a passed stage is history, which made the reuse branch
  # UNREACHABLE ON THE ONLY ROUTE THAT REACHES IT. The single path from a
  # remediation stage back to the gate runs THROUGH `passed` — the executor
  # must drive the stage to `passed` for the gate to re-run at all — so at the
  # moment of a second gate failure the existing remediation stage is always
  # `passed`, and excluding it inserted a second near-identical stage every
  # time. It is precisely the round-1 stage, already passed, that round 2 must
  # reopen.
  #
  # Reopening a `passed` stage is safe because reuse re-pends its own
  # `test_pass`/`lint_pass` and clears `started_at`/`completed_at`, so the
  # engine cannot read it as satisfied and advance straight past the gate;
  # `reset_gate_stage/1` closes the gate in the same transaction, leaving the
  # reopened stage as the lowest-position pending one.
  #
  # `skipped` stays out: a skipped stage was deliberately taken out of the plan
  # by a human, and silently resurrecting it would overrule that.
  #
  # `asc: :position` is load-bearing rather than cosmetic now that a plan
  # carrying a legacy duplicate pair (inserted before this fix) can exist: the
  # EARLIER stage is the one that sits in front of the gate.
  #
  # Matched on the synthesized name, which `remediation_stage_name/0` is the
  # single source of.
  defp open_remediation_stage_for(plan_id) do
    Stage
    |> where(
      [s],
      s.plan_id == ^plan_id and s.name == ^@remediation_stage_name and
        s.status in ~w(pending running failed passed)
    )
    |> order_by([s], asc: s.position)
    |> limit(1)
    |> Repo.one()
  end

  defp insert_remediation_stage(gate, failed, feedback) do
    shift_stages_from(gate.plan_id, gate.position)

    stage =
      %Stage{}
      |> Stage.changeset(%{
        plan_id: gate.plan_id,
        position: gate.position,
        name: @remediation_stage_name,
        description: remediation_description(gate, failed, feedback),
        status: "pending"
      })
      |> Repo.insert!()

    Enum.each(~w(test_pass lint_pass), fn kind ->
      %Validation{}
      |> Validation.changeset(%{stage_id: stage.id, kind: kind, status: "pending"})
      |> Repo.insert!()
    end)

    stage
  end

  # Reuse APPENDS. The prior round's finding stays because the executor may not
  # have addressed it, and the new one is added because it is the reason the
  # gate failed again — a reuse that overwrote either would dispatch against a
  # description that does not match the plan's actual state.
  defp reuse_remediation_stage(%Stage{} = stage, gate, failed, feedback) do
    round = round_count(stage.description) + 1

    description =
      String.trim_trailing(stage.description || "") <>
        "\n\n---\n\n## Round #{round}\n\n" <> remediation_description(gate, failed, feedback)

    # Its own validations may have been passed on the previous round; they have
    # to be re-earned or the stage advances the instant the router opens it.
    Validation
    |> where([v], v.stage_id == ^stage.id and v.status != "pending")
    |> Repo.all()
    |> Enum.each(fn v ->
      v
      |> Validation.changeset(%{
        status: "pending",
        evidence: archive_ruling(v),
        evaluated_by: nil,
        evaluated_at: nil
      })
      |> Repo.update!()
    end)

    stage
    |> Stage.changeset(%{description: description, status: "pending"})
    |> Ecto.Changeset.put_change(:started_at, nil)
    |> Ecto.Changeset.put_change(:completed_at, nil)
    |> Repo.update!()
  end

  # Round 1 has no marker; every reuse writes exactly one.
  defp round_count(nil), do: 1

  defp round_count(description) do
    1 + length(Regex.scan(~r/^## Round \d+$/m, description))
  end

  # `(plan_id, position)` carries a PLAIN index, not a unique one
  # (`20260320120000_create_tasks_tables.exs:110`), so a +1 shift cannot
  # collide at the database level. It is still written descending — highest
  # position first — because the ordering is the property that makes the
  # shift correct under a unique constraint too, and a later migration that
  # tightens the index must not silently turn this into a runtime error.
  defp shift_stages_from(plan_id, from_position) do
    Stage
    |> where([s], s.plan_id == ^plan_id and s.position >= ^from_position)
    |> order_by([s], desc: s.position)
    |> Repo.all()
    |> Enum.each(fn s ->
      s
      |> Stage.changeset(%{position: s.position + 1})
      |> Repo.update!()
    end)
  end

  # The gate must not be open while the remediation stage runs, or the router
  # dispatches both at once. `@valid_stage_transitions` has no `failed ->
  # pending` edge — it describes the progression of a stage that is being
  # WORKED, and this is a re-plan around it — so the reset is written
  # directly, clearing the timestamps so the gate reads as never having run.
  defp reset_gate_stage(%Stage{status: status} = gate) when status in ~w(failed running) do
    gate
    |> Stage.changeset(%{status: "pending"})
    |> Ecto.Changeset.put_change(:started_at, nil)
    |> Ecto.Changeset.put_change(:completed_at, nil)
    |> Repo.update!()
  end

  defp reset_gate_stage(gate), do: gate

  # The gate agent's evidence goes in VERBATIM. A summary would drop exactly
  # the expected-vs-observed detail the dispatched executor needs, and that
  # detail is the only thing that makes the synthesized stage actionable.
  defp remediation_description(gate, failed, feedback) do
    findings =
      failed
      |> Enum.with_index(1)
      |> Enum.map(fn {v, i} ->
        "## Finding #{i} (e2e_behavior #{v.id})\n\n" <>
          "```json\n" <> encode_evidence(v.evidence) <> "\n```"
      end)

    [
      "The behavioural gate \"#{gate.name}\" failed. Address the finding(s) below; " <>
        "the gate re-runs once this stage passes.",
      feedback && String.trim(feedback),
      Enum.join(findings, "\n\n")
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp encode_evidence(evidence) do
    case Jason.encode(evidence || %{}, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(evidence)
    end
  end

  @doc """
  Record a validation result and auto-advance if this was the last pending
  validation for its stage.

  `result` must be a map with at least `:status` (`"passed"` or `"failed"`)
  and optionally `:evidence` and `:evaluated_by`.
  """
  @spec evaluate_validation(Ecto.UUID.t(), map()) :: {:ok, Validation.t()} | {:error, term()}
  def evaluate_validation(validation_id, result) do
    status = Map.get(result, :status) || Map.get(result, "status")
    evidence = Map.get(result, :evidence) || Map.get(result, "evidence", %{})
    evaluated_by = Map.get(result, :evaluated_by) || Map.get(result, "evaluated_by", "system")

    unless status in ~w(passed failed) do
      raise ArgumentError,
            "validation result status must be \"passed\" or \"failed\", got: #{inspect(status)}"
    end

    deferring_broadcasts(fn ->
      Repo.transaction(fn ->
        # `validation_id` is an agent-supplied MCP tool argument. The bang form's
        # contract is `Ecto.NoResultsError` on a miss, so a malformed id raises
        # THAT rather than `Ecto.Query.CastError` — otherwise this one lookup
        # raises two different ways depending on how the agent typo'd.
        Platform.UUID.valid?(validation_id) ||
          raise(Ecto.NoResultsError, queryable: Validation)

        validation = Repo.get!(Validation, validation_id)

        {:ok, updated} =
          validation
          |> Validation.changeset(%{
            status: status,
            evidence: carry_prior_rulings(validation, evidence),
            evaluated_by: evaluated_by,
            evaluated_at: DateTime.utc_now()
          })
          |> Repo.update()

        emit_validation_telemetry(updated)

        # Auto-advance: if no more pending/running validations on this stage, advance.
        # A newly failed validation should fail a running stage immediately, while
        # a later failed->passed flip must be able to reopen and re-advance a stage
        # that had already entered failed.
        stage = Repo.get!(Stage, updated.stage_id)

        cond do
          stage.status == "running" and status == "failed" ->
            advance_stage(stage)

          all_validations_resolved?(stage.id) ->
            maybe_advance_resolved_stage(stage)

          true ->
            :ok
        end

        # ADR 0041 (T5 stage 3) — when a validation pass resolves the
        # last pending validation on a stack member's review stage, the
        # member is now review-ready. The in_review transition's earlier
        # rollup-merge attempt may have no-op'd as `:not_ready`; re-fire
        # the deployer hook so the merge can now proceed. The deployer
        # is idempotent (already-merged short-circuits) and enforces its
        # own readiness gate.
        if status == "passed" do
          maybe_retrigger_stack_member_merge(updated.stage_id)
        end

        updated
      end)
    end)
  end

  # The `prior_rulings` archive used to survive only because every KNOWN caller
  # re-attached it — `ReviewRequests` copied the archive forward itself before
  # calling in here (that duplicate was removed at task `01a006f6` stage 3).
  # That was a habit of the callers, not a property of the write.
  # `Platform.Federation.ToolSurface`'s
  # `execute("validation_evaluate", ...)` calls `evaluate_validation/2`
  # DIRECTLY with agent-supplied evidence and never touches `ReviewRequests`,
  # so an agent dispositioning a manual gate through the tool surface destroyed
  # the human's recorded words with no error and no failed gate. Merging at the
  # write makes the guarantee caller-independent.
  #
  # Deliberately narrow: an explicit caller-supplied `"prior_rulings"` wins (so
  # `ReviewRequests` stays idempotent), nothing is invented where there was no
  # archive, and only `manual_approval` rows are touched — the archive has no
  # meaning on deploy/test kinds and must not leak into them.
  defp carry_prior_rulings(%Validation{kind: "manual_approval"} = validation, evidence)
       when is_map(evidence) do
    case validation.evidence do
      %{"prior_rulings" => [_ | _] = prior} ->
        if Map.has_key?(evidence, "prior_rulings") do
          evidence
        else
          Map.put(evidence, "prior_rulings", prior)
        end

      _ ->
        evidence
    end
  end

  defp carry_prior_rulings(_validation, evidence), do: evidence

  defp maybe_retrigger_stack_member_merge(stage_id) do
    query =
      from(s in Stage,
        join: p in Plan,
        on: p.id == s.plan_id,
        join: t in Task,
        on: t.id == p.task_id,
        where: s.id == ^stage_id,
        where: not is_nil(t.stack_id),
        where: t.status == "in_review",
        select: t
      )

    case Repo.one(query) do
      nil ->
        :ok

      %Task{} = task ->
        _ = StackDeployer.handle_member_transition(task, :validation_passed, :in_review)

        # TAIL-stall fix (2026-07-22), direction (2): advance the member
        # `in_review -> deploying` ON this last-validation-pass event instead
        # of waiting up to 15 min for the reconcile sweep. The merge
        # re-trigger above runs FIRST so `merged_into_rollup_at` is stamped
        # before the deploy-ready gate checks it; we reload to observe the
        # fresh stamp. `advance_member_to_deploying/1` self-guards
        # (returns `:noop` unless the member is deploy-ready) and
        # log-and-swallows, so an async merge that has not stamped yet is a
        # harmless no-op and the periodic sweep remains the backstop. This is
        # the direct analog of the commencement fix's post-commit promote
        # hook — promote on the triggering event, idempotent, never disturb
        # the validation write.
        task
        |> Repo.reload!()
        |> Stacks.advance_member_to_deploying()

        :ok
    end
  rescue
    # The hook is best-effort — never crash evaluate_validation if the
    # deployer-side lookup or dispatch fails.
    error ->
      Logger.warning(
        "[PlanEngine] stack-member merge re-trigger / deploy promote failed: " <>
          Exception.message(error)
      )

      :ok
  end

  @doc """
  Check the current stage's validations and advance the plan accordingly.

  For the current (first running or first pending) stage:
  - If all validations passed → mark stage passed, move to next stage or complete plan
  - If any validation failed → mark stage failed
  - If validations still pending → no-op

  Returns `{:ok, plan}` with the updated plan (preloaded with stages).
  """
  @spec advance(Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, term()}
  def advance(plan_id), do: advance(plan_id, [])

  @doc """
  Advance a plan, optionally scoped to the stage the caller is asserting.

  Options:

    * `:stage_id` — the stage the caller claims to have completed. When given,
      the call is a NO-OP unless that stage IS the current stage. Without it
      `advance/1` is PLAN-scoped: it picks its subject via `current_stage/1`
      ("first running, else first pending"), which is not necessarily the
      stage the caller named. `stage_complete` admits a call naming an
      already-`passed` stage so idempotent re-calls succeed, so a late or
      duplicate completion used to advance whatever stage happened to be
      running — and since a stage with zero validation rows has verdict
      `:all_passed`, it was marked `passed` with no executor involvement
      (task 019fec3a). Scoping here makes `passed` uniformly mean "an actor
      asserted THIS stage is done".

    * `:completed_by` — identifier of the actor asserting completion, threaded
      into the `passed` transition's telemetry metadata so the audit trail
      distinguishes an asserted stage from a swept one.

  Returns `{:ok, plan}` with the updated plan (preloaded with stages).
  """
  @spec advance(Ecto.UUID.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def advance(plan_id, opts) when is_list(opts) do
    asserted_stage_id = Keyword.get(opts, :stage_id)
    completed_by = Keyword.get(opts, :completed_by)

    deferring_broadcasts(fn ->
      Repo.transaction(fn ->
        plan = Repo.get!(Plan, plan_id)
        stages = ordered_stages(plan_id)

        case current_stage(stages) do
          nil ->
            # `current_stage/1` returns nil for [passed, failed] exactly as it does
            # for [passed, passed] — it looks only for a running or pending stage.
            # This branch used to call `complete_plan/1` unconditionally, which on
            # 2026-07-25 completed task 019f9ae5's plan at 20:58:58 while its
            # stage 3 sat `failed`; the stale `completed` later rode a
            # `{:plan_updated}` broadcast into the router and marked the task
            # `done` eight minutes before its PR merged (task 019f9b34).
            # Mirror `maybe_advance_next/3`'s all-terminal guard instead, and
            # route completion through the deploy-aware seam.
            cond do
              stages == [] ->
                # Degenerate plan with no stages at all — nothing to deploy,
                # preserve the historical completion behavior.
                {:ok, completed} = complete_plan(plan, :degenerate_plan)
                Repo.preload(completed, stages_query())

              Enum.all?(stages, &(&1.status in ~w(passed skipped))) ->
                maybe_inject_deploy_or_complete(plan, stages)

              true ->
                # A failed stage is present — leave the plan alone. The failed
                # stage reopens when its validations flip (see
                # `maybe_advance_resolved_stage/1`).
                Repo.preload(plan, stages_query())
            end

          stage when is_binary(asserted_stage_id) and stage.id != asserted_stage_id ->
            # The caller asserted a stage other than the one currently in
            # flight. Do not sweep a stage nobody claimed — no-op.
            Repo.preload(plan, stages_query())

          stage ->
            case stage_verdict(stage) do
              :all_passed ->
                {:ok, _passed_stage} = transition_stage(stage, "passed", completed_by)
                maybe_advance_next(plan, stages, stage.position)

              :has_failures ->
                {:ok, _failed_stage} = transition_stage(stage, "failed")
                Repo.preload(Repo.get!(Plan, plan_id), stages_query())

              :pending ->
                Repo.preload(plan, stages_query())
            end
        end
      end)
    end)
  end

  # ── Plan ingestion: e2e_behavior routing + UI heuristic ───────────────────

  # File-path / module-name tokens that strongly imply a stage actually renders
  # or modifies user-visible UI. Used by the heuristic safety net (see
  # `check_manual_approval_heuristic/1`) — purely advisory; planner authority wins.
  @ui_tokens [
    ".heex",
    "tasks_live.ex",
    "assets/js/",
    "assets/css/",
    "compose_input",
    "app.css",
    "chat_live",
    "_web/live/",
    "_web/components/"
  ]

  # Case-insensitive substring triggers that make the engine adopt an
  # ALREADY-AUTHORED stage as the host for a plan's `e2e_behavior`
  # validations. This list, and the exemption below, are the single copy:
  # every consumer (the router, and any write-time detector) must read them
  # through `e2e_host_name_match/1` rather than restating them, because a
  # detector holding its own copy is precisely the drift this guard exists
  # to prevent.
  @e2e_host_name_triggers ["review", "validation"]

  # Name prefixes that are NEVER adopted as the e2e host even when they
  # contain a trigger (a "Deploy: ... review" stage is a deploy, not a gate).
  @e2e_host_exempt_prefixes ["deploy:"]

  @doc """
  Re-route any `e2e_behavior` validations in a list of planner-authored
  stage_input maps to a single task-level review stage.

  Behavior:
  - If any stage already has `kind: "e2e_behavior"` validations, strip them
    from that stage and collect them all into one final review stage.
  - If a stage already exists whose name matches "review"/"validation" (the
    final task-level review stage), append the e2e_behavior validations to its
    validations list. Otherwise, synthesize a new "Task-level review" stage at
    `max_position + 1` carrying just the lifted e2e_behavior validations.
  - If multiple e2e_behavior validations were emitted, all are kept (the
    planner template forbids this; we don't enforce here so a misbehaving
    planner can still surface for the human reviewer to catch).

  Stage maps use string OR atom keys (planner output is JSON-derived → strings;
  in-process callers may use atoms). The returned list preserves the input
  shape (string-keyed if input was string-keyed).
  """
  @spec route_e2e_behavior_validations([map()]) :: [map()]
  def route_e2e_behavior_validations(stages_input) when is_list(stages_input) do
    {stripped_stages, e2e_validations} =
      Enum.map_reduce(stages_input, [], fn stage, acc ->
        validations = stage_validations_field(stage)

        {kept, lifted} =
          Enum.split_with(validations, fn v ->
            (Map.get(v, "kind") || Map.get(v, :kind)) != "e2e_behavior"
          end)

        new_stage = put_stage_validations(stage, kept)
        {new_stage, acc ++ lifted}
      end)

    case e2e_validations do
      [] ->
        stripped_stages

      _ ->
        attach_e2e_validations_to_review_stage(stripped_stages, e2e_validations)
    end
  end

  def route_e2e_behavior_validations(other), do: other

  @doc """
  Refuse a plan whose stage NAME would silently make it the e2e host.

  Returns `:ok`, or `{:error, %{stage_name:, stage_position:, matched_substring:,
  e2e_case_count:}}` for the FIRST offending stage.

  Reads RAW planner stages, so it must run BEFORE
  `route_e2e_behavior_validations/1`.

  Why the ordering matters (corrected in stage 4 by probe; the earlier
  rationale here was wrong): routing RELOCATES e2e cases, it does not delete
  them, so `e2e_case_count` survives the rewrite and rule 1 would still fire.
  The real hazard is the other direction — routing SYNTHESIZES a stage named
  "Task-level review", which itself carries the trigger, so a detector running
  after the rewrite refuses every clean e2e plan. The pin for this ordering is
  therefore the DIRECTION CONTROL test in `tool_surface_test.exs`, not the
  rejection test.
  """
  # DISPOSITION: reject, not warn.
  #
  # In all three confirmed incidents the relocation was unintended, by authors
  # who already had the naming rule written down — so a warning is exactly the
  # signal they had already internalised and still tripped over. Worse, the
  # moment after `plan_create` returns is when the author can no longer act: a
  # draft/pending_review plan blocks `plan_create` and cannot be read back
  # (`plan_get` returns approved plans only). A warning delivered where nothing
  # can act on it is not a mitigation. Rejection happens pre-persistence and
  # leaves the author free to rename and retry.
  #
  # The risk of rejecting a legitimately-named stage is retired by the explicit
  # `e2e_host` opt-in below — an expressed field, never inferred from prose.
  @spec detect_e2e_host_collision([map()]) :: :ok | {:error, map()}
  def detect_e2e_host_collision(stages_input) when is_list(stages_input) do
    e2e_case_count =
      Enum.reduce(stages_input, 0, fn stage, acc ->
        acc + Enum.count(stage_validations_field(stage), &e2e_behavior_validation?/1)
      end)

    cond do
      # 1. No e2e cases at all — the trigger word is harmless here, and firing
      #    would reject plans the bug cannot touch.
      e2e_case_count == 0 ->
        :ok

      # 2. Exactly one stage explicitly opts in as the host.
      Enum.count(stages_input, &e2e_host_opt_in?/1) == 1 ->
        :ok

      true ->
        # 3. First stage adopted by NAME alone.
        stages_input
        |> Enum.with_index(1)
        |> Enum.find_value(:ok, fn {stage, idx} ->
          case e2e_host_name_match(stage) do
            nil ->
              nil

            substring ->
              {:error,
               %{
                 stage_name: stage_field(stage, "name"),
                 stage_position: stage_field(stage, "position") || idx,
                 matched_substring: substring,
                 e2e_case_count: e2e_case_count
               }}
          end
        end)
    end
  end

  def detect_e2e_host_collision(_other), do: :ok

  defp e2e_behavior_validation?(v) when is_map(v) do
    (Map.get(v, "kind") || Map.get(v, :kind)) == "e2e_behavior"
  end

  defp e2e_behavior_validation?(_), do: false

  defp e2e_host_opt_in?(stage) when is_map(stage) do
    (Map.get(stage, "e2e_host") || Map.get(stage, :e2e_host)) == true
  end

  defp e2e_host_opt_in?(_), do: false

  @doc """
  Log warnings about manual_approval scoping based on a hybrid heuristic.

  - Warns when a stage description contains UI tokens (`.heex`, `assets/js/`, etc.)
    but the planner did NOT include a `manual_approval` validation — likely a
    missed UI gate.
  - Warns when a stage has a `manual_approval` validation but the description
    contains zero UI tokens — likely overscoping.

  Always returns the input untouched. Planner authority wins; heuristics only
  surface likely mistakes for human reviewers.
  """
  @spec check_manual_approval_heuristic([map()]) :: [map()]
  def check_manual_approval_heuristic(stages_input) when is_list(stages_input) do
    Enum.each(stages_input, fn stage ->
      desc = stage_field(stage, "description") || ""
      name = stage_field(stage, "name") || "<unnamed stage>"
      validations = stage_validations_field(stage)

      has_manual_approval? =
        Enum.any?(validations, fn v ->
          (Map.get(v, "kind") || Map.get(v, :kind)) == "manual_approval"
        end)

      ui_touching? = ui_touching?(desc)

      cond do
        ui_touching? and not has_manual_approval? ->
          Logger.warning(
            "[PlanEngine] likely missed UI manual_approval — stage \"#{name}\" description " <>
              "contains UI-touching tokens but no manual_approval validation. " <>
              "Planner authority wins; flagging for human review."
          )

        has_manual_approval? and not ui_touching? ->
          Logger.warning(
            "[PlanEngine] likely overscoped manual_approval — stage \"#{name}\" carries a " <>
              "manual_approval validation but description has zero UI-touching tokens. " <>
              "Planner authority wins; flagging for human review."
          )

        true ->
          :ok
      end
    end)

    stages_input
  end

  def check_manual_approval_heuristic(other), do: other

  @doc """
  Log an advisory warning for every stage that carries zero validations.

  A stage with no validations has nothing to gate it — the engine will advance
  straight through it, so nobody ever confirms the work landed. That is
  occasionally intentional, so this is purely advisory.

  Always returns the input untouched. Planner authority wins; there are live
  plans carrying zero-validation stages today and rejecting them at plan time
  would strand in-flight work. This only surfaces the signal for the human
  reviewer.
  """
  @spec check_zero_validation_stages([map()]) :: [map()]
  def check_zero_validation_stages(stages_input) when is_list(stages_input) do
    Enum.each(stages_input, fn stage ->
      name = stage_field(stage, "name") || "<unnamed stage>"

      case stage_validations_field(stage) do
        [] ->
          Logger.warning(
            "[PlanEngine] zero-validation stage — stage \"#{name}\" carries an empty " <>
              "validations list, so nothing gates its completion. " <>
              "Planner authority wins; flagging for human review."
          )

        _ ->
          :ok
      end
    end)

    stages_input
  end

  def check_zero_validation_stages(other), do: other

  # Pure helper exposed for the heuristic and for tests.
  @spec ui_touching?(String.t() | nil) :: boolean()
  def ui_touching?(nil), do: false

  def ui_touching?(description) when is_binary(description) do
    Enum.any?(@ui_tokens, &String.contains?(description, &1))
  end

  def ui_touching?(_), do: false

  defp stage_field(stage, key) when is_map(stage) do
    Map.get(stage, key) || Map.get(stage, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(stage, key)
  end

  defp stage_validations_field(stage) when is_map(stage) do
    Map.get(stage, "validations") || Map.get(stage, :validations) || []
  end

  defp put_stage_validations(stage, validations) when is_map(stage) do
    cond do
      Map.has_key?(stage, "validations") ->
        Map.put(stage, "validations", validations)

      Map.has_key?(stage, :validations) ->
        Map.put(stage, :validations, validations)

      # Originally absent — pick a key style consistent with other stage keys.
      Map.has_key?(stage, "name") or Map.has_key?(stage, "description") ->
        Map.put(stage, "validations", validations)

      true ->
        Map.put(stage, :validations, validations)
    end
  end

  defp attach_e2e_validations_to_review_stage(stages_input, e2e_validations) do
    # An explicit `e2e_host` stage WINS over name matching: the opt-in is the
    # author's expressed intent, the name match is only an inference.
    review_idx =
      Enum.find_index(stages_input, &e2e_host_opt_in?/1) ||
        Enum.find_index(stages_input, &(e2e_host_name_match(&1) != nil))

    case review_idx do
      nil ->
        stages_input ++ [synthesize_task_level_review_stage(stages_input, e2e_validations)]

      idx ->
        List.update_at(stages_input, idx, fn stage ->
          existing = stage_validations_field(stage)
          put_stage_validations(stage, existing ++ e2e_validations)
        end)
    end
  end

  @doc """
  Whether a stage NAME makes the engine adopt that stage as the e2e host.

  An existing "task-level review" or generic "review"/"validation" stage is
  reused; "Deploy: ..." stages are NEVER reused as the e2e gate.

  Public, and the single copy: any stage the engine SYNTHESIZES must be
  checked against this predicate (see `remediation_stage_name/0`), and a
  test that hand-copies the substring list would drift from the matcher it
  claims to be testing.
  """
  @spec e2e_host_stage_name?(String.t() | nil) :: boolean()
  def e2e_host_stage_name?(name), do: e2e_host_name_match(name) != nil

  @doc """
  The FIRST trigger substring that makes a stage the e2e host, or `nil`.

  Accepts either a planner-authored stage_input map or a bare name. Matching
  is case-insensitive substring matching against `@e2e_host_name_triggers`;
  a name starting with any of `@e2e_host_exempt_prefixes` never matches.

  Returns the substring rather than a boolean so a caller refusing the plan
  can NAME which trigger fired (e.g. `"review"` inside
  `"task_plan_review"`) instead of asserting an unexplained match.
  """
  @spec e2e_host_name_match(map() | String.t() | nil) :: String.t() | nil
  def e2e_host_name_match(stage) when is_map(stage) do
    e2e_host_name_match(stage_field(stage, "name"))
  end

  def e2e_host_name_match(name) do
    name = String.downcase(name || "")

    if Enum.any?(@e2e_host_exempt_prefixes, &String.starts_with?(name, &1)) do
      nil
    else
      Enum.find(@e2e_host_name_triggers, &String.contains?(name, &1))
    end
  end

  defp synthesize_task_level_review_stage(existing_stages, e2e_validations) do
    next_position =
      existing_stages
      |> Enum.map(&(stage_field(&1, "position") || 0))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    %{
      "name" => "Task-level review",
      "description" =>
        "Synthesized by the plan engine to host the planner-authored e2e_behavior validation " <>
          "as a single per-task review gate. The review agent executes the behavioral script " <>
          "in a dev environment and dispositions the validation.",
      "position" => next_position,
      "validations" => e2e_validations
    }
  end

  @doc """
  Build deploy stages for a task based on its resolved deploy strategy.

  Looks up the task's project deploy strategy via `Tasks.resolve_deploy_strategy/1`,
  then calls `DeployStageBuilder.build_stage/3` to produce stage definitions.

  If the task already has an approved plan, the deploy stage position is set to
  follow the last existing stage. Otherwise, it starts at position 1.

  Returns `{:ok, [stage_def]}` with a list of stage definition maps, or
  `{:ok, :skip}` if the strategy is `"none"`.

  This provides TaskRouter a clean API to request deploy stage injection
  without needing to understand strategy resolution or stage construction.
  """
  @spec build_deploy_plan(Ecto.UUID.t()) :: {:ok, [map()] | :skip} | {:error, term()}
  def build_deploy_plan(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        task = Repo.preload(task, :project)

        # `_with_repos` — the deploy stage gates on the repository SET the
        # task lands in (one `pr_merged` per repo), not on whichever PR
        # merges first. Resolves to exactly today's shape for a task that
        # declares nothing: `"repos"` is left absent when the set is empty,
        # and `DeployStageBuilder` reads absent as one unscoped gate.
        strategy = Tasks.resolve_deploy_strategy_with_repos(task)

        # Determine position: after last existing stage if plan exists
        next_position =
          case Repo.one(
                 from(p in Plan,
                   where: p.task_id == ^task_id and p.status in ~w(approved),
                   order_by: [desc: p.inserted_at],
                   limit: 1
                 )
               ) do
            nil ->
              1

            plan ->
              stages = ordered_stages(plan.id)
              max_position(stages) + 1
          end

        # The branch is RECORDED onto each scoped `pr_merged` gate here, at
        # mint time, rather than re-derived by the consumer. See
        # `DeployStageBuilder`'s moduledoc: the derivation
        # (`HeartbeatScheduler.member_slug/1`) answers a UUIDv7 time bucket
        # for a non-stack task, so two sibling tasks minted within ~65s share
        # it and one merge could close both their gates.
        #
        # `StackDeployer.member_branch_for/1` and not a fourth spelling of
        # the derivation: it is the existing `Platform.Tasks.*` helper for
        # "the branch for this task", already aliased above, and its
        # `@doc false` comment is the in-tree record of this defect class.
        # Reaching for `HeartbeatScheduler.member_slug/1` from `Platform.Tasks`
        # directly would make the `Tasks -> Orchestration` reference mutual
        # (`tasks.ex:1679-1696`); a sibling submodule calling it is already
        # established, the top-level context calling it is not.
        case DeployStageBuilder.build_stage(
               strategy,
               next_position,
               StackDeployer.member_branch_for(task)
             ) do
          :skip -> {:ok, :skip}
          stage_def -> {:ok, [stage_def]}
        end
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  # `stage_id` reaches here from the agent-supplied `stage_start` /
  # `stage_complete` tool arguments. Malformed folds into :not_found.
  defp fetch_stage(stage_id) do
    stage = if Platform.UUID.valid?(stage_id), do: Repo.get(Stage, stage_id)

    case stage do
      nil -> {:error, :not_found}
      stage -> {:ok, stage}
    end
  end

  defp transition_stage(stage, new_status, completed_by \\ nil) do
    allowed = Map.get(@valid_stage_transitions, stage.status, [])

    if new_status in allowed do
      now = DateTime.utc_now()

      extra =
        case new_status do
          "running" -> %{started_at: now, completed_at: nil}
          s when s in ~w(passed failed skipped) -> %{completed_at: now}
          _ -> %{}
        end

      {:ok, updated} =
        stage
        |> Stage.changeset(Map.put(extra, :status, new_status))
        |> Repo.update()

      emit_stage_telemetry(updated, stage.status, completed_by)

      # ADR-0044 stage 4: post-executor drift hook. Fire the architect's
      # `architecture.audit_diff` responsibility once per successful stage
      # completion. Progressive-enhancement — no-ops when no architect is
      # assigned. Wrapped in try/rescue/catch :exit inside the helper so a
      # handler crash cannot stall the state machine or the board broadcast
      # (memory ref: `[Suite engine quirks]` cascade-fix 019f3440).
      if new_status == "passed" do
        _ = after_stage_completed(updated)
      end

      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  # ADR-0044 stage 4 hook — kept private so `transition_stage/2` reads as
  # a single linear branch. The hook fires the architect's
  # `architecture.audit_diff` responsibility and is the only side effect
  # this stage-complete transition owns beyond the telemetry emit.
  #
  # Load-bearing: this function MUST NOT raise. It's called inside
  # `evaluate_validation/2`'s Ecto transaction (via `advance_stage/1`),
  # and a raise here would roll back the validation update itself — the
  # opposite of the additive-annotation contract. Every error mode logs
  # + RETURNS an error tuple; nothing here raises or re-raises.
  #
  # ADR-0046 member 1 stage 4: the fire result is inspected rather than
  # discarded. Before stages 1-2 gave `Responsibilities.fire/2` a real
  # return contract, a drift-audit endpoint that was down was
  # indistinguishable from "no architect assigned" — the stage passed
  # unaudited with nothing in the log.
  #
  # NIL-PLAN HAZARD (verified, do not regress): `plan` is a plain
  # `Repo.get/2` and CAN be nil — hence `plan && Repo.get(...)` on the
  # next line. The log lines below therefore key off `stage.id` /
  # `stage.plan_id`, never `plan.task_id`, so a stage whose plan row
  # vanished logs instead of raising a `KeyError` inside the
  # transaction. The rescue/catch clauses are the backstop, not the
  # plan.
  defp after_stage_completed(%Stage{} = stage) do
    plan = Repo.get(Plan, stage.plan_id)
    task = plan && Repo.get(Task, plan.task_id)

    result =
      case Platform.Responsibilities.fire("architecture.audit_diff", %{
             stage_id: stage.id,
             plan_id: stage.plan_id,
             task_id: plan && plan.task_id,
             stage: stage,
             plan: plan,
             task: task
           }) do
        {:error, reason} = result ->
          Logger.warning(
            "[Responsibilities] architecture.audit_diff dispatch failed " <>
              "stage=#{stage.id} plan=#{stage.plan_id} reason=#{inspect(reason)}"
          )

          result

        {:ok, state} = result when state in [:unfilled, :unknown_responsibility] ->
          # Progressive enhancement, not a problem: no architect holds the
          # responsibility (or the key was never seeded).
          Logger.info(
            "[Responsibilities] architecture.audit_diff #{state} " <>
              "stage=#{stage.id} plan=#{stage.plan_id}"
          )

          result

        # {:ok, :dispatched} — the Router already logged the dispatch.
        result ->
          result
      end

    # Task 019fa61c. Everything above LOGS the outcome; logs are not an
    # artefact. Until this line, all three outcomes left the same durable
    # trace — none — so 28 broadcasts in a 3.3-hour window were
    # indistinguishable from an architect who was never assigned, and the
    # payload defect behind them ran six days unnoticed.
    #
    # Called on EVERY branch, deliberately: a fire that failed and a fire
    # that never applied are exactly the two facts a reader needs to tell
    # apart, and skipping the write on either would rebuild the blind
    # spot for that case.
    #
    # This write is inside `evaluate_validation/2`'s transaction, which is
    # what we want — a fire recorded for a stage transition that later
    # rolled back would be a lie. `open_from_fire/2` is total (its own
    # rescue returns an error tuple), so it cannot reach this function's
    # rescue backstop and turn "recorded" back into "nothing".
    _ = StageAudit.open_from_fire(stage, result)

    result
  rescue
    e ->
      Logger.warning(
        "[Responsibilities] architecture.audit_diff crashed: #{Exception.message(e)}"
      )

      {:error, {:hook_raised, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[Responsibilities] architecture.audit_diff exited: #{inspect(reason)}")

      {:error, {:hook_exited, reason}}
  end

  defp ordered_stages(plan_id) do
    Stage
    |> where([s], s.plan_id == ^plan_id)
    |> order_by([s], asc: s.position)
    |> Repo.all()
  end

  defp current_stage(stages) do
    # First running stage, or first pending stage
    Enum.find(stages, &(&1.status == "running")) ||
      Enum.find(stages, &(&1.status == "pending"))
  end

  defp stage_verdict(stage) do
    validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))

    cond do
      validations == [] -> :all_passed
      Enum.any?(validations, &(&1.status == "failed")) -> :has_failures
      Enum.all?(validations, &(&1.status == "passed")) -> :all_passed
      true -> :pending
    end
  end

  defp all_validations_resolved?(stage_id) do
    pending_count =
      Validation
      |> where([v], v.stage_id == ^stage_id and v.status in ~w(pending running))
      |> Repo.aggregate(:count)

    pending_count == 0
  end

  defp maybe_advance_resolved_stage(%Stage{} = stage) do
    case stage.status do
      "running" ->
        advance_stage(stage)

      "failed" ->
        case stage_verdict(stage) do
          :all_passed ->
            {:ok, reopened_stage} = transition_stage(stage, "running")
            advance_stage(reopened_stage)

          :has_failures ->
            :ok

          :pending ->
            :ok
        end

      _other ->
        :ok
    end
  end

  defp advance_stage(stage) do
    case stage_verdict(stage) do
      :all_passed ->
        {:ok, _} = transition_stage(stage, "passed")
        plan = Repo.get!(Plan, stage.plan_id)
        stages = ordered_stages(plan.id)
        maybe_advance_next(plan, stages, stage.position)

      :has_failures ->
        {:ok, failed_stage} = transition_stage(stage, "failed")

        if deploy_stage?(failed_stage) do
          emit_deploy_failure_telemetry(failed_stage)
        end

        {:ok, failed_stage}

      :pending ->
        :ok
    end
  end

  @doc """
  Returns true if the stage is a deploy stage (has ci_passed or pr_merged validations,
  or its name starts with "Deploy:").
  """
  @spec deploy_stage?(Stage.t()) :: boolean()
  def deploy_stage?(%Stage{} = stage) do
    name_match = String.starts_with?(stage.name || "", "Deploy:")

    if name_match do
      true
    else
      validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))

      Enum.any?(validations, fn v ->
        v.kind in ~w(ci_passed pr_merged)
      end)
    end
  end

  defp emit_deploy_failure_telemetry(%Stage{} = stage) do
    # Collect failure evidence from failed validations
    failed_validations =
      Repo.all(
        from(v in Validation,
          where: v.stage_id == ^stage.id and v.status == "failed"
        )
      )

    failure_reason =
      failed_validations
      |> Enum.map(fn v -> "#{v.kind}: #{inspect(v.evidence)}" end)
      |> Enum.join("; ")

    # Extract merge SHA from any validation evidence (for potential revert)
    merge_sha =
      failed_validations
      |> Enum.find_value(fn v ->
        get_in(v.evidence, ["sha"]) || get_in(v.evidence, ["merge_sha"])
      end)

    :telemetry.execute(
      [:platform, :tasks, :deploy_stage_failed],
      %{system_time: System.system_time()},
      %{
        stage_id: stage.id,
        plan_id: stage.plan_id,
        failure_reason: failure_reason,
        merge_sha: merge_sha,
        failed_validations: Enum.map(failed_validations, & &1.kind)
      }
    )
  end

  defp maybe_advance_next(plan, _old_stages, current_position) do
    # Re-fetch stages to get current statuses after transitions
    fresh_stages = ordered_stages(plan.id)
    next = Enum.find(fresh_stages, &(&1.position > current_position and &1.status == "pending"))

    case next do
      nil ->
        # No more stages — complete the plan if all are terminal
        all_terminal? = Enum.all?(fresh_stages, &(&1.status in ~w(passed skipped)))

        if all_terminal? do
          maybe_inject_deploy_or_complete(plan, fresh_stages)
        else
          # Some stages failed; reload plan
          Repo.preload(Repo.get!(Plan, plan.id), stages_query())
        end

      next_stage ->
        # Auto-start the next pending stage so the agent can proceed immediately
        {:ok, _started} = transition_stage(next_stage, "running")
        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  # Statuses from which the ENGINE will inject a deploy stage (task 019ff788
  # stage 2). `in_progress` was dropped: it was correct when
  # `@deployable_statuses` was written (commit 3e37b8cd, #109), because a plan
  # then held only implementation stages and "plan completed" meant
  # "implementation done". `synthesize_task_level_review_stage/2` later put the
  # review gate INSIDE the same plan, which redefined plan completion as
  # "implementation AND review done" — so a plan that completes while its task
  # still reads `in_progress` now means the review gate never ran or the task
  # never entered `in_review` (stage 1's write failed). Deploying on it would
  # ship an unreviewed task.
  #
  # This is deliberately a NARROWING: unreviewed work stops rather than ships.
  # The failure mode it introduces is a task that completes its plan without a
  # deploy stage, and that mode is loud — the `Logger.warning` below names the
  # task id and the disqualifying status.
  @deployable_statuses ~w(in_review)

  # Check if a deploy stage needs to be injected before completing the plan.
  # If a deploy stage already exists (was previously injected), complete normally.
  # If no deploy stage exists and the strategy isn't "none", inject one.
  # Only injects when the task is in a status that can transition to deploying.
  defp maybe_inject_deploy_or_complete(plan, stages) do
    has_deploy_stage? = Enum.any?(stages, &DeployStageBuilder.deploy_stage_name?(&1.name))

    if has_deploy_stage? do
      # Deploy stage already ran and passed — complete the plan
      {:ok, completed} = complete_plan(plan, :deploy_stage_passed)
      Repo.preload(completed, stages_query())
    else
      # No deploy stage yet — check strategy and maybe inject one
      task =
        Task
        |> Repo.get!(plan.task_id)
        |> Repo.preload(:project)

      cond do
        Tasks.dispatch_deploy_for_task(task) == {:error, :stack_ships_atomically} ->
          # ADR 0041 (T5 stage 3) — stack members never get a per-task
          # deploy stage. The stack rollup PR (T6) carries the deploy
          # for all members. The per-task plan completes when its
          # review stages pass; the stack-level deployer takes over
          # from there.
          #
          # The single-seam guard `Tasks.dispatch_deploy_for_task/1`
          # owns the "is this a stack member?" decision plus the
          # `[:platform, :tasks, :deploy_dispatch, :rejected_stack_member]`
          # telemetry emission. Any new call site that forgets the
          # check would silently ship a member alone.
          #
          # Task 019e2be4 stage 1: fire the rollup-merge trigger here.
          # `handle_member_transition/3` is async-aware (config
          # `:platform, :stack_deployer, async: true|false`) and
          # idempotent: the deployer noops when the member's commit is
          # already on the rollup branch (`{:ok, :already_merged}`),
          # when the review-stage validations haven't all passed
          # (`{:ok, :not_ready}`), or when the task is not actually a
          # stack member. Calling it on every plan completion in this
          # branch is therefore safe and is the missing seam this task
          # closes — without it, members that complete via plan-engine
          # advance never get assembled onto the stack rollup.
          #
          # Task 019f487d stage 3: fire the stack-level deploy dispatch
          # BEFORE the per-member rollup merge trigger. This is the
          # canonical "last member's stage_complete → open the rollup
          # PR" gate. `Stacks.dispatch_stack_deploy/1` is a no-op when
          # any member is still pending validations (that's the whole
          # `deploy_ready?/1` predicate) and uses a compare-and-swap on
          # `stacks.status` so concurrent double-fires collapse to
          # exactly one telemetry event. Members 1..N-1 exit as `:noop`;
          # only the last member's completion trips the transition.
          #
          # Ordering rationale: `dispatch_stack_deploy` must run BEFORE
          # `handle_member_transition` because the merge stamp fires
          # its own `maybe_open_stack_pr` trigger, which would then race
          # this stage's telemetry emission. Running dispatch first
          # deterministically flips the stack to `"deploying"` and emits
          # the `:dispatched` event; the downstream merge trigger then
          # opens the PR via `deploy_validations_ready?/1`'s
          # `%Stack{status: "deploying"}` pass-through.
          {:ok, completed} = complete_plan(plan, :stack_member)
          _ = Stacks.dispatch_stack_deploy(task.stack_id)
          _ = StackDeployer.handle_member_transition(task, :plan_completed, :in_review)
          Repo.preload(completed, stages_query())

        true ->
          # `_with_repos` — see `build_deploy_plan/1`. The `:skip` split
          # below and `skip_reason/1` read only `strategy["type"]`, which
          # the repo set does not touch: a stack member still emits no
          # deploy stage at all.
          strategy = Tasks.resolve_deploy_strategy_with_repos(task)

          # Recorded branch — see the identical call in `build_deploy_plan/1`
          # for why it is recorded here rather than derived by the consumer.
          case DeployStageBuilder.build_stage(
                 strategy,
                 max_position(stages) + 1,
                 StackDeployer.member_branch_for(task)
               ) do
            :skip ->
              # No deploy stage to inject — complete normally. The reason is
              # split by strategy type because `:skip` collapses two strategies
              # with OPPOSITE terminal meanings; see `skip_reason/1`.
              {:ok, completed} = complete_plan(plan, skip_reason(strategy))
              Repo.preload(completed, stages_query())

            stage_def ->
              if task.status in @deployable_statuses do
                inject_deploy_stage(plan, task, stage_def, strategy)
              else
                # Task can't transition to deploying (e.g. backlog, planning) —
                # complete normally. Warning, not info: this branch is exactly
                # where a task with a wrong status silently piles up looking
                # like a clean completion, so the message names the id AND the
                # status that disqualified it.
                Logger.warning(
                  "[PlanEngine] NOT injecting deploy stage for task #{task.id} - " <>
                    "status #{task.status} is not in @deployable_statuses; " <>
                    "plan completed without deploy"
                )

                {:ok, completed} = complete_plan(plan, :not_deployable)
                Repo.preload(completed, stages_query())
              end
          end
      end
    end
  end

  # `DeployStageBuilder.build_stage/3` returns a bare `:skip` for TWO strategy
  # types — `"none"` and `"no_op_wait_for_rollup"` — and they mean opposite
  # things for the task's terminal status:
  #
  #   * `"none"`                 → no deploy step will ever run. The plan is
  #                                fully passed, so the task is finished.
  #   * `"no_op_wait_for_rollup"` → the deploy has NOT happened; it ships via a
  #                                stack rollup PR that may not even be open
  #                                yet. Sweeping the task to `done` here would
  #                                mark an undeployed task deployed — the exact
  #                                bug family task 019fa2fc exists to fix.
  #
  # Genuine stack members never reach this arm: `dispatch_deploy_for_task/1`
  # rejects on any non-nil `stack_id` and the earlier `cond` arm catches them.
  # The residual hole this split closes is a task with `stack_id == nil`
  # carrying an explicit `no_op_wait_for_rollup` override (task-level
  # `deploy_strategy`, or a project `default_strategy`), which resolves to
  # `:skip` without ever touching the stack path.
  #
  # The discrimination lives HERE rather than inside `PlanCompletion` because
  # this is the only place that still holds the already-resolved `strategy`;
  # re-deriving it downstream would be a second, independently-drifting
  # derivation of the same fact, which is precisely the shape
  # `PlanCompletion`'s moduledoc argues against. Task 019fa2fc stage 2.
  defp skip_reason(%{"type" => "no_op_wait_for_rollup"}), do: :awaiting_rollup
  defp skip_reason(_strategy), do: :no_deploy_strategy

  defp inject_deploy_stage(plan, task, stage_def, strategy) do
    # Invariant repair (task 019f9b34): a plan that hosts a running deploy stage
    # is not `completed`. This seam owns that invariant — with the `advance/1`
    # guard in place nothing should reach here with a completed plan, so the
    # warning firing is itself the signal that another premature-completion path
    # exists.
    plan = uncomplete_plan_for_deploy(plan)

    # Create the deploy stage record
    {:ok, deploy_stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: stage_def.position,
        name: stage_def.name,
        description: stage_def.description
      })

    # Create validation records for the deploy stage
    for validation_def <- stage_def.validations do
      attrs =
        %{
          stage_id: deploy_stage.id,
          kind: validation_def.kind
        }
        |> maybe_put_evaluation_payload(validation_def)

      {:ok, _} = Tasks.create_validation(attrs)
    end

    # Start the deploy stage immediately
    {:ok, running_stage} = transition_stage(deploy_stage, "running")

    # Transition the task to "deploying"
    case Tasks.transition_task(task, "deploying") do
      {:ok, updated_task} ->
        Logger.info(
          "[PlanEngine] injected deploy stage (#{stage_def.name}) for task #{task.id}, " <>
            "strategy: #{strategy["type"]}"
        )

        # Strategies whose deploy is executed entirely inside the platform
        # (currently `project_files`) do not require an agent to push
        # evidence — `Platform.Deploy.dispatch/3` runs the handler and
        # evaluates the stage's own validations. Other strategies no-op
        # here; the assigned agent (or a webhook) supplies the evidence.
        _ = Platform.Deploy.dispatch(updated_task, strategy, running_stage)

        # Broadcast plan update so the board refreshes
        Tasks.broadcast_board({:plan_updated, Repo.get!(Plan, plan.id)})

        Repo.preload(Repo.get!(Plan, plan.id), stages_query())

      {:error, reason} ->
        Logger.warning(
          "[PlanEngine] failed to transition task #{task.id} to deploying: #{inspect(reason)}"
        )

        # Roll back the deploy stage so we don't leave an orphaned running
        # stage when the task couldn't actually enter the deploying status.
        transition_stage(deploy_stage, "failed")

        # Still broadcast so the board shows the current state
        Tasks.broadcast_board({:plan_updated, Repo.get!(Plan, plan.id)})

        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  # Pull `:evaluation_payload` (or string-keyed equivalent) out of a validation
  # definition map and merge it into the create-validation attrs map. Used both
  # for deploy-stage builder output (which won't carry one) and for plan ingestion
  # paths that pass planner-authored e2e_behavior payloads through.
  defp maybe_put_evaluation_payload(attrs, validation_def) when is_map(validation_def) do
    case Map.get(validation_def, :evaluation_payload) ||
           Map.get(validation_def, "evaluation_payload") do
      nil -> attrs
      payload -> Map.put(attrs, :evaluation_payload, payload)
    end
  end

  defp maybe_put_evaluation_payload(attrs, _), do: attrs

  defp max_position(stages) do
    stages
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> 0 end)
  end

  # Flip a `completed` plan back to `approved` immediately before a deploy stage
  # is injected into it. `Plan.changeset/2` validates status by inclusion with no
  # transition graph, so completed -> approved is a legal write. Any other status
  # passes through untouched.
  defp uncomplete_plan_for_deploy(%Plan{status: "completed"} = plan) do
    Logger.warning(
      "[PlanEngine] plan #{plan.id} (task #{plan.task_id}) was `completed` while a deploy " <>
        "stage was about to be injected — reverting to `approved`. A plan hosting a running " <>
        "deploy stage must never be completed; see task 019f9b34."
    )

    case plan |> Plan.changeset(%{status: "approved"}) |> Repo.update() do
      {:ok, reopened} ->
        reopened

      {:error, reason} ->
        Logger.warning(
          "[PlanEngine] failed to revert plan #{plan.id} to approved: #{inspect(reason)}"
        )

        plan
    end
  end

  defp uncomplete_plan_for_deploy(%Plan{} = plan), do: plan

  # The ONLY writer of `plan.status = "completed"` in the codebase, which is
  # what makes it a true single seam for the follow-on task advance.
  #
  # `reason` is threaded from the call site (task 019fa2fc) because each branch
  # already knows WHY it is completing the plan — see
  # `Platform.Tasks.PlanCompletion` for why that beats re-deriving the target
  # from the task's status after the fact.
  #
  # Ordering is load-bearing: advance the task BEFORE broadcasting, so any live
  # router observing `{:plan_updated, completed}` sees an already-advanced task
  # rather than racing it.
  defp complete_plan(%Plan{} = plan, reason) do
    case plan
         |> Plan.changeset(%{status: "completed"})
         |> Repo.update() do
      {:ok, completed} ->
        _ = PlanCompletion.advance_task(completed, reason)
        Tasks.broadcast_board({:plan_updated, completed})
        {:ok, completed}

      error ->
        error
    end
  end

  defp stages_query do
    [stages: from(s in Stage, order_by: [asc: s.position])]
  end

  # ── Telemetry ───────────────────────────────────────────────────────────

  defp emit_stage_telemetry(%Stage{} = stage, from_status, completed_by \\ nil) do
    base = %{
      stage_id: stage.id,
      plan_id: stage.plan_id,
      from: from_status,
      to: stage.status
    }

    # Only `passed` transitions carry an asserting actor — for every other
    # transition the key is absent rather than nil, so a consumer can tell
    # "swept" (no key) from "asserted by X" without a sentinel value.
    metadata =
      if stage.status == "passed" and not is_nil(completed_by) do
        Map.put(base, :completed_by, completed_by)
      else
        base
      end

    :telemetry.execute(
      [:platform, :tasks, :stage_transitioned],
      %{system_time: System.system_time()},
      metadata
    )

    # Broadcast to the board PubSub topic so TaskRouter can react.
    #
    # DEFERRED PAST COMMIT ON PURPOSE (task 019ff788). Every consumer of this
    # message RE-READS the database off it — `TaskRouter`'s review-failure
    # bounce calls `Tasks.list_validations/1` from its own process. Emitting
    # from inside `evaluate_validation/2`'s `Repo.transaction` published the
    # transition while the writer's rows were still uncommitted, so a fast
    # subscriber read `status: "pending"` for a validation this very
    # transaction had just marked `failed`. The observed consequence: an
    # empty failed-validation list, `ReviewDisposition.classify_all([])`, and
    # a correctly-marked un-runnable review spending a round of the bound —
    # the one outcome the bound exists to prevent.
    #
    # LOAD DIRECTION IS INVERTED, which is why this hid: under eight busy
    # routers the subscriber never won the race (8/8 correct); a single IDLE
    # router with a ~300 ms quiet gap lost it every time (0/8). Production
    # sits in the quiet state — a router is idle while a reviewer composes a
    # verdict. Any probe for this must exercise the idle path.
    #
    # `defer_broadcast/1` is a no-op wrapper outside a
    # `deferring_broadcasts/1` scope, so callers that transition a stage
    # without a surrounding transaction still broadcast synchronously.
    defer_broadcast({:stage_transitioned, stage})
  end

  # ── Post-commit broadcast deferral ──────────────────────────────────────
  #
  # Scoped via the process dictionary rather than `Repo.in_transaction?/0`:
  # the sandbox owns a connection-level transaction in test, so that
  # predicate cannot distinguish "inside OUR transaction" from "checked out
  # by the test", and a mis-read would silently drop every broadcast under
  # test. An explicit scope is decidable in both environments.
  #
  # Scope is limited to `{:stage_transitioned, _}` (task 019ff788 fence).
  # The `{:plan_updated, _}` emits carry the same shape of hazard, but
  # changing them is a separate, separately-revertible decision.
  @deferred_broadcasts_key :platform_plan_engine_deferred_broadcasts

  # Run `fun` (which owns a `Repo.transaction`) with stage broadcasts queued
  # instead of published. On commit the queue is flushed IN ORDER; on
  # rollback it is DISCARDED — a transition that did not commit must not be
  # announced, which the pre-commit emit could not honour either way.
  defp deferring_broadcasts(fun) do
    case Process.get(@deferred_broadcasts_key) do
      # Already inside an outer scope — let the outermost one flush, so a
      # nested transaction cannot publish before the outer commit.
      nil ->
        Process.put(@deferred_broadcasts_key, [])

        try do
          result = fun.()

          case result do
            {:ok, _} -> flush_deferred_broadcasts()
            _ -> :ok
          end

          result
        after
          Process.delete(@deferred_broadcasts_key)
        end

      _queued ->
        fun.()
    end
  end

  defp defer_broadcast(message) do
    case Process.get(@deferred_broadcasts_key) do
      nil ->
        Tasks.broadcast_board(message)

      queued ->
        Process.put(@deferred_broadcasts_key, [message | queued])
        :ok
    end
  end

  defp flush_deferred_broadcasts do
    queued = Process.get(@deferred_broadcasts_key, [])
    Process.put(@deferred_broadcasts_key, [])

    queued
    |> Enum.reverse()
    |> Enum.each(&Tasks.broadcast_board/1)
  end

  defp emit_validation_telemetry(%Validation{} = validation) do
    :telemetry.execute(
      [:platform, :tasks, :validation_evaluated],
      %{system_time: System.system_time()},
      %{
        validation_id: validation.id,
        stage_id: validation.stage_id,
        kind: validation.kind,
        status: validation.status
      }
    )
  end
end
