defmodule Platform.Goals.ClockSchemaTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals.{GoalClock, WakeUp, Ask, AskAnswer, TaskLink}
  alias Platform.Repo

  setup do
    enable_goals!()
    org = org_id!()
    user = member!(org)
    %{goal: goal!(user, org), other: goal!(user, org), user: user}
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
       %{ask_id: Ecto.UUID.generate(), answer: "bad", answered_at: now()}, :answer}
    ]

    for {mod, row, attrs, field} <- cases do
      assert {:error, cs} = row |> mod.changeset(attrs) |> Repo.insert()
      assert Keyword.has_key?(cs.errors, field)
    end
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
    task = Repo.insert!(%Platform.Tasks.Task{title: "Goal work"})

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

    task = Repo.insert!(%Platform.Tasks.Task{title: "Goal work"})

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
