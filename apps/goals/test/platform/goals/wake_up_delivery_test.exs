defmodule Platform.Goals.WakeUpDeliveryTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{Clock, GoalClock, WakeUp}
  alias Platform.Goals.WakeUps.Briefing
  alias Platform.Federation.DeadLetter
  @now ~U[2026-02-04 07:00:00.000000Z]
  @secret_words ["ZEBRA-QUARTZ", "VIOLET-ANVIL", "florps", "4242"]

  setup do
    enable_goals!()

    old =
      Map.new(
        [:clock_now, :wake_up_dispatcher, :default_time_zone],
        &{&1, Application.fetch_env(:goals, &1)}
      )

    Application.put_env(:goals, :clock_now, fn -> @now end)
    Application.put_env(:goals, :default_time_zone, "Etc/UTC")

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    owner = member!(org)
    %{org: org, owner: owner}
  end

  defp external(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-delivery-#{unique()}",
        display_name: "Goals delivery test",
        status: "active"
      })

    coach =
      agent!()
      |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
      |> Repo.update!()

    {coach, runtime}
  end

  defp fire(c, coach) do
    goal =
      goal!(c.owner, c.org, %{
        coach_agent_id: coach.id,
        rhythm: "daily",
        title: "ZEBRA-QUARTZ",
        why: "VIOLET-ANVIL",
        unit: "florps",
        source_key: "self_reported"
      })

    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: "4242", measured_at: @now})
    Clock.tick(@now)
    slot = Repo.one!(from(cl in GoalClock, where: cl.goal_id == ^goal.id)).next_wake_at
    Application.put_env(:goals, :clock_now, fn -> slot end)
    Clock.tick(slot)
    Repo.one!(from(w in WakeUp, where: w.goal_id == ^goal.id))
  end

  test "wire signal has exactly the protocol keys and no goal content", c do
    parent = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    {coach, _} = external(c.owner)
    wake = fire(c, coach)
    assert_received {:signal, signal}

    assert signal == %{
             reason: :system_event,
             metadata: %{
               agent_id: coach.id,
               agent_slug: coach.slug,
               responsibility_key: "goals.wake_up",
               feature: "goals",
               trigger_kind: "cron",
               prompt: Briefing.wire_prompt(wake),
               prompt_status: :rendered
             }
           }

    assert wake.delivery == "sent"

    for word <- @secret_words do
      refute inspect(signal) =~ word
      assert Briefing.text(wake.briefing) =~ word
    end
  end

  test "coach without an external runtime is not dispatched", c do
    parent = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    assert fire(c, agent!()).delivery == "no_runtime"
    refute_received {:signal, _}
  end

  test "offline real dispatcher stores only the content-free wire signal", c do
    Application.put_env(:goals, :wake_up_dispatcher, {Platform.Chat.AgentResponder, :respond})
    {coach, runtime} = external(c.owner)
    wake = fire(c, coach)
    assert wake.delivery == "offline"
    assert [letter] = Repo.all(from(d in DeadLetter, where: d.runtime_id == ^runtime.runtime_id))

    for word <- @secret_words do
      refute inspect(letter.payload) =~ word
      assert Briefing.text(wake.briefing) =~ word
    end
  end

  test "other dispatcher errors and exceptions are recorded as failed", c do
    {coach, _} = external(c.owner)
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> {:error, :other} end)
    assert fire(c, coach).delivery == "failed"
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> raise "dispatch failed" end)
    assert fire(c, coach).delivery == "failed"
  end
end
