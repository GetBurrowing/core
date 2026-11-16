defmodule Platform.Goals.ContributorTasksTest do
  @moduledoc """
  Goals 7/8 stage 2 (task 01a1dfc1-dffb): one goal_do may split work into up
  to three tasks, each for the coach or a contributor agent of a space the
  goal is handed to; the tasks come back to the coach in later briefings.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures
  import Platform.Goals.OutcomeFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.{Clock, Entry, TaskLink, ToolDefinitions, Tools, WakeUp}
  alias Platform.Goals.WakeUps.Briefing
  alias Platform.Tasks.Task

  setup do
    c = setup_outcome()
    manager = root_admin!()
    x = agent!()
    y = agent!()
    space = space!(c.org)

    for user <- [c.owner, manager], do: join_space!(space.id, :user, user.id)
    for agent <- [c.coach, x, y], do: join_space!(space.id, :agent, agent.id)

    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})
    {:ok, _} = Goals.hand_goal_to_space(manager, c.goal.id, space.id)

    Map.merge(c, %{manager: manager, x: x, y: y, space: space, project: project(c.org)})
  end

  defp call(tool, args, agent), do: Tools.execute(tool, args, %{agent_id: agent.id})

  defp code({:error, %{code: code}}), do: code
  defp code(other), do: flunk("expected an error envelope, got #{inspect(other)}")

  defp do_args(wake, tasks) do
    %{
      "wake_up_id" => wake.id,
      "title" => "Split the work",
      "prediction" => "Two hands go faster",
      "predicted_by" => Date.to_iso8601(Date.add(DateTime.to_date(Clock.now()), 3)),
      "task" => tasks
    }
  end

  defp task_for(c, assignee_id, title \\ "Draft the outline") do
    %{
      "project_id" => c.project.id,
      "title" => title,
      "description" => "Write the first pass",
      "assignee_agent_id" => assignee_id
    }
  end

  defp wake_status(wake), do: Repo.one!(from(w in WakeUp, where: w.id == ^wake.id)).status
  defp counts, do: Enum.map([Task, TaskLink, Entry], &Repo.aggregate(&1, :count))

  defp wait!(c, wake),
    do: {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Work in progress"})

  test "one goal_do gives two contributors one task each, reviewed by the coach", c do
    wake = fire(c.goal)
    before = Repo.aggregate(from(t in Task, where: t.project_id == ^c.project.id), :count)

    assert {:ok, result} =
             call("goal_do", do_args(wake, [task_for(c, c.x.id), task_for(c, c.y.id)]), c.coach)

    assert [%{assignee_agent_id: x_id}, %{assignee_agent_id: y_id}] = result.tasks
    assert {x_id, y_id} == {c.x.id, c.y.id}
    assert result.task.id == hd(result.tasks).id

    tasks = Repo.all(from(t in Task, where: t.project_id == ^c.project.id))
    assert length(tasks) == before + 2

    for {agent, created} <- Enum.zip([c.x, c.y], result.tasks) do
      task = Repo.one!(from(t in Task, where: t.id == ^created.id))
      assert task.phase_assignees["planning"]["assignee_id"] == agent.id
      assert task.phase_assignees["execution"]["assignee_id"] == agent.id
      assert task.phase_assignees["review"]["assignee_id"] == c.coach.id
      refute task.auto_approve_plan
      assert task.metadata == %{"source" => "goals.wake_up"}
      carried = inspect({task.title, task.description, task.metadata})
      refute carried =~ c.goal.id
      refute carried =~ c.goal.title

      assert [link] = Repo.all(from(l in TaskLink, where: l.task_id == ^task.id))
      assert {link.goal_id, link.wake_up_id} == {c.goal.id, wake.id}
    end

    assert [entry] =
             Repo.all(from(e in Entry, where: e.goal_id == ^c.goal.id and e.kind == "action"))

    assert entry.details["task_ids"] == Enum.map(result.tasks, & &1.id)
    assert entry.details["task_id"] == hd(result.tasks).id

    assert %{status: "closed", outcome: "do"} =
             Repo.one!(from(w in WakeUp, where: w.id == ^wake.id))

    snapshot = counts()

    assert code(call("goal_do", do_args(wake, [task_for(c, c.x.id)]), c.coach)) ==
             :wake_up_closed

    assert counts() == snapshot
  end

  test "finished contributor tasks come back once with their assignee; blocked stays open", c do
    wake = fire(c.goal)

    {:ok, %{tasks: [tx, ty, tz]}} =
      Goals.close_wake_up(
        c.coach,
        wake.id,
        "do",
        do_args(wake, [
          task_for(c, c.x.id, "X work"),
          task_for(c, c.y.id, "Y work"),
          task_for(c, c.x.id, "Blocked work")
        ])
      )

    Repo.update!(Ecto.Changeset.change(tx, status: "done"))
    Repo.update!(Ecto.Changeset.change(ty, status: "cancelled"))
    Repo.update!(Ecto.Changeset.change(tz, status: "blocked"))

    next = fire(c.goal)
    finished = next.briefing["since_last"]["finished_tasks"]

    assert Enum.sort_by(finished, & &1["title"]) == [
             %{
               "id" => tx.id,
               "title" => "X work",
               "status" => "done",
               "assignee_agent_id" => c.x.id,
               "assignee_name" => c.x.name
             },
             %{
               "id" => ty.id,
               "title" => "Y work",
               "status" => "cancelled",
               "assignee_agent_id" => c.y.id,
               "assignee_name" => c.y.name
             }
           ]

    assert [open] = next.briefing["since_last"]["open_tasks"]
    assert open["id"] == tz.id
    assert open["status"] == "blocked"
    assert open["assignee_name"] == c.x.name

    text = Briefing.text(next.briefing)
    assert text =~ "Finished task: X work (done), held by #{c.x.name}"
    assert text =~ "Open task: Blocked work (blocked), held by #{c.x.name}"

    wait!(c, next)
    Repo.update!(Ecto.Changeset.change(tz, deleted_at: Clock.now()))
    later = fire(c.goal)
    assert [%{"id" => id}] = later.briefing["since_last"]["finished_tasks"]
    assert id == tz.id
    assert later.briefing["since_last"]["open_tasks"] == []

    wait!(c, later)
    last = fire(c.goal)
    assert last.briefing["since_last"]["finished_tasks"] == []
  end

  test "every agent that may not take the task gets the same refusal and nothing is written",
       c do
    nowhere = agent!()
    shown = space!(c.org)
    shown_agent = agent!()
    join_space!(shown.id, :user, c.owner.id)
    join_space!(shown.id, :agent, shown_agent.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, shown.id})

    left = agent!()
    row = join_space!(c.space.id, :agent, left.id)
    leave_space!(row)

    inactive = agent!()
    join_space!(c.space.id, :agent, inactive.id)
    {:ok, _} = inactive |> Platform.Agents.Agent.changeset(%{status: "paused"}) |> Repo.update()

    other_tenant = org_id!()

    pinned =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "pinned-#{unique()}",
        name: "Pinned",
        metadata: %{"org_id" => other_tenant}
      })

    join_space!(c.space.id, :agent, pinned.id)
    assert {:ok, contributors} = Goals.list_contributors(c.owner, c.goal.id)
    assert pinned.id in Enum.map(contributors, & &1.agent_id)

    wake = fire(c.goal)
    before = counts()

    results =
      for id <- [
            nowhere.id,
            shown_agent.id,
            left.id,
            inactive.id,
            Ecto.UUID.generate(),
            "not-a-uuid",
            pinned.id
          ] do
        result = Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, [task_for(c, id)]))
        assert counts() == before
        assert wake_status(wake) == "open"
        result
      end

    assert Enum.uniq(results) == [{:error, :assignee_not_available}]

    assert code(call("goal_do", do_args(wake, [task_for(c, nowhere.id)]), c.coach)) ==
             :assignee_not_available

    assert {:ok, %{tasks: [task]}} =
             Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, [task_for(c, c.coach.id)]))

    for phase <- ~w(planning execution review),
        do: assert(task.phase_assignees[phase]["assignee_id"] == c.coach.id)
  end

  test "a list with one outside agent creates no task at all", c do
    outside = agent!()
    wake = fire(c.goal)
    before = counts()

    assert Goals.close_wake_up(
             c.coach,
             wake.id,
             "do",
             do_args(wake, [task_for(c, c.x.id), task_for(c, outside.id)])
           ) == {:error, :assignee_not_available}

    assert counts() == before
    assert wake_status(wake) == "open"
  end

  test "the cap counts every task in the call; more than three is too_many_tasks", c do
    for n <- 1..4 do
      task = Repo.insert!(%Task{project_id: c.project.id, title: "Open #{n}", status: "backlog"})
      {:ok, _} = Goals.link_task(c.coach, c.goal.id, task.id)
    end

    wake = fire(c.goal)
    before = counts()

    assert Goals.close_wake_up(
             c.coach,
             wake.id,
             "do",
             do_args(wake, [task_for(c, c.x.id), task_for(c, c.y.id)])
           ) == {:error, :task_cap_reached}

    assert counts() == before

    four = for _ <- 1..4, do: task_for(c, c.x.id)

    assert Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, four)) ==
             {:error, :too_many_tasks}

    assert code(call("goal_do", do_args(wake, four), c.coach)) == :too_many_tasks
    assert counts() == before

    assert {:ok, %{tasks: [_]}} =
             Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, [task_for(c, c.x.id)]))
  end

  test "advise refuses do and coach refuses any task list, writing nothing", c do
    for {mode, refusal} <- [{"advise", :mode_forbids_do}, {"coach", :mode_forbids_task}] do
      {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: mode})
      wake = fire(c.goal)
      before = counts()

      assert Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, [task_for(c, c.x.id)])) ==
               {:error, refusal}

      assert counts() == before
      wait!(c, wake)
    end
  end

  test "link_task refuses a task held by an outside agent and links a contributor's", c do
    outside = agent!()

    held_by = fn agent ->
      one = %{"assignee_type" => "agent", "assignee_id" => agent.id}

      Repo.insert!(%Task{
        project_id: c.project.id,
        title: "Existing",
        status: "backlog",
        phase_assignees: %{"planning" => one, "execution" => one},
        assignee_type: "agent",
        assignee_id: agent.id
      })
    end

    before = counts()

    assert Goals.link_task(c.coach, c.goal.id, held_by.(outside).id) ==
             {:error, :assignee_not_available}

    # Only the inserted task row moved: no link was written.
    assert Enum.drop(counts(), 1) == Enum.drop(before, 1)

    task = held_by.(c.x)
    assert {:ok, _} = Goals.link_task(c.coach, c.goal.id, task.id)

    assert {:ok, rows} = Goals.list_goal_tasks(c.owner, c.goal.id)

    assert %{assignee_agent_id: x_id, assignee_name: x_name} =
             Enum.find(rows, &(&1.task_id == task.id))

    assert {x_id, x_name} == {c.x.id, c.x.name}
  end

  test "after take-back the contributor may not take tasks; earlier tasks stay linked and return",
       c do
    wake = fire(c.goal)

    {:ok, %{tasks: [task]}} =
      Goals.close_wake_up(c.coach, wake.id, "do", do_args(wake, [task_for(c, c.x.id)]))

    {:ok, _} = Goals.take_goal_back(c.owner, c.goal.id, c.space.id)
    next = fire(c.goal)

    assert Goals.close_wake_up(c.coach, next.id, "do", do_args(next, [task_for(c, c.x.id)])) ==
             {:error, :assignee_not_available}

    assert Repo.exists?(from(l in TaskLink, where: l.task_id == ^task.id))
    wait!(c, next)
    Repo.update!(Ecto.Changeset.change(task, status: "done"))
    back = fire(c.goal)

    assert [%{"id" => id, "assignee_name" => name}] =
             back.briefing["since_last"]["finished_tasks"]

    assert {id, name} == {task.id, c.x.name}
  end

  test "the tools show assign, contributors and assignees; the bundle keeps its names", c do
    names = ToolDefinitions.names()
    # Goals 5/8 adds the takeaway and proposal tools after 8/8's goal_retro.
    assert names ==
             ~w(goal_list goal_get goal_wake_up_get goal_do goal_ask goal_wait goal_retro) ++
               ~w(goal_takeaway_add goal_proposal_get goal_propose)

    {:ok, _} = Goals.take_goal_back(c.owner, c.goal.id, c.space.id)
    wake = fire(c.goal)

    assert {:ok, %{allowed: %{"assign" => :no_contributors}, text: text}} =
             call("goal_wake_up_get", %{"wake_up_id" => wake.id}, c.coach)

    refute text =~ "Agents you can give tasks to:"
    assert {:ok, %{contributors: []}} = call("goal_get", %{"goal_id" => c.goal.id}, c.coach)
    wait!(c, wake)

    {:ok, _} = Goals.hand_goal_to_space(c.manager, c.goal.id, c.space.id)
    wake = fire(c.goal)

    assert {:ok, %{allowed: %{"assign" => true}, briefing: briefing, text: text}} =
             call("goal_wake_up_get", %{"wake_up_id" => wake.id}, c.coach)

    assert Enum.sort(Enum.map(briefing["contributors"], & &1["agent_id"])) ==
             Enum.sort([c.x.id, c.y.id])

    assert text =~ "Agents you can give tasks to:\n"
    assert text =~ "#{c.x.name} (#{c.x.id})"
    assert text =~ "One goal_do may create up to 3 tasks."

    {:ok, _} = call("goal_do", do_args(wake, [task_for(c, c.y.id)]), c.coach)
    assert {:ok, read} = call("goal_get", %{"goal_id" => c.goal.id}, c.coach)
    assert Enum.sort(Enum.map(read.contributors, & &1.agent_id)) == Enum.sort([c.x.id, c.y.id])
    assert [%{assignee_agent_id: y_id, assignee_name: y_name}] = read.tasks
    assert {y_id, y_name} == {c.y.id, c.y.name}

    assert ToolDefinitions.names() == names
  end

  test "in coach mode the briefing lists no agents and assign names the mode", c do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{agent_mode: "coach"})
    wake = fire(c.goal)

    assert {:ok, %{allowed: %{"assign" => :mode_forbids_task}, text: text}} =
             call("goal_wake_up_get", %{"wake_up_id" => wake.id}, c.coach)

    refute text =~ "Agents you can give tasks to:"
    assert Chat.get_agent_participant(c.space.id, c.x.id)
  end
end
