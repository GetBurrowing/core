defmodule Platform.Tasks.PlanEngineArchitectDriftHookTest do
  @moduledoc """
  Tests for the ADR-0044 stage 4 post-executor drift-audit hook.

  `Platform.Tasks.PlanEngine.transition_stage/2` fires the
  `architecture.audit_diff` responsibility immediately after a stage
  successfully transitions to `passed`. The fire is wrapped in
  `try/rescue/catch :exit` inside the private
  `after_stage_completed/1` helper so a handler crash cannot roll back
  the enclosing Ecto transaction, stall the state machine, or prevent
  the `{:stage_transitioned, stage}` board broadcast.

  The progressive-enhancement contract (ADR-0044): no assignee → no
  side effect. Stage completion is invariant across the "architect
  assigned" and "no architect" branches — regressing that silently
  breaks the plan-engine invariant that motivated the ADR.

  Not `async: true` because the tests toggle the module-level
  `:responsibility_router_native_dispatcher` app env to neutralise the
  actual AgentResponder dispatch (or in the crash-isolation case, to
  substitute a dispatcher that raises).
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleResponsibility}
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Stage}

  @audit_diff_key "architecture.audit_diff"

  # Travels the whole external round trip: stub body → Dispatcher →
  # ContractValidator (both architecture contracts classify `:unknown`, so
  # the raw string survives) → `extract_annotation/1` → `record_note/3`'s
  # `summary` → the execution-space line. A mismatch means the path broke,
  # not that a payload shape drifted.
  @answer_sentinel "ARCHITECT_ANSWERED_SENTINEL"

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  defmodule CrashingDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: raise("simulated architect audit_diff crash")
  end

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

    # Register the `architecture.audit_diff` responsibility row in the
    # per-case sandbox. Production seeds this via the Registry provider
    # boot walk which is disabled in the test env
    # (`:start_responsibilities_registry` = false), so each test that
    # touches the responsibility row has to install it explicitly.
    {:ok, _row} =
      Responsibilities.upsert_by_key(%{
        key: @audit_diff_key,
        feature: "architecture",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "stage:completed"},
        scope: "per_project",
        context_provided: ["stage_diff", "planned_shape", "org_memory_entries"],
        output_contract: %{"annotations" => "list[map]"},
        default_prompt_template: "architecture.audit_diff.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.architecture", "adr" => "0044"}
      })

    {:ok, project} = Tasks.create_project(%{name: "Drift Hook Project"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Drift Hook Task",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Wire the drift hook",
        description: "Edit only apps/platform/lib/platform/tasks/plan_engine.ex."
      })

    {:ok, running_stage} = PlanEngine.start_stage(stage.id)

    {:ok, v_test} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})
    {:ok, v_lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})

    %{
      project: project,
      task: task,
      plan: plan,
      stage: running_stage,
      v_test: v_test,
      v_lint: v_lint
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp attach_telemetry(events) when is_list(events) do
    handler_id = "drift-hook-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  defp override_native_dispatcher(module, function) do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {module, function}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)
  end

  defp wire_architect_assignee do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: @audit_diff_key
    })
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "architect-audit-#{System.unique_integer([:positive])}",
        name: "Fixture Architect Audit",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  # Every `"[architect | audit_diff] "` line in the space, so a test can
  # assert there is exactly ONE. A note that landed twice reads to a human
  # as two separate audits.
  defp audit_annotations(space_id) do
    space_id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.filter(fn msg ->
      is_binary(msg.content) and String.starts_with?(msg.content, "[architect | audit_diff] ")
    end)
  end

  # Complete every validation on the stage. The last one flips
  # `all_validations_resolved?/1` to true, which drives the stage from
  # `running` → `passed` (the terminal transition the hook fires on).
  defp complete_stage_via_validations(v_test, v_lint) do
    {:ok, _} = PlanEngine.evaluate_validation(v_test.id, %{status: "passed"})
    {:ok, _} = PlanEngine.evaluate_validation(v_lint.id, %{status: "passed"})
  end

  # ── stage-complete transition — no architect assigned ─────────────────

  describe "transition to passed — no architect assigned (progressive enhancement default)" do
    test "still transitions the stage to passed", %{
      stage: stage,
      v_test: v_test,
      v_lint: v_lint
    } do
      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      updated_stage = Repo.get!(Stage, stage.id)
      assert updated_stage.status == "passed"
      assert updated_stage.completed_at != nil
    end

    test "emits :unfilled telemetry for architecture.audit_diff (no assignee)", %{
      v_test: v_test,
      v_lint: v_lint
    } do
      _handler_id =
        attach_telemetry([
          [:platform, :responsibility, :unfilled],
          [:platform, :responsibility, :fired]
        ])

      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      assert_receive {:telemetry, [:platform, :responsibility, :unfilled], _measurements,
                      %{key: @audit_diff_key}}

      refute_receive {:telemetry, [:platform, :responsibility, :fired], _, _}, 50
    end

    test "still broadcasts {:stage_transitioned, stage} on the board", %{
      stage: stage,
      v_test: v_test,
      v_lint: v_lint
    } do
      Tasks.subscribe_board()

      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      stage_id = stage.id

      assert_receive {:stage_transitioned, %Stage{id: ^stage_id, status: "passed"}}
    end
  end

  # ── stage-complete transition — architect assigned ────────────────────

  describe "transition to passed — architect assigned" do
    setup do
      override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
      agent = wire_architect_assignee()
      %{agent: agent}
    end

    test "still transitions the stage to passed", %{
      stage: stage,
      v_test: v_test,
      v_lint: v_lint
    } do
      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      updated_stage = Repo.get!(Stage, stage.id)
      assert updated_stage.status == "passed"
    end

    test "fires the architecture.audit_diff responsibility (emits :fired telemetry)", %{
      v_test: v_test,
      v_lint: v_lint
    } do
      _handler_id =
        attach_telemetry([
          [:platform, :responsibility, :fired]
        ])

      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      assert_receive {:telemetry, [:platform, :responsibility, :fired], _measurements,
                      %{key: @audit_diff_key, dispatch_kind: :native}}
    end

    test "logs the native-dispatch line (sanity check the fire actually ran)", %{
      v_test: v_test,
      v_lint: v_lint
    } do
      log =
        capture_log([level: :info], fn ->
          complete_stage_via_validations(v_test, v_lint)
        end)

      assert log =~ "[ResponsibilityRouter] native dispatch key=#{@audit_diff_key}"
    end
  end

  # ── crash isolation ──────────────────────────────────────────────────

  describe "transition to passed — hook crash isolation" do
    test "stage transition survives an architect dispatcher crash", %{
      stage: stage,
      v_test: v_test,
      v_lint: v_lint
    } do
      # Wire an assignee whose native dispatcher raises. The hook's
      # try/rescue/catch :exit must swallow the crash so the stage
      # transition + broadcast still complete. This is the load-bearing
      # property from memory `[Suite engine quirks]` cascade-fix
      # 019f3440.
      override_native_dispatcher(__MODULE__.CrashingDispatcher, :maybe_dispatch)
      _agent = wire_architect_assignee()

      Tasks.subscribe_board()

      log =
        capture_log([level: :info], fn ->
          # The stage MUST transition to passed despite the architect
          # dispatch attempt going sideways.
          complete_stage_via_validations(v_test, v_lint)
        end)

      # Router's native dispatcher swallows the raise internally
      # ("native dispatcher raised" warning) — either that OR our own
      # `[Responsibilities] architecture.audit_diff crashed` warning is
      # acceptable evidence that the crash was caught. The important
      # assertion is the transition + broadcast below.
      assert log =~ "native dispatcher raised" or
               log =~ "[Responsibilities] architecture.audit_diff crashed" or
               log =~ "[Responsibilities] architecture.audit_diff exited"

      # Stage still transitioned to passed.
      updated_stage = Repo.get!(Stage, stage.id)
      assert updated_stage.status == "passed"

      # Broadcast still fires — the crash cannot stall the board.
      stage_id = stage.id
      assert_receive {:stage_transitioned, %Stage{id: ^stage_id, status: "passed"}}
    end
  end

  # ── ADR-0046 member 1 stage 4: the hook OBSERVES the fire result ──────
  #
  # `after_stage_completed/1` used to throw the fire result away, and the
  # pre-task Router laundered every outcome into a flat `:ok`. A drift-audit
  # endpoint that was DOWN therefore looked exactly like "no architect
  # assigned": the stage passed unaudited, silently.
  #
  # GUARD half   — the stage still reaches `passed` and the validation row
  #                survives. Passes either way; it is here so the detector
  #                cannot be satisfied by breaking fire-and-forget or by
  #                rolling back the enclosing transaction.
  # DETECTOR half — `:failed` telemetry AND the new warning. Impossible
  #                against pre-task code.
  describe "transition to passed — architect assigned but endpoint down (external)" do
    alias Platform.ExternalAgents.EphemeralCredentials
    alias Platform.Tasks.Validation

    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :architect_drift_hook_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    # External sibling of `wire_architect_assignee/0`. An HTTP endpoint is
    # the only assignee kind whose failure the Router can actually observe
    # — the native path returns `{:ok, :dispatched}` on handoff (see the
    # Router moduledoc's honesty limit).
    defp wire_external_architect! do
      role_key = "historian"

      Repo.insert!(
        %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
        on_conflict: :nothing,
        conflict_target: :key
      )

      %RoleResponsibility{}
      |> RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: @audit_diff_key
      })
      |> Repo.insert!()

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "architect-drift-ext-#{System.unique_integer([:positive])}",
          name: "Fixture Architect Audit External",
          status: "active",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://api.example.test",
          model: "test-model",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = EphemeralCredentials.put(agent.id, "sk-architect-drift-hook")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      agent
    end

    test "GUARD: the stage still passes and the validation row survives; DETECTOR: the failure is logged",
         %{stage: stage, plan: plan, v_test: v_test, v_lint: v_lint} do
      _handler_id = attach_telemetry([[:platform, :responsibility, :failed]])
      _agent = wire_external_architect!()

      test_pid = self()

      Req.Test.stub(:architect_drift_hook_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      log =
        capture_log([level: :info], fn ->
          complete_stage_via_validations(v_test, v_lint)
        end)

      # ── GUARD half (passes either way — fire-and-forget must hold) ────
      assert %Stage{status: "passed", completed_at: completed_at} = Repo.get!(Stage, stage.id)
      assert completed_at != nil

      # The hook runs INSIDE `evaluate_validation/2`'s Ecto transaction.
      # If the new logging raised, this row would have been rolled back to
      # `pending`.
      assert %Validation{status: "passed"} = Repo.get!(Validation, v_lint.id)
      assert %Validation{status: "passed"} = Repo.get!(Validation, v_test.id)

      # Mechanism proof: the Router really did resolve an assignee and
      # call the endpoint.
      assert_receive {:external_dispatch, "/chat/completions"}

      # ── DETECTOR half (impossible before this stage) ──────────────────
      assert_receive {:telemetry, [:platform, :responsibility, :failed], _measurements,
                      %{key: @audit_diff_key, dispatch_kind: :external}}

      assert log =~
               "[Responsibilities] architecture.audit_diff dispatch failed " <>
                 "stage=#{stage.id} plan=#{plan.id}"

      assert log =~ "dispatch_failed"
    end

    # ── task 019fa61c stage 4: the external path lands a real note ──────
    #
    # THE ORDERING THIS PINS, which is the reverse of the order the code
    # reads in. `after_stage_completed/1` calls `Responsibilities.fire/2`
    # first and `StageAudit.open_from_fire/2` second — but for an
    # `kind: "external"` assignee the entire round trip happens INSIDE
    # that fire: `run_external_dispatch/5` gets the HTTP body and calls
    # `invoke_handle_output/3` (`router.ex:1106`) before `fire/2` returns.
    # So the handler records its note against a column that is still NULL,
    # and the engine's `open_from_fire/2` runs AFTERWARDS on a row that by
    # then holds the answer.
    #
    # A convergence that ignored this is worse than the bug it replaces:
    # the note would land, be visible in the execution space, and then be
    # overwritten with `"pending"` — an audit reading UNANSWERED with its
    # answer sitting one surface away. Two mechanisms hold it, and each is
    # independently detonatable (verified, both against this test):
    #
    #   * delete the `open_from_fire/2` call in `land_note/2`
    #     → `record_note/3` refuses `:audit_not_open`, the row stays
    #       `"pending"` with a nil summary and NO annotation is posted.
    #   * delete the `coalesce(?->>'state','') <> 'noted'` predicate from
    #     `commit_open/3` → the row reads `"pending"`, source nil, summary
    #       nil, while the annotation IS in the space.
    #
    # Neither is masked by the other: they fail with different signatures
    # (the first loses the annotation too, the second keeps it), which is
    # why both are asserted below rather than just the state.
    test "an external architect who ANSWERS leaves a noted/handle_output row that the engine's trailing fire record does not erase",
         %{stage: stage, task: task, plan: plan, v_test: v_test, v_lint: v_lint} do
      _agent = wire_external_architect!()
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      test_pid = self()

      Req.Test.stub(:architect_drift_hook_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "#{@answer_sentinel} clean — no drift, no new deps"
              }
            }
          ]
        })
      end)

      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      # POSITIVE CONTROL: the round trip really happened. Every assertion
      # below is about what an ANSWER leaves behind, and all of them would
      # be vacuous against a fire that never reached the endpoint.
      assert_receive {:external_dispatch, "/chat/completions"}

      audit = Repo.get!(Stage, stage.id).architecture_audit

      assert is_map(audit), "no artefact at all — the fire recorded nothing"
      assert audit["state"] == "noted"
      assert audit["source"] == "handle_output"
      assert audit["summary"] =~ @answer_sentinel

      # Keyed to the right subject: a row that names another stage is not
      # evidence about this one.
      assert audit["stage_id"] == stage.id
      assert audit["task_id"] == task.id
      assert audit["plan_id"] == plan.id

      # The dispatch facts survive the note rather than being replaced by
      # it — `record_note/3` MERGES onto the open row.
      assert is_binary(audit["dispatched_at"])
      assert is_binary(audit["deadline_at"])
      assert is_binary(audit["resolved_at"])

      # The row and the note land TOGETHER. Asserting either alone is the
      # half-evidence this task exists to stop shipping.
      assert [annotation] = audit_annotations(space.id)
      assert annotation.content =~ @answer_sentinel
      assert String.starts_with?(annotation.content, "[architect | audit_diff] ")
    end

    # PAIRED CONTROL for the test above. Same fixture, same wiring, same
    # engine call — only the endpoint's answer differs. Without this, a
    # writer that stamped `"noted"` unconditionally would pass everything
    # above, and the `state` assertion would be measuring nothing.
    test "CONTROL: the same path with no answer records the fire, not a note",
         %{stage: stage, v_test: v_test, v_lint: v_lint} do
      _agent = wire_external_architect!()

      Req.Test.stub(:architect_drift_hook_dispatch_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      capture_log([level: :info], fn ->
        complete_stage_via_validations(v_test, v_lint)
      end)

      audit = Repo.get!(Stage, stage.id).architecture_audit

      assert audit["state"] == "failed"
      assert audit["source"] == nil
      assert audit["summary"] == nil
    end
  end

  # ── nil-plan regression ───────────────────────────────────────────────

  test "REGRESSION: a stage whose plan row is gone logs instead of raising inside the transaction",
       %{stage: stage, plan: plan, v_test: v_test, v_lint: v_lint} do
    # `after_stage_completed/1` does `plan = Repo.get(Plan, stage.plan_id)`
    # — a plain `get`, so `plan` CAN be nil (hence `plan && Repo.get(...)`
    # on the following line). Interpolating `plan.task_id` into the new log
    # lines would raise a KeyError INSIDE `evaluate_validation/2`'s
    # transaction; the hook keys off `stage.id` / `stage.plan_id` instead.
    #
    # `stages.plan_id` is `NOT NULL REFERENCES plans(id) ON DELETE CASCADE`,
    # so the only way to reach the state is to drop the constraint first.
    # DDL is transactional in Postgres and this runs inside the DataCase
    # sandbox transaction, so it is reverted with the rest of the case.
    # The test is `async: false` (module-level), so the ACCESS EXCLUSIVE
    # lock cannot block a concurrent case.
    Logger.put_module_level(Platform.Tasks.PlanEngine, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Tasks.PlanEngine) end)

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE stages DROP CONSTRAINT stages_plan_id_fkey"
    )

    plan_id = plan.id
    {1, _} = Repo.delete_all(from(p in Platform.Tasks.Plan, where: p.id == ^plan_id))
    assert Repo.get(Platform.Tasks.Plan, plan_id) == nil
    assert Repo.get!(Stage, stage.id).plan_id == plan_id

    log =
      capture_log([level: :info], fn ->
        # PRE-EXISTING, UNRELATED: `advance_stage/1` does `Repo.get!(Plan,
        # stage.plan_id)` immediately AFTER the hook returns, so the
        # transaction ends in an `Ecto.NoResultsError` regardless of this
        # stage's diff. Asserting the exact exception type is the point —
        # a KeyError / BadMapError here would mean the new logging blew up.
        assert_raise Ecto.NoResultsError, fn ->
          complete_stage_via_validations(v_test, v_lint)
        end
      end)

    # The hook ran to completion with `plan == nil` …
    assert log =~
             "[Responsibilities] architecture.audit_diff unfilled " <>
               "stage=#{stage.id} plan=#{plan_id}"

    # … and the rescue backstop never had to catch anything. This is the
    # regression assertion: an unguarded `plan.task_id` would land here.
    refute log =~ "[Responsibilities] architecture.audit_diff crashed"
  end

  # ── invariant guard ─────────────────────────────────────────────────

  test "sanity: transition-to-passed lands the same stage status across the with/without-architect paths",
       %{project: project, stage: stage, v_test: v_test, v_lint: v_lint} do
    # Path A: no architect assigned. Complete the fixture stage.
    capture_log([level: :info], fn ->
      complete_stage_via_validations(v_test, v_lint)
    end)

    assert %Stage{status: "passed"} = Repo.get!(Stage, stage.id)

    # Path B needs a fresh task + plan + stage.
    {:ok, task_b} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Drift Hook Task B",
        status: "in_progress"
      })

    {:ok, plan_b} = Tasks.create_plan(%{task_id: task_b.id})

    {:ok, stage_b} =
      Tasks.create_stage(%{
        plan_id: plan_b.id,
        position: 1,
        name: "Wire the drift hook (B)",
        description: "Edit only apps/platform/lib/platform/tasks/plan_engine.ex."
      })

    {:ok, _} = PlanEngine.start_stage(stage_b.id)

    {:ok, v_test_b} = Tasks.create_validation(%{stage_id: stage_b.id, kind: "test_pass"})
    {:ok, v_lint_b} = Tasks.create_validation(%{stage_id: stage_b.id, kind: "lint_pass"})

    override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
    _agent = wire_architect_assignee()

    capture_log([level: :info], fn ->
      complete_stage_via_validations(v_test_b, v_lint_b)
    end)

    # The load-bearing invariant: the hook is a leaf-node emit, not a
    # state-machine mutation. Both stages land in the same terminal
    # `passed` status regardless of whether an architect was assigned.
    assert %Stage{status: "passed"} = Repo.get!(Stage, stage_b.id)
  end
end
