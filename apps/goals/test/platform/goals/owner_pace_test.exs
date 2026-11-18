defmodule Platform.Goals.OwnerPaceTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  import Platform.Goals.BriefFixtures
  import Platform.Goals.PaceFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, Rhythm, WakeUp}

  setup do
    with_limits(%{ask_expiry_days: 1000})
    setup_brief()
  end

  test "one notice per slow-down, one final owner answer restores, then a later run slows again",
       c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{outreach: "gentle"})
    c = %{c | goal: goal}
    asks = for _ <- 1..3, do: ignore_brief(c)
    notice_date = date()
    {:ok, status} = Goals.clock_status(c.owner, goal.id)
    assert status.paced_at == Clock.now()
    assert status.paced_every == 7

    assert status.next_wake_at ==
             regular_after(goal, Clock.visible_clock(c.owner, goal.id), Clock.now(), 7)

    assert length(notices(goal)) == 1
    assert {:ok, items} = Goals.brief_items(c.owner, notice_date)
    assert Enum.count(items, &(&1.kind == :notice)) == 1
    for _ <- 1..2, do: ignore_brief(c)
    assert length(notices(goal)) == 1
    assert {:ok, today} = Goals.brief_items(c.owner, date())
    refute Enum.any?(today, &(&1.kind == :notice))
    assert {:ok, old} = Goals.brief_items(c.owner, notice_date)
    assert Enum.count(old, &(&1.kind == :notice)) == 1
    assert {:ok, _} = Goals.answer_ask(c.owner, hd(asks).id, "declined")
    {:ok, restored} = Goals.clock_status(c.owner, goal.id)
    assert restored.paced_at == nil
    assert restored.paced_every == nil

    assert restored.next_wake_at ==
             regular_after(goal, Clock.visible_clock(c.owner, goal.id), Clock.now(), 1)

    for _ <- 1..3, do: ignore_brief(c)
    assert length(notices(goal)) == 2
  end

  test "fourteen daily slots while slowed fire twice, and settings/restart retain pacing", c do
    for _ <- 1..3, do: ignore_brief(c)
    {:ok, before} = Goals.clock_status(c.owner, c.goal.id)
    start = Clock.now()
    initial = Repo.aggregate(from(w in WakeUp, where: w.goal_id == ^c.goal.id), :count)

    for n <- 1..14 do
      now = DateTime.add(start, n, :day)
      put_now(now)
      Clock.tick(now)
      {:ok, wakes} = Goals.list_wake_ups(c.coach, c.goal.id)

      for wake <- wakes, wake.status == "open" do
        if wake.kind == "retro",
          do: Goals.close_retro(c.coach, wake.id, %{title: "Review", summary: "Review"}),
          else: Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Wait"})
      end
    end

    assert Repo.aggregate(from(w in WakeUp, where: w.goal_id == ^c.goal.id), :count) - initial ==
             2

    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{rhythm: "weekly", rhythm_weekday: 4})
    {:ok, _} = Goals.restart_clock(c.owner, c.goal.id)
    {:ok, after_status} = Goals.clock_status(c.owner, c.goal.id)
    assert before.paced_at == after_status.paced_at
    assert after_status.paced_every == 2
  end

  test "pushy coach may hold only one open ask while slowed", c do
    for _ <- 1..3, do: ignore_brief(c)
    queued(c)
    wake = fire(c.goal)
    assert {:error, :ask_cap_reached} = Goals.close_wake_up(c.coach, wake.id, "ask", ask_attrs())
    assert wake.briefing["pace"]["state"] == "slowed"
    assert Platform.Goals.WakeUps.Briefing.text(wake.briefing) =~ "may hold one open ask"
  end

  test "non-owner answer does not restore pacing", c do
    reader = Platform.GoalsFixtures.member!(c.org)
    Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    ask = queued(c, %{addressed_user_ids: [reader.id]})
    for _ <- 1..3, do: ignore_brief(c)
    Goals.answer_ask(reader, ask.id, "declined")
    {:ok, status} = Goals.clock_status(c.owner, c.goal.id)
    assert status.paced_at
  end

  defp regular_after(goal, clock, now, times) do
    settings =
      Map.merge(
        Map.take(goal, [:rhythm, :rhythm_weekday]),
        Map.take(clock, [:wake_hour, :time_zone, :anchor_on])
      )

    Enum.reduce(1..times, now, fn _, at ->
      {:ok, next} = Rhythm.next_slot(at, settings)
      next
    end)
  end
end
