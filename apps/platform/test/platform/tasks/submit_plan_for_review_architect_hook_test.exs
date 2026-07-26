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
end
