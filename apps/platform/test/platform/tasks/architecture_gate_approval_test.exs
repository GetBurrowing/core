defmodule Platform.Tasks.ArchitectureGateApprovalTest do
  @moduledoc """
  ADR-0046 member 5, stage 3 — the guard at the single approval choke point
  and `Tasks.resolve_architecture_gate/3`, the single exit from the gate.

  Stage 2 deferred the AUTO path. This stage closes the other two approval
  writers, one of which is agent-reachable: the MCP `plan_approve` tool
  lives in the `plan` capability bundle and defaults `approved_by` to the
  literal string `"system"`. Both halves of the detector are required —
  closing it only at the context function leaves the tool free to regress
  independently.

  Not `async: true`: `approve_plan/3` broadcasts `{:task_updated, _}` on
  `tasks:board` via `apply_dispatch_gate/1`, which wakes the singleton
  `TaskRouterWatcher` (see `019fa003-091a`). Fixtures go through
  `Repo.insert!` where the shape allows for the same reason.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Federation.ToolSurface
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Task}

  # ── fixtures ───────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Gate Approval Project #{u()}"})
    %{project: project}
  end

  defp user_fixture do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Reviewer #{n}",
      email: "reviewer-#{n}@example.com",
      oidc_sub: "gate-approval-sub-#{n}"
    })
  end

  # A task that WOULD auto-approve on submit: flag on (unless overridden)
  # and both `auto_approve_precondition/2` legs satisfied — stages plus
  # execution and review assignees. Without all three the "it auto-approved
  # late" assertions below would pass for the wrong reason.
  defp gate_fixture(project, opts \\ []) do
    attrs =
      %{
        project_id: project.id,
        title: "Gate approval fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, true),
        phase_assignees: %{
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      }
      |> then(fn a ->
        case Keyword.get(opts, :sponsor_user_id) do
          nil -> a
          id -> Map.put(a, :sponsor_user_id, id)
        end
      end)

    {:ok, task} = Tasks.create_task(attrs)
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan}
  end

  # Put the plan in the state the gated submit leaves it in, WITHOUT going
  # through `submit_plan_for_review/1`: `pending_review`, gate open, cursor
  # parked at `:architecting`. Direct so these tests exercise the approval
  # guard rather than re-testing stage 2's branch — the one test that
  # genuinely needs the real submit (the deferred sponsor row) wires the
  # architect for real.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    gated
  end

  defp reload(%Plan{id: id}), do: Repo.get!(Plan, id)
  defp reload(%Task{id: id}), do: Repo.get!(Task, id)

  defp architecture_entry(task_id) do
    (Repo.get!(Task, task_id).planning_step_outcomes || %{})
    |> Map.get("architecture", %{})
  end

  defp attach_telemetry(events) do
    handler_id = "gate-approval-#{u()}"
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

  defp plan_review_row_count(user_id) do
    user_id |> Inbox.list_unread_for_user(kind: "task_plan_review") |> length()
  end

  # ── DETECTOR ──────────────────────────────────────────────────────────
  #
  # The mandatory fix detector for this stage. Against `main`, and against
  # this branch with the `architecture_gate_admission/2` case in
  # `approve_plan/3` reverted to a bare `do_approve_plan/3` call, BOTH
  # halves return an approved plan: the context function approves and the
  # MCP tool reports success. Detonation output is in the stage report.
  #
  # Two halves, not one, because they are two independently regressable
  # surfaces. `plan_approve` defaults `approved_by` to `"system"` and is
  # held by every runtime carrying the `plan` bundle — including the
  # architect's own runtime. A guard that only covered the context
  # function would ship a gate with an agent standing next to the bypass.

  describe "DETECTOR: an open gate refuses a non-human approval" do
    test "Tasks.approve_plan/3 refuses \"system\" and leaves the plan untouched", %{
      project: project
    } do
      {task, plan} = gate_fixture(project)
      gated = open_gate!(task, plan)

      assert {:error, :architecture_gate_open} = Tasks.approve_plan(gated, "system")

      # Read the ROW: the claim is about what is persisted, not about the
      # struct we happened to hand in.
      reloaded = reload(gated)
      assert reloaded.status == "pending_review"
      assert reloaded.approved_by == nil
      assert reloaded.approved_at == nil
      assert reloaded.auto_approved_at == nil

      # The gate is still OPEN — a refusal must not consume it.
      assert Tasks.architecture_gate_open?(reloaded)
      assert {:open, %{"state" => "pending"}} = Tasks.architecture_gate(reloaded)
    end

    test "the MCP plan_approve tool refuses too, with a typed envelope", %{project: project} do
      {task, plan} = gate_fixture(project)
      gated = open_gate!(task, plan)

      assert {:error, envelope} =
               ToolSurface.execute("plan_approve", %{"plan_id" => gated.id}, %{})

      assert envelope.recoverable == true
      assert envelope.error =~ "architecture gate"
      assert is_binary(envelope.suggestion)

      reloaded = reload(gated)
      assert reloaded.status == "pending_review"
      assert reloaded.approved_by == nil
      assert Tasks.architecture_gate_open?(reloaded)
    end

    test "an agent slug and \"system:auto\" are refused on the same mechanism", %{
      project: project
    } do
      for actor <- ["system:auto", "moore", "reviewer:test", Ecto.UUID.generate()] do
        {task, plan} = gate_fixture(project)
        gated = open_gate!(task, plan)

        assert {:error, :architecture_gate_open} = Tasks.approve_plan(gated, actor),
               "expected #{inspect(actor)} to be refused past an open gate"

        assert reload(gated).status == "pending_review"
      end
    end
  end

  # ── GUARD (positive control on the SAME mechanism) ────────────────────
  #
  # Deliberately a POSITIVE control: it passes against unfixed `main` too,
  # because on `main` every approval succeeds. It cannot detect the bug
  # alone and is not claimed to. Its job is to stop the detector above
  # from being satisfied by a guard that refuses everything — which is
  # the cheapest wrong fix available here, and would take the human
  # approval button down with it.

  describe "GUARD: a human may approve past an open gate" do
    test "approval succeeds, the verdict records human_override, and telemetry fires", %{
      project: project
    } do
      user = user_fixture()
      {task, plan} = gate_fixture(project, auto_approve_plan: false)
      gated = open_gate!(task, plan)

      _handler = attach_telemetry([[:platform, :plan, :architecture_gate_overridden]])

      assert {:ok, %Plan{status: "approved"}} = Tasks.approve_plan(gated, user.id)

      reloaded = reload(gated)
      assert reloaded.status == "approved"
      assert reloaded.approved_by == user.id
      assert reloaded.approved_at != nil

      verdict = reloaded.architecture_verdict
      assert verdict["state"] == "human_override"
      assert verdict["resolved_by"] == user.id
      assert verdict["source"] == "human"
      assert is_binary(verdict["resolved_at"])

      # The bypass is not silent.
      assert_receive {:telemetry, [:platform, :plan, :architecture_gate_overridden], %{count: 1},
                      %{
                        plan_id: plan_id,
                        resolved_by: resolved_by,
                        resource_type: "plan",
                        action: "architecture_gate_overridden",
                        actor_type: "user"
                      }}

      assert plan_id == gated.id
      assert resolved_by == user.id

      # The gate is CLOSED, not still open: a second approval attempt by a
      # non-human would now be inert rather than refused.
      refute Tasks.architecture_gate_open?(reloaded)
      assert {:resolved, _} = Tasks.architecture_gate(reloaded)

      # The cursor came back — the override went through the one exit.
      assert %Task{planning_step: "planning"} = reload(task)
    end
  end

  # ── GUARD: the ~40 pre-existing call sites ────────────────────────────
  #
  # `architecture_verdict == nil` means the gate never opened for this
  # plan version, `architecture_gate/1` returns `:none`, and the guard is
  # inert. This is the regression net for every existing `approve_plan`
  # caller passing `"system"` / `"reviewer:test"` / a random UUID.

  describe "GUARD: no gate, no change" do
    test "approve_plan/3 with a nil verdict behaves exactly as before", %{project: project} do
      {task, plan} = gate_fixture(project, auto_approve_plan: false)
      {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      assert submitted.architecture_verdict == nil
      assert Tasks.architecture_gate(submitted) == :none

      assert {:ok, %Plan{status: "approved"}} = Tasks.approve_plan(submitted, "system")

      reloaded = reload(submitted)
      assert reloaded.approved_by == "system"

      # Still `:none` — an inert guard must not leave a verdict behind.
      assert reloaded.architecture_verdict == nil
      assert %Task{status: "in_progress"} = reload(task)
    end
  end

  # ── GUARD: `:pass` runs the deferred tail, late instead of never ──────

  describe "resolve_architecture_gate/3 — :pass" do
    test "the deferred auto-approval genuinely runs on resolution", %{project: project} do
      {task, plan} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      # Precondition: stage 2's deferral is what we are resuming.
      assert reload(gated).status == "pending_review"

      assert {:ok, %Plan{status: "approved"}} = Tasks.resolve_architecture_gate(gated, :pass)

      reloaded = reload(gated)
      assert reloaded.status == "approved"
      assert reloaded.approved_by == "system:auto"
      assert reloaded.auto_approved_at != nil
      assert reloaded.architecture_verdict["state"] == "passed"
      assert reloaded.architecture_verdict["source"] == "architect"

      assert %Task{planning_step: "planning"} = reload(task)
    end

    test "the sponsor plan-review row is emitted on resolution, not at submit", %{
      project: project
    } do
      sponsor = user_fixture()

      # This one goes through the REAL gated submit, because the claim is
      # about which of the two moments emits the row.
      dispatcher = wire_architect!()

      {_task, plan} =
        gate_fixture(project, auto_approve_plan: false, sponsor_user_id: sponsor.id)

      before_submit = plan_review_row_count(sponsor.id)

      gated =
        capture_log([level: :info], fn ->
          assert {:ok, %Plan{status: "pending_review"} = g} = Tasks.submit_plan_for_review(plan)
          send(self(), {:gated, g.id})
        end)
        |> then(fn _log ->
          receive do
            {:gated, id} -> Repo.get!(Plan, id)
          after
            0 -> flunk("no gated plan captured")
          end
        end)

      assert Tasks.architecture_gate_open?(gated)
      submit_delta = plan_review_row_count(sponsor.id) - before_submit

      before_resolve = plan_review_row_count(sponsor.id)
      assert {:ok, _} = Tasks.resolve_architecture_gate(gated, :pass)
      resolve_delta = plan_review_row_count(sponsor.id) - before_resolve

      # Deferred, not lost — asserted as a delta across the two moments so
      # neither half can be satisfied by an inbox that emits nothing.
      assert submit_delta == 0
      assert resolve_delta == 1

      # …and the plan is still awaiting the human it just notified.
      assert reload(gated).status == "pending_review"

      :ok = unwire_architect!(dispatcher)
    end
  end

  # ── GUARD: `:reject` STOPS — and the member-6 seam is asserted ────────

  describe "resolve_architecture_gate/3 — :reject" do
    test "parks the plan, emits nothing, approves nothing, and creates no v2", %{
      project: project
    } do
      sponsor = user_fixture()

      {task, plan} =
        gate_fixture(project, auto_approve_plan: true, sponsor_user_id: sponsor.id)

      gated = open_gate!(task, plan)
      before_rows = plan_review_row_count(sponsor.id)

      assert {:ok, %Plan{status: "pending_review"}} =
               Tasks.resolve_architecture_gate(gated, :reject,
                 summary: "Crosses a context boundary",
                 findings: [%{"constraint" => "module_boundary", "detail" => "Two contexts"}]
               )

      reloaded = reload(gated)
      assert reloaded.status == "pending_review"
      assert reloaded.approved_by == nil
      assert reloaded.auto_approved_at == nil

      verdict = reloaded.architecture_verdict
      assert verdict["state"] == "rejected"
      assert verdict["summary"] == "Crosses a context boundary"
      assert [%{"constraint" => "module_boundary"}] = verdict["findings"]

      # `auto_approve_plan: true` on the task — so this is a real refusal
      # to settle, not a fixture that could never have approved.
      assert reload(task).auto_approve_plan == true
      assert %Task{planning_step: "planning", status: "planning"} = reload(task)

      assert plan_review_row_count(sponsor.id) - before_rows == 0

      # THE MEMBER-6 SEAM, asserted rather than described: the v2
      # supersession belongs to `019f9b29-251e`. If a future change starts
      # creating it here, this line names the collision.
      assert length(Tasks.list_plans(task.id)) == 1
    end
  end

  # ── GUARD: `:expired` falls open AND is recorded — both, in one test ──
  #
  # Separately asserted, one could regress alone. Falling open without
  # recording is the exact conflation ADR-0046:83 forbids.

  describe "resolve_architecture_gate/3 — :expired" do
    test "the plan proceeds to approval and the architecture step reads \"failed\"", %{
      project: project
    } do
      {task, plan} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      # Seed the step the gated submit wrote, so the assertion below is a
      # genuine OVERWRITE rather than a first write into an empty map.
      {:ok, _} = Tasks.record_planning_step(task.id, :architecture, {:ok, :dispatched})
      assert architecture_entry(task.id)["outcome"] == "complete"

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "approved"}} =
                 Tasks.resolve_architecture_gate(gated, :expired)
      end)

      reloaded = reload(gated)

      # FALL OPEN (ADR-0046 decision 7).
      assert reloaded.status == "approved"
      assert reloaded.approved_by == "system:auto"
      assert reloaded.architecture_verdict["state"] == "expired"
      assert reloaded.architecture_verdict["source"] == "deadline"

      # …AND SAY SO (ADR-0046:83). Member 4's merge-time surface reads this.
      entry = architecture_entry(task.id)
      assert entry["outcome"] == "failed"
      assert Tasks.planning_gate_failed?(reload(task))
    end

    test "a late verdict racing the deadline loses, deterministically", %{project: project} do
      {task, plan} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "approved"}} =
                 Tasks.resolve_architecture_gate(gated, :expired)
      end)

      # The architect answers after the deadline already wrote.
      assert {:error, :gate_already_resolved} =
               Tasks.record_architecture_verdict(gated, %{"state" => "rejected"})

      assert {:error, :gate_already_resolved} =
               Tasks.resolve_architecture_gate(gated, :reject)

      reloaded = reload(gated)
      assert reloaded.status == "approved"
      assert reloaded.architecture_verdict["state"] == "expired"
    end
  end

  # ── GUARD: `:dispatch_failed` is the same fall-open, differently sourced

  describe "resolve_architecture_gate/3 — :dispatch_failed" do
    test "falls open, records \"failed\", and is distinguishable from :expired", %{
      project: project
    } do
      {task, plan} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      capture_log([level: :info], fn ->
        assert {:ok, %Plan{status: "approved"}} =
                 Tasks.resolve_architecture_gate(gated, :dispatch_failed)
      end)

      reloaded = reload(gated)
      assert reloaded.status == "approved"
      assert reloaded.architecture_verdict["state"] == "dispatch_failed"
      assert reloaded.architecture_verdict["source"] == "dispatch"
      assert architecture_entry(task.id)["outcome"] == "failed"
    end
  end

  # ── GUARD: the gate is read from the ROW, never from the struct ───────
  #
  # `AutoMerger` hands a task into an async `Task.start`, and this
  # function is reachable from a LiveView holding a struct assigned on
  # mount. A guard that trusted its argument would fall open for anyone
  # holding a pre-gate copy.

  describe "GUARD: stale struct" do
    test "a struct loaded before the gate opened is still refused", %{project: project} do
      {task, plan} = gate_fixture(project, auto_approve_plan: false)
      {:ok, stale} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      assert stale.architecture_verdict == nil

      {:ok, _gated} = Tasks.open_architecture_gate(stale, nil)

      # `stale` still carries `architecture_verdict: nil` in memory.
      assert stale.architecture_verdict == nil
      assert {:error, :architecture_gate_open} = Tasks.approve_plan(stale, "system")

      assert reload(task).id == task.id
      assert Repo.get!(Plan, stale.id).status == "pending_review"
    end
  end

  # ── architect wiring, for the one test that needs a real gated submit ─

  defp wire_architect! do
    alias Platform.Agents.Agent
    alias Platform.Roles
    alias Platform.Roles.{Role, RoleResponsibility}

    {:ok, _row} =
      Platform.Responsibilities.upsert_by_key(%{
        key: "architecture.review_plan",
        feature: "architecture",
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => "plan:submitted"},
        scope: "per_project",
        context_provided: ["plan_payload"],
        output_contract: %{"comments" => "list[map]"},
        default_prompt_template: "architecture.review_plan.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.architecture", "adr" => "0046"}
      })

    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {__MODULE__.NoopDispatcher, :maybe_dispatch}
    )

    Repo.insert!(
      %Role{key: "historian", name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: "architecture.review_plan"
    })
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "gate-approval-architect-#{u()}",
        name: "Fixture Architect",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role("historian", agent.id)

    previous
  end

  defp unwire_architect!(previous) do
    import Ecto.Query, only: [from: 2]

    Repo.delete_all(
      from(rr in Platform.Roles.RoleResponsibility,
        where: rr.responsibility_key == "architecture.review_plan"
      )
    )

    if previous do
      Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
    else
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end

    :ok
  end

  defmodule NoopDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal), do: :ok
  end
end
