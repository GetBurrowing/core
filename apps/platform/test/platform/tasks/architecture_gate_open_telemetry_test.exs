defmodule Platform.Tasks.ArchitectureGateOpenTelemetryTest do
  @moduledoc """
  Task 019fa605 stage 4 — make the unrouted-gate class visible AT THE MOMENT
  THE GATE OPENS, and pin the ruling that produced it.

  ## Why an emit at open time and not a counter in a log line

  Stages 1-3 heal the stall. They do not tell an operator it happened until
  after the fact, in an aggregate counter on a reconcile line that names no
  task. `open_architecture_gate_at_submit/1` is the one place in the system
  that knows, synchronously, both that a gate is now holding a plan AND
  whether anything exists that will ever arm its deadline. `routed` is that
  fact, recorded once, keyed to the plan.

  ## What the tests here are and are not

    * `routed` is asserted for a user-assigned AND an agent-assigned fixture
      IN THE SAME TEST. A single-fixture assertion passes just as well
      against `routed: false` hard-coded, which would measure nothing.
    * The unrouted `Logger.info` is asserted present for the user case and
      ABSENT for the agent case, in the same test, for the same reason.
    * The envelope test is deliberately labelled: `:telemetry.execute/3`
      catches and detaches a faulty handler itself, so a raising handler
      cannot reach the caller no matter how the emit is wrapped. That test
      therefore pins "submit survives a bad observer" and NOT the rescue
      clause. The non-vacuous half of the envelope claim is the gated-outcome
      test below it, which detonates if the emit is ever allowed to reach
      `open_architecture_gate_at_submit/1`'s fall-open rescue: that rescue
      calls `settle_ungated_plan_submission/1`, which would auto-approve an
      armed plan whose gate is genuinely open.
    * The citation test follows `process-patterns.md`, "Cite ADR Headings,
      Not Line Numbers": assert the file exists, the heading exists, and the
      section still states the claimed rule. Asserting that an emitted string
      equals a literal is circular — both sides can agree while pointing
      nowhere.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Roles
  alias Platform.Roles.{Role, RoleResponsibility}
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  @architect_key "architecture.review_plan"

  @adr_filename "0046-design-and-architecture-phases-in-planning.md"
  @adr_heading "### Addendum (2026-07-28, task 019fa605): a user planning assignee under auto-approval is supported"

  @migration_filename "20260726051454_add_architecture_verdict_to_plans.exs"

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end

  defp u, do: System.unique_integer([:positive])

  setup do
    # `submit_plan_for_review/1` only reaches `open_architecture_gate_at_submit/1`
    # when `architecture.review_plan` resolves to a real assignee. Production
    # seeds the responsibility row through the Registry boot walk, which is
    # off in the test env, so it is installed per case here — same shape as
    # `submit_plan_for_review_architect_hook_test.exs`.
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
        metadata: %{"owner" => "platform.architecture", "adr" => "0046"}
      })

    override_native_dispatcher(NoopDispatcher, :maybe_dispatch)
    _architect = wire_architect_assignee()

    {:ok, project} = Tasks.create_project(%{name: "Gate Open Telemetry #{u()}"})

    test_pid = self()
    handler_id = "gate-opened-#{u()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :plan, :architecture_gate_opened],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:gate_opened, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{project: project}
  end

  # ── fixtures ───────────────────────────────────────────────────────────
  #
  # Mirrors `task_router_watcher_gate_expiry_sweep_test.exs`. The load-bearing
  # knob is `assignee_type`: it is the ONLY input `should_run?/1` branches on
  # here, so the two fixtures differ in exactly the field `routed` claims to
  # measure.
  defp task_fixture(project, opts) do
    assignee_type = Keyword.get(opts, :assignee_type, "user")
    assignee_id = Keyword.get(opts, :assignee_id, Ecto.UUID.generate())

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Gate open telemetry fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
        assignee_type: assignee_type,
        assignee_id: assignee_id,
        phase_assignees: %{
          "planning" => %{"assignee_id" => assignee_id, "assignee_type" => assignee_type},
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan}
  end

  defp override_native_dispatcher(module, function) do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(:platform, :responsibility_router_native_dispatcher, {module, function})

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
    |> RoleResponsibility.changeset(%{role_key: role_key, responsibility_key: @architect_key})
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "architect-native-#{u()}",
        name: "Fixture Architect",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  defp repo_root do
    # Ancestor walk rather than a fixed `../..`: `mix test` runs from
    # `apps/platform`, but an umbrella-root invocation runs from one level up
    # and a hard-coded relative path would silently resolve to nothing.
    File.cwd!() |> Path.expand() |> find_ancestor_with("docs/decisions", 8)
  end

  defp find_ancestor_with(_path, _dir, 0), do: nil

  defp find_ancestor_with(path, dir, depth) do
    cond do
      File.dir?(Path.join(path, dir)) -> path
      Path.dirname(path) == path -> nil
      true -> find_ancestor_with(Path.dirname(path), dir, depth - 1)
    end
  end

  # ── routed is measuring the assignee, not a constant ───────────────────

  describe "[:platform, :plan, :architecture_gate_opened]" do
    test "carries routed: false for a user-assigned task and routed: true for an otherwise-identical agent-assigned one",
         %{project: project} do
      {user_task, user_plan} = task_fixture(project, assignee_type: "user")

      {agent_task, agent_plan} =
        task_fixture(project, assignee_type: "agent", assignee_id: Ecto.UUID.generate())

      # POSITIVE CONTROL ON THE FIXTURES. If both tasks answered the same
      # here, every assertion below would be satisfiable by a constant.
      refute TaskRouterWatcher.should_run?(Repo.reload!(user_task))
      assert TaskRouterWatcher.should_run?(Repo.reload!(agent_task))

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(user_plan)
        assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(agent_plan)
      end)

      user_plan_id = user_plan.id
      user_task_id = user_task.id
      agent_plan_id = agent_plan.id
      agent_task_id = agent_task.id

      assert_receive {:gate_opened, [:platform, :plan, :architecture_gate_opened], %{count: 1},
                      %{plan_id: ^user_plan_id, task_id: ^user_task_id, routed: false} = user_meta}

      assert_receive {:gate_opened, [:platform, :plan, :architecture_gate_opened], %{count: 1},
                      %{plan_id: ^agent_plan_id, task_id: ^agent_task_id, routed: true} =
                        agent_meta}

      # The audit-shaped keys the sibling plan events already carry
      # (`maybe_auto_approve/1`'s `:auto_approved` emit is the reference).
      for meta <- [user_meta, agent_meta] do
        assert meta.resource_type == "plan"
        assert meta.action == "architecture_gate_opened"
        assert meta.actor_type == "system"
        assert is_binary(meta.deadline_at)
        assert {:ok, _dt, _} = DateTime.from_iso8601(meta.deadline_at)
      end

      assert user_meta.resource_id == user_plan_id
      assert agent_meta.resource_id == agent_plan_id
    end

    test "the unrouted log line names the task and names the sweep as the settler — and is absent for a routed task",
         %{project: project} do
      # `config/test.exs` pins the primary Logger level above `:info`, and
      # `capture_log(level: :info)` only lowers the CAPTURE threshold, not
      # the Logger's own. Without this the assertions below run against an
      # empty string and pass or fail for the wrong reason — same override
      # `submit_plan_for_review_architect_hook_test.exs` applies to the
      # responsibility router.
      Logger.put_module_level(Platform.Tasks, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.Tasks) end)

      # LIVENESS CONTROL for the paired absence below. The responsibility
      # router logs its native dispatch on BOTH paths, so its presence in
      # each captured string proves the capture was live — without it,
      # `refute routed_log =~ "no router"` would be satisfied by a logger
      # that was simply switched off.
      Logger.put_module_level(Platform.Responsibilities.Router, :info)
      on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

      {user_task, user_plan} = task_fixture(project, assignee_type: "user")

      {_agent_task, agent_plan} =
        task_fixture(project, assignee_type: "agent", assignee_id: Ecto.UUID.generate())

      unrouted_log =
        capture_log([level: :info], fn ->
          assert {:ok, _} = Tasks.submit_plan_for_review(user_plan)
        end)

      routed_log =
        capture_log([level: :info], fn ->
          assert {:ok, _} = Tasks.submit_plan_for_review(agent_plan)
        end)

      # Both captures are live.
      assert unrouted_log =~ "[ResponsibilityRouter] native dispatch key=#{@architect_key}"
      assert routed_log =~ "[ResponsibilityRouter] native dispatch key=#{@architect_key}"

      assert unrouted_log =~ user_task.id
      assert unrouted_log =~ user_plan.id
      assert unrouted_log =~ "no router"
      assert unrouted_log =~ "sweep_expired_architecture_gates/0"

      # PAIRED ABSENCE. A log assertion with no negative twin passes against
      # a line emitted unconditionally.
      refute routed_log =~ "no router"
      refute routed_log =~ "sweep_expired_architecture_gates/0"
    end
  end

  # ── the emit cannot disturb the transition it observes ─────────────────

  describe "the emit envelope" do
    test "a raising telemetry handler does not prevent submit_plan_for_review/1 returning {:ok, pending_review}",
         %{project: project} do
      # HONEST LABEL: `:telemetry.execute/3` wraps each handler in its own
      # try/catch and DETACHES a handler that fails, so this raise cannot
      # reach the caller regardless of how the emit is wrapped. This test
      # therefore pins "submit survives a bad observer", which is a real if
      # weak contract, and NOT the rescue clause. The `assert log =~
      # "has been detached"` below is what stops it being vacuous in the
      # other direction: without it the test would also pass against a
      # handler that never ran at all.
      raising_id = "gate-opened-raiser-#{u()}"

      :ok =
        :telemetry.attach(
          raising_id,
          [:platform, :plan, :architecture_gate_opened],
          fn _e, _m, _md, _c -> raise "observer exploded" end,
          nil
        )

      on_exit(fn -> :telemetry.detach(raising_id) end)

      {_task, plan} = task_fixture(project, assignee_type: "user")

      log =
        capture_log(fn ->
          assert {:ok, %Plan{status: "pending_review"}} = Tasks.submit_plan_for_review(plan)
        end)

      assert log =~ "has been detached"

      settled = Repo.reload!(plan)
      assert settled.status == "pending_review"
      assert settled.architecture_verdict["state"] == "pending"
    end

    test "an armed gated submit returns {:ok, _} and leaves the cursor at :architecting — the emit never reaches the fall-open rescue",
         %{project: project} do
      # THE NON-VACUOUS HALF, and its claim is MEASURED rather than argued.
      # `open_architecture_gate_at_submit/1`'s function-level rescue falls
      # open by calling `settle_ungated_plan_submission/1`. Running this file
      # with the emit's own envelope removed and a fault injected inside it
      # produced, on this exact fixture:
      #
      #     left:  {:ok, _}
      #     right: {:error, :architecture_gate_open}
      #
      # So the plan is NOT auto-approved — `approve_plan/3` refuses the open
      # gate, which is the containment working. What breaks instead is the
      # contract: a committed, correctly-gated submit reports failure to its
      # MCP caller, and the fall-open path has already returned the planning
      # cursor to `:planning` while the gate is genuinely holding. Both are
      # asserted below; the arming assertions stay because the auto path is
      # what would make a regression here expensive rather than merely wrong.
      {task, plan} = task_fixture(project, assignee_type: "user", auto_approve_plan: true)

      assert Repo.reload!(task).auto_approve_plan
      assert Repo.reload!(task).phase_assignees["execution"]["assignee_id"]
      assert Repo.reload!(task).phase_assignees["review"]["assignee_id"]

      capture_log([level: :info], fn ->
        assert {:ok, _} = Tasks.submit_plan_for_review(plan)
      end)

      gated = Repo.reload!(plan)
      assert gated.status == "pending_review"
      assert is_nil(gated.auto_approved_at)
      assert {:open, _verdict} = Tasks.architecture_gate(gated.id)

      # The cursor stays where the gate put it. This is the assertion the
      # fall-open path fails even when `approve_plan/3` contains the damage.
      assert Repo.reload!(task).planning_step == "architecting"

      # And the observation still happened.
      plan_id = plan.id
      assert_receive {:gate_opened, _e, _m, %{plan_id: ^plan_id, routed: false}}
    end
  end

  # ── the ruling is recorded where the next planner will look ────────────

  describe "the support-don't-refuse ruling" do
    test "ADR-0046 carries the addendum heading and still states the rule it is cited for" do
      root = repo_root()
      assert root, "could not locate repo root from #{File.cwd!()}"

      path = Path.join([root, "docs", "decisions", @adr_filename])
      assert File.exists?(path), "missing ADR: #{path}"

      body = File.read!(path)

      # 1. The heading exists (headings do not move; line numbers do).
      assert body =~ @adr_heading

      # 2. The section still states the claimed rule. Read the slice from the
      #    heading to the next same-or-higher-level heading so a later insert
      #    elsewhere in the file cannot satisfy these by accident.
      [_before, after_heading] = String.split(body, @adr_heading, parts: 2)

      section =
        after_heading
        |> String.split(~r/\n#+ /, parts: 2)
        |> List.first()

      assert section =~ "supported"
      assert section =~ "auto_approve_plan"
      assert section =~ "auto_accept_plan"

      # The two mechanisms the ruling rests on — the reason the combination
      # is supported rather than refused.
      assert section =~ "Platform.Responsibilities.fire/2"
      assert section =~ "settle_ungated_plan_submission/1"

      # ...and the one corner that genuinely stalled, without which "it
      # works" would be an overclaim.
      assert section =~ "silent-architect"

      # The invariant, stated as one line.
      assert section =~ "THE ROUTER IS AN OPTIMISATION, THE WATCHER SWEEP IS THE GUARANTEE"

      # THE EXPIRY CONDITION. A decision recorded without a falsifier is how
      # someone later obeys a rule whose justification has lapsed.
      assert section =~ "Revisit"

      # PAIRED ABSENCE, and it enforces a real org convention rather than a
      # phrasing preference: `process-patterns.md`, "Cite ADR Headings, Not
      # Line Numbers". A `file.ex:123` citation records no expected content,
      # so no guard can ever tell whether it still resolves.
      refute section =~ ~r/\.(ex|exs|md):\d+/
    end

    test "the architecture_verdict migration no longer asserts that no gate scan exists" do
      root = repo_root()
      assert root

      path =
        Path.join([root, "apps", "platform", "priv", "repo", "migrations", @migration_filename])

      assert File.exists?(path), "missing migration: #{path}"

      body = File.read!(path)

      # The claim stage 1 falsified must be marked superseded where a reader
      # of the migration will meet it, and must name what superseded it.
      assert body =~ "sweep_expired_architecture_gates/0"
      assert body =~ "@gate_expiry_sweep_cap"

      # PAIRED: the follow-up is named but explicitly NOT taken, so a later
      # reader does not mistake the note for a pending obligation.
      assert body =~ "partial index"
      refute body =~ "create index(:plans"
    end
  end
end
