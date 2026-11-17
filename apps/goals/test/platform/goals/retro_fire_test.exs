defmodule Platform.Goals.RetroFireTest do
  use Platform.DataCase, async: false
  import Platform.Goals.OutcomeFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, WakeUp, Entry}
  alias Platform.Goals.WakeUps.Briefing
  setup do: setup_outcome()

  test "weekly slots replace the fourth check-in with one retro", c do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: c.owner.id,
        runtime_id: "retro-dispatch-#{System.unique_integer([:positive])}",
        display_name: "Retro",
        status: "active"
      })

    c.coach
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()

    parent = self()
    previous = Application.fetch_env(:goals, :wake_up_dispatcher)

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:retro_dispatch, signal})
      :ok
    end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :wake_up_dispatcher, value)
        :error -> Application.delete_env(:goals, :wake_up_dispatcher)
      end
    end)

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

        assert_received {:retro_dispatch, _}
        refute_received {:retro_dispatch, _}
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

  test "an undated prediction is described without a deadline or expected number", c do
    {:ok, goal} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: 2})

    {:ok, _} =
      Goals.add_entry(c.coach, goal.id, %{
        kind: "wait",
        prediction: "Wait for a signal",
        predicted_change: 12345,
        occurred_at: Clock.now()
      })

    wake = fire(goal)
    {:ok, _} = Goals.close_wake_up(c.coach, wake.id, "wait", %{reason: "Wait"})
    retro = fire(goal)
    text = Briefing.text(retro.briefing)
    assert text =~ "Wait for a signal: not scored"
    refute text =~ "expected 12345"

    assert [%{"predicted_by" => nil, "actual_change" => nil}] =
             retro.briefing["retro"]["predictions"]
  end
end
