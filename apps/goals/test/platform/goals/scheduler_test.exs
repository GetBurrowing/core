defmodule Platform.Goals.SchedulerTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals.{Clock, GoalClock, WakeUp}
  alias Platform.Goals.Clock.Scheduler
  @now ~U[2026-02-04 07:00:00.000000Z]

  setup do
    enable_goals!()
    old = Application.fetch_env(:goals, :clock_now)
    Application.put_env(:goals, :clock_now, fn -> @now end)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:goals, :clock_now, v)
        :error -> Application.delete_env(:goals, :clock_now)
      end
    end)

    :ok
  end

  test "manual scheduler processes an injected tick without waiting" do
    org = org_id!()
    goal = goal!(member!(org), org, %{coach_agent_id: agent!().id, rhythm: "daily"})
    Clock.tick(@now)
    slot = Repo.one!(from(c in GoalClock, where: c.goal_id == ^goal.id)).next_wake_at
    Application.put_env(:goals, :clock_now, fn -> slot end)
    pid = start_supervised!({Scheduler, interval_ms: :manual, name: nil})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :tick)
    :sys.get_state(pid)
    assert Repo.aggregate(from(w in WakeUp, where: w.goal_id == ^goal.id), :count) == 1
    assert Process.alive?(pid)
  end

  test "a raised clock operation leaves the scheduler alive" do
    Application.put_env(:goals, :clock_now, fn -> raise "injected clock failure" end)
    pid = start_supervised!({Scheduler, interval_ms: :manual, name: nil})
    send(pid, :tick)
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  test "only an enabled full-role node starts the background scheduler" do
    Application.put_env(:goals, :enabled, false)
    assert Platform.Goals.Application.children(:full) == []
    assert Platform.Goals.Application.children(:web) == []
    Application.put_env(:goals, :enabled, true)
    assert Scheduler in Platform.Goals.Application.children(:full)
    assert Platform.Goals.Application.children(:web) == []
    assert Scheduler in Platform.Goals.Application.background_ids()
  end
end
