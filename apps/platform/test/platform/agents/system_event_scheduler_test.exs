defmodule Platform.Agents.SystemEventSchedulerTest do
  @moduledoc """
  Tests for SystemEventScheduler — scheduling logic and agent dispatch.

  Pure scheduling tests (next_fire_time/3, recently_fired?/4, offset_for/1)
  use ExUnit.Case. Dispatch / DB tests use DataCase.
  """

  # ── Scheduling logic (no DB) ─────────────────────────────────────────────────

  defmodule SchedulingTest do
    use ExUnit.Case, async: true

    alias Platform.Agents.SystemEventScheduler

    @anchors [0, 6, 12, 18]

    # Helper: a fire time anchored at `anchor_hour` with `offset_minutes`
    # offset is the DateTime obtained by adding `offset_minutes * 60` seconds
    # to that hour's start (carrying into later hours / days). Tests verify
    # the algorithm round-trips rather than pinning a specific hour, because
    # an offset of e.g. 303 minutes spills into hour anchor+5.
    defp expected_fire(date, anchor_hour, offset_minutes) do
      date
      |> DateTime.new!(Time.new!(anchor_hour, 0, 0), "Etc/UTC")
      |> DateTime.add(offset_minutes * 60, :second)
    end

    describe "next_fire_time/3" do
      test "returns the soonest anchor+offset strictly in the future" do
        now = ~U[2026-04-14 03:00:00.000000Z]
        workspace_id = "00000000-0000-0000-0000-000000000000"
        offset = SystemEventScheduler.offset_for(workspace_id)

        result = SystemEventScheduler.next_fire_time(now, workspace_id, @anchors)

        # Compute the soonest future candidate by enumerating today's anchors
        # and picking the first strictly > now.
        expected =
          @anchors
          |> Enum.map(&expected_fire(~D[2026-04-14], &1, offset))
          |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
          |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))

        assert DateTime.compare(result, expected) == :eq
        assert DateTime.compare(result, now) == :gt
      end

      test "wraps to tomorrow's first anchor when today's last anchor has passed" do
        workspace_id = "00000000-0000-0000-0000-000000000001"
        offset = SystemEventScheduler.offset_for(workspace_id)

        # 23:59 UTC, beyond all of today's anchors+offset since the last
        # anchor 18:00 + offset (88min = 19:28) is past.
        now = ~U[2026-04-14 23:59:00.000000Z]
        result = SystemEventScheduler.next_fire_time(now, workspace_id, @anchors)

        # Should land on tomorrow's 00:00 + offset.
        expected = expected_fire(~D[2026-04-15], 0, offset)
        assert DateTime.compare(result, expected) == :eq
        assert DateTime.to_date(result) == ~D[2026-04-15]
        assert DateTime.compare(result, now) == :gt
      end

      test "stagger: adjacent workspace UUIDs yield different offsets" do
        # Two UUIDs that differ by one byte — the phash2 modulus distributes
        # them to different minute offsets with overwhelming probability.
        ws_a = "00000000-0000-0000-0000-000000000001"
        ws_b = "00000000-0000-0000-0000-000000000002"

        offset_a = SystemEventScheduler.offset_for(ws_a)
        offset_b = SystemEventScheduler.offset_for(ws_b)

        refute offset_a == offset_b,
               "expected adjacent UUIDs to hash to different minute offsets, both = #{offset_a}"

        # Both offsets must land in the 0..359 range (the 6h staggered window).
        assert offset_a in 0..359
        assert offset_b in 0..359

        # And the actual fire times differ by exactly the offset delta (or by a
        # whole anchor cycle if they wrap differently). At now = 00:00, neither
        # has fired yet today, so both target today's 00:00 anchor.
        now = ~U[2026-04-14 00:00:00.000000Z]
        fire_a = SystemEventScheduler.next_fire_time(now, ws_a, @anchors)
        fire_b = SystemEventScheduler.next_fire_time(now, ws_b, @anchors)

        # Both must be strictly future relative to now and distinct.
        assert DateTime.compare(fire_a, now) == :gt
        assert DateTime.compare(fire_b, now) == :gt
        refute DateTime.compare(fire_a, fire_b) == :eq

        # And each must equal anchor 00:00 (today or tomorrow) + own offset.
        assert DateTime.compare(fire_a, expected_fire(~D[2026-04-14], 0, offset_a)) == :eq
        assert DateTime.compare(fire_b, expected_fire(~D[2026-04-14], 0, offset_b)) == :eq
      end

      test "nil workspace_id (V1 org-scope fan-out) yields a stable offset" do
        offset = SystemEventScheduler.offset_for(nil)
        assert offset in 0..359
        # Stable across calls.
        assert SystemEventScheduler.offset_for(nil) == offset
      end
    end

    describe "recently_fired?/4" do
      test "returns false when never fired" do
        refute SystemEventScheduler.recently_fired?(
                 "ws-a",
                 6,
                 nil,
                 ~U[2026-04-14 06:00:00.000000Z]
               )
      end

      test "06:00 fire blocks 06:00 today (same anchor, same day)" do
        last = ~U[2026-04-14 06:05:00.000000Z]
        # 06:05 same day → 5 min ago, well within 6h window.
        now = ~U[2026-04-14 06:10:00.000000Z]
        assert SystemEventScheduler.recently_fired?("ws-a", 6, last, now)
      end

      test "06:00 fire does NOT block 12:00 today (different anchor key)" do
        # The caller looks up last_fired by {workspace_id, anchor_hour}.
        # When querying the 12:00 anchor key, last is nil → not blocked.
        refute SystemEventScheduler.recently_fired?(
                 "ws-a",
                 12,
                 nil,
                 ~U[2026-04-14 12:00:00.000000Z]
               )
      end

      test "yesterday's same-anchor fire does NOT block today" do
        last = ~U[2026-04-14 06:00:00.000000Z]
        # 24h later → outside the 6h window → eligible.
        now = ~U[2026-04-15 06:00:00.000000Z]
        refute SystemEventScheduler.recently_fired?("ws-a", 6, last, now)
      end
    end
  end

  # ── Schema + dispatch (DB required) ──────────────────────────────────────────

  defmodule DispatchTest do
    use Platform.DataCase

    import ExUnit.CaptureLog

    alias Platform.Agents.Agent
    alias Platform.Agents.SystemEventScheduler
    alias Platform.Chat
    alias Platform.Chat.Message
    alias Platform.Chat.Space

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

    defp read_system_space_messages(agent) do
      %Space{id: space_id} = Chat.get_space_by_slug("system-#{agent.slug}")

      Repo.all(
        from(m in Message,
          where: m.space_id == ^space_id,
          order_by: [asc: m.inserted_at]
        )
      )
    end

    describe "system_events field (post-T6 whitelist)" do
      test "agent changeset accepts the new historian event" do
        changeset =
          Agent.changeset(
            %Agent{},
            Map.put(@valid_agent_attrs, :system_events, ["historian"])
          )

        assert changeset.valid?
      end

      test "agent changeset rejects the legacy daily_summary event" do
        changeset =
          Agent.changeset(
            %Agent{},
            Map.put(@valid_agent_attrs, :system_events, ["daily_summary"])
          )

        refute changeset.valid?
      end

      test "agent changeset rejects the legacy dreaming event" do
        changeset =
          Agent.changeset(
            %Agent{},
            Map.put(@valid_agent_attrs, :system_events, ["dreaming"])
          )

        refute changeset.valid?
      end

      test "agent changeset rejects unknown system events" do
        changeset =
          Agent.changeset(
            %Agent{},
            Map.put(@valid_agent_attrs, :system_events, ["invalid_event"])
          )

        refute changeset.valid?
      end

      test "agent changeset accepts empty system events" do
        changeset =
          Agent.changeset(%Agent{}, Map.put(@valid_agent_attrs, :system_events, []))

        assert changeset.valid?
      end

      test "system_events persists as JSONB array" do
        agent = create_agent(%{system_events: ["historian"]})
        reloaded = Repo.get!(Agent, agent.id)

        assert reloaded.system_events == ["historian"]
      end

      test "system_events defaults to empty list" do
        agent = create_agent()
        assert agent.system_events == []
      end
    end

    describe "agent_for_event query" do
      test "fire_now finds the historian-flagged active agent" do
        agent = create_agent(%{system_events: ["historian"]})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        _result = SystemEventScheduler.fire_now("historian")

        # Verify a system space was created for this agent.
        space = Chat.get_space_by_slug("system-#{agent.slug}")
        assert space != nil
        assert space.kind == "system"
      end

      test "fire_now skips when no agent is flagged" do
        _agent = create_agent(%{system_events: []})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("historian")
      end

      test "fire_now skips inactive agents" do
        _agent = create_agent(%{system_events: ["historian"], status: "paused"})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("historian")
      end

      test "legacy event names are routed to the historian agent with a warning" do
        agent = create_agent(%{system_events: ["historian"]})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        log =
          capture_log(fn ->
            SystemEventScheduler.fire_now("daily_summary")
          end)

        assert log =~ "legacy event \"daily_summary\""
        # And the historian agent still got dispatched.
        assert Chat.get_space_by_slug("system-#{agent.slug}") != nil
      end
    end

    describe "one-agent-per-event enforcement" do
      test "flagging agent B unflags agent A via config save logic" do
        agent_a = create_agent(%{slug: "agent-a", system_events: ["historian"]})
        agent_b = create_agent(%{slug: "agent-b", system_events: []})

        # Mirror the unflag logic from control_center_live.ex.
        newly_claimed = ["historian"]

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

        agent_b |> Agent.changeset(%{system_events: ["historian"]}) |> Repo.update!()

        reloaded_a = Repo.get!(Agent, agent_a.id)
        reloaded_b = Repo.get!(Agent, agent_b.id)

        assert reloaded_a.system_events == []
        assert reloaded_b.system_events == ["historian"]
      end
    end

    describe "historian instruction content" do
      test "posted instruction includes the activity digest and writes-to-pages guidance" do
        agent = create_agent(%{system_events: ["historian"]})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("historian")

        messages = read_system_space_messages(agent)

        assert Enum.any?(messages, fn m ->
                 String.contains?(m.content, "## Activity since") and
                   String.contains?(m.content, "Historian")
               end)
      end

      test "instruction does not leave the digest placeholder uninterpolated" do
        agent = create_agent(%{system_events: ["historian"]})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("historian")

        messages = read_system_space_messages(agent)

        refute Enum.any?(messages, fn m ->
                 String.contains?(m.content, "{activity_digest}")
               end)
      end
    end

    describe "external runtime handling" do
      setup do
        user =
          Repo.insert!(%Platform.Accounts.User{
            email: "sched_test_#{System.unique_integer([:positive])}@example.com",
            name: "Sched Test User",
            oidc_sub: "oidc-sched-test-#{System.unique_integer([:positive])}"
          })

        runtime_id_string = "ext-runtime-#{System.unique_integer([:positive])}"

        {:ok, runtime} =
          Platform.Federation.register_runtime(user.id, %{runtime_id: runtime_id_string})

        agent =
          create_agent(%{
            slug: "external-historian",
            runtime_type: "external",
            runtime_id: runtime.id,
            system_events: ["historian"]
          })

        {:ok, agent: agent, runtime: runtime, runtime_id_string: runtime_id_string}
      end

      test "skips dispatch when external runtime is offline, logs warning",
           %{agent: agent, runtime_id_string: runtime_id_string} do
        Platform.Federation.RuntimePresence.untrack(runtime_id_string)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        log =
          capture_log(fn ->
            SystemEventScheduler.fire_now("historian")
          end)

        assert log =~ "external runtime #{runtime_id_string} is offline"
        refute Chat.get_space_by_slug("system-#{agent.slug}")
      end

      test "dispatches when external runtime presence is tracked under its string runtime_id",
           %{agent: agent, runtime_id_string: runtime_id_string} do
        Platform.Federation.RuntimePresence.track(runtime_id_string)
        on_exit(fn -> Platform.Federation.RuntimePresence.untrack(runtime_id_string) end)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        log =
          capture_log(fn ->
            SystemEventScheduler.fire_now("historian")
          end)

        refute log =~ "is offline"
        assert Chat.get_space_by_slug("system-#{agent.slug}") != nil
      end
    end

    describe "ambiguity when multiple agents claim same event" do
      test "picks the oldest agent and logs a warning" do
        older = create_agent(%{slug: "older-historian", system_events: ["historian"]})
        newer = create_agent(%{slug: "newer-historian", system_events: ["historian"]})

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        log =
          capture_log(fn ->
            SystemEventScheduler.fire_now("historian")
          end)

        assert log =~ "multiple agents flagged for historian"
        assert Chat.get_space_by_slug("system-#{older.slug}") != nil
        assert Chat.get_space_by_slug("system-#{newer.slug}") == nil
      end
    end
  end

  # ── Fan-out via list_active_workspaces (no DB) ─────────────────────────────

  defmodule FanOutTest do
    use ExUnit.Case, async: true

    alias Platform.Tasks.Projects

    test "V1 fan-out returns [nil] (org-scope only)" do
      assert Projects.list_active_workspaces() == [nil]
    end
  end
end
