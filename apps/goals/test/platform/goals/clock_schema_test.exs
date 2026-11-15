defmodule Platform.Goals.ClockSchemaTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals.{GoalClock, WakeUp, Ask, AskAnswer, TaskLink}
  alias Platform.Repo

  setup do
    enable_goals!()
    org = org_id!()
    user = member!(org)

    project =
      Repo.insert!(%Platform.Tasks.Project{
        org_id: org,
        name: "Clock",
        slug: "clock-#{unique()}"
      })

    %{goal: goal!(user, org), other: goal!(user, org), user: user, project: project}
  end

  defp now, do: ~U[2026-11-15 06:00:00.000000Z]

  defp wake(goal),
    do:
      WakeUp.changeset(%WakeUp{goal_id: goal.id}, %{
        due_at: now(),
        fired_at: now(),
        respond_by: DateTime.add(now(), 3600)
      })

  test "all value CHECKs reject invalid values as changesets", c do
    ask =
      %Ask{goal_id: c.goal.id}
      |> Ask.changeset(%{kind: "question", title: "Ask", expires_at: now()})
      |> Repo.insert!()

    cases = [
      {GoalClock, %GoalClock{goal_id: c.goal.id},
       %{
         time_zone: "Etc/UTC",
         next_wake_at: now(),
         anchor_on: ~D[2026-11-15],
         schedule_key: "daily:-:6:Etc/UTC",
         wake_hour: 24
       }, :wake_hour},
      {WakeUp, %WakeUp{goal_id: c.goal.id},
       %{due_at: now(), fired_at: now(), respond_by: now(), kind: "bad"}, :kind},
      {WakeUp, %WakeUp{goal_id: c.goal.id},
       %{due_at: now(), fired_at: now(), respond_by: now(), status: "bad"}, :status},
      {WakeUp, %WakeUp{goal_id: c.goal.id},
       %{due_at: now(), fired_at: now(), respond_by: now(), delivery: "bad"}, :delivery},
      {WakeUp, %WakeUp{goal_id: c.goal.id},
       %{due_at: now(), fired_at: now(), respond_by: now(), status: "closed", outcome: "bad"},
       :outcome},
      {Ask, %Ask{goal_id: c.goal.id}, %{kind: "bad", title: "Ask", expires_at: now()}, :kind},
      {Ask, %Ask{goal_id: c.goal.id},
       %{kind: "question", status: "bad", title: "Ask", expires_at: now()}, :status},
      {AskAnswer, %AskAnswer{user_id: c.user.id},
       %{ask_id: ask.id, answer: "bad", answered_at: now()}, :answer}
    ]

    for {mod, row, attrs, field} <- cases do
      assert {:error, cs} = row |> mod.changeset(attrs) |> Repo.insert()
      assert Keyword.has_key?(cs.errors, field)
      # Bypass application validation to exercise the named PostgreSQL CHECK too.
      probe = mod.changeset(row, attrs)
      assert {:error, checked} = Repo.insert(%{probe | errors: [], valid?: true})
      assert Keyword.has_key?(checked.errors, field)
    end
  end

  test "schema identity attrs cannot replace context-set ids", c do
    agent = agent!()

    for {mod, row} <- [
          {GoalClock, %GoalClock{goal_id: c.goal.id}},
          {WakeUp, %WakeUp{goal_id: c.goal.id, coach_agent_id: agent.id}},
          {Ask, %Ask{goal_id: c.goal.id, created_by_agent_id: agent.id}},
          {AskAnswer, %AskAnswer{user_id: c.user.id}},
          {TaskLink, %TaskLink{goal_id: c.goal.id, created_by_agent_id: agent.id}}
        ] do
      changed =
        mod.changeset(row, %{
          goal_id: Ecto.UUID.generate(),
          coach_agent_id: Ecto.UUID.generate(),
          created_by_agent_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate()
        })
        |> Ecto.Changeset.apply_changes()

      for field <- [:goal_id, :coach_agent_id, :created_by_agent_id, :user_id],
          Map.has_key?(row, field) do
        assert Map.get(changed, field) == Map.get(row, field)
      end
    end
  end

  test "an empty audience is accepted and null audience is a changeset error", c do
    row = %Ask{goal_id: c.goal.id}
    attrs = %{kind: "question", title: "Next?", expires_at: now()}
    assert {:ok, _} = row |> Ask.changeset(attrs) |> Repo.insert()

    assert {:error, cs} =
             row |> Ask.changeset(Map.put(attrs, :addressed_user_ids, nil)) |> Repo.insert()

    assert Keyword.has_key?(cs.errors, :addressed_user_ids)
  end

  test "wake-up outcome matches closed status", c do
    for attrs <- [
          %{status: "closed"},
          %{status: "open", outcome: "wait"},
          %{status: "unanswered", outcome: "do"}
        ] do
      assert {:error, cs} =
               c.goal
               |> wake()
               |> Ecto.Changeset.apply_changes()
               |> WakeUp.changeset(attrs)
               |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :outcome)
      probe = c.goal |> wake() |> Ecto.Changeset.apply_changes() |> WakeUp.changeset(attrs)
      assert {:error, checked} = Repo.insert(%{probe | errors: [], valid?: true})
      assert Keyword.has_key?(checked.errors, :outcome)
    end
  end

  test "only one open check-in but multiple closed slots", c do
    c.goal |> wake() |> Repo.insert!()

    assert {:error, cs} =
             c.goal
             |> wake()
             |> Ecto.Changeset.put_change(:due_at, DateTime.add(now(), 60))
             |> Repo.insert()

    assert cs.errors != []

    for offset <- [120, 180] do
      c.goal
      |> wake()
      |> Ecto.Changeset.put_change(:due_at, DateTime.add(now(), offset))
      |> WakeUp.changeset(%{status: "closed", outcome: "wait"})
      |> Repo.insert!()
    end
  end

  test "task links are unique and cascade when core task is deleted", c do
    task = Repo.insert!(%Platform.Tasks.Task{title: "Goal work", project_id: c.project.id})

    link =
      %TaskLink{goal_id: c.goal.id} |> TaskLink.changeset(%{task_id: task.id}) |> Repo.insert!()

    assert {:error, _} =
             %TaskLink{goal_id: c.other.id}
             |> TaskLink.changeset(%{task_id: task.id})
             |> Repo.insert()

    Repo.delete!(task)
    refute Repo.get(TaskLink, link.id)
  end

  test "deleting goal cascades all five tables", c do
    clock =
      %GoalClock{goal_id: c.goal.id}
      |> GoalClock.changeset(%{
        time_zone: "Etc/UTC",
        next_wake_at: now(),
        anchor_on: ~D[2026-11-15],
        schedule_key: "daily:-:6:Etc/UTC"
      })
      |> Repo.insert!()

    wake = c.goal |> wake() |> Repo.insert!()

    ask =
      %Ask{goal_id: c.goal.id}
      |> Ask.changeset(%{
        kind: "question",
        title: "Next?",
        expires_at: now(),
        wake_up_id: wake.id
      })
      |> Repo.insert!()

    answer =
      %AskAnswer{user_id: c.user.id}
      |> AskAnswer.changeset(%{ask_id: ask.id, answer: "used", answered_at: now()})
      |> Repo.insert!()

    task = Repo.insert!(%Platform.Tasks.Task{title: "Goal work", project_id: c.project.id})

    link =
      %TaskLink{goal_id: c.goal.id} |> TaskLink.changeset(%{task_id: task.id}) |> Repo.insert!()

    Repo.delete!(c.goal)

    for {mod, row} <- [
          {GoalClock, clock},
          {WakeUp, wake},
          {Ask, ask},
          {AskAnswer, answer},
          {TaskLink, link}
        ],
        do: refute(Repo.get(mod, row.id))

    assert Repo.get(Platform.Tasks.Task, task.id)
  end
end
