defmodule Platform.Federation.DeadLetterTriggerKindE2ETest do
  @moduledoc """
  Fix detector for task `019fa56b-ca2d`: an `event_topic` responsibility
  fire that dead-letters must be RECORDED with `trigger_kind` set, so
  `DeadLetterPolicy.classify/1` can rule on it.

  ## Why the rest of the suite missed this

  `dead_letter_policy_test.exs`, `dead_letter_replay_test.exs` and
  `agent_responder_test.exs` all hand-build the signal they feed in, with
  `metadata.trigger_kind` ALREADY SET (`:cron` / `:event_topic`), and then
  assert the recorded row carries that same value. That is vacuous in the
  precise sense this defect requires: the test supplies the very value
  whose absence is the bug. Nothing in the suite drove
  `PlanEngine -> Router -> AgentResponder -> DeadLetters.record/1`, so the
  gap between what the Router EMITS and what the tests SUPPLY was invisible.

  In production neither producer passes `:kind`:

    * `PlanEngine.after_stage_completed/1` fires `architecture.audit_diff`
      with `%{stage_id:, plan_id:, task_id:, stage:, plan:, task:}`, and
    * `Tasks.fire_architecture_review_plan/1` fires
      `architecture.review_plan` with `%{plan_id:, task_id:, plan:}`.

  `Router.build_native_signal/4` wrote `trigger_kind: trigger_meta[:kind]`,
  which is `nil` for both, so every recorded row normalised to
  `{:drop, :unclassified}` and was dropped forever. Only the cron path
  carried a kind (`Router` passes `%{kind: :cron, fired_at: now}`), which is
  why the cron half of the policy looked healthy.

  ## What these tests assert

  The RECORDED row — never a hand-built one. Each test drives the real
  producer, lets the real Router build the signal, lets the real
  `AgentResponder` find the runtime offline, and then reads
  `Platform.Federation.DeadLetter` out of Postgres.

  ## Detonation

  Revert `build_native_signal/4` to `trigger_kind: Map.get(trigger_meta, :kind)`
  and both tests fail on `letter.trigger_kind == "event_topic"` (actual: nil)
  and on `classify/1` (actual: `{:drop, :unclassified}`).

  Not `async: true`: the tests toggle `:chat_agent_dispatch_mode` app env and
  share the `RuntimePresence` process.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterPolicy
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanEngine

  setup do
    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    # The production native dispatcher is what is under test here. Any
    # override (the drift-hook test's `NoopDispatcher`, for example) would
    # short-circuit exactly the code path this file exists to exercise.
    previous_dispatcher = Application.get_env(:platform, :responsibility_router_native_dispatcher)
    Application.delete_env(:platform, :responsibility_router_native_dispatcher)

    on_exit(fn ->
      if previous_mode do
        Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      else
        Application.delete_env(:platform, :chat_agent_dispatch_mode)
      end

      if previous_dispatcher do
        Application.put_env(
          :platform,
          :responsibility_router_native_dispatcher,
          previous_dispatcher
        )
      end
    end)

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  # The responsibility row comes from the handler's OWN `register/0`. A
  # hand-written fixture would let the shipped `trigger_kind` drift away
  # from what this fix reads, and the test would keep passing against a row
  # nobody dispatches.
  defp upsert_registered_row!(handler) do
    [spec] = handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  # A federated architect whose runtime exists but is NOT in presence —
  # the exact production condition (`runtime_offline`) that dead-letters
  # the fire.
  defp wire_offline_architect(responsibility_key) do
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
      responsibility_key: responsibility_key
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    unique = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "dl-tk-#{unique}@example.com",
        name: "Dead Letter Trigger Kind Owner",
        oidc_sub: "oidc-dl-tk-#{unique}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-dl-tk-#{unique}",
        display_name: "architect-runtime-offline"
      })

    # Never tracked — presence is empty for this runtime.
    refute RuntimePresence.online?(runtime.runtime_id)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "architect-dl-tk-#{unique}",
        name: "Offline Architect",
        status: "active",
        kind: "native",
        runtime_type: "external",
        runtime_id: runtime.id,
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    %{agent: agent, runtime: runtime}
  end

  defp recorded_letter!(responsibility_key) do
    case Repo.all(DeadLetter) do
      [%DeadLetter{} = letter] ->
        assert letter.responsibility_key == responsibility_key
        letter

      other ->
        flunk(
          "expected exactly one dead letter for #{responsibility_key}, got: #{inspect(other)}"
        )
    end
  end

  # ── architecture.audit_diff, via a real PlanEngine stage pass ────────────

  describe "architecture.audit_diff dead-lettered from PlanEngine.transition_stage/2" do
    setup do
      row = upsert_registered_row!(ArchitectureAuditDiff)
      wiring = wire_offline_architect(row.key)

      {:ok, project} = Tasks.create_project(%{name: "Trigger Kind Audit Project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Trigger Kind Audit Task",
          status: "in_progress"
        })

      {:ok, draft_plan} = Tasks.create_plan(%{task_id: task.id})

      # Approved, not draft. `DeadLetterPolicy.audit_diff_freshness/1` reads
      # `Tasks.current_plan/1`, which only sees `approved` / `completed`
      # plans — a draft would classify `{:drop, :subject_superseded}` and the
      # replay half of the assertion below would prove nothing. Set directly
      # rather than via `submit_plan_for_review/1`, which would itself fire
      # `architecture.review_plan` and dead-letter a second row.
      {:ok, plan} =
        draft_plan
        |> Plan.changeset(%{status: "approved"})
        |> Repo.update()

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Stamp trigger_kind on the native signal",
          description: "Edit only apps/platform/lib/platform/responsibilities/router.ex."
        })

      {:ok, running_stage} = PlanEngine.start_stage(stage.id)

      {:ok, v_test} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
      {:ok, v_lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

      Map.merge(wiring, %{
        row: row,
        project: project,
        task: task,
        plan: plan,
        stage: running_stage,
        v_test: v_test,
        v_lint: v_lint
      })
    end

    test "records the row with trigger_kind from the responsibility, not nil", ctx do
      capture_log([level: :info], fn ->
        {:ok, _} = PlanEngine.evaluate_validation(ctx.v_test.id, %{status: "passed"})
        {:ok, _} = PlanEngine.evaluate_validation(ctx.v_lint.id, %{status: "passed"})
      end)

      letter = recorded_letter!("architecture.audit_diff")

      # THE assertion. `PlanEngine.after_stage_completed/1` passes no
      # `:kind`, so before the fix this is nil and every real audit_diff
      # fire was unclassifiable.
      assert letter.trigger_kind == "event_topic",
             "recorded trigger_kind was #{inspect(letter.trigger_kind)} — " <>
               "the Router emitted a signal with no trigger_kind, so the ledger " <>
               "cannot rule on this fire"

      assert letter.subject_type == "stage"
      assert letter.subject_id == ctx.stage.id
      assert letter.disposition == "pending"
    end

    test "the recorded row is classifiable rather than {:drop, :unclassified}", ctx do
      capture_log([level: :info], fn ->
        {:ok, _} = PlanEngine.evaluate_validation(ctx.v_test.id, %{status: "passed"})
        {:ok, _} = PlanEngine.evaluate_validation(ctx.v_lint.id, %{status: "passed"})
      end)

      letter = recorded_letter!("architecture.audit_diff")

      # The user-visible half of the defect: 34 production fires were
      # recorded and then dropped. The stage is `passed`, on the current
      # plan of a live task, so the freshness predicate says replay.
      refute DeadLetterPolicy.classify(letter) == {:drop, :unclassified}
      assert DeadLetterPolicy.classify(letter) == :replay
    end
  end

  # ── architecture.review_plan, via a real plan submission ─────────────────

  describe "architecture.review_plan dead-lettered from Tasks.submit_plan_for_review/1" do
    setup do
      row = upsert_registered_row!(ArchitectureReviewPlan)
      wiring = wire_offline_architect(row.key)

      {:ok, project} = Tasks.create_project(%{name: "Trigger Kind Review Project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Trigger Kind Review Task",
          status: "planning"
        })

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Stamp trigger_kind on the native signal",
          description: "Edit only apps/platform/lib/platform/responsibilities/router.ex."
        })

      Map.merge(wiring, %{row: row, project: project, task: task, plan: plan})
    end

    test "records the row with trigger_kind from the responsibility, not nil", ctx do
      capture_log([level: :info], fn ->
        {:ok, _plan} = Tasks.submit_plan_for_review(ctx.plan)
      end)

      letter = recorded_letter!("architecture.review_plan")

      # Second producer, same defect: `fire_architecture_review_plan/1`
      # passes `%{plan_id:, task_id:, plan:}` and no `:kind`.
      assert letter.trigger_kind == "event_topic",
             "recorded trigger_kind was #{inspect(letter.trigger_kind)} — " <>
               "the review_plan producer passes no :kind either"

      assert letter.subject_type == "plan"
      assert letter.subject_id == ctx.plan.id
      refute DeadLetterPolicy.classify(letter) == {:drop, :unclassified}
    end
  end

  # ── the cron path must be undisturbed ────────────────────────────────────

  describe "an explicit trigger_meta[:kind] still wins over the responsibility row" do
    test "a cron-kind fire on an event_topic row records cron" do
      row = upsert_registered_row!(ArchitectureAuditDiff)
      _wiring = wire_offline_architect(row.key)

      # Deliberately contradictory: the ROW says event_topic, the FIRE says
      # cron. The fallback must not overwrite a kind the caller supplied —
      # `Router.maybe_fire_cron/4` is the one producer that passes a real
      # `:kind`, and reclassifying its fires as event_topic would replay
      # wall-clock-stale work the cron tick is already going to redo.
      capture_log([level: :info], fn ->
        assert {:ok, :dispatched} =
                 Responsibilities.fire(row.key, %{
                   kind: :cron,
                   fired_at: DateTime.utc_now()
                 })
      end)

      letter = recorded_letter!("architecture.audit_diff")

      assert letter.trigger_kind == "cron"
      assert DeadLetterPolicy.classify(letter) == {:drop, :stale_by_wall_clock}
    end
  end
end
