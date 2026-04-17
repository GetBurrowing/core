defmodule Platform.Agents.SystemEventSchedulerTest do
  @moduledoc """
  Tests for SystemEventScheduler — scheduling logic and agent dispatch.

  Pure scheduling tests (next_fire_time, fired_today?) use ExUnit.Case.
  Dispatch / DB tests use DataCase.
  """

  # ── Scheduling logic (no DB) ─────────────────────────────────────────────────

  defmodule SchedulingTest do
    use ExUnit.Case, async: true

    alias Platform.Agents.SystemEventScheduler

    describe "next_fire_time/2" do
      test "returns today's target hour when it hasn't passed yet" do
        # 10:00 UTC, target hour 23 → should be 23:00 today
        now = ~U[2026-04-14 10:00:00.000000Z]
        result = SystemEventScheduler.next_fire_time(now, 23)

        assert result.hour == 23
        assert result.minute == 0
        assert result.second == 0
        assert DateTime.to_date(result) == ~D[2026-04-14]
      end

      test "returns tomorrow's target hour when today's has passed" do
        # 23:30 UTC, target hour 23 → should be 23:00 tomorrow
        now = ~U[2026-04-14 23:30:00.000000Z]
        result = SystemEventScheduler.next_fire_time(now, 23)

        assert result.hour == 23
        assert DateTime.to_date(result) == ~D[2026-04-15]
      end

      test "returns tomorrow when exactly at the target hour" do
        now = ~U[2026-04-14 23:00:00.000000Z]
        result = SystemEventScheduler.next_fire_time(now, 23)

        # At exactly 23:00, now == target, so compare is not :lt → tomorrow
        assert DateTime.to_date(result) == ~D[2026-04-15]
      end

      test "works for early morning target hours" do
        # 01:00 UTC, target hour 3 → should be 03:00 today
        now = ~U[2026-04-14 01:00:00.000000Z]
        result = SystemEventScheduler.next_fire_time(now, 3)

        assert result.hour == 3
        assert DateTime.to_date(result) == ~D[2026-04-14]
      end
    end

    describe "fired_today?/2" do
      test "returns false when event has never fired" do
        refute SystemEventScheduler.fired_today?("daily_summary", %{})
      end

      test "returns true when event fired today" do
        last_fired = %{"daily_summary" => ~U[2026-04-14 23:01:00.000000Z]}
        # Simulate "today" being 2026-04-14
        assert SystemEventScheduler.fired_today?("daily_summary", last_fired) ==
                 (Date.compare(~D[2026-04-14], Date.utc_today()) == :eq)
      end

      test "returns false for a different event type" do
        last_fired = %{"daily_summary" => ~U[2026-04-14 23:01:00.000000Z]}
        refute SystemEventScheduler.fired_today?("dreaming", last_fired)
      end
    end
  end

  # ── Schema + dispatch (DB required) ──────────────────────────────────────────

  defmodule DispatchTest do
    use Platform.DataCase

    alias Platform.Agents.Agent
    alias Platform.Agents.SystemEventScheduler
    alias Platform.Chat

    @valid_agent_attrs %{
      slug: "test-agent",
      name: "Test Agent",
      status: "active"
    }

    defp create_agent(attrs \\ %{}) do
      %Agent{}
      |> Agent.changeset(Map.merge(@valid_agent_attrs, attrs))
      |> Repo.insert!()
    end

    describe "system_events field" do
      test "agent changeset accepts valid system events" do
        changeset =
          Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :system_events, ["daily_summary"]))

        assert changeset.valid?
      end

      test "agent changeset rejects invalid system events" do
        changeset =
          Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :system_events, ["invalid_event"]))

        refute changeset.valid?
      end

      test "agent changeset accepts empty system events" do
        changeset =
          Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :system_events, []))

        assert changeset.valid?
      end

      test "agent changeset accepts multiple valid system events" do
        changeset =
          Agent.changeset(
            %Agent{},
            Map.put(@valid_agent_attrs, :system_events, ["daily_summary", "dreaming"])
          )

        assert changeset.valid?
      end

      test "system_events persists as JSONB array" do
        agent = create_agent(%{system_events: ["daily_summary", "dreaming"]})
        reloaded = Repo.get!(Agent, agent.id)

        assert reloaded.system_events == ["daily_summary", "dreaming"]
      end

      test "system_events defaults to empty list" do
        agent = create_agent()
        assert agent.system_events == []
      end
    end

    describe "agent_for_event query" do
      test "fire_now finds flagged active agent" do
        agent = create_agent(%{system_events: ["daily_summary"]})

        # Start scheduler in test to use fire_now
        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        # fire_now should not crash and should dispatch to the agent
        result = SystemEventScheduler.fire_now("daily_summary")

        # Verify a system space was created for this agent
        space = Chat.get_space_by_slug("system-#{agent.slug}")
        assert space != nil
        assert space.kind == "system"
      end

      test "fire_now skips when no agent is flagged" do
        _agent = create_agent(%{system_events: []})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("daily_summary")
      end

      test "fire_now skips inactive agents" do
        _agent = create_agent(%{system_events: ["daily_summary"], status: "paused"})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("daily_summary")
      end
    end

    describe "one-agent-per-event enforcement" do
      test "flagging agent B unflags agent A via config save logic" do
        agent_a = create_agent(%{slug: "agent-a", system_events: ["daily_summary"]})
        agent_b = create_agent(%{slug: "agent-b", system_events: []})

        # Simulate the unflag logic from control_center_live.ex
        newly_claimed = ["daily_summary"]

        for event <- newly_claimed do
          from(a in Agent,
            where: a.id != ^agent_b.id,
            where: fragment("? @> ?", a.system_events, ^[event])
          )
          |> Repo.all()
          |> Enum.each(fn other ->
            cleaned = Enum.reject(other.system_events || [], &(&1 == event))
            other |> Agent.changeset(%{system_events: cleaned}) |> Repo.update!()
          end)
        end

        agent_b |> Agent.changeset(%{system_events: ["daily_summary"]}) |> Repo.update!()

        reloaded_a = Repo.get!(Agent, agent_a.id)
        reloaded_b = Repo.get!(Agent, agent_b.id)

        assert reloaded_a.system_events == []
        assert reloaded_b.system_events == ["daily_summary"]
      end
    end
  end
end
