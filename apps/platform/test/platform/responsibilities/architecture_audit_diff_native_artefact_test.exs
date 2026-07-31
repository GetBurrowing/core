defmodule Platform.Responsibilities.ArchitectureAuditDiffNativeArtefactTest do
  @moduledoc """
  FIX DETECTOR for task `019fa61c` stage 2: completing a stage while a
  FEDERATED architect holds `architecture.audit_diff` — which is what
  production has — must leave a durable server-written artefact behind.
  Before this stage it left nothing, for every outcome alike.

  ## Why the gap survived

  `architecture_dispatch_test.exs` wires an EXTERNAL agent on purpose and
  says so in its own moduledoc: the Router only runs `handle_output/3`
  inline on the external path, so a native assignee would never reach
  `ExecutionSpace.post_log/2` and that detector would prove nothing. It
  is green, correct, and blind — the one end-to-end detector for this key
  exercises the one dispatch path production does not use.

  ## Why this drives the plan engine and not the Router

  The planner's draft of this file called `Router.fire_trigger/3`
  directly. That reproduces the dispatch but NOT the call site: the
  artefact is written by `PlanEngine.after_stage_completed/1`, which is
  reached only from a real `running -> passed` stage transition inside
  `evaluate_validation/2`'s Ecto transaction. Firing the Router directly
  would exercise a path production never takes to get here, which is the
  same shape of mistake that let the bug survive. So these tests complete
  a stage the way the engine does — through its validations.

  Note the federated agent's shape: `kind: "native", runtime_type:
  "external"`. There is no `"federated"` agent kind —
  `Platform.Agents.Agent.@valid_kinds` is `~w(native external)` and the
  changeset rejects anything else, so a fixture written with
  `kind: "federated"` dies with `Ecto.InvalidChangesetError` before it
  reaches the Router. `Platform.Agents.Kind.classify/1` calls this shape
  `:fed_conversational`. The Router branches on `agent.kind`, which is
  `"native"`, so this lands in `dispatch_native/5`.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Architecture.StageAudit
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage

  @audit_diff_key "architecture.audit_diff"

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :audit_diff_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  # A native dispatcher that REFUSES the handoff. `call_agent_responder/1`
  # (`router.ex:1549-1556`) maps a `{:error, reason}` return onto
  # `{:error, {:native_dispatch_failed, reason}}`, which is the only way
  # the native path can produce a `:failed` outcome — the honesty limit
  # documented on `fire_trigger/3` is that an ACCEPTED handoff tells us
  # nothing further.
  defmodule RefusingDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :audit_diff_capture_pid)
      if is_pid(pid), do: send(pid, {:refused_signal, signal})
      {:error, :architect_runtime_unreachable}
    end
  end

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

    Application.put_env(:platform, :audit_diff_capture_pid, self())
    on_exit(fn -> Application.delete_env(:platform, :audit_diff_capture_pid) end)

    on_exit(fn -> Application.delete_env(:platform, :responsibility_router_native_dispatcher) end)

    # The row under test comes from the handler's OWN `register/0`, never
    # a hand-written map — `architecture_dispatch_test.exs:113-121`. A
    # fixture that re-states the spec by hand keeps passing against a row
    # nobody dispatches. The provider boot walk is disabled in the test
    # env, so each case installs the row explicitly.
    [spec] = ArchitectureAuditDiff.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} = Tasks.create_project(%{name: "Audit Diff Artefact Project"})

    ctx = fresh_stage!(project, "Prove the audit fire leaves a trace")

    Map.merge(ctx, %{row: row, project: project})
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp fresh_stage!(project, title) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: title, status: "in_progress"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Wire the artefact",
        description: "Edit only apps/platform/lib/platform/architecture/stage_audit.ex."
      })

    {:ok, running} = PlanEngine.start_stage(stage.id)

    {:ok, v_test} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
    {:ok, v_lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)

    %{task: task, plan: plan, stage: running, v_test: v_test, v_lint: v_lint, space: space}
  end

  # Drive the stage to `passed` exactly as the engine does. The last
  # validation flips `all_validations_resolved?/1`, which is what reaches
  # `after_stage_completed/1`.
  defp complete_stage!(%{v_test: v_test, v_lint: v_lint}) do
    capture_log([level: :info], fn ->
      {:ok, _} = PlanEngine.evaluate_validation(v_test.id, %{status: "passed"})
      {:ok, _} = PlanEngine.evaluate_validation(v_lint.id, %{status: "passed"})
    end)
  end

  defp use_dispatcher(module) do
    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {module, :maybe_dispatch}
    )
  end

  defp wire_federated_architect! do
    role_key = "architect"

    Repo.insert!(
      %Role{
        key: role_key,
        name: "Architect",
        description: "test",
        icon: "hero-cube-transparent"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: @audit_diff_key
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "audit-diff-fed-#{System.unique_integer([:positive])}",
        name: "Architect Test Federated",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  defp audit_for(stage_id), do: Repo.get!(Stage, stage_id).architecture_audit

  # ── the detector ─────────────────────────────────────────────────────

  test "a federated audit_diff fire leaves a durable per-stage artefact", ctx do
    use_dispatcher(CaptureDispatcher)
    _agent = wire_federated_architect!()

    complete_stage!(ctx)

    # POSITIVE CONTROL. Without this, "an artefact exists" would pass on a
    # fire that never happened — and a row written for a fire that never
    # happened is worse than no row.
    assert_receive {:captured_signal, signal}
    assert signal.metadata.responsibility_key == @audit_diff_key
    assert signal.metadata.stage_id == ctx.stage.id

    # GUARD: the hook is a leaf-node emit. The write is inside
    # `evaluate_validation/2`'s transaction, so a write that raised would
    # show up here as a stage that never reached `passed`.
    assert %Stage{status: "passed"} = Repo.get!(Stage, ctx.stage.id)

    audit = audit_for(ctx.stage.id)

    assert is_map(audit),
           "no durable artefact on stages.architecture_audit after a federated audit_diff fire " <>
             "— got #{inspect(audit)}"

    # The artefact must carry the SUBJECT ID, not merely exist. A row
    # keyed to the wrong stage is not evidence.
    assert audit["stage_id"] == ctx.stage.id
    assert audit["task_id"] == ctx.task.id
    assert audit["plan_id"] == ctx.plan.id

    # And it must be distinguishable from a fire that failed.
    assert audit["state"] == "pending"
    assert audit["reason"] == nil
    assert is_binary(audit["dispatched_at"])
    assert is_binary(audit["deadline_at"])

    # An accepted handoff is not a captured output, so the audit is OPEN
    # and unresolved. Recording `"noted"` here would make every later
    # silence indistinguishable from a win.
    assert audit["resolved_at"] == nil
    assert audit["source"] == nil
    assert audit["summary"] == nil
    assert audit["findings"] == []

    # Every required key present, nil-valued or not — no reader should
    # ever have to distinguish an absent key from a nil one. Asserted
    # against the schema's accessor so the list and its enforcement
    # cannot separate.
    for key <- Stage.architecture_audit_required_keys() do
      assert Map.has_key?(audit, key), "audit is missing required key #{inspect(key)}"
    end

    assert {:open, ^audit} = StageAudit.read(ctx.stage.id)
  end

  # ── the three outcomes must not collapse ─────────────────────────────
  #
  # `019f9b29-5ecd` stage 4's first detonation was a re-laundered outcome
  # mapping that made a crashed designer indistinguishable from an absent
  # one. This is that detonation kept as a standing guard: three fires,
  # three distinct persisted states, each with its own positive control
  # proving which fire actually ran.
  #
  # Ordered deliberately. `Roles.assign_role/2` is global, so the
  # no-assignee case MUST run before any architect is wired.
  test "three fire outcomes persist three distinct states", %{project: project} = ctx do
    # ── (1) no assignee: progressive enhancement, nothing was fired ────
    use_dispatcher(CaptureDispatcher)
    unfilled_ctx = fresh_stage!(project, "No architect assigned")
    complete_stage!(unfilled_ctx)

    refute_receive {:captured_signal, _}, 50
    unfilled = audit_for(unfilled_ctx.stage.id)

    assert unfilled["state"] == "skipped"
    # `Responsibilities.outcome/1` merges `:unfilled` and
    # `:unknown_responsibility` onto `:not_applicable` on purpose; the
    # RECORD keeps them apart in `reason`, or the collapse this task
    # exists to undo reappears one level down.
    assert unfilled["reason"] == "unfilled"
    assert is_binary(unfilled["resolved_at"])

    # ── (2) dispatched: handoff accepted, answer still outstanding ─────
    _agent = wire_federated_architect!()
    dispatched_ctx = fresh_stage!(project, "Architect dispatched")
    complete_stage!(dispatched_ctx)

    assert_receive {:captured_signal, _}
    dispatched = audit_for(dispatched_ctx.stage.id)

    assert dispatched["state"] == "pending"
    assert dispatched["reason"] == nil
    assert dispatched["resolved_at"] == nil

    # ── (3) dispatcher refuses: a real loss, not an absence ────────────
    use_dispatcher(RefusingDispatcher)
    failed_ctx = fresh_stage!(project, "Architect runtime unreachable")
    complete_stage!(failed_ctx)

    assert_receive {:refused_signal, _}
    failed = audit_for(failed_ctx.stage.id)

    assert failed["state"] == "failed"
    assert failed["reason"] =~ "native_dispatch_failed"
    assert failed["reason"] =~ "architect_runtime_unreachable"
    assert is_binary(failed["resolved_at"])

    # The point of the whole task, stated as one assertion: these three
    # were byte-identical (all `nil`) before this stage.
    assert Enum.uniq([unfilled["state"], dispatched["state"], failed["state"]]) ==
             ["skipped", "pending", "failed"]

    # The three stages are all `passed` regardless — the hook never
    # mutates the state machine.
    for c <- [unfilled_ctx, dispatched_ctx, failed_ctx] do
      assert %Stage{status: "passed"} = Repo.get!(Stage, c.stage.id)
    end

    # And the setup stage, which nothing completed, has no row at all.
    # NULL means no fire was ever recorded — a distinct fact from "fired
    # and produced nothing".
    assert audit_for(ctx.stage.id) == nil
    assert StageAudit.read(ctx.stage.id) == :none
  end

  # ── the write must not be able to move the stage ─────────────────────

  test "recording the fire cannot move the stage's status", ctx do
    use_dispatcher(CaptureDispatcher)
    _agent = wire_federated_architect!()

    complete_stage!(ctx)
    assert_receive {:captured_signal, _}

    passed = Repo.get!(Stage, ctx.stage.id)
    assert passed.status == "passed"
    assert passed.completed_at != nil

    # `open_from_fire/2` goes through `architecture_audit_changeset/2`,
    # which casts ONLY `:architecture_audit`. Re-recording against an
    # already-`passed` stage must not disturb the transition columns.
    {:ok, rewritten} = StageAudit.open_from_fire(passed, {:ok, :unfilled})

    assert rewritten.status == "passed"
    assert rewritten.completed_at == passed.completed_at
    assert rewritten.architecture_audit["state"] == "skipped"
  end
end
