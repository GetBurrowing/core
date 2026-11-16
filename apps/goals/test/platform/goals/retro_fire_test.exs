defmodule Platform.Goals.RetroFireTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, WakeUp, Entry}
  alias Platform.Goals.WakeUps.Briefing
  setup do: setup_outcome()

  test "weekly slots replace the fourth check-in with one retro", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{rhythm: "weekly", rhythm_weekday: 4})

    kinds =
      for _ <- 1..5 do
        wake = fire(goal)

        if wake.kind == "retro",
          do:
            assert(
              {:ok, _} =
                Goals.close_retro(c.coach, wake.id, %{title: "Review", summary: "Looked back"})
            ),
          else:
            assert({:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Wait"}))

        wake.kind
      end

    assert kinds == ~w(check_in check_in check_in retro check_in)
    assert Repo.aggregate(from(w in WakeUp, where: w.goal_id == ^goal.id), :count) == 5
    assert length(Platform.Goals.Application.children(:full)) == 1
  end

  test "an unanswered retro has its own title and is never sent twice", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})
    first = fire(goal)
    retro = fire(goal)
    assert retro.kind == "retro"
    assert Repo.one!(from(w in WakeUp, where: w.id == ^first.id)).status == "unanswered"
    put_now(retro.respond_by)
    Clock.tick(retro.respond_by)
    Clock.tick(retro.respond_by)

    assert [%{title: "Retro not answered"}] =
             Repo.all(
               from(e in Entry, where: e.goal_id == ^goal.id and e.title == "Retro not answered")
             )
  end

  test "retro wire signal omits goal content while private text keeps it", c do
    {:ok, goal} =
      Goals.update_goal(c.owner, c.goal.id, %{
        retro_every: 2,
        title: "ZEBRA-QUARTZ",
        why: "VIOLET-ANVIL",
        unit: "florps"
      })

    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 4242, measured_at: Clock.now()})
    wake = fire(goal)
    {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Wait"})
    retro = fire(goal)

    for secret <- ~w(ZEBRA-QUARTZ VIOLET-ANVIL florps 4242) do
      refute Briefing.wire_prompt(retro) =~ secret
      assert Briefing.text(retro.briefing) =~ secret
    end

    assert Briefing.wire_prompt(retro) =~ "close it with goal_retro"
    assert Map.has_key?(retro.briefing, "retro")
    {:ok, _} = Goals.update_goal(c.owner, goal.id, %{status: "paused"})
    count = Repo.aggregate(WakeUp, :count)
    Clock.tick(DateTime.add(Clock.now(), 86400 * 50))
    assert Repo.aggregate(WakeUp, :count) == count
  end
end

