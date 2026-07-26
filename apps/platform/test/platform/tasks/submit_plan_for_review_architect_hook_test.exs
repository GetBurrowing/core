defmodule Platform.Tasks.SubmitPlanForReviewArchitectHookTest do
  @moduledoc """
  Tests for the ADR-0044 stage 2 plan-time architect hook.

  `Platform.Tasks.submit_plan_for_review/1` fires the
  `architecture.review_plan` responsibility immediately after the plan
  flips `draft → pending_review` and BEFORE the board broadcast. The
  fire is wrapped in `try/rescue/catch :exit` so a handler crash
  cannot stall the plan-approval flow.

  The progressive-enhancement contract (ADR-0044): no assignee → no
  side effect; return semantics of `submit_plan_for_review/1` are
  invariant across the "architect assigned" and "no architect"
  branches. Regressing that silently breaks the plan-engine invariant
  that motivated the ADR.

  Not `async: true` because the tests toggle the module-level
  `:responsibility_router_native_dispatcher` app env to neutralise the
  actual AgentResponder dispatch that would otherwise crash on a bare
  system-event signal.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleResponsibility}
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Task}

  @architect_key "architecture.review_plan"

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

    # Register the `architecture.review_plan` responsibility row in the
    # per-case sandbox. Production seeds this via the Registry provider
    # boot walk which is disabled in the test env
    # (`:start_responsibilities_registry` = false), so each test that
    # touches the responsibility row has to install it explicitly.
    {:ok, _row} =
      Responsibilities.upsert_by_key(%{
        key: @architect_key,
        feature: "architecture",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "plan:submitted"},
        scope: "per_project",
        context_provided: ["plan_payload", "sibling_tasks", "adr_index"],
        output_contract: %{"comments" => "list[map]"},
        default_prompt_template: "architecture.review_plan.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.architecture", "adr" => "0044"}
      })

    {:ok, project} = Tasks.create_project(%{name: "Architect Hook Project"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Hook Test Task",
        status: "planning"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    %{project: project, task: task, plan: plan}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp attach_telemetry(events) when is_list(events) do
    handler_id = "submit-plan-hook-#{System.unique_integer([:positive])}"
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
    # Reuse `historian` — a canonical seeded role — as the carrier for
    # the architecture.review_plan responsibility. This keeps the test
    # off the seeded `architect` role's own bundle (which the
    # closed-roster coverage suite already exercises) and stays
    # co-tenant-friendly with the router tests that use the same
    # pattern.
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: @architect_key
    })
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "architect-native-#{System.unique_integer([:positive])}",
        name: "Fixture Architect",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  # ── tests ──────────────────────────────────────────────────────────────

  describe "submit_plan_for_review/1 — no architect assigned (progressive enhancement default)" do
    test "returns {:ok, plan} with pending_review status", %{plan: plan} do
      test_pid = self()

      capture_log([level: :info], fn ->
        send(test_pid, {:result, Tasks.submit_plan_for_review(plan)})
      end)

      assert_received {:result, {:ok, %Plan{status: "pending_review"}}}
    end

    test "emits :unfilled telemetry for architecture.review_plan (no assignee)", %{plan: plan} do
      _handler_id =
        attach_telemetry([
          [:platform, :responsibility, :unfilled],
          [:platform, :responsibility, :fired]
        ])

      capture_log([level: :info], fn ->
        assert {:ok, _} = Tasks.submit_plan_for_review(plan)
      end)

      # Progressive-enhancement contract: unfilled telemetry fires and
      # NO `:fired` telemetry (no assignee → no dispatch).
      assert_receive {:telemetry, [:platform, :responsibility, :unfilled], _measurements,
                      %{key: @architect_key}}

      refute_receive {:telemetry, [:platform, :responsibility, :fired], _, _}, 50
    end
  end

  describe "submit_plan_for_review/1 — architect assigned" do
    setup do
      override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
      agent = wire_architect_assignee()
      %{agent: agent}
    end

    test "still returns {:ok, plan} with pending_review status", %{plan: plan} do
      log =
        capture_log([level: :info], fn ->
          assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
        end)

      # Sanity: the architect dispatch actually ran (native dispatch log).
      assert log =~ "[ResponsibilityRouter] native dispatch key=#{@architect_key}"
    end

    test "fires the architecture.review_plan responsibility (emits :fired telemetry)", %{
      plan: plan
    } do
      _handler_id =
        attach_telemetry([
          [:platform, :responsibility, :fired]
        ])

      capture_log([level: :info], fn ->
        assert {:ok, _} = Tasks.submit_plan_for_review(plan)
      end)

      assert_receive {:telemetry, [:platform, :responsibility, :fired], _measurements,
                      %{key: @architect_key, dispatch_kind: :native}}
    end

    test "broadcasts {:plan_updated, plan} on the board after firing hook", %{plan: plan} do
      Tasks.subscribe_board()

      capture_log([level: :info], fn ->
        assert {:ok, submitted} = Tasks.submit_plan_for_review(plan)
        send(self(), {:submitted, submitted.id})
      end)

      submitted_id =
        receive do
          {:submitted, id} -> id
        after
          0 -> flunk("no submitted id captured")
        end

      assert_receive {:plan_updated, %Plan{id: ^submitted_id, status: "pending_review"}}
    end
  end

  describe "submit_plan_for_review/1 — hook crash isolation" do
    test "plan-submit transition survives an architect dispatcher crash", %{plan: plan} do
      # Wire an assignee whose native dispatcher raises. The hook's
      # try/rescue/catch :exit must swallow the crash so the plan
      # transition and board broadcast still complete. This is the
      # load-bearing property from memory `[Suite engine quirks]`
      # cascade-fix 019f3440.
      override_native_dispatcher(__MODULE__.CrashingDispatcher, :maybe_dispatch)
      _agent = wire_architect_assignee()

      Tasks.subscribe_board()

      log =
        capture_log([level: :info], fn ->
          # The plan MUST transition to pending_review despite the
          # architect dispatch attempt going sideways.
          assert {:ok, %Plan{status: "pending_review"} = submitted} =
                   Tasks.submit_plan_for_review(plan)

          send(self(), {:submitted, submitted.id})
        end)

      # Router's native dispatcher swallows the raise internally
      # ("native dispatcher raised" warning) — either that OR our
      # own `[Responsibilities] architecture.review_plan crashed`
      # warning is acceptable evidence that the crash was caught.
      # The important assertion is the transition + broadcast below.
      assert log =~ "native dispatcher raised" or
               log =~ "[Responsibilities] architecture.review_plan crashed" or
               log =~ "[Responsibilities] architecture.review_plan exited"

      submitted_id =
        receive do
          {:submitted, id} -> id
        after
          0 -> flunk("no submitted id captured")
        end

      # Broadcast still fires — the crash cannot stall the board.
      assert_receive {:plan_updated, %Plan{id: ^submitted_id, status: "pending_review"}}
    end
  end

  defmodule CrashingDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: raise("simulated architect crash")
  end

  # ── ADR-0046 member 1 stage 4: the hook OBSERVES the fire result ──────
  #
  # `fire_architecture_review_plan/1` used to throw the fire result away.
  # Combined with the pre-task Router, which laundered every outcome into
  # a flat `:ok`, an architect endpoint that was DOWN was indistinguishable
  # from "no architect assigned": the plan went to review unreviewed and
  # nothing in the log said so.
  #
  # The two halves below are deliberately separated:
  #   * GUARD  — the lifecycle transition still succeeds. Passes either
  #     way; it exists so the detector cannot be satisfied by breaking
  #     fire-and-forget.
  #   * DETECTOR — `:failed` telemetry AND the new warning. Cannot pass
  #     against pre-task code, where the hook only ever saw `:ok`.
  describe "submit_plan_for_review/1 — architect assigned but endpoint down (external)" do
    alias Platform.ExternalAgents.EphemeralCredentials

    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :architect_plan_hook_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      :ok
    end

    # External sibling of `wire_architect_assignee/0`. Mirrors
    # `wire_external_assignee/1` at
    # test/platform/responsibilities/router_test.exs:1088-1128 — an HTTP
    # endpoint is the only assignee kind whose failure the Router can
    # actually observe (the native path returns `{:ok, :dispatched}` on
    # handoff; see the Router moduledoc's honesty limit).
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
        responsibility_key: @architect_key
      })
      |> Repo.insert!()

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "architect-plan-ext-#{System.unique_integer([:positive])}",
          name: "Fixture Architect External",
          status: "active",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://api.example.test",
          model: "test-model",
          workspace_id: nil
        })
        |> Repo.insert!()

      :ok = EphemeralCredentials.put(agent.id, "sk-architect-plan-hook")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      {:ok, _} = Roles.assign_role(role_key, agent.id)

      agent
    end

    test "GUARD: the plan still reaches pending_review; DETECTOR: the failure is logged",
         %{plan: plan} do
      _handler_id = attach_telemetry([[:platform, :responsibility, :failed]])
      _agent = wire_external_architect!()

      test_pid = self()

      Req.Test.stub(:architect_plan_hook_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      log =
        capture_log([level: :info], fn ->
          send(test_pid, {:result, Tasks.submit_plan_for_review(plan)})
        end)

      # ── GUARD half (passes either way — fire-and-forget must hold) ────
      assert_received {:result, {:ok, %Plan{status: "pending_review"}}}
      assert %Plan{status: "pending_review"} = Repo.get!(Plan, plan.id)

      # Mechanism proof: the Router really did resolve an assignee and
      # really did call the endpoint, so the detector below is not
      # passing because the hook short-circuited somewhere earlier.
      assert_receive {:external_dispatch, "/chat/completions"}

      # ── DETECTOR half (impossible before this stage) ──────────────────
      assert_receive {:telemetry, [:platform, :responsibility, :failed], _measurements,
                      %{key: @architect_key, dispatch_kind: :external}}

      assert log =~
               "[Responsibilities] architecture.review_plan dispatch failed " <>
                 "plan=#{plan.id} task=#{plan.task_id}"

      assert log =~ "dispatch_failed"
    end
  end

  test "unfilled architecture.review_plan logs at info, not warning (progressive enhancement)",
       %{plan: plan} do
    # The second new branch: `{:ok, :unfilled}` is a steady state, so it
    # must not be reported as a dispatch failure. The module level has to
    # come down for the same reason the setup lowers the Router's: the
    # test env's global Logger level filters :info before `capture_log`
    # ever sees it.
    Logger.put_module_level(Platform.Tasks, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Tasks) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, _} = Tasks.submit_plan_for_review(plan)
      end)

    assert log =~
             "[Responsibilities] architecture.review_plan unfilled " <>
               "plan=#{plan.id} task=#{plan.task_id}"

    refute log =~ "architecture.review_plan dispatch failed"
  end

  # ── invariant guard ────────────────────────────────────────────────────

  test "sanity: no-architect and with-architect paths return identically shaped {:ok, plan}",
       %{plan: plan, task: task, project: project} do
    # Path A: no architect assigned. Fires the fixture plan.
    capture_log(fn ->
      assert {:ok, %Plan{status: "pending_review", task_id: tid_a}} =
               Tasks.submit_plan_for_review(plan)

      assert tid_a == task.id
    end)

    # Path B needs a fresh task because `create_plan/1` refuses a
    # second draft when the parent task already has a plan in
    # pending_review (see `Platform.Tasks.create_plan/1`).
    {:ok, task_b} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Hook Test Task B",
        status: "planning"
      })

    {:ok, plan_b} = Tasks.create_plan(%{task_id: task_b.id})

    override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
    _agent = wire_architect_assignee()

    capture_log(fn ->
      assert {:ok, %Plan{status: "pending_review", task_id: tid_b}} =
               Tasks.submit_plan_for_review(plan_b)

      assert tid_b == task_b.id
    end)

    # Guard: both parent tasks retain planning status until
    # approve_plan/2 fires (the hook must not accidentally advance
    # the task).
    assert %Task{status: "planning"} = Tasks.get_task_record(task.id)
    assert %Task{status: "planning"} = Tasks.get_task_record(task_b.id)
  end

  # ── ADR-0046 member 4 stage 3: the hook PERSISTS the fire result ───────
  #
  # Member 1 (wave 1) made the Router honest and centralised the
  # fire-result → outcome mapping in `Responsibilities.outcome/1`.
  # Member 019f9b27 stage 4 made this hook OBSERVE the result (log +
  # telemetry). This stage makes it DURABLE: the outcome lands in
  # `tasks.planning_step_outcomes["architecture"]`, and the
  # `tasks.planning_step` cursor moves to `"architecting"` for the
  # duration of the dispatch and back to `"planning"` afterwards.
  #
  # Everything here reads the row back from the database. A log line is
  # not evidence a merge-time reader can consult.
  describe "submit_plan_for_review/1 — architecture step outcome persistence" do
    defp architecture_entry(task_id) do
      Task
      |> Repo.get!(task_id)
      |> Map.fetch!(:planning_step_outcomes)
      |> Map.get("architecture")
    end

    # ── DETECTOR ────────────────────────────────────────────────────────
    #
    # The one mandatory detector for this task. Two submits down the SAME
    # code path, differing only in why the architect did not review:
    #
    #   A — nobody holds `architecture.review_plan`  → `not_applicable`
    #   B — an agent holds it and the endpoint is down → `failed`
    #
    # Against pre-member-1 code these are indistinguishable: the Router
    # laundered both into a flat `:ok`, so both would record the same
    # value and the inequality below cannot pass. That conflation is the
    # bug ADR-0046:83 forbids — `not_applicable` is the progressive-
    # enhancement path, `failed` is a gate that was supposed to run and
    # did not.
    #
    # Written as a direct inequality rather than two equalities so that a
    # future refactor collapsing the two values fails ONE named test
    # instead of two unrelated ones.
    test "DETECTOR: an unfilled architect and a failed dispatch record DIFFERENT outcomes",
         %{plan: plan, task: task, project: project} do
      {:ok, _} = Application.ensure_all_started(:req)

      # ── A: no architect holds the responsibility ──────────────────────
      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      end)

      entry_a = architecture_entry(task.id)

      # ── B: an architect holds it, but its endpoint answers 503 ────────
      {:ok, task_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Hook Test Task B (endpoint down)",
          status: "planning"
        })

      {:ok, plan_b} = Tasks.create_plan(%{task_id: task_b.id})

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :architect_plan_hook_dispatch_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      # Reuses the module-level fixture from the "endpoint down" describe
      # above — an HTTP assignee is the only kind whose failure the Router
      # can actually observe (see the Router moduledoc's honesty limit).
      _agent = wire_external_architect!()

      test_pid = self()

      Req.Test.stub(:architect_plan_hook_dispatch_test, fn conn ->
        send(test_pid, {:external_dispatch, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error":"down"}))
      end)

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan_b)
      end)

      # Mechanism proof: the Router really resolved an assignee and really
      # called the endpoint, so "failed" below is not an artefact of the
      # hook short-circuiting somewhere earlier.
      assert_receive {:external_dispatch, "/chat/completions"}

      entry_b = architecture_entry(task_b.id)

      # ── the detector proper ───────────────────────────────────────────
      refute entry_a["outcome"] == entry_b["outcome"]

      assert entry_a["outcome"] == "not_applicable"
      assert entry_b["outcome"] == "failed"

      # `failed` carries WHY; `not_applicable` has nothing to explain.
      assert is_binary(entry_b["detail"])
      assert entry_a["detail"] == nil

      # Both paths still returned {:ok, plan} — neither stalled the flow.
      assert %Plan{status: "pending_review"} = Repo.get!(Plan, plan.id)
      assert %Plan{status: "pending_review"} = Repo.get!(Plan, plan_b.id)
    end

    # ── GUARD: the happy path ───────────────────────────────────────────
    test "GUARD: a dispatched architect records \"complete\" with a timestamp and no detail",
         %{plan: plan, task: task} do
      override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
      _agent = wire_architect_assignee()

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      end)

      entry = architecture_entry(task.id)

      assert entry["outcome"] == "complete"
      assert entry["detail"] == nil
      assert {:ok, _, _} = DateTime.from_iso8601(entry["recorded_at"])

      # A complete step is not a failed gate — the stage-4 merge-time
      # readers must see nothing here.
      refute Tasks.planning_gate_failed?(Repo.get!(Task, task.id))
    end

    # ── GUARD: belt and braces ──────────────────────────────────────────
    #
    # The plan flow must not stall AND the failure must not evaporate.
    # Before this stage the first half held and the second did not: the
    # crash was rescued into `{:error, :architect_crashed}` and then
    # thrown away by `_ =`.
    test "GUARD: a raising handler still yields {:ok, pending_review} AND records \"failed\"",
         %{plan: plan, task: task} do
      override_native_dispatcher(__MODULE__.CrashingDispatcher, :maybe_dispatch)
      _agent = wire_architect_assignee()

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      end)

      assert %Plan{status: "pending_review"} = Repo.get!(Plan, plan.id)

      entry = architecture_entry(task.id)

      assert entry["outcome"] == "failed"
      assert is_binary(entry["detail"])

      # And it reaches the single "a gate did not run" predicate that
      # stage 4's two merge-time writers consult.
      reloaded = Repo.get!(Task, task.id)
      assert Tasks.planning_gate_failed?(reloaded)
      assert [%{step: "architecture", detail: detail}] = Tasks.failed_planning_steps(reloaded)
      assert is_binary(detail)
    end

    # ── GUARD: the cursor moves, and moves back ─────────────────────────
    #
    # `"planning"` is the column DEFAULT, so asserting the final value
    # alone is vacuous. Two things defeat that here:
    #   1. the cursor is parked at `"designing"` BEFORE the submit, so
    #      ending at `"planning"` can only be a write; and
    #   2. the mid-flight `"architecting"` value is observed through the
    #      board broadcast, which proves the first move happened rather
    #      than inferring it from the end state.
    test "GUARD: the cursor moves to architecting during the fire and back to planning",
         %{plan: plan, task: task} do
      override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
      _agent = wire_architect_assignee()

      {:ok, _} = Tasks.set_planning_step(task.id, :designing)
      assert %Task{planning_step: "designing"} = Repo.get!(Task, task.id)

      Tasks.subscribe_board()
      task_id = task.id

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      end)

      # Member 8's dependency: the card live-refreshes off these.
      assert_receive {:task_updated, %Task{id: ^task_id, planning_step: "architecting"}}
      assert_receive {:task_updated, %Task{id: ^task_id, planning_step: "planning"}}

      assert %Task{planning_step: "planning"} = Repo.get!(Task, task_id)

      # ADR-0046 does not add a status. The cursor is a sub-phase of
      # `status == "planning"`, and the transition table is untouched.
      assert %Task{status: "planning"} = Repo.get!(Task, task_id)
    end

    # ── GUARD (paired positive control for the test above) ──────────────
    #
    # Same assertion on a submit with NO architect. If the cursor logic
    # were somehow conditional on an assignee being present, the test
    # above would still pass and this one would not.
    test "GUARD: a submit with no architect also parks the cursor back at planning",
         %{plan: plan, task: task} do
      {:ok, _} = Tasks.set_planning_step(task.id, :designing)

      Tasks.subscribe_board()
      task_id = task.id

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
      end)

      assert_receive {:task_updated, %Task{id: ^task_id, planning_step: "architecting"}}
      assert_receive {:task_updated, %Task{id: ^task_id, planning_step: "planning"}}

      assert %Task{planning_step: "planning"} = Repo.get!(Task, task_id)
      assert architecture_entry(task_id)["outcome"] == "not_applicable"
    end

    # ── GUARD: the mapping is not re-derived here ───────────────────────
    #
    # Stage 2 bound `tasks.ex` to `Responsibilities.outcome/1`. This stage
    # adds the production call site, so re-assert the binding at the point
    # where a future editor is most tempted to write `case fire_result do`.
    test "GUARD: submit_plan_for_review/1 records via record_planning_step/3, not a local case" do
      source = File.read!("lib/platform/tasks.ex")

      assert source =~ "record_architecture_planning_step(updated.task_id, fire_result)"
      assert source =~ "Platform.Responsibilities.outcome("
      refute source =~ ~r/defp?\s+outcome\(/
    end
  end
end
