defmodule Platform.Tasks.HumanInertMovesTest do
  @moduledoc """
  Task 01a18e02 stage 2: a human move with no agent assigned just changes
  status.

  "If I move a ticket into development without an agent assigned, same with
  review, it should just do nothing." The BizDev shape (`phase_assignees`
  naming only a planning agent, the flat pointer still on that agent) used
  to keep the planning agent as the pointer when a person moved the task to
  in_progress, and the router then dispatched that agent. The fix clears
  the stale pointer on the same changeset as the status, for user actors
  only.

  ## The counter is proven before it is trusted

  (a) is the POSITIVE CONTROL and comes first: the same rig, with an
  execution agent, a connected runtime and an approved plan, records an
  `execution.dispatch_attempt` RuntimeEvent and arms a `LeaseManager`
  liveness lease.
  Without it, the zero counts in (b) and (c) could come from a rig that
  cannot dispatch at all. The counting mirrors
  `task_router_needs_human_hold_test.exs`; the linked agent/runtime fixture
  mirrors `task_router_delivered_but_open_hold_test.exs`.

  Mutation probe (run for stage 2): remove the inert branch
  (`inert_pointer_attrs/4`) and (b) goes red on its `assignee_id`
  assertion.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Stage, Task}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    previous_debounce = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
    Application.put_env(:platform, :task_router_dispatch_debounce_ms, 1)

    on_exit(fn ->
      if previous_debounce do
        Application.put_env(:platform, :task_router_dispatch_debounce_ms, previous_debounce)
      else
        Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{name: "Human inert moves #{System.unique_integer([:positive])}"})

    {agent, runtime_id} = create_linked_agent_runtime()

    %{project: project, agent: agent, runtime_id: runtime_id, user: create_user()}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp create_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "inert-#{n}@example.com",
      name: "Inert Move User #{n}",
      oidc_sub: "oidc-inert-#{n}"
    })
  end

  # An agent linked to its own activated runtime: the only shape
  # `PhaseRuntime.resolve/1` follows all the way to a runtime id.
  defp create_linked_agent_runtime do
    user = create_user()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "inert-agent-#{System.unique_integer([:positive])}",
        name: "Inert Move Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "inert-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp slot(agent_id), do: %{"assignee_id" => agent_id, "assignee_type" => "agent"}

  # Written with a bare change so no `{:task_updated}` broadcast and no
  # transition row comes from setup.
  defp task!(ctx, attrs) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: ctx.project.id,
        title: "Inert #{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      stop_router_if_running(task.id)
      LeaseManager.clear(task.id)
    end)

    task
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  # The stuck BizDev shape: a planning agent only, flat pointer on it, no
  # plan, no sponsor.
  defp bizdev_task!(ctx) do
    task!(ctx, %{
      status: "backlog",
      sponsor_user_id: nil,
      assignee_id: ctx.agent.id,
      assignee_type: "agent",
      phase_assignees: %{"planning" => slot(ctx.agent.id)}
    })
  end

  defp approved_plan_with_running_stage!(%Task{} = task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "stage one",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, _lint} = Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass"})
    task
  end

  # ── counters ─────────────────────────────────────────────────────────────

  defp dispatch_attempts(task_id) do
    Repo.all(from(e in RuntimeEvent, where: e.task_id == ^task_id))
    |> Enum.count(&(&1.event_type == "execution.dispatch_attempt"))
  end

  defp runtime_events(task_id),
    do: Repo.aggregate(from(e in RuntimeEvent, where: e.task_id == ^task_id), :count)

  defp leases(task_id),
    do: Repo.aggregate(from(l in ExecutionLease, where: l.task_id == ^task_id), :count)

  defp stages(task_id) do
    Repo.aggregate(
      from(s in Stage, join: p in Plan, on: s.plan_id == p.id, where: p.task_id == ^task_id),
      :count
    )
  end

  defp router_running?(task_id),
    do: Registry.lookup(Platform.Orchestration.Registry, task_id) != []

  defp stop_router_if_running(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp should_run?(task_id) do
    task_id
    |> Tasks.get_task_record()
    |> Repo.preload(:project)
    |> TaskRouterWatcher.should_run?()
  end

  # ── (a) POSITIVE CONTROL: the counter can see a dispatch ──────────────────

  describe "(a) positive control" do
    test "an execution agent with an approved plan IS dispatched after a user move", ctx do
      task =
        ctx
        |> task!(%{status: "backlog", phase_assignees: %{"execution" => slot(ctx.agent.id)}})
        |> approved_plan_with_running_stage!()

      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")

      assert {:ok, moved} = Tasks.transition_task(task, "in_progress", {:user, ctx.user.id})
      assert moved.status == "in_progress"
      assert moved.assignee_id == ctx.agent.id
      assert should_run?(task.id)

      assert :ok = TaskRouterWatcher.force_dispatch(task.id)
      :ok = sync_router(task.id)
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      :ok = sync_router(task.id)

      assert dispatch_attempts(task.id) >= 1

      # The dispatch arms the liveness lease (`LeaseManager.record_dispatch`),
      # which is what carries the no-ack and safety-net timers. The
      # `execution_leases` TABLE is NOT written by a dispatch: its rows come
      # from runtime events (ack, start, blocker), so a dispatch with no
      # runtime reply leaves it empty (measured on moon for this stage). It
      # is still counted in (b) and (c) as a zero, never as a control.
      assert %{} = LeaseManager.get(task.id)
    end
  end

  # ── (b) the BizDev shape is inert ─────────────────────────────────────────

  describe "(b) a user drag to in_progress with no execution agent" do
    test "changes status, clears the stale pointer and dispatches nothing", ctx do
      task = bizdev_task!(ctx)
      stages_before = stages(task.id)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")

      assert {:ok, %{status: "in_progress", assignee_id: nil}} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, ctx.user.id})

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.status == "in_progress"
      assert reloaded.assignee_id == nil
      assert reloaded.assignee_type == nil
      # The planning agent is kept where it lives.
      assert reloaded.phase_assignees["planning"]["assignee_id"] == ctx.agent.id

      refute should_run?(task.id)
      assert TaskRouterWatcher.force_dispatch(task.id) == :noop

      refute router_running?(task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert runtime_events(task.id) == 0
      assert LeaseManager.get(task.id) == nil
      assert leases(task.id) == 0
      assert stages(task.id) == stages_before
    end
  end

  # ── (c) the same for in_review through the panel ─────────────────────────

  describe "(c) a user move to in_review with no review agent" do
    test "transition_task/3 changes status and dispatches nothing", ctx do
      task = bizdev_task!(ctx)
      stages_before = stages(task.id)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{ctx.runtime_id}")

      assert {:ok, %{status: "in_review", assignee_id: nil}} =
               Tasks.transition_task(task, "in_review", {:user, ctx.user.id})

      refute should_run?(task.id)
      assert TaskRouterWatcher.force_dispatch(task.id) == :noop

      refute router_running?(task.id)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300
      assert runtime_events(task.id) == 0
      assert LeaseManager.get(task.id) == nil
      assert leases(task.id) == 0
      assert stages(task.id) == stages_before
    end

    test "CONTROL: an engine (:system) move of the same shape keeps today's fallback", ctx do
      task = bizdev_task!(ctx)

      assert {:ok, %{status: "in_progress", assignee_id: agent_id}} =
               Tasks.transition_task_status(task, "in_progress")

      assert agent_id == ctx.agent.id
    end
  end

  # ── (d) coarse mode counts as agent-assigned ─────────────────────────────

  describe "(d) coarse mode" do
    test "an empty phase_assignees with a flat agent is agent-assigned; the move is not inert",
         ctx do
      task =
        task!(ctx, %{
          status: "backlog",
          assignee_id: ctx.agent.id,
          assignee_type: "agent",
          phase_assignees: %{}
        })

      assert Tasks.agent_assigned_for_phase?(task, "execution")
      assert Tasks.agent_assigned_for_phase?(task, "review")

      assert {:ok, %{status: "in_progress", assignee_id: agent_id}} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, ctx.user.id})

      assert agent_id == ctx.agent.id
    end

    test "agent_assigned_for_phase?/2 resolution order", ctx do
      user_id = ctx.user.id
      agent_id = ctx.agent.id

      granular = %Task{
        assignee_id: agent_id,
        assignee_type: "agent",
        phase_assignees: %{
          "planning" => slot(agent_id),
          "review" => %{"assignee_id" => user_id, "assignee_type" => "user"},
          "execution" => %{}
        }
      }

      # The phase entry decides when there is one.
      assert Tasks.agent_assigned_for_phase?(granular, "planning")
      refute Tasks.agent_assigned_for_phase?(granular, "review")
      # Granular mode, no entry (a cleared slot is not an entry): no agent,
      # whatever the flat pointer says.
      refute Tasks.agent_assigned_for_phase?(granular, "execution")

      # A bare id with no type counts as an agent.
      assert Tasks.agent_assigned_for_phase?(
               %Task{phase_assignees: %{"execution" => %{"assignee_id" => agent_id}}},
               "execution"
             )

      # Coarse mode: the flat pointer.
      refute Tasks.agent_assigned_for_phase?(
               %Task{assignee_id: user_id, assignee_type: "user", phase_assignees: %{}},
               "execution"
             )

      refute Tasks.agent_assigned_for_phase?(%Task{phase_assignees: nil}, "execution")
    end
  end

  # ── (e) the confirmation predicate ───────────────────────────────────────

  describe "(e) human_move_needs_confirmation?/3" do
    test "true for an execution agent, no plan, a user, to in_progress; false on each flip",
         ctx do
      user = {:user, ctx.user.id}

      task =
        task!(ctx, %{status: "backlog", phase_assignees: %{"execution" => slot(ctx.agent.id)}})

      assert Tasks.human_move_needs_confirmation?(task, "in_progress", user)

      # Flip: an agent actor.
      refute Tasks.human_move_needs_confirmation?(task, "in_progress", {:agent, ctx.agent.id})
      refute Tasks.human_move_needs_confirmation?(task, "in_progress", :system)

      # Flip: the target.
      refute Tasks.human_move_needs_confirmation?(task, "in_review", user)

      # Flip: no agent.
      no_agent = task!(ctx, %{status: "backlog", phase_assignees: %{}})
      refute Tasks.human_move_needs_confirmation?(no_agent, "in_progress", user)

      # Flip: an approved plan.
      planned =
        ctx
        |> task!(%{status: "backlog", phase_assignees: %{"execution" => slot(ctx.agent.id)}})
        |> approved_plan_with_running_stage!()

      refute Tasks.human_move_needs_confirmation?(planned, "in_progress", user)
    end

    test "it is a warning, not a refusal: the move itself is accepted", ctx do
      task =
        task!(ctx, %{status: "backlog", phase_assignees: %{"execution" => slot(ctx.agent.id)}})

      assert Tasks.human_move_needs_confirmation?(task, "in_progress", {:user, ctx.user.id})

      # Called directly, the server accepts in_progress: humans are never
      # blocked. The UI's confirm (stage 3) sends the task to planning
      # instead, as decided.
      assert {:ok, %{status: "in_progress", assignee_id: agent_id}} =
               Tasks.transition_task(task, "in_progress", {:user, ctx.user.id})

      assert agent_id == ctx.agent.id
    end
  end

  # ── (f) the planning agent comes back ────────────────────────────────────

  describe "(f) moving back to planning" do
    test "restores the planning agent pointer after an inert move", ctx do
      task = bizdev_task!(ctx)

      assert {:ok, %{assignee_id: nil} = inert} =
               Tasks.drop_task_to_column(task, "in_progress", {:user, ctx.user.id})

      assert {:ok, back} = Tasks.transition_task(inert, "planning", {:user, ctx.user.id})
      assert back.status == "planning"
      assert back.assignee_id == ctx.agent.id
      assert back.assignee_type == "agent"
    end
  end
end
