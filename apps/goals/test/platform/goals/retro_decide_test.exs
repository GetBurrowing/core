defmodule Platform.Goals.RetroDecideTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Goal, GoalClock, Stop, Entry}
  setup do: setup_outcome()

  defp proposal(c, set) do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
    wake = fire(goal)
    {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Wait"})
    retro = fire(goal)

    {:ok, result} =
      Goals.close_retro(c.coach, retro.id, %{
        title: "Rhythm",
        summary: "Try another rhythm",
        check_in_change: %{"summary" => "Use weekdays", "set" => set}
      })

    result.entry
  end

  defp settings(c) do
    {Repo.one!(from(g in Goal, where: g.id == ^c.goal.id)),
     Repo.one!(from(cl in GoalClock, where: cl.goal_id == ^c.goal.id)),
     Repo.all(from(s in Stop, where: s.goal_id == ^c.goal.id))}
  end

  test "Keep it changes no goal, clock or stop and writes one owner entry", c do
    entry = proposal(c, %{"rhythm" => "weekdays"})
    before = settings(c)
    count = Repo.aggregate(Entry, :count)

    assert {:ok, %{decision: "keep"}} =
             Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "keep")

    assert settings(c) == before
    assert Repo.aggregate(Entry, :count) == count + 1

    assert {:error, :already_decided} =
             Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "switch")
  end

  test "Switch uses the settings writer and reanchors its clock", c do
    entry = proposal(c, %{"rhythm" => "weekly", "rhythm_weekday" => 7})
    {_, before, _} = settings(c)

    assert {:ok, %{decision: "switch", goal: %{rhythm: "weekly"}}} =
             Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "switch")

    {_, after_clock, _} = settings(c)
    refute before.next_wake_at == after_clock.next_wake_at

    assert {:error, :already_decided} =
             Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "keep")
  end

  test "only owner can decide and invalid decisions write nothing", c do
    entry = proposal(c, %{"rhythm" => "weekdays"})
    viewer = member!(c.org)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, viewer.id})
    before = settings(c)
    count = Repo.aggregate(Entry, :count)

    for actor <- [viewer, c.coach] do
      assert {:error, :forbidden} =
               Goals.decide_retro_change(actor, c.goal.id, entry.id, "switch")
    end

    assert {:error, :not_found} =
             Goals.decide_retro_change(member!(c.org), c.goal.id, entry.id, "switch")

    assert {:error, :unknown_decision} =
             Goals.decide_retro_change(c.owner, c.goal.id, entry.id, "other")

    assert settings(c) == before
    assert Repo.aggregate(Entry, :count) == count
  end
end
