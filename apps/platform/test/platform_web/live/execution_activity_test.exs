defmodule PlatformWeb.ExecutionActivityTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Repo, Tasks, Chat}
  alias Platform.Orchestration.{ExecutionLease, RuntimeSupervision}

  setup %{conn: conn} do
    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "activity#{System.unique_integer([:positive])}@example.com",
        name: "Activity viewer",
        oidc_sub: Ecto.UUID.generate()
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {:ok, project} =
      Tasks.create_project(%{name: "Activity board #{System.unique_integer([:positive])}"})

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "owner-#{Ecto.UUID.generate()}",
        owner_user_id: user.id,
        display_name: "Status owner"
      })

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "status-#{Ecto.UUID.generate()}",
        name: "Status owner",
        status: "active",
        runtime_id: runtime.id
      })

    task =
      Repo.insert!(%Tasks.Task{
        project_id: project.id,
        title: "Episode status",
        status: "in_progress",
        assignee_id: agent.id,
        assignee_type: "agent"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Render clips",
        status: "running"
      })

    now = DateTime.utc_now()

    hold =
      Repo.insert!(%ExecutionLease{
        task_id: task.id,
        stage_id: stage.id,
        phase: "execution",
        runtime_id: runtime.runtime_id,
        status: "blocked",
        runtime_worker_ref: "worker",
        started_at: now,
        last_progress_at: now,
        expires_at: DateTime.add(now, 600),
        block_reason: "approve plan",
        metadata: %{"needs_human" => true, "blocked_at" => DateTime.to_iso8601(now)}
      })

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      task: task,
      stage: stage,
      hold: hold,
      user: user,
      project: project
    }
  end

  test "board and header expose hold; clock updates freshness without resetting detail", c do
    {:ok, view, _} = live(c.conn, "/tasks?task_id=#{c.task.id}")
    assert has_element?(view, "[data-role=execution-status][data-state=human]")

    assert has_element?(
             view,
             "[data-role=tasks-my-row] [data-role=execution-status][data-state=human]"
           )

    # Open through the actual navigation event, independent of URL filter aliases.
    render_click(view, "select_task", %{"id" => c.task.id})
    assert has_element?(view, "[data-role=execution-header][data-state=human]")
    refute has_element?(view, "[data-role=execution-recheck]")

    Repo.update!(
      Ecto.Changeset.change(c.hold,
        status: "active",
        metadata: %{},
        last_progress_at: DateTime.utc_now()
      )
    )

    send(view.pid, :execution_activity_tick)
    render(view)
    assert has_element?(view, "[data-role=execution-status][data-state=running]")
    active = Repo.get!(ExecutionLease, c.hold.id)

    Repo.update!(
      Ecto.Changeset.change(active, last_progress_at: DateTime.add(DateTime.utc_now(), -121))
    )

    send(view.pid, :execution_activity_tick)
    render(view)
    assert has_element?(view, "[data-role=execution-header][data-state=unknown]")
    refute has_element?(view, ".execution-pulse")
  end

  test "execution-space chat renders same recorded hold and updates from runtime broadcast", c do
    {:ok, space} =
      Chat.create_space(%{
        name: "Episode activity",
        slug: "activity-#{System.unique_integer([:positive])}",
        kind: "execution",
        org_id: c.project.org_id,
        metadata: %{"task_id" => c.task.id}
      })

    Chat.add_participant(space.id, %{
      participant_type: "user",
      participant_id: c.user.id,
      display_name: c.user.name,
      joined_at: DateTime.utc_now()
    })

    {:ok, view, _} = live(c.conn, "/chat/#{space.slug}")
    assert has_element?(view, "#chat-execution-activity [data-state=human]")

    Repo.update!(
      Ecto.Changeset.change(c.hold, status: "active", metadata: %{}, last_progress_at: nil)
    )

    Tasks.broadcast_board({:runtime_event, %{task_id: c.task.id}})
    render(view)
    assert has_element?(view, "#chat-execution-activity [data-state=unknown]")
  end

  test "forged recheck request cannot clear true human hold", c do
    {:ok, view, _} = live(c.conn, "/tasks")
    render_click(view, "select_task", %{"id" => c.task.id})
    # There is deliberately no recheck button for an untyped human hold.
    send(view.pid, :execution_activity_tick)
    render(view)
    assert RuntimeSupervision.needs_human_hold?(Repo.get!(ExecutionLease, c.hold.id))
  end
end
