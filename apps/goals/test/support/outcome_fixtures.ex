defmodule Platform.Goals.OutcomeFixtures do
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, GoalClock, WakeUp}
  alias Platform.Repo
  import Ecto.Query

  def setup_outcome do
    enable_goals!()
    previous = Application.fetch_env(:goals, :clock_now)
    put_now(~U[2026-02-04 07:00:00.000000Z])

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :clock_now, value)
        :error -> Application.delete_env(:goals, :clock_now)
      end
    end)

    org = org_id!()
    owner = member!(org)
    coach = agent!()

    goal =
      goal!(owner, org, %{
        coach_agent_id: coach.id,
        agent_mode: "do",
        outreach: "pushy",
        rhythm: "daily",
        source_key: "self_reported",
        unit: "steps"
      })

    %{org: org, owner: owner, coach: coach, goal: goal}
  end

  def put_now(now), do: Application.put_env(:goals, :clock_now, fn -> now end)

  def fire(goal) do
    if is_nil(Repo.one(from(c in GoalClock, where: c.goal_id == ^goal.id))),
      do: Clock.tick(Clock.now())

    clock = Repo.one!(from(c in GoalClock, where: c.goal_id == ^goal.id))
    put_now(clock.next_wake_at)
    :ok = Clock.tick(clock.next_wake_at)
    Repo.one!(from(w in WakeUp, where: w.goal_id == ^goal.id and w.status == "open"))
  end

  def prediction(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Prepare a useful next step",
        prediction: "This will help",
        predicted_by: Date.add(DateTime.to_date(Clock.now()), 3)
      },
      attrs
    )
  end

  def ask_attrs(attrs \\ %{}),
    do: prediction(Map.merge(%{kind: "question", title: "Try it?"}, attrs))

  def row_counts,
    do:
      Enum.map(
        [Goals.Entry, Goals.Ask, Goals.TaskLink, Platform.Tasks.Task],
        &Repo.aggregate(&1, :count)
      )

  def project(org, attrs \\ %{}),
    do:
      Repo.insert!(
        struct(
          Platform.Tasks.Project,
          Map.merge(%{org_id: org, name: "Outcome", slug: "outcome-#{unique()}"}, attrs)
        )
      )
end

