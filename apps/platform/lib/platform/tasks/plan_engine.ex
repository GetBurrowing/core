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

  ## The pass invariant (task 01a0e8c1 stage 2)

  `transition_stage/4` is the ONE write that makes a stage `passed`, and it
  refuses to make it while any of the stage's validation rows is `pending`,
  `running` or `failed`, or is a prior-round failed row (`owed?/2`). It
  returns `{:error, {:unsatisfied_validations, [%{id, kind, status}]}}`, logs
  an error naming the stage and each row, and emits
  `[:platform, :tasks, :stage_pass_refused]`. The verdict should never ask for
  a pass the guard refuses; the guard is the belt behind it, so no future
  caller path can pass a stage over an unmet row.

  `skipped` counts as SATISFIED here, deliberately. It is the designed product
  of `skip_unevaluated_validations/2` (task 01a0665e), which runs just before
  the transition in the same transaction, and of a human skip. Making
  `skipped` block would wedge every 01a0665e gate. So the rule is "every row
  passed or skipped", not "every row passed".

  A refused pass leaves the stage as it was and does not advance the plan;
  the validation write that triggered it still commits. Skips written for a
  pass that is then refused are rolled back to a savepoint (`pass_stage/3`),
  so no row is left `skipped` on a stage that stayed running.
  """

  import Ecto.Query

  alias Platform.Repo
  require Logger

  alias Platform.Architecture.StageAudit
  alias Platform.Tasks
  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.EvidenceCarry
  alias Platform.Tasks.MemberReviewEntry
  alias Platform.Tasks.PlanCompletion
  alias Platform.Tasks.PostCommit
  alias Platform.Tasks.ReviewDisposition
  alias Platform.Orchestration.ExecutionSpace

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
      # `transition_stage/4` is the central execution boundary and checks the
      # owning task before every transition to running.
      transition_stage(stage, "running")
    end
  end

  defp require_stage_task_not_quarantined(%Stage{} = stage) do
    case Tasks.get_plan(stage.plan_id) do
      %Plan{} = plan -> Tasks.require_not_quarantined_task(plan.task_id)
      nil -> {:error, :task_not_found}
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
  # Task 019fe383: the wording used to matter FUNCTIONALLY, because
  # `e2e_host_stage_name?/1` adopted any stage whose name merely contained
  # "review" or "validation" as the e2e host — a remediation stage called
  # "Fix the failed review" would have been silently adopted the next time a
  # plan was built. That name-based adoption path is gone: the engine now
  # only ever adopts a stage the author explicitly marks `"e2e_host": true`,
  # so this stage's name carries no such hazard anymore. The wording is kept
  # descriptive rather than reworded back to something trigger-shaped,
  # purely so a future reader is not left wondering why it was ever chosen.
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
  it shift by +1) so the gate still re-runs afterwards, carries BOTH the
  failed case's planner-authored `evaluation_payload` (setup, actions,
  expected) and the gate agent's evidence verbatim as its description (task
  01a08e81), and gets the ordinary
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
          # `change/2`, not `Validation.changeset/2`: legacy e2e rows with no payload must not crash remediation, and a re-pend never writes the payload.
          validation
          |> Ecto.Changeset.change(%{
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
  # `asc: :id` IS WHAT DELIVERS THAT (ticket 01a089e6). `position` on its own
  # cannot, and this comment used to claim it did. `position` is not unique:
  # `stages` carries exactly one index and it is `index(:stages, [:plan_id])`
  # — plan_id alone, plain, with no unique index on `(plan_id, position)` and
  # no index on `position` at all (`20260320120000_create_tasks_tables.exs:110`)
  # — `Stage.changeset/2` validates `position` as required and nothing more,
  # and the only place distinctness is written down is prose in `plan_create`'s
  # tool description. So the very legacy pair the paragraph above reasons about
  # can sit at ONE position, and there `ORDER BY position LIMIT 1` returns
  # whichever row the scan happened to hand the sort node. In exactly the
  # scenario the paragraph was written for, the engine could open the wrong
  # remediation stage — and a comment asserting a guarantee is precisely what
  # stops the next reader checking whether the query provides one.
  #
  # What `asc: :id` buys is a TOTAL, STABLE order. Not "creation order": `id`
  # is `Platform.Types.UUIDv7`, whose `rand_a` is a per-millisecond monotonic
  # counter, so the earlier row sorts first in the ordinary case, but the
  # counter WRAPS after 4096 ids inside one millisecond and the timestamp is a
  # WALL CLOCK, so a step backwards inverts a pair. Total and stable is the
  # property this call site actually needs — `id` is the primary key so it can
  # never tie itself, and one row therefore wins every time.
  #
  # The consequence of not having it was MEASURED, not reasoned about, and it
  # is worse than "unspecified once": successive rounds of the SAME gate
  # ALTERNATE between the two rows. Four consecutive rounds against a tied pair
  # picked LATER, EARLIER, LATER, EARLIER. The mechanism is this function's own
  # caller — `reuse_remediation_stage/1` `Repo.update!`s the row it chose, and
  # an UPDATE writes a new row version at the end of the heap, so the next
  # sequential scan hands the sort node the OTHER row first. The effect is one
  # gate's accumulated findings split across two stages, each holding half the
  # rounds, which defeats the one-stage bound above. With the tiebreak the same
  # four rounds picked EARLIER every time.
  #
  # A unique index on `(plan_id, position)` is the OTHER repair and it stays
  # parked in 01a089e6. The paragraph above says legacy duplicate pairs
  # already exist, so that migration has a known-nonempty adversary and needs
  # a production census first; this makes the read deterministic whether or
  # not the index ever lands.
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
    |> order_by([s], asc: s.position, asc: s.id)
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
        status: "pending",
        # Task 01a0588e. Engine-emitted, so structurally marked as such.
        origin: "synthesized"
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

  # Each Finding carries TWO texts, both VERBATIM, in this order (task
  # 01a08e81):
  #
  #   1. the case itself — the validation's planner-authored
  #      `evaluation_payload`, keys ordered setup, actions, expected, then any
  #      others (nothing dropped); and
  #   2. the gate agent's ruling — its evidence map, unchanged.
  #
  # The payload is read from the validation ROW, never from anything the
  # reviewer echoed. Before this the description carried the evidence alone,
  # so an executor saw only the reviewer's paraphrase of `expected`, which can
  # stop short of its last clause: the executor closes half the finding and
  # the identical case fails on re-review. A summary of either text would
  # reintroduce exactly that loss.
  #
  # Both are JSON-encoded, not rendered as raw text. `round_count/1` counts
  # `^## Round \d+$` lines over the WHOLE accumulated description, and a
  # planner-authored string can contain such a line, or a ``` run that closes
  # the fence early. JSON puts every string on one line inside quotes, so
  # neither can escape. The price is that quotes, backslashes and newlines
  # read escaped; byte-identity holds after `Jason.decode!/1`.
  defp remediation_description(gate, failed, feedback) do
    findings =
      failed
      |> Enum.with_index(1)
      |> Enum.map(fn {v, i} ->
        amendments = amendments_of(v)

        "## Finding #{i} (e2e_behavior #{v.id})\n\n" <>
          case_heading(amendments) <>
          render_payload(v.evaluation_payload) <>
          render_amendments(amendments) <>
          "\n\n### The gate agent's ruling (evidence)\n\n" <>
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

  # Task 01a0acb4 stage 3. A case corrected through `validation_payload_amend`
  # after authoring must not read as planner-authored: the heading says the text
  # is the AMENDED one, and the append-only `payload_amendments` history follows
  # it, so the remediation executor sees what the case said before and who
  # changed it, and why. The history is JSON-encoded for the same reason as the
  # payload: an amendment `reason` is free text and can carry a `## Round N`
  # line or a ``` run. An UNAMENDED row takes neither branch and renders
  # byte-identical to the renderer before this change.
  defp amendments_of(%{payload_amendments: [_ | _] = amendments}), do: amendments
  defp amendments_of(_), do: []

  defp case_heading([]),
    do: "### The case (planner-authored evaluation_payload, verbatim)\n\n"

  defp case_heading(_amendments),
    do: "### The case (evaluation_payload as amended, verbatim)\n\n"

  defp render_amendments([]), do: ""

  defp render_amendments(amendments) do
    n = length(amendments)
    noun = if n == 1, do: "amendment", else: "amendments"

    "\n\n### This case was amended after authoring (#{n} #{noun})\n\n" <>
      "```json\n" <> encode_amendments(amendments) <> "\n```"
  end

  defp encode_amendments(amendments) do
    case Jason.encode(amendments, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(amendments)
    end
  end

  @payload_key_order ~w(setup actions expected)

  # Legacy rows can carry no payload (the changeset requires one only for rows
  # written since); they render a placeholder rather than an empty block.
  defp render_payload(payload) when payload in [nil, %{}],
    do: "(this validation carries no evaluation_payload)"

  defp render_payload(payload) when is_map(payload) do
    "```json\n" <> encode_payload(payload) <> "\n```"
  end

  defp encode_payload(payload) do
    stringified = Map.new(payload, fn {k, val} -> {to_string(k), val} end)
    {known, rest} = Map.split(stringified, @payload_key_order)

    pairs =
      Enum.flat_map(@payload_key_order, fn k ->
        if Map.has_key?(known, k), do: [{k, Map.fetch!(known, k)}], else: []
      end) ++ Enum.sort_by(rest, &elem(&1, 0))

    case Jason.encode(Jason.OrderedObject.new(pairs), pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload)
    end
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
            evidence: EvidenceCarry.carry_prior_rulings(validation, evidence),
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

          all_validations_resolved?(stage) ->
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
        # Task 01a136c1: deferred to AFTER the enclosing transaction commits.
        # The merge child (`async: true`) reads through its own connection,
        # so firing it here, before commit, showed it the validation this
        # transaction just passed as still pending and it declined the merge
        # as `{:stages_pending, n - 1, n}` with nothing to retry it. The
        # deploy promote in `promote_member_to_deploying/1` reads the stamp
        # the merge writes, so it is deferred too, queued right after it.
        StackDeployer.handle_member_transition_after_commit(task, :validation_passed, :in_review)
        PostCommit.run_after_commit(fn -> promote_member_to_deploying(task) end)
        :ok
    end
  rescue
    # The hook is best-effort — never crash evaluate_validation if the
    # deployer-side lookup fails.
    error ->
      Logger.warning(
        "[PlanEngine] stack-member merge re-trigger lookup failed: " <>
          Exception.message(error)
      )

      :ok
  end

  # Queued AFTER the merge thunk above, so in `async: false` mode the stamp
  # the merge writes is committed before this reload reads it.
  defp promote_member_to_deploying(%Task{} = task) do
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
  rescue
    # The hook is best-effort — never crash evaluate_validation if the
    # deployer-side dispatch or the deploy promote fails.
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
                pass_and_advance_plan(plan, stages, stage, [], completed_by)

              {:passed_with_unevaluated, rows} ->
                pass_and_advance_plan(plan, stages, stage, rows, completed_by)

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

  @doc """
  Re-route any `e2e_behavior` validations in a list of planner-authored
  stage_input maps to a single task-level review stage.

  Behavior:
  - If any stage already has `kind: "e2e_behavior"` validations, strip them
    from that stage and collect them all into one final review stage.
  - If exactly one stage explicitly opts in via `"e2e_host": true`, append the
    e2e_behavior validations to its validations list. Otherwise, ALWAYS
    synthesize a new "Task-level review" stage at `max_position + 1` carrying
    just the lifted e2e_behavior validations — an existing stage is never
    adopted by NAME alone (task 019fe383: a stage merely named "...review" or
    "...validation" used to be silently adopted as the host, which could
    deadlock the task when that stage's other work never advanced).
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
  Refuse a plan where MORE THAN ONE stage explicitly opts in as the e2e host.

  Returns `:ok`, or `{:error, %{reason: :multiple_e2e_hosts, hosts: [%{stage_name:,
  stage_position:}, ...], e2e_case_count:}}` naming every opted-in stage.

  Reads RAW planner stages, so it must run BEFORE
  `route_e2e_behavior_validations/1`.

  Task 019fe383: this used to also refuse a plan whose stage NAME merely
  CONTAINED "review" or "validation", on the theory that the engine would
  silently adopt that stage as the e2e host. That name-matching adoption
  path is now gone entirely (see `route_e2e_behavior_validations/1` and
  `attach_e2e_validations_to_review_stage/2`) — the engine ALWAYS synthesizes
  a fresh "Task-level review" stage unless an author explicitly opts a stage
  in with `"e2e_host": true`. With no name-based adoption left, the only way
  two stages can genuinely collide over the host role is two explicit
  opt-ins, which is what this now detects.
  """
  # DISPOSITION: reject, not warn.
  #
  # A plan with two `"e2e_host": true` stages is a genuine structural
  # ambiguity the author must resolve — the engine cannot silently pick one
  # without leaving the other's opt-in dead code the author never asked to
  # write. Rejection happens pre-persistence and leaves the author free to
  # drop the extra opt-in and retry.
  @spec detect_e2e_host_collision([map()]) :: :ok | {:error, map()}
  def detect_e2e_host_collision(stages_input) when is_list(stages_input) do
    e2e_case_count =
      Enum.reduce(stages_input, 0, fn stage, acc ->
        acc + Enum.count(stage_validations_field(stage), &e2e_behavior_validation?/1)
      end)

    opted_in_hosts =
      stages_input
      |> Enum.with_index(1)
      |> Enum.filter(fn {stage, _idx} -> e2e_host_opt_in?(stage) end)

    cond do
      # 1. No e2e cases at all — nothing to host, so firing here would reject
      #    plans the bug cannot touch.
      e2e_case_count == 0 ->
        :ok

      # 2. Zero or one explicit opt-in — zero means the engine will
      #    unconditionally synthesize a task-level review stage, one means
      #    that stage is the unambiguous host. Neither can collide.
      length(opted_in_hosts) <= 1 ->
        :ok

      true ->
        # 3. Two or more stages both explicitly claim the host role — a
        #    genuine structural conflict, not an inference from prose.
        {:error,
         %{
           reason: :multiple_e2e_hosts,
           hosts:
             Enum.map(opted_in_hosts, fn {stage, idx} ->
               %{
                 stage_name: stage_field(stage, "name"),
                 stage_position: stage_field(stage, "position") || idx
               }
             end),
           e2e_case_count: e2e_case_count
         }}
    end
  end

  def detect_e2e_host_collision(_other), do: :ok

  @doc """
  Regression guard: refuse a plan where e2e_behavior cases exist but, after
  `route_e2e_behavior_validations/1` runs, there is no single stage hosting
  all of them (neither an explicit `"e2e_host": true` opt-in nor the
  freshly-synthesized "Task-level review" stage).

  Returns `:ok`, or `{:error, %{reason: :missing_e2e_host, e2e_case_count:}}`.

  Task 019fe383: since `attach_e2e_validations_to_review_stage/2` now ALWAYS
  synthesizes a task-level review stage when no stage opts in, this should be
  structurally unreachable by construction — there is no longer a code path
  that drops e2e cases on the floor. Rather than assert that invariant by
  NAME (which is exactly the failure mode this ticket is about — a detector
  restating an assumption instead of checking it), this actually re-derives
  the outcome by running the real rewrite pipe and counting where the cases
  landed. If a future change to the attach logic reintroduces a gap, this is
  the detector that catches it, rather than the task silently dispatching
  with an unhosted e2e case.

  Reads RAW planner stages, so — like `detect_e2e_host_collision/1` — it must
  run BEFORE the real, persisted call to `route_e2e_behavior_validations/1`
  (this function's own internal use of it is a pure, side-effect-free
  simulation for verification only).
  """
  @spec detect_missing_e2e_host([map()]) :: :ok | {:error, map()}
  def detect_missing_e2e_host(stages_input) when is_list(stages_input) do
    e2e_case_count =
      Enum.reduce(stages_input, 0, fn stage, acc ->
        acc + Enum.count(stage_validations_field(stage), &e2e_behavior_validation?/1)
      end)

    case e2e_case_count do
      0 ->
        :ok

      _ ->
        host_stages =
          stages_input
          |> route_e2e_behavior_validations()
          |> Enum.filter(fn stage ->
            Enum.any?(stage_validations_field(stage), &e2e_behavior_validation?/1)
          end)

        case host_stages do
          [_single_host] -> :ok
          _ -> {:error, %{reason: :missing_e2e_host, e2e_case_count: e2e_case_count}}
        end
    end
  end

  def detect_missing_e2e_host(_other), do: :ok

  @doc """
  Refuse a plan whose `manual_approval` gate does not NAME the UI surface it
  will show.

  Returns `:ok`, or `{:error, %{stage_name:, stage_position:, validation_index:,
  reason:}}` for the FIRST offending stage.

  The name is carried as a `ui_surface` string inside the validation's
  `evaluation_payload` map. Missing, nil, non-binary, or blank after
  `String.trim/1` all count as UNNAMED.

  Reads RAW planner stages (string or atom keys), so it must run BEFORE
  anything rewrites or persists the stage list.

  ## What this proves, and what it does not

  A required field proves NAMING, not truth. Nothing here checks that the stage
  touches any UI, and nothing checks the named surface exists — an author who
  wants a gate can write any string and proceed. The honest reading is "the gate
  must state its subject", not "gates that cannot show UI are refused". That is
  still worth the friction: it makes the gate auditable and gives the rejection
  rate something to correlate against.

  Deliberately NOT decided by `ui_touching?/1`. That is a prose heuristic over
  the stage description; this rule is an EXPLICIT FIELD, mirroring the `e2e_host`
  opt-in for the reason recorded in `detect_e2e_host_collision/1`'s DISPOSITION
  comment — an expressed field, never inferred from prose.

  ## PROBE RECORD (01a00b91 stage 5)

  Two mutations were run against this function, one at a time, reverting to a
  clean tree between them (two probes on one predicate absorb each other and
  both report a false kill).

  PROBE A — always return `:ok`. Predicted the stage-3 refusal test detonates.
  KILLED as predicted, and by five more: the unnamed, blank-string, atom-key,
  non-binary and first-offender cases here all detonate too. The refusal side
  is pinned six ways over, not one.

  PROBE B — always return `{:error, ...}`. Predicted BOTH the named-surface
  persistence test AND the direction control (a plan with no `manual_approval`
  at all) detonate. BOTH KILLED — neither side is unpinned. Eight further tests
  in the tool surface detonated with them, which is the expected blast radius
  of a guard that refuses every plan; it is also the reason the direction
  control is worth stating separately, since without it "refuses everything"
  would still look like a working detector from the refusal case alone.

  No survivor. No coverage hole found, and no behaviour was changed.
  """
  @spec detect_unnamed_manual_gate([map()]) :: :ok | {:error, map()}
  def detect_unnamed_manual_gate(stages_input) when is_list(stages_input) do
    stages_input
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {stage, idx} ->
      stage
      |> stage_validations_field()
      |> Enum.with_index(1)
      |> Enum.find_value(nil, fn {validation, v_idx} ->
        if manual_approval_validation?(validation) and not names_ui_surface?(validation) do
          {:error,
           %{
             stage_name: stage_field(stage, "name"),
             stage_position: stage_field(stage, "position") || idx,
             validation_index: v_idx,
             reason: :unnamed_ui_surface
           }}
        end
      end)
    end)
  end

  def detect_unnamed_manual_gate(_other), do: :ok

  defp manual_approval_validation?(v) when is_map(v) do
    (Map.get(v, "kind") || Map.get(v, :kind)) == "manual_approval"
  end

  defp manual_approval_validation?(_), do: false

  defp names_ui_surface?(v) when is_map(v) do
    payload = Map.get(v, "evaluation_payload") || Map.get(v, :evaluation_payload)

    surface =
      case payload do
        p when is_map(p) -> Map.get(p, "ui_surface") || Map.get(p, :ui_surface)
        _ -> nil
      end

    is_binary(surface) and String.trim(surface) != ""
  end

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
    # Task 019fe383: name-based adoption is gone. The ONLY non-synthesis path
    # is the explicit `"e2e_host": true` opt-in — an expressed field, never
    # inferred from a stage's prose.
    case Enum.find_index(stages_input, &e2e_host_opt_in?/1) do
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
  Whether a stage was written by a PLANNER rather than by the engine.

  Takes a `%Stage{}` or a raw stage map (string- or atom-keyed) and reads
  its `origin` and nothing else. Absence reads as authored: rows written
  before the marker existed, and every writer that does not opt in, are
  planner-authored by construction.

  This and `Tasks.authored_stage_count/1` are the ONLY sanctioned
  authored/synthesized predicates. Do not re-derive the distinction from a
  stage's name or description — see `Platform.Tasks.Stage`'s `@origins`
  note for why a prose-keyed classifier fails open.
  """
  @spec authored_stage?(Stage.t() | map()) :: boolean()
  def authored_stage?(%Stage{origin: origin}), do: origin != "synthesized"

  def authored_stage?(stage) when is_map(stage),
    do: stage_field(stage, "origin") != "synthesized"

  @doc """
  Strip any caller-supplied `origin` from raw planner stage input.

  `origin` is the engine's marker. A planner that hands us
  `"origin": "synthesized"` in an MCP payload would otherwise be able to
  disguise its own stage as the engine's and slip past any authored-stage
  requirement, so the key is removed from planner input BEFORE the engine
  gets a chance to add its own. Run this ahead of
  `route_e2e_behavior_validations/1`, never after: afterwards it would
  erase the engine's own marker.
  """
  @spec strip_planner_origin([map()]) :: [map()]
  def strip_planner_origin(stages_input) when is_list(stages_input),
    do: Enum.map(stages_input, &strip_planner_origin_from_stage/1)

  def strip_planner_origin(other), do: other

  defp strip_planner_origin_from_stage(stage) when is_map(stage),
    do: stage |> Map.delete("origin") |> Map.delete(:origin)

  defp strip_planner_origin_from_stage(other), do: other

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
      "validations" => e2e_validations,
      # Task 01a0588e. The STRUCTURAL marker that this stage is the engine's,
      # not a planner's. Anything downstream that needs to know "did the
      # planner author an implementation stage?" reads this key — never the
      # name above ("Task-level review") or the description above, both of
      # which are template copy a reword would silently invalidate.
      "origin" => "synthesized"
    }
  end

  @doc """
  Build deploy stages for a task based on its resolved deploy strategy.

  Looks up the task's project deploy strategy via `Tasks.resolve_deploy_strategy/1`,
  then calls `DeployStageBuilder.build_stage/4` to produce stage definitions.

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
        branch = StackDeployer.member_branch_for(task)

        case DeployStageBuilder.build_stage(
               strategy,
               next_position,
               branch,
               BranchProvisioner.branch_tip_shas(strategy, branch)
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

  # `opts[:keep_started_at]` — the internal failed->running flip-reopen in
  # `maybe_advance_resolved_stage/1` re-judges the SAME round it is reopening,
  # so it must not restart the round clock: a fresh `started_at` would make
  # every row of that round look prior-round (see `owed?/2`) and wedge the
  # designed failed->passed flip (task 01a0e8c1 stage 1).
  defp transition_stage(stage, new_status, completed_by \\ nil, opts \\ []) do
    with :ok <- require_stage_transition_not_quarantined(stage, new_status) do
      do_guarded_transition_stage(stage, new_status, completed_by, opts)
    end
  end

  defp require_stage_transition_not_quarantined(stage, "running"),
    do: require_stage_task_not_quarantined(stage)

  defp require_stage_transition_not_quarantined(_stage, _new_status), do: :ok

  defp do_guarded_transition_stage(stage, new_status, completed_by, opts) do
    allowed = Map.get(@valid_stage_transitions, stage.status, [])

    cond do
      new_status not in allowed ->
        {:error, :invalid_transition}

      new_status == "passed" ->
        case unsatisfied_validations(stage) do
          [] -> do_transition_stage(stage, new_status, completed_by, opts)
          unsatisfied -> refuse_pass(stage, unsatisfied)
        end

      true ->
        do_transition_stage(stage, new_status, completed_by, opts)
    end
  end

  # The pass guard's row set: a row is unsatisfied when its status is unmet
  # (`pending`/`running`/`failed`) or when stage 1's `owed?/2` says so. The
  # second clause is subsumed today (a prior-round failed row is `failed`) and
  # is kept so the guard cannot drift from the verdict if `owed?/2` grows.
  defp unsatisfied_validations(%Stage{} = stage) do
    validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))
    round = round_cutoff(stage, validations)
    unmet = Validation.unmet_statuses()

    validations
    |> Enum.filter(&(&1.status in unmet or owed?(round, &1)))
    |> Enum.map(&%{id: &1.id, kind: &1.kind, status: &1.status})
  end

  defp refuse_pass(%Stage{} = stage, unsatisfied) do
    Logger.error(
      "[PlanEngine] refused to pass stage #{stage.id}: unsatisfied validations " <>
        Enum.map_join(unsatisfied, ", ", &"#{&1.kind} #{&1.id} (#{&1.status})")
    )

    :telemetry.execute(
      [:platform, :tasks, :stage_pass_refused],
      %{system_time: System.system_time(), count: length(unsatisfied)},
      %{
        stage_id: stage.id,
        plan_id: stage.plan_id,
        validation_ids: Enum.map(unsatisfied, & &1.id),
        validations: unsatisfied
      }
    )

    {:error, {:unsatisfied_validations, unsatisfied}}
  end

  # Pass `stage`, first moving each `could_not_evaluate` row in `skip_rows`
  # `failed -> skipped`. The skips and the transition share a SAVEPOINT: if
  # the guard in `transition_stage/4` refuses the pass, the skips (and the
  # task stamp / engagement they wrote) are rolled back so no row is left
  # `skipped` on a stage that stayed running. Ecto's nested transactions do
  # not use savepoints (an inner rollback aborts the whole outer transaction,
  # losing the triggering validation write), hence the raw SQL. Every caller
  # already runs inside a transaction. Telemetry the skips emitted is not
  # retracted.
  @pass_savepoint "plan_engine_pass_guard"
  defp pass_stage(%Stage{} = stage, skip_rows, completed_by) do
    Repo.query!("SAVEPOINT #{@pass_savepoint}")

    if skip_rows != [], do: skip_unevaluated_validations(stage, skip_rows)

    case transition_stage(stage, "passed", completed_by) do
      {:ok, passed} ->
        Repo.query!("RELEASE SAVEPOINT #{@pass_savepoint}")
        {:ok, passed}

      {:error, {:unsatisfied_validations, _rows}} = refused ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{@pass_savepoint}")
        Repo.query!("RELEASE SAVEPOINT #{@pass_savepoint}")
        refused
    end
  end

  defp do_transition_stage(stage, new_status, completed_by, opts) do
    now = DateTime.utc_now()

    extra =
      case new_status do
        "running" ->
          if Keyword.get(opts, :keep_started_at, false),
            do: %{completed_at: nil},
            else: %{started_at: now, completed_at: nil}

        s when s in ~w(passed failed skipped) ->
          %{completed_at: now}

        _ ->
          %{}
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
    |> order_by([s], asc: s.position, asc: s.id)
    |> Repo.all()
  end

  defp current_stage(stages) do
    # First running stage, or first pending stage
    Enum.find(stages, &(&1.status == "running")) ||
      Enum.find(stages, &(&1.status == "pending"))
  end

  # A stage's verdict from its validation rows.
  #
  #   * `:all_passed`     — every row is `passed` or `skipped` (or there are
  #                         none). `skipped` is terminal here for the same
  #                         reason it is terminal in `maybe_advance_next/3`'s
  #                         stage sweep.
  #   * `:has_failures`   — at least one row is a real failure.
  #   * `:pending`        — nothing failed for real and a row is still owed.
  #   * `{:passed_with_unevaluated, rows}` — ONLY for a stage hosting
  #                         `e2e_behavior` rows (task 01a0665e stage 3): every
  #                         failed row is an `e2e_behavior` case whose evidence
  #                         says `could_not_evaluate` with a reason, nothing is
  #                         owed, and at least one `e2e_behavior` row passed.
  #                         `rows` are the `{validation, reason}` pairs to skip.
  #
  # Why the e2e host gets its own arm. A review verdict has two statuses, and
  # `could_not_evaluate` rides as a marker on a `failed` row
  # (`ReviewDisposition`). The router's bounce path treats an all-unevaluated
  # gate as "fix the environment and retry", which is right when the gate
  # could not run at all — but a case that is structurally un-runnable (needs
  # a real media device; the branch the case was written for did not occur)
  # never becomes runnable, so the retry loop has no exit: the task bounces,
  # the router withholds, and the stage sits `failed` forever (01a03f4e,
  # 01a0666d). When the reviewer DID run the gate and passed at least one case,
  # the unevaluated remainder is a list for a human, not a verdict about the
  # feature; the stage passes, the rows are `skipped` with their evidence
  # retained, and the task carries the list in
  # `metadata["unevaluated_review_cases"]`.
  #
  # What stays exactly as it was: a `:genuine` or `:malformed` failure still
  # fails the stage (the marker without a reason is a free "don't count this"
  # switch — `ReviewDisposition` explains why that must read as genuine); a
  # gate whose EVERY case is unevaluated and NONE passed still fails, so the
  # router's 3-strikes bookkeeping and blocker path
  # (`task_router_review_round_bound_test.exs`) are untouched; and a stage
  # with no `e2e_behavior` row never reaches the new arm.
  #
  # What CHANGED (task 01a08e86 stage 3): a `:genuine`/`:malformed` failure no
  # longer fails the stage ON SIGHT — it fails it on the first SETTLED round.
  # While any sibling on the gate is `pending` or `running` the verdict is not
  # in yet and `:pending` wins. See the arm comment in `e2e_host_verdict/1`
  # for the measured bounce this covers and the second bounce it does not.
  defp stage_verdict(stage) do
    validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))

    cond do
      validations == [] -> :all_passed
      Enum.any?(validations, &(&1.kind == "e2e_behavior")) -> e2e_host_verdict(stage, validations)
      Enum.any?(validations, &(&1.status == "failed")) -> :has_failures
      Enum.all?(validations, &(&1.status in ~w(passed skipped))) -> :all_passed
      true -> :pending
    end
  end

  defp e2e_host_verdict(stage, validations) do
    round = round_cutoff(stage, validations)

    classified =
      validations
      |> Enum.filter(&(&1.status == "failed"))
      |> Enum.map(fn v -> {v, classify_failed_row(v)} end)

    cond do
      # THE SETTLED-ROUND HOLD (task 01a08e86 stage 3). Nothing on an e2e host
      # is a verdict until the round settles, so an owed sibling outranks every
      # failure classification. This arm was BELOW the `:genuine`/`:malformed`
      # arm and covered `could_not_evaluate` only; it now covers all of them,
      # which is the whole behavioural change.
      #
      # WHAT THIS COVERS, precisely: the 09:38:09.960Z bounce of 2026-09-11 on
      # gate stage 01a08fa3-b3ef-7006-876b-08a7a0ef1a85. At that evaluation the
      # gate held ONE failed row (`…700a`) and one never-dispositioned sibling
      # (`…700b`), so the reviewer was mid-run and the fast-fail path bounced
      # the task and opened a remediation stage quoting a partial finding set.
      # Under this arm that write returns `:pending` and the gate holds.
      #
      # WHAT THIS DOES NOT COVER, and the distinction matters: the SECOND
      # bounce at 09:50:17.903Z is UNEXPLAINED, and this change does not claim
      # to prevent it. That write was `passed`, so it cannot reach the
      # fast-fail branch; `reset_gate_stage/1` had already driven the gate to
      # `pending`, and `maybe_advance_resolved_stage/1` takes `_other -> :ok`
      # there. No write path was identified that produces that transition. Do
      # not read a recurrence of it as a regression in this hold.
      #
      # A genuine failure is DELAYED here, never swallowed: once the last
      # sibling lands, this arm goes false and the `:has_failures` arm below
      # fails the stage exactly as it did before.
      #
      # PRIOR-ROUND VERDICTS (task 01a0e8c1 stage 1). A `failed` row whose
      # `evaluated_at` is strictly before the stage's `started_at` was written
      # by an EARLIER round and is owed exactly like a `pending` row — see
      # `owed?/2`. Without this, a stage put back to `running` without its
      # rows re-pended let four stale `could_not_evaluate` rows satisfy the
      # skip arm below the moment the reviewer passed one case (specimen
      # 01a0d4a0 stage 4, 2026-09-28 04:13:15). Keyed on the rows, not on
      # the path that reopened the stage, so it holds whichever path did.
      Enum.any?(validations, &owed?(round, &1)) ->
        :pending

      # A real verdict about the feature fails the stage — unchanged, except
      # that it is now reached only on a settled round.
      Enum.any?(classified, fn {_v, disposition} -> disposition in [:genuine, :malformed] end) ->
        :has_failures

      classified == [] ->
        :all_passed

      Enum.any?(validations, &(&1.kind == "e2e_behavior" and &1.status == "passed")) ->
        {:passed_with_unevaluated,
         Enum.map(classified, fn {v, {:could_not_evaluate, reason}} -> {v, reason} end)}

      # Every case unevaluated and nothing passed: the gate did not run.
      # Unchanged — this is the router's "fix the environment" bounce.
      true ->
        :has_failures
    end
  end

  # Only an `e2e_behavior` row may claim `could_not_evaluate`; any other kind
  # failing on an e2e host stage is a genuine failure whatever its evidence.
  defp classify_failed_row(%Validation{kind: "e2e_behavior", evidence: evidence}),
    do: ReviewDisposition.classify(evidence)

  defp classify_failed_row(_validation), do: :genuine

  # ── Unevaluated review cases (task 01a0665e stage 3) ──────────────────────

  # Move each could_not_evaluate row `failed -> skipped` (evidence retained),
  # stamp the task with the list, and tell the execution space once. Runs
  # inside the caller's transaction, before the stage flips to `passed`, so
  # nothing observes a passed stage that still holds a failed row.
  defp skip_unevaluated_validations(%Stage{} = stage, rows) when is_list(rows) do
    skipped_at = DateTime.utc_now()

    entries =
      Enum.map(rows, fn {%Validation{} = validation, reason} ->
        {:ok, skipped} =
          validation
          |> Validation.changeset(%{status: "skipped"})
          |> Repo.update()

        emit_validation_telemetry(skipped)

        %{
          "validation_id" => skipped.id,
          "reason" => reason,
          "skipped_at" => DateTime.to_iso8601(skipped_at)
        }
      end)

    plan = Repo.get!(Plan, stage.plan_id)
    task = Repo.get!(Task, plan.task_id)

    {:ok, stamped} = stamp_unevaluated_review_cases(task, entries)
    post_unevaluated_engagement(stamped, stage, entries)
    :ok
  end

  # Appends to any earlier list (a re-run review can leave a second batch)
  # rather than overwriting it, keyed by validation id so a re-skip of the
  # same row does not duplicate.
  defp stamp_unevaluated_review_cases(%Task{} = task, entries) do
    existing =
      case Map.get(task.metadata || %{}, "unevaluated_review_cases") do
        list when is_list(list) -> list
        _ -> []
      end

    new_ids = MapSet.new(entries, & &1["validation_id"])
    kept = Enum.reject(existing, &(is_map(&1) and MapSet.member?(new_ids, &1["validation_id"])))

    merged_metadata =
      (task.metadata || %{})
      |> Map.put("unevaluated_review_cases", kept ++ entries)

    Tasks.update_task(task, %{metadata: merged_metadata})
  end

  # Best-effort narration, same posture as `Tasks.stamp_delivered_but_open/2`:
  # a chat failure must never roll back the verdict that was just recorded.
  defp post_unevaluated_engagement(%Task{id: task_id}, %Stage{} = stage, entries) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        :ok

      space ->
        lines =
          Enum.map(entries, fn entry ->
            "- `#{entry["validation_id"]}`: #{entry["reason"]}"
          end)

        ExecutionSpace.post_engagement(
          space.id,
          "Review gate \"#{stage.name}\" passed with #{length(entries)} " <>
            "case(s) the reviewer could not evaluate. Nothing about the feature was " <>
            "found wrong; these cases were skipped (evidence retained) and are " <>
            "listed on the task as `unevaluated_review_cases` for a person to " <>
            "judge or follow up:\n" <> Enum.join(lines, "\n"),
          metadata: %{
            "reason" => "review.unevaluated_cases",
            "stage_id" => stage.id,
            "validation_ids" => Enum.map(entries, & &1["validation_id"])
          }
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[PlanEngine] task #{task_id} — unevaluated-cases engagement failed: " <>
          Exception.message(error)
      )

      :ok
  end

  # FIX (b) of task 01a0665e stage 3. `@deployable_statuses` is `~w(in_review)`
  # (019ff788) so that a plan completing at `in_progress` — meaning the review
  # never ran — does not ship. But the no-ack watchdog stamps a task `blocked`
  # and a human drags it back to `in_progress` regardless of what the review
  # gate says; when that gate is `passed`, refusing to deploy leaves a
  # reviewed task with no route to `deploying` (01a03f4e). The lift is scoped
  # to exactly that shape: the task is `in_progress` or `blocked` AND a stage
  # hosting `e2e_behavior` rows is `passed`. A plan with no e2e host stage
  # still completes without a deploy stage — the 019ff788 guard and its
  # warning are untouched.
  #
  # Actor is `:system` (`Tasks.transition_task/2`), so this lift does NOT
  # release a `needs_human` hold (stage 2's release is user-actor only) and
  # does not clear a `delivered_but_open` stamp (stage 1 clears on
  # done/cancelled only).
  defp maybe_lift_to_in_review_for_deploy(%Task{status: status} = task, stages)
       when status in ~w(in_progress blocked) do
    if e2e_host_stage_passed?(stages) do
      case Tasks.transition_task(task, "in_review") do
        {:ok, _lifted} ->
          Logger.info(
            "[PlanEngine] lifted task #{task.id} #{status} -> in_review: its e2e review " <>
              "gate passed, so the deploy edge may fire"
          )

          Task |> Repo.get!(task.id) |> Repo.preload(:project)

        {:error, reason} ->
          Logger.warning(
            "[PlanEngine] could not lift task #{task.id} #{status} -> in_review for " <>
              "deploy: #{inspect(reason)}"
          )

          task
      end
    else
      task
    end
  end

  defp maybe_lift_to_in_review_for_deploy(%Task{} = task, _stages), do: task

  defp e2e_host_stage_passed?(stages) do
    passed_ids = for %Stage{status: "passed", id: id} <- stages, do: id

    passed_ids != [] and
      Repo.exists?(
        from(v in Validation,
          where: v.stage_id in ^passed_ids and v.kind == "e2e_behavior"
        )
      )
  end

  @doc false
  # Public only so the prior-round test can assert this and the e2e host
  # verdict agree. Both go through `owed?/2`; they must not drift.
  @spec all_validations_resolved?(Stage.t()) :: boolean()
  def all_validations_resolved?(%Stage{} = stage) do
    validations = Repo.all(from(v in Validation, where: v.stage_id == ^stage.id))
    round = round_cutoff(stage, validations)

    not Enum.any?(validations, &owed?(round, &1))
  end

  # The ONE owed-row predicate (task 01a0e8c1 stage 1), shared by
  # `e2e_host_verdict/2` and `all_validations_resolved?/1`.
  #
  # A row is owed when it has no verdict yet (`pending`/`running`), or when it
  # is `failed` by a PRIOR round: `evaluated_at` strictly before the round's
  # cutoff (the stage's `started_at`). Strictly: a row evaluated in the same
  # microsecond as `started_at` is this round. A nil cutoff or a nil
  # `evaluated_at` counts as current (legacy rows, stages driven to running
  # without a clock). A `passed` row is never stale — a pass is a verdict
  # whatever round wrote it.
  defp owed?(_cutoff, %Validation{status: status}) when status in ~w(pending running),
    do: true

  defp owed?(%DateTime{} = cutoff, %Validation{status: "failed", evaluated_at: %DateTime{} = at}),
    do: DateTime.compare(at, cutoff) == :lt

  defp owed?(_cutoff, _validation), do: false

  # The prior-round clause applies to e2e host stages only — the stage kind
  # whose verdict has the settled-round hold and the could_not_evaluate skip
  # arm. Every other stage keeps its pending/running-only resolution (nil
  # cutoff), so a non-e2e stage's behaviour is unchanged.
  defp round_cutoff(%Stage{started_at: started_at}, validations) do
    if Enum.any?(validations, &(&1.kind == "e2e_behavior")), do: started_at
  end

  defp maybe_advance_resolved_stage(%Stage{} = stage) do
    case stage.status do
      "running" ->
        advance_stage(stage)

      "failed" ->
        case stage_verdict(stage) do
          # The reopen re-judges the round it reopens, so it keeps that
          # round's `started_at` (see `transition_stage/4`).
          :all_passed ->
            {:ok, reopened_stage} = transition_stage(stage, "running", nil, keep_started_at: true)
            advance_stage(reopened_stage)

          {:passed_with_unevaluated, _rows} ->
            {:ok, reopened_stage} = transition_stage(stage, "running", nil, keep_started_at: true)
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

  # `advance/2`'s pass seam. A refused pass (task 01a0e8c1 stage 2) leaves
  # the stage as it is, does not advance the plan, and returns the reloaded
  # plan so the enclosing transaction — and the write that triggered it —
  # commits.
  defp pass_and_advance_plan(plan, stages, stage, skip_rows, completed_by) do
    case pass_stage(stage, skip_rows, completed_by) do
      {:ok, _passed_stage} ->
        maybe_advance_next(plan, stages, stage.position)

      {:error, {:unsatisfied_validations, _rows}} ->
        Repo.preload(Repo.get!(Plan, plan.id), stages_query())
    end
  end

  # `advance_stage/1`'s pass seam: same contract, returns `:ok` on refusal.
  defp pass_and_advance_stage(stage, skip_rows) do
    case pass_stage(stage, skip_rows, nil) do
      {:ok, _passed_stage} ->
        plan = Repo.get!(Plan, stage.plan_id)
        stages = ordered_stages(plan.id)
        maybe_advance_next(plan, stages, stage.position)

      {:error, {:unsatisfied_validations, _rows}} ->
        :ok
    end
  end

  defp advance_stage(stage) do
    case stage_verdict(stage) do
      :all_passed ->
        pass_and_advance_stage(stage, [])

      {:passed_with_unevaluated, rows} ->
        pass_and_advance_stage(stage, rows)

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

    # Task 01a05393: move a STACK MEMBER `in_progress -> in_review` once its
    # non-gate work is settled. This runs on EVERY stage settlement, which is
    # what closes both holes at once: hole A (a command-only member plan has no
    # gate stage, so no gate-driven seam ever produces the transition) and
    # hole B (the member's LAST stage is the gated one, so the plan never
    # completes and no completion seam ever runs). Ordered BEFORE the
    # `transition_stage(next_stage, "running")` branch below so a member with
    # remaining non-gate work stays `in_progress`, and before
    # `maybe_inject_deploy_or_complete/2` so its `handle_member_transition/3`
    # call sees a task that passes the deployer's `:member_not_in_review` gate.
    # The predicate's status clause is the ADR-0046 guard; a member already at
    # `deploying` is untouched.
    _ = MemberReviewEntry.maybe_enter_in_review(plan, fresh_stages)

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
          # `:platform, :stack_deployer, async: true|false`) and runs
          # AFTER the enclosing transaction commits (task 01a136c1,
          # `StackDeployer.handle_member_transition_after_commit/3`),
          # because the async merge child reads through its own
          # connection and cannot see this transaction's uncommitted
          # stage and validation writes. It is idempotent: the deployer noops when the member's commit is
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
          # `%Stack{status: "deploying"}` pass-through. The dispatch
          # stays in-transaction (it is an in-DB compare-and-swap); only
          # the merge trigger is deferred to post-commit, which keeps
          # dispatch-before-merge.
          {:ok, completed} = complete_plan(plan, :stack_member)
          _ = Stacks.dispatch_stack_deploy(task.stack_id)

          _ =
            StackDeployer.handle_member_transition_after_commit(
              task,
              :plan_completed,
              :in_review
            )

          Repo.preload(completed, stages_query())

        true ->
          # `_with_repos` — see `build_deploy_plan/1`. The `:skip` split
          # below and `skip_reason/1` read only `strategy["type"]`, which
          # the repo set does not touch: a stack member still emits no
          # deploy stage at all.
          strategy = Tasks.resolve_deploy_strategy_with_repos(task)

          # Recorded branch — see the identical call in `build_deploy_plan/1`
          # for why it is recorded here rather than derived by the consumer.
          #
          # The TIP each repository's copy of that branch stands at right now
          # is recorded alongside it, and "right now" is the load-bearing
          # word: this line runs at the moment the last review stage passed,
          # so the sha it captures IS the commit the review passed on.
          # `DeployMergeReconciler` later requires the merged PR's head to
          # equal it. Resolving it here rather than at poll time is the whole
          # point — a tip read at poll time is just "whatever the branch says
          # now", which a force-push controls.
          #
          # `branch_tip_shas/3` fails SOFT (an unreachable repository yields
          # no key, a `warning`, and a gate that keeps only the ordering
          # check), so a flaky `gh` degrades this gate instead of blocking
          # plan completion. It is a shell-out inside this function's
          # enclosing `Repo.transaction`, which `Platform.Deploy.dispatch/3`
          # below already is; N is the declared repo count, almost always 1.
          branch = StackDeployer.member_branch_for(task)

          case DeployStageBuilder.build_stage(
                 strategy,
                 max_position(stages) + 1,
                 branch,
                 BranchProvisioner.branch_tip_shas(strategy, branch)
               ) do
            :skip ->
              # No deploy stage to inject — complete normally. The reason is
              # split by strategy type because `:skip` collapses two strategies
              # with OPPOSITE terminal meanings; see `skip_reason/1`.
              {:ok, completed} = complete_plan(plan, skip_reason(strategy))
              Repo.preload(completed, stages_query())

            stage_def ->
              # Task 01a0665e stage 3: a task the no-ack watchdog knocked to
              # `blocked` (or a bounce returned to `in_progress`) whose review
              # gate has since PASSED is a reviewed task. Lift it back to
              # `in_review` so the guard below sees what the review actually
              # says; the guard itself is unchanged.
              task = maybe_lift_to_in_review_for_deploy(task, stages)

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

  # `DeployStageBuilder.build_stage/4` returns a bare `:skip` for TWO strategy
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

  # A query-level preload REPLACES the association's own `preload_order`
  # (`Plan.has_many(:stages)`) rather than merging with it, so the tiebreak has
  # to be repeated here or every plan this module hands back is ordered by a
  # different rule than the same plan reloaded through `Repo.preload(:stages)`.
  # `position` is not unique — see the long argument at
  # `open_remediation_stage_for/1` — so `asc: :position` alone is not a total
  # order, and this list is what the thirteen call sites above hand back to
  # their caller as `{:ok, plan}`. `asc: :id` makes it total and stable; it does not
  # promise creation order (`Platform.Types.UUIDv7`'s counter wraps at 4096 per
  # millisecond and its timestamp is a wall clock). Ticket 01a089e6.
  defp stages_query do
    [stages: from(s in Stage, order_by: [asc: s.position, asc: s.id])]
  end

  # ── Telemetry ───────────────────────────────────────────────────────────

  defp emit_stage_telemetry(%Stage{} = stage, from_status, completed_by) do
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
  #
  # The same scope also opens a `Platform.Tasks.PostCommit` scope (task
  # 01a136c1), so side effects queued with `PostCommit.run_after_commit/2`
  # (the stack-member rollup-merge triggers) run from the same outermost
  # commit point. Broadcasts flush first, then the post-commit thunks.
  defp deferring_broadcasts(fun) do
    PostCommit.scope(fn ->
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
    end)
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
