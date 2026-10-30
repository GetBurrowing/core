defmodule PlatformWeb.TasksLiveHumanMovesTest do
  @moduledoc """
  Task 01a18e02 stage 3: a person moves tasks freely from the board and the
  task panel, and sees one warning.

  The warning (`data-role="agent-without-plan-confirm"`) appears only when
  an execution agent is assigned, there is no approved plan and the target
  is in_progress. Confirming sends the task to PLANNING (decided), so the
  agent plans first; cancelling changes nothing. Each refusal or warning
  here is paired with a positive control of the same shape.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, Task}

  defp authenticated_conn_with_user(conn) do
    user =
      Repo.insert!(%User{
        email: "human_moves_#{System.unique_integer([:positive])}@example.com",
        name: "Human Moves User",
        oidc_sub: "oidc-human-moves-#{System.unique_integer([:positive])}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{name: "Human moves #{System.unique_integer([:positive])}"})

    project
  end

  defp create_agent do
    Repo.insert!(%Agent{
      slug: "human-moves-agent-#{System.unique_integer([:positive])}",
      name: "Human Moves Agent",
      status: "active"
    })
  end

  defp slot(agent), do: %{"assignee_id" => agent.id, "assignee_type" => "agent"}

  # Written with a bare change so setup records no transition row.
  defp task!(project, attrs) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Human move #{System.unique_integer([:positive])}",
        priority: "medium"
      })

    task |> Ecto.Changeset.change(Map.merge(%{status: "backlog"}, attrs)) |> Repo.update!()
  end

  # Agent-assigned, no plan, no sponsor: the shape nobody could close.
  defp agent_task!(project, agent) do
    task!(project, %{
      assignee_id: agent.id,
      assignee_type: "agent",
      sponsor_user_id: nil,
      phase_assignees: %{"planning" => slot(agent)}
    })
  end

  # An execution agent and no approved plan: the warning's shape.
  defp exec_agent_task!(project, agent) do
    task!(project, %{phase_assignees: %{"execution" => slot(agent)}})
  end

  defp board(view), do: with_target(view, "#tasks-board")

  defp drop(view, task, column) do
    view |> board() |> render_hook("board_drop", %{"task_id" => task.id, "column" => column})
    render(view)
  end

  defp status(task), do: Repo.get!(Task, task.id).status
  defp rows(task), do: PhaseTransitions.list_for_task(task.id)

  describe "(a) acceptance: the board closes a backlog task" do
    test "a drop onto Done lands, with one user-attributed human close", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      task = agent_task!(create_project(), create_agent())
      assert Tasks.current_plan(task.id) == nil

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = drop(view, task, "done")

      assert html =~ "Task moved to Done"
      refute html =~ "no approved plan"
      assert status(task) == "done"

      assert [row] = rows(task)
      assert {row.from_status, row.to_status} == {"backlog", "done"}
      assert row.actor_kind == "user"
      assert row.actor_id == user.id
      assert row.via == "human_close"
    end

    test "Planning and Blocked are drop targets too", %{conn: conn} do
      {conn, _user} = authenticated_conn_with_user(conn)
      project = create_project()
      to_planning = task!(project, %{})
      to_blocked = task!(project, %{})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      drop(view, to_planning, "planning")
      drop(view, to_blocked, "blocked")

      assert status(to_planning) == "planning"
      assert status(to_blocked) == "blocked"
    end
  end

  describe "(b) the panel's Mark Done" do
    test "closes a backlog task, recorded as a human close", %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      task = agent_task!(create_project(), create_agent())

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> element("#tasks-detail button[phx-value-status='done']", "Mark Done")
      |> render_click()

      assert status(task) == "done"
      assert [%{actor_kind: "user", actor_id: actor_id, via: "human_close"}] = rows(task)
      assert actor_id == user.id
    end
  end

  describe "(c) the agent counterpart" do
    test "task_update backlog -> done as an agent is still refused", %{conn: _conn} do
      agent = create_agent()
      task = agent_task!(create_project(), agent)

      assert {:error, %{error: error}} =
               ToolSurface.execute(
                 "task_update",
                 %{"task_id" => task.id, "status" => "done"},
                 %{agent_id: agent.id}
               )

      assert error =~ "Valid next statuses from 'backlog'"
      assert status(task) == "backlog"
      assert rows(task) == []
    end
  end

  describe "(d) the agent-without-plan warning" do
    test "a drop onto In Progress asks first; cancel changes nothing; confirm lands planning",
         %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      task = exec_agent_task!(create_project(), create_agent())
      assert Tasks.human_move_needs_confirmation?(task, "in_progress", {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      refute has_element?(view, "[data-role='agent-without-plan-confirm']")

      drop(view, task, "in_progress")
      assert has_element?(view, "[data-role='agent-without-plan-confirm']")
      assert render(view) =~ "is assigned and this task has no approved plan"
      # Held, not moved.
      assert status(task) == "backlog"

      view |> element("[data-role='cancel-move']") |> render_click()
      refute has_element?(view, "[data-role='agent-without-plan-confirm']")
      assert status(task) == "backlog"
      assert rows(task) == []

      drop(view, task, "in_progress")
      view |> element("[data-role='confirm-plan-first']") |> render_click()
      html = render(view)

      assert status(task) == "planning"
      assert html =~ "Sent to planning"
      assert [%{to_status: "planning", actor_kind: "user"}] = rows(task)
    end

    test "the panel's Resume onto in_progress shows the same confirm", %{conn: conn} do
      {conn, _user} = authenticated_conn_with_user(conn)
      task = task!(create_project(), %{status: "blocked"})

      task =
        task
        |> Ecto.Changeset.change(%{phase_assignees: %{"execution" => slot(create_agent())}})
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view
      |> element("#tasks-detail button[phx-value-status='in_progress']", "Resume")
      |> render_click()

      assert has_element?(view, "#tasks-detail [data-role='agent-without-plan-confirm']")
      assert status(task) == "blocked"

      view |> element("#tasks-detail [data-role='confirm-plan-first']") |> render_click()
      assert status(task) == "planning"
    end
  end

  describe "(e) no agent, no warning" do
    test "a no-agent task dropped onto In Progress shows no modal and lands", %{conn: conn} do
      {conn, _user} = authenticated_conn_with_user(conn)
      task = task!(create_project(), %{})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      drop(view, task, "in_progress")

      refute has_element?(view, "[data-role='agent-without-plan-confirm']")
      assert status(task) == "in_progress"
    end
  end

  describe "(f) the panel's Move to… menu" do
    test "lists the human moves without a button, never stack_pending or the current status",
         %{conn: conn} do
      {conn, user} = authenticated_conn_with_user(conn)
      project = create_project()

      for from <- ~w(backlog planning in_progress in_review deploying blocked done) do
        task = task!(project, %{status: from})
        {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

        assert has_element?(view, "#tasks-detail [data-role='status-move-menu']"),
               "no Move-to menu on a #{from} task"

        refute has_element?(view, "[data-role='status-move-stack_pending']")
        refute has_element?(view, "[data-role='status-move-#{from}']")

        # Every listed item is a real human edge (derived, not transcribed).
        allowed = Tasks.allowed_next_statuses(from, {:user, user.id})

        listed =
          for s <- Platform.Tasks.Task.statuses(),
              has_element?(view, "[data-role='status-move-#{s}']"),
              do: s

        assert listed != []
        assert listed -- allowed == []
      end
    end

    test "an item moves the task", %{conn: conn} do
      {conn, _user} = authenticated_conn_with_user(conn)
      task = task!(create_project(), %{status: "in_review"})

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("[data-role='status-move-backlog']") |> render_click()

      assert status(task) == "backlog"
    end
  end
end
