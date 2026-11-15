defmodule Platform.Goals.CapsTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Ask, Clock, WakeUp}
  setup do: setup_outcome()

  test "gentle allows one unanswered ask; an answer or expiry frees the slot", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{outreach: "gentle"})
    first = fire(goal)
    assert {:ok, %{ask: ask}} = Goals.close_wake_up(c.coach, first.id, "ask", ask_attrs())
    second = fire(goal)
    before = row_counts()

    assert Goals.close_wake_up(c.coach, second.id, "ask", ask_attrs()) ==
             {:error, :ask_cap_reached}

    assert row_counts() == before
    assert Repo.get!(WakeUp, second.id).status == "open"
    assert {:ok, _} = Goals.answer_ask(c.owner, ask.id, "used")
    assert {:ok, %{ask: second_ask}} = Goals.close_wake_up(c.coach, second.id, "ask", ask_attrs())
    Repo.update!(Ecto.Changeset.change(second_ask, expires_at: Clock.now()))
    third = fire(goal)
    assert Repo.get!(Ask, second_ask.id).status == "expired"
    assert {:ok, _} = Goals.close_wake_up(c.coach, third.id, "ask", ask_attrs())
  end

  test "pushy allows three outstanding asks and refuses the fourth", c do
    for _ <- 1..3 do
      wake = fire(c.goal)
      assert {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs())
    end

    fourth = fire(c.goal)
    before = row_counts()

    assert Goals.close_wake_up(c.coach, fourth.id, "ask", ask_attrs()) ==
             {:error, :ask_cap_reached}

    assert row_counts() == before
    assert Repo.get!(WakeUp, fourth.id).status == "open"
  end

  test "five open linked tasks block creating a sixth; done frees a slot", c do
    project = project(c.org)

    tasks =
      for _ <- 1..5 do
        task =
          Repo.insert!(%Platform.Tasks.Task{
            project_id: project.id,
            title: "Existing work",
            status: "backlog"
          })

        assert {:ok, _} = Goals.link_task(c.coach, c.goal.id, task.id)
        task
      end

    wake = fire(c.goal)

    attrs =
      prediction(%{
        task: %{
          "project_id" => project.id,
          "title" => "Sixth work item",
          "description" => "Do work"
        }
      })

    before = row_counts()
    assert Goals.close_wake_up(c.coach, wake.id, "do", attrs) == {:error, :task_cap_reached}
    assert row_counts() == before
    Repo.update!(Ecto.Changeset.change(hd(tasks), status: "done"))
    assert {:ok, %{task: task}} = Goals.close_wake_up(c.coach, wake.id, "do", attrs)
    assert task.id
  end

  test "concurrent links competing for the last task slot admit only one", c do
    project = project(c.org)

    make_task = fn ->
      Repo.insert!(%Platform.Tasks.Task{
        project_id: project.id,
        title: "Competing work",
        status: "backlog"
      })
    end

    for _ <- 1..4 do
      task = make_task.()
      assert {:ok, _} = Goals.link_task(c.coach, c.goal.id, task.id)
    end

    candidates = for _ <- 1..2, do: make_task.()
    owner = self()

    jobs =
      Enum.map(candidates, fn task ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          receive do: (:go -> Goals.link_task(c.coach, c.goal.id, task.id))
        end)
      end)

    Enum.each(jobs, &send(&1.pid, :go))
    results = Enum.map(jobs, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :task_cap_reached})) == 1
    assert Repo.aggregate(Goals.TaskLink, :count) == 5
  end
end
