defmodule Platform.Tasks.HumanTransitionsTest do
  @moduledoc """
  Task 01a18e02 stage 1: humans move freely, agents keep every gate.

  A `{:user, _}` actor gets the human transition table through
  `Tasks.allowed_next_statuses/2` and is never blocked by
  `require_approved_plan_for/3`. Every other actor keeps
  `Tasks.valid_task_transitions/0` and the plan gate. A human close
  (backlog, planning or blocked straight to done) is recorded with
  `via: "human_close"`.

  Every refusal here is paired with a positive control of the same shape:
  a rule that refused everything would satisfy a lone `{:error, _}`.

  Mutation probes this file is built to catch (run for stage 1):

    * `{"user", id}` -> `_` in `allowed_next_statuses/2` (every actor gets
      the human table): (c), (d) and (f) go red.
    * the user clause deleted from `require_approved_plan_for/3`: (a) goes
      red.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, Task, TransitionActor}

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Human Transitions #{System.unique_integer([:positive])}"})

    %{project: project, agent_id: insert_agent(), user: insert_user()}
  end

  defp insert_agent do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "human-tx-#{n}", name: "Human Tx Agent #{n}", status: "active"}).id
  end

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Human #{n}",
      email: "human-tx-#{n}@example.com",
      oidc_sub: "human-tx-sub-#{n}"
    })
  end

  defp task!(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Human tx #{System.unique_integer([:positive])}"},
          attrs
        )
      )

    task
  end

  # The stuck BizDev shape (01a18b3a, 01a18dbe-348e): no sponsor, a planning
  # agent in `phase_assignees`, the flat pointer on that agent, no plan.
  # Written with a bare change so no transition row is recorded by setup.
  defp bizdev_task!(project, agent_id, status) do
    project
    |> task!(%{})
    |> Ecto.Changeset.change(%{
      status: status,
      sponsor_user_id: nil,
      assignee_id: agent_id,
      assignee_type: "agent",
      phase_assignees: %{
        "planning" => %{"assignee_id" => agent_id, "assignee_type" => "agent"}
      }
    })
    |> Repo.update!()
  end

  defp approve_plan!(%Task{} = task) do
    {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    task
  end

  defp rows(task_id), do: PhaseTransitions.list_for_task(task_id)

  describe "(a) the stuck BizDev shape closes from the board" do
    test "a user drop planning -> done lands, recorded as a human close", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "planning")

      # The shape really is the stuck one: no plan, no sponsor bypass.
      assert Tasks.current_plan(task.id) == nil
      refute Tasks.sponsor_bypasses_plan_gate?(task, {:user, ctx.user.id})
      assert rows(task.id) == []

      assert {:ok, %{status: "done"}} =
               Tasks.drop_task_to_column(task, "done", {:user, ctx.user.id})

      assert Repo.get!(Task, task.id).status == "done"

      assert [row] = rows(task.id)
      assert row.from_status == "planning"
      assert row.to_status == "done"
      assert row.actor_kind == "user"
      assert row.actor_id == ctx.user.id
      assert row.via == "human_close"
    end
  end

  describe "(b) the panel closes a backlog task" do
    test "transition_task backlog -> done as a user, recorded as a human close", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done", {:user, ctx.user.id})

      assert [row] = rows(task.id)
      assert row.from_status == "backlog"
      assert row.to_status == "done"
      assert row.actor_kind == "user"
      assert row.actor_id == ctx.user.id
      assert row.via == "human_close"
    end

    test "blocked -> done is a human close too", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "blocked")

      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done", {:user, ctx.user.id})

      assert [%{from_status: "blocked", via: "human_close", actor_kind: "user"}] = rows(task.id)
    end

    test "CONTROL: a human move that is not a close keeps its ordinary via", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:ok, %{status: "in_review"}} =
               Tasks.drop_task_to_column(task, "in_review", {:user, ctx.user.id})

      assert {:ok, %{status: "done"}} =
               Tasks.transition_task(Repo.get!(Task, task.id), "done", {:user, ctx.user.id})

      assert [first, second] = rows(task.id)

      assert {first.from_status, first.to_status, first.via} ==
               {"backlog", "in_review", "drop_task_to_column"}

      # in_review -> done went through execution: not a human close.
      assert {second.from_status, second.to_status, second.via} ==
               {"in_review", "done", "transition_task"}
    end
  end

  describe "(c) agents stay refused through MCP task_update" do
    test "backlog -> done as an agent is refused with the unchanged table text", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:error, %{error: error}} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "status" => "done"},
                 %{agent_id: ctx.agent_id}
               )

      assert error =~
               "Valid next statuses from 'backlog': planning, blocked, in_progress, stack_pending, cancelled."

      assert Repo.get!(Task, task.id).status == "backlog"
      assert rows(task.id) == []
    end

    test "CONTROL: the same agent call on an agent edge is accepted", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:ok, _} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "status" => "planning"},
                 %{agent_id: ctx.agent_id}
               )

      assert Repo.get!(Task, task.id).status == "planning"
    end

    # Architecture must-have: no agent-originated path can carry the human
    # table. MCP derives the actor from the call context and never yields a
    # user, and the ambient `TransitionActor` context is NOT read by the
    # table: agent or engine code running inside a user's `with_actor` block
    # still gets the agent table.
    test "agent calls inside a user's with_actor block still get the agent table", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      TransitionActor.with_actor({:user, ctx.user.id}, "outer_user_block", fn ->
        assert {:error, %{error: error}} =
                 ToolSurface.execute(
                   "task_update",
                   %{"task_id" => task.id, "status" => "done"},
                   %{agent_id: ctx.agent_id}
                 )

        assert error =~ "Valid next statuses from 'backlog'"

        # A context with no agent id is still an agent, never a user.
        assert {:error, %{error: _}} =
                 ToolSurface.execute(
                   "task_update",
                   %{"task_id" => task.id, "status" => "done"},
                   %{}
                 )

        # The engine primitive ignores the ambient user too.
        assert {:error, :invalid_transition} = Tasks.transition_task_status(task, "done")
      end)

      assert Repo.get!(Task, task.id).status == "backlog"
      assert rows(task.id) == []
    end
  end

  describe "(d) agent and system actors keep the agent table on transition_task" do
    # An APPROVED plan is present so the plan gate is open and the transition
    # table is the only thing that can refuse. Without it the plan gate would
    # answer `:no_approved_plan` first and this would not test the table.
    test "backlog -> done as an agent or :system is an invalid transition", ctx do
      task = ctx.project |> bizdev_task!(ctx.agent_id, "backlog") |> approve_plan!()

      assert {:error, :invalid_transition} =
               Tasks.transition_task(task, "done", {:agent, ctx.agent_id})

      assert {:error, :invalid_transition} = Tasks.transition_task(task, "done", :system)

      assert Repo.get!(Task, task.id).status == "backlog"
      assert rows(task.id) == []

      # CONTROL, same task: the human actor is accepted.
      assert {:ok, %{status: "done"}} = Tasks.transition_task(task, "done", {:user, ctx.user.id})
    end

    test "with no plan an agent is refused too, and nothing moves", ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:error, _} = Tasks.transition_task(task, "done", {:agent, ctx.agent_id})
      assert {:error, _} = Tasks.transition_task(task, "done", :system)
      assert Repo.get!(Task, task.id).status == "backlog"
    end
  end

  describe "(e) agents still cannot start or finish their own work without a plan" do
    test "apply_task_update into in_progress as an agent with no plan is :no_approved_plan",
         ctx do
      task = bizdev_task!(ctx.project, ctx.agent_id, "backlog")

      assert {:error, :no_approved_plan} =
               Tasks.apply_task_update(task, %{},
                 status: "in_progress",
                 actor: {:agent, ctx.agent_id}
               )

      assert Repo.get!(Task, task.id).status == "backlog"

      # CONTROL: the same call by a person is accepted.
      assert {:ok, %{status: "in_progress"}} =
               Tasks.apply_task_update(task, %{},
                 status: "in_progress",
                 actor: {:user, ctx.user.id}
               )
    end
  end

  describe "(f) the agent table is exactly valid_task_transitions/0" do
    test "for every status and every non-user actor", ctx do
      agent_table = Tasks.valid_task_transitions()

      non_users = [
        {:agent, ctx.agent_id},
        :system,
        :unattributed,
        :agent,
        ctx.agent_id,
        {:user, nil},
        nil
      ]

      for from <- Task.statuses(), actor <- non_users do
        assert Tasks.allowed_next_statuses(from, actor) == Map.get(agent_table, from, []),
               "#{inspect(actor)} from #{from}"
      end

      # Anti-vacuity: the two tables really differ where the ticket says.
      refute "done" in Tasks.allowed_next_statuses("backlog", {:agent, ctx.agent_id})
      assert "done" in Tasks.allowed_next_statuses("backlog", {:user, ctx.user.id})
      assert "done" in Tasks.allowed_next_statuses("planning", ctx.user)
    end
  end

  describe "(g) what a human still cannot do" do
    test "no status lets a user target stack_pending; cancelled has no human exit", ctx do
      user = {:user, ctx.user.id}
      agent_table = Tasks.valid_task_transitions()

      for from <- Task.statuses() do
        human = Tasks.allowed_next_statuses(from, user)
        refute "stack_pending" in human, "user may target stack_pending from #{from}"
        refute from in human, "user table lists the self-edge #{from}"

        # `cancelled` as a target stays exactly where the agent table has it,
        # for every status that has human exits at all.
        if from not in ~w(cancelled stack_pending) do
          assert "cancelled" in human == "cancelled" in Map.get(agent_table, from, []),
                 "cancelled reachability differs from the agent table for #{from}"
        end
      end

      assert Tasks.allowed_next_statuses("cancelled", user) == []
      assert Tasks.allowed_next_statuses("stack_pending", user) == []
    end

    test "a user cannot move a cancelled task or park a task in stack_pending", ctx do
      user = {:user, ctx.user.id}
      cancelled = task!(ctx.project, %{status: "cancelled"})

      assert {:error, :invalid_transition} = Tasks.transition_task(cancelled, "backlog", user)
      assert {:error, :invalid_drop} = Tasks.drop_task_to_column(cancelled, "backlog", user)
      assert Repo.get!(Task, cancelled.id).status == "cancelled"

      backlog = task!(ctx.project, %{})
      # A stack guard may answer before the table does (a 3-tuple); either
      # way it is a refusal and nothing is written.
      assert :error == elem(Tasks.transition_task(backlog, "stack_pending", user), 0)
      assert Repo.get!(Task, backlog.id).status == "backlog"
      assert rows(backlog.id) == []
    end
  end
end
