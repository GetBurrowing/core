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

    # Task 019f2444 stage 6: fixtures no longer seed
    # `system_events: ["historian"]` (column dropped in stage 5). Callers
    # pass `assign_historian?: true` to pin the Historian role on the
    # freshly-inserted agent. `Roles.assign_role/2` returns
    # `{:error, changeset}` when the role is already pinned — swallow it
    # so the older assignment wins (mirrors the legacy `order_by:
    # inserted_at` behaviour for the multi-Historian tiebreak).
    defp create_agent(attrs \\ %{}, opts \\ []) do
      agent =
        %Agent{}
        |> Agent.changeset(Map.merge(@valid_agent_attrs, attrs))
        |> Repo.insert!()

      if Keyword.get(opts, :assign_historian?, false) and agent.status == "active" do
        assign_historian_role(agent)
      end

      agent
    end

    defp assign_historian_role(%Agent{id: id}) do
      case Platform.Roles.assign_role("historian", id) do
        {:ok, _} -> :ok
        {:error, _changeset} -> :ok
      end
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

    describe "agent_for_event query" do
      test "fire_now finds the historian-pinned active agent" do
        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        _result = SystemEventScheduler.fire_now("historian")

        # Verify a system space was created for this agent.
        space = Chat.get_space_by_slug("system-#{agent.slug}")
        assert space != nil
        assert space.kind == "system"
      end

      test "fire_now skips when no agent is pinned" do
        _agent = create_agent()

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("historian")
      end

      test "fire_now skips inactive agents" do
        _agent = create_agent(%{status: "paused"}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert :ok = SystemEventScheduler.fire_now("historian")
      end

      test "legacy event names are routed to the historian agent with a warning" do
        agent = create_agent(%{}, assign_historian?: true)

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

    describe "historian instruction content" do
      test "posted instruction includes the activity digest and writes-to-pages guidance" do
        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("historian")

        messages = read_system_space_messages(agent)

        assert Enum.any?(messages, fn m ->
                 String.contains?(m.content, "## Activity since") and
                   String.contains?(m.content, "memory_create") and
                   String.contains?(m.content, "Historian")
               end)
      end

      test "instruction does not leave the digest placeholder uninterpolated" do
        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("historian")

        messages = read_system_space_messages(agent)

        refute Enum.any?(messages, fn m ->
                 String.contains?(m.content, "{activity_digest}")
               end)
      end
    end

    describe "deleted-paths notice injection (task 019f6381 stage 5)" do
      # Bridge test: `Platform.MemoryFeedback` delete rows are surfaced
      # into every historian dispatch under the "Intentionally deleted
      # paths" section so the Historian doesn't restore backlink
      # targets that were purposefully cleaned up.
      #
      # Legacy `"dreaming"` event name still resolves through the
      # scheduler's `normalize_event/1` funnel to the modern
      # `historian.scheduled` template — the plan spec pins this via the
      # e2e_behavior case. Firing `"dreaming"` here mirrors that
      # contract at the unit level.

      test "dreaming fire renders recent delete rows under 'Intentionally deleted paths'" do
        # Seed two delete rows via the stage-1 capture API so the
        # rendered notice pulls from the real corpus, not a stub.
        {:ok, _} =
          Platform.MemoryFeedback.record_delete(%{
            original_content: "old agent roster",
            path: "ORG_AGENTS.md",
            namespace: "org_context",
            reason_text: "outdated"
          })

        {:ok, _} =
          Platform.MemoryFeedback.record_delete(%{
            original_content: "old memory sketch",
            path: "ORG_MEMORY.md",
            namespace: "org_context"
          })

        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        # Fire the legacy event name so we also cover the
        # `normalize_event("dreaming")` → historian.scheduled routing.
        SystemEventScheduler.fire_now("dreaming")

        [message | _] = read_system_space_messages(agent)

        assert message.content =~ "Intentionally deleted paths"
        assert message.content =~ "- ORG_AGENTS.md — outdated"
        assert message.content =~ "- ORG_MEMORY.md"

        # Regression guard: the placeholder must NEVER survive the
        # render — an interpolation miss here would ship broken prompt
        # scaffold to the Historian.
        refute String.contains?(message.content, "{deleted_paths_notice}")
        refute String.contains?(message.content, "{{deleted_paths_notice}}")
      end

      test "empty delete corpus renders '(none in the recent window)' rather than crashing" do
        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("dreaming")

        [message | _] = read_system_space_messages(agent)

        assert message.content =~ "Intentionally deleted paths"
        assert message.content =~ "(none in the recent window)"
        refute String.contains?(message.content, "{deleted_paths_notice}")
        refute String.contains?(message.content, "{{deleted_paths_notice}}")
      end

      test "namespace filter isolates other namespaces from the notice" do
        # A delete row in a non-org_context namespace must not leak
        # into the org_context-scoped notice. The MemoryFeedback API's
        # namespace filter is strict-eq (verified in the stage 3
        # tests); this asserts the injection uses the same scope.
        {:ok, _} =
          Platform.MemoryFeedback.record_delete(%{
            original_content: "space-scoped content",
            path: "SPACE_NOTES.md",
            namespace: "space_context"
          })

        agent = create_agent(%{}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        SystemEventScheduler.fire_now("dreaming")

        [message | _] = read_system_space_messages(agent)

        assert message.content =~ "(none in the recent window)"
        refute message.content =~ "SPACE_NOTES.md"
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
          create_agent(
            %{
              slug: "external-historian",
              runtime_type: "external",
              runtime_id: runtime.id
            },
            assign_historian?: true
          )

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

    describe "role_assignments unique-index enforces one Historian" do
      test "second assign_role/2 loses; dispatch lands on the pinned one, no ambiguity warning" do
        # M4/ADR-0041: `role_assignments.role_key` is UNIQUE, so the
        # "two agents flagged historian" state the legacy column
        # allowed is now impossible. Stage 6 (this task) dropped the
        # column entirely — the fixture below tries to pin both agents
        # to the Historian role; the second `assign_role/2` returns
        # `{:error, changeset}` and the older assignment wins.
        # Dispatch resolves to `older`, `newer` gets nothing, and no
        # ambiguity warning is emitted (the multi-agent tiebreak branch
        # in the legacy scheduler is dead code post-M4).
        older = create_agent(%{slug: "older-historian"}, assign_historian?: true)
        newer = create_agent(%{slug: "newer-historian"}, assign_historian?: true)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        log =
          capture_log(fn ->
            SystemEventScheduler.fire_now("historian")
          end)

        refute log =~ "multiple agents flagged for historian"
        assert Chat.get_space_by_slug("system-#{older.slug}") != nil
        assert Chat.get_space_by_slug("system-#{newer.slug}") == nil
      end
    end
  end

  # ── Fan-out via list_active_workspaces (no DB) ─────────────────────────────

  defmodule FanOutTest do
    use ExUnit.Case, async: true

    alias Platform.Tasks.Projects

    test "V1 fan-out returns the org-scope sentinel UUID" do
      # Sentinel UUID per ADR-0041 T6 stage 5: org_historian_cursors enforces
      # workspace_id NOT NULL, so the V1 org-scope fan-out uses a sentinel
      # UUID instead of nil. Real multi-tenancy is a future task.
      assert Projects.list_active_workspaces() == [Projects.org_scope_workspace_id()]
      assert Projects.org_scope_workspace_id() == "00000000-0000-0000-0000-000000000000"
    end
  end

  # ── 100k-token threshold + debounce (pure function) ─────────────────────────

  defmodule ThresholdLogicTest do
    @moduledoc """
    Pure-function table for `SystemEventScheduler.should_fire_threshold?/5`.

    Plan-mandated cases (T6 stage 5):
      - under threshold = false
      - over threshold, last_run nil = true
      - over threshold, last_run 30min ago = false
      - over threshold, last_run 61min ago = true
    """
    use ExUnit.Case, async: true

    alias Platform.Agents.SystemEventScheduler

    @threshold 100_000
    @debounce_ms 60 * 60 * 1_000
    @now ~U[2026-05-20 12:00:00.000000Z]

    test "under threshold → false (no dispatch regardless of last_run_at)" do
      refute SystemEventScheduler.should_fire_threshold?(
               99_999,
               nil,
               @now,
               @threshold,
               @debounce_ms
             )

      refute SystemEventScheduler.should_fire_threshold?(
               0,
               nil,
               @now,
               @threshold,
               @debounce_ms
             )

      # Even with a stale last_run_at, low pending → no fire.
      stale = DateTime.add(@now, -:timer.hours(48), :millisecond)

      refute SystemEventScheduler.should_fire_threshold?(
               50_000,
               stale,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "over threshold + last_run nil → true (first run is always allowed)" do
      assert SystemEventScheduler.should_fire_threshold?(
               @threshold,
               nil,
               @now,
               @threshold,
               @debounce_ms
             )

      assert SystemEventScheduler.should_fire_threshold?(
               @threshold * 2,
               nil,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "over threshold + last_run 30min ago → false (still within debounce)" do
      last = DateTime.add(@now, -30 * 60 * 1_000, :millisecond)

      refute SystemEventScheduler.should_fire_threshold?(
               @threshold,
               last,
               @now,
               @threshold,
               @debounce_ms
             )

      refute SystemEventScheduler.should_fire_threshold?(
               @threshold * 4,
               last,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "over threshold + last_run 61min ago → true (debounce elapsed)" do
      last = DateTime.add(@now, -61 * 60 * 1_000, :millisecond)

      assert SystemEventScheduler.should_fire_threshold?(
               @threshold,
               last,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "boundary: exactly debounce_ms elapsed → true (>= semantics)" do
      last = DateTime.add(@now, -@debounce_ms, :millisecond)

      assert SystemEventScheduler.should_fire_threshold?(
               @threshold,
               last,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "boundary: 1ms shy of debounce → false (still within window)" do
      last = DateTime.add(@now, -(@debounce_ms - 1), :millisecond)

      refute SystemEventScheduler.should_fire_threshold?(
               @threshold,
               last,
               @now,
               @threshold,
               @debounce_ms
             )
    end

    test "uses module defaults when threshold/debounce args omitted" do
      # 100k pending, never run → defaults should permit fire.
      assert SystemEventScheduler.should_fire_threshold?(100_000, nil, @now)
      refute SystemEventScheduler.should_fire_threshold?(99_999, nil, @now)
    end
  end

  # ── 100k-token threshold + debounce (integration) ───────────────────────────

  defmodule ThresholdSweepTest do
    @moduledoc """
    Integration tests for the threshold sweep:
      - inserts 100k+ tokens of journal content,
      - calls `run_threshold_check_now/0`,
      - asserts the scheduler dispatched the historian AND stamped
        `Historian.last_run_at(nil)`.
      - simulates clock advance by backdating `last_run_at` in the cursor table
        between sweeps to verify debounce + post-debounce re-fire.
    """
    use Platform.DataCase

    alias Platform.Agents.Agent
    alias Platform.Agents.Historian
    alias Platform.Agents.HistorianCursor
    alias Platform.Agents.SystemEventScheduler
    alias Platform.Chat
    alias Platform.Chat.Message
    alias Platform.Chat.Space
    alias Platform.Org.WikiJournalEntry, as: MemoryEntry
    alias Platform.Tasks.Projects

    # V1 fan-out uses the org-scope sentinel UUID — `Projects.list_active_workspaces/0`
    # returns `[org_scope_workspace_id()]`, so the threshold sweep evaluates that
    # workspace_id and not `nil`.
    @historian_workspace_id Projects.org_scope_workspace_id()

    defp create_historian_agent do
      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "threshold-historian",
          name: "Threshold Historian",
          status: "active"
        })
        |> Repo.insert!()

      # Task 019f2444: HistorianDispatcher.agent_for_event/1 consults
      # Platform.Roles as source-of-truth. Pin the Historian role so
      # threshold-sweep dispatch resolves to this agent. The legacy
      # `agents.system_events` column was dropped in stage 5.
      {:ok, _} = Platform.Roles.assign_role("historian", agent.id)

      agent
    end

    defp insert_journal_chars!(workspace_id, n) when is_integer(n) and n > 0 do
      # Prod stores actual org-scope journal rows with `workspace_id IS NULL`;
      # the sentinel string is a fan-out identifier from `Tasks.Projects`,
      # never a value written to `org_wiki_journal_entries.workspace_id`.
      # Coerce here so the test seed mirrors on-disk shape (see
      # `Historian.sum_corpus_bytes/3` pass-through clauses).
      seed_ws = if workspace_id == Projects.org_scope_workspace_id(), do: nil, else: workspace_id

      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        workspace_id: seed_ws,
        content: String.duplicate("x", n),
        date: Date.utc_today()
      })
      |> Repo.insert!()
    end

    # Seed `days` rows of `bytes_per_day` bytes each, one per calendar day
    # working backward from today. Backdates `inserted_at` via raw update
    # so the per-day slicer walks distinct day-ranges (mirrors the
    # `force_inserted_at!` pattern in `historian_test.exs`).
    #
    # Used by the debounce tests: they need enough real content spread
    # across enough days that a single capped dispatch cannot drain the
    # pending backlog past the 100k-token threshold. Under the pre-stage-2
    # uniform-distribute heuristic, a single-day 410KB row happened to
    # survive because cursor advance smeared to old empty days; the real
    # per-day slicer correctly drains a single-day row in one sweep, so
    # these tests now seed multi-day content explicitly.
    defp insert_multi_day_journal!(workspace_id, days, bytes_per_day)
         when is_integer(days) and days > 0 and is_integer(bytes_per_day) and bytes_per_day > 0 do
      today = Date.utc_today()

      Enum.each(0..(days - 1), fn offset ->
        day = Date.add(today, -offset)
        row = insert_journal_chars!(workspace_id, bytes_per_day)
        inserted_at = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

        {1, _} =
          Repo.update_all(
            from(e in MemoryEntry, where: e.id == ^row.id),
            set: [inserted_at: inserted_at]
          )
      end)

      :ok
    end

    # Backdate every cursor row's `last_run_at` for `workspace_id` to `delta_ms`
    # in the past, relative to now. Simulates "clock advance" without needing
    # a mock clock — the debounce policy reads cursor `last_run_at` directly.
    #
    # Task 019f5e7d: `mark_run_started(sentinel)` now coerces to `nil` and
    # persists rows with `workspace_id IS NULL` (the canonical org-scope
    # on-disk shape). This helper mirrors the same coercion so the backdate
    # updates the same rows the debounce read (also coerced) queries.
    defp backdate_last_run!(workspace_id, delta_ms) when is_binary(workspace_id) do
      past = DateTime.add(DateTime.utc_now(), -delta_ms, :millisecond)
      sentinel = Projects.org_scope_workspace_id()

      target_query =
        if workspace_id == sentinel do
          from(c in HistorianCursor, where: is_nil(c.workspace_id))
        else
          from(c in HistorianCursor, where: c.workspace_id == ^workspace_id)
        end

      {_, _} = Repo.update_all(target_query, set: [last_run_at: past])

      :ok
    end

    defp historian_messages(agent) do
      case Chat.get_space_by_slug("system-#{agent.slug}") do
        %Space{id: space_id} ->
          Repo.all(
            from(m in Message,
              where: m.space_id == ^space_id,
              order_by: [asc: m.inserted_at]
            )
          )

        nil ->
          []
      end
    end

    describe "threshold sweep — fire path" do
      test "inserts 100k+ tokens, sweep dispatches and stamps last_run_at" do
        agent = create_historian_agent()

        # 400k+ bytes ≈ 100k tokens (char/4 heuristic). Insert 410_000 bytes
        # of journal content for the org-scope (nil) workspace so the
        # Historian context module picks it up.
        insert_journal_chars!(@historian_workspace_id, 410_000)

        assert Historian.pending_tokens(@historian_workspace_id) >= 100_000
        assert Historian.last_run_at(@historian_workspace_id) == nil

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        results = SystemEventScheduler.run_threshold_check_now()

        assert {@historian_workspace_id, :fired} in results

        # last_run_at must be stamped before the dispatch returns (the
        # scheduler calls mark_run_started BEFORE the dispatch fan-out).
        assert %DateTime{} = Historian.last_run_at(@historian_workspace_id)

        # A system-space message was posted with the threshold-trigger metadata.
        messages = historian_messages(agent)
        assert length(messages) >= 1

        first = hd(messages)
        assert first.metadata["event_type"] == "historian"
        assert first.metadata["trigger"] == "threshold"
        assert first.metadata["source"] == "system_event"
      end
    end

    describe "threshold sweep — debounce path" do
      test "fire once, sweep within debounce window → no second dispatch" do
        _agent = create_historian_agent()
        # Seed 30 days of multi-day content so a single capped sweep can't
        # drain pending below the threshold — see comment on
        # `insert_multi_day_journal!/3` for why the previous single-day
        # seeding no longer keeps pending above threshold post-sweep.
        insert_multi_day_journal!(@historian_workspace_id, 30, 100_000)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        # First sweep fires.
        assert {@historian_workspace_id, :fired} in SystemEventScheduler.run_threshold_check_now()
        first_run = Historian.last_run_at(@historian_workspace_id)
        assert %DateTime{} = first_run

        # Simulate 30min elapsed — still within the 1h debounce.
        backdate_last_run!(@historian_workspace_id, 30 * 60 * 1_000)

        results = SystemEventScheduler.run_threshold_check_now()
        assert {@historian_workspace_id, :debounced} in results

        # last_run_at must not have advanced (it was backdated, then the
        # debounced sweep did not call mark_run_started).
        after_debounce = Historian.last_run_at(@historian_workspace_id)
        # Tolerance: it equals the backdate stamp ± microseconds; not advanced
        # to "now". So it is strictly less than `now`.
        assert DateTime.compare(after_debounce, DateTime.utc_now()) == :lt
        # And it must be older than the original first_run (since we backdated).
        assert DateTime.compare(after_debounce, first_run) == :lt
      end

      test "after debounce elapses, sweep dispatches again" do
        _agent = create_historian_agent()
        insert_multi_day_journal!(@historian_workspace_id, 30, 100_000)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        # First sweep fires.
        assert {@historian_workspace_id, :fired} in SystemEventScheduler.run_threshold_check_now()

        # Within debounce → no fire.
        backdate_last_run!(@historian_workspace_id, 30 * 60 * 1_000)

        assert {@historian_workspace_id, :debounced} in SystemEventScheduler.run_threshold_check_now()

        # Past debounce (61min) → fire again.
        backdate_last_run!(@historian_workspace_id, 61 * 60 * 1_000)

        results = SystemEventScheduler.run_threshold_check_now()
        assert {@historian_workspace_id, :fired} in results

        # last_run_at advanced to ~now.
        latest = Historian.last_run_at(@historian_workspace_id)
        delta_ms = DateTime.diff(DateTime.utc_now(), latest, :millisecond)
        assert delta_ms >= 0 and delta_ms < 5_000
      end
    end

    describe "threshold sweep — under-threshold path" do
      test "below 100k tokens → no dispatch" do
        _agent = create_historian_agent()
        # 4 bytes → 1 token, nowhere near 100k.
        insert_journal_chars!(@historian_workspace_id, 4)

        assert Historian.pending_tokens(@historian_workspace_id) < 100_000

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        results = SystemEventScheduler.run_threshold_check_now()
        assert {@historian_workspace_id, :under_threshold} in results

        # No run stamped; no message posted.
        assert Historian.last_run_at(@historian_workspace_id) == nil
      end
    end

    describe "threshold sweep — telemetry" do
      test "fire emits [:platform, :agents, :historian_scheduler, :threshold_fired]" do
        _agent = create_historian_agent()
        insert_journal_chars!(@historian_workspace_id, 410_000)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        test_pid = self()

        handler_id = "threshold-fired-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler_id,
          [:platform, :agents, :historian_scheduler, :threshold_fired],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_fired, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        SystemEventScheduler.run_threshold_check_now()

        assert_receive {:telemetry_fired, measurements, metadata}, 1_000
        assert measurements.pending_tokens >= 100_000
        assert metadata.workspace_id == @historian_workspace_id
      end

      test "debounced sweep emits [:platform, :agents, :historian_scheduler, :threshold_debounced]" do
        _agent = create_historian_agent()
        insert_multi_day_journal!(@historian_workspace_id, 30, 100_000)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        # Prime: fire once, then backdate to within debounce window.
        SystemEventScheduler.run_threshold_check_now()
        backdate_last_run!(@historian_workspace_id, 30 * 60 * 1_000)

        test_pid = self()

        handler_id = "threshold-debounced-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler_id,
          [:platform, :agents, :historian_scheduler, :threshold_debounced],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_debounced, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        SystemEventScheduler.run_threshold_check_now()

        assert_receive {:telemetry_debounced, measurements, metadata}, 1_000
        assert measurements.pending_tokens >= 100_000
        assert metadata.workspace_id == @historian_workspace_id
        assert %DateTime{} = metadata.last_run_at
      end
    end
  end

  # ── Windowed sweep (task 019f4f55 stage 3) ─────────────────────────────

  defmodule WindowedThresholdSweepTest do
    @moduledoc """
    Task 019f4f55 stage 3 rewired `fire_threshold/2` to call
    `HistorianDispatcher.dispatch_windowed/4`. These tests seed a
    chat-message backlog large enough for the slicer to fan out well
    past `historian_max_windows_per_pass`, then assert:

      * the sweep dispatches exactly `cap` windows per tick,
      * the messages cursor advances forward with each window,
      * telemetry (`threshold_windows_dispatched`,
        `threshold_sweep_capped`, `historian.window_dispatched`)
        surfaces the cap-hit + remaining backlog,
      * a subsequent tick past the debounce picks up the next batch.

    Setup mirrors `historian_dispatcher_test.exs` — a `NoopAgentChat`
    stub keeps the tail `AgentResponder.maybe_dispatch/1` synchronous
    and side-effect-free so the test doesn't need to fake an LLM.
    """
    use Platform.DataCase, async: false

    alias Platform.Agents.Agent
    alias Platform.Agents.Historian
    alias Platform.Agents.HistorianCursor
    alias Platform.Agents.HistorianDispatcher
    alias Platform.Agents.SystemEventScheduler
    alias Platform.Chat
    alias Platform.Chat.Message
    alias Platform.Chat.Space
    alias Platform.Tasks.Projects

    @historian_workspace_id Projects.org_scope_workspace_id()

    # No-op chat module so `AgentResponder.maybe_dispatch/1` at the end
    # of each windowed post_instruction doesn't try to reach an LLM.
    defmodule NoopAgentChat do
      def chat(_message, _opts), do: {:ok, %{content: "", model: "test", usage: %{}}}
    end

    setup do
      previous_module = Application.get_env(:platform, :chat_agent_module)
      previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
      previous_budget = Application.get_env(:platform, :historian_window_token_budget)
      previous_cap = Application.get_env(:platform, :historian_max_windows_per_pass)

      Application.put_env(:platform, :chat_agent_module, NoopAgentChat)
      Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

      # Tight budget so a modest backlog fans out into many sub-windows.
      # Cap at 20 mirrors the production default the plan pins.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      # Clear baseline nil-workspace pages so the assertions about "all
      # dispatched windows carry corpus=:messages" aren't broken by the
      # test DB's seeded org pages (identity.md, memory.md, agents.md).
      # Post-hotfix the sentinel query correctly includes those rows in
      # the sweep; without this cleanup a stray page window would leak
      # into a messages-focused test.
      Repo.delete_all(from(f in "org_wiki_pages", where: is_nil(f.workspace_id)))

      on_exit(fn ->
        restore_env(:chat_agent_module, previous_module)
        restore_env(:chat_agent_dispatch_mode, previous_mode)
        restore_env(:historian_window_token_budget, previous_budget)
        restore_env(:historian_max_windows_per_pass, previous_cap)
      end)

      agent = create_historian_agent()

      {:ok, agent: agent}
    end

    defp restore_env(_key, nil), do: :ok
    defp restore_env(key, value), do: Application.put_env(:platform, key, value)

    defp create_historian_agent do
      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "windowed-historian-#{System.unique_integer([:positive])}",
          name: "Windowed Historian",
          status: "active"
        })
        |> Repo.insert!()

      case Platform.Roles.assign_role("historian", agent.id) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          Platform.Roles.unassign_role("historian") &&
            Platform.Roles.assign_role("historian", agent.id)
      end

      agent
    end

    defp insert_channel_space(name_suffix) do
      {:ok, space} =
        Chat.create_space(%{
          name: "Backlog #{name_suffix}",
          slug: "backlog-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      space
    end

    defp insert_user_participant(space_id, display_name) do
      {:ok, participant} =
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: display_name,
          joined_at: DateTime.utc_now()
        })

      participant
    end

    defp insert_message!(space_id, participant_id, content, inserted_at) do
      participant = Repo.get!(Chat.Participant, participant_id)

      changeset =
        Message.changeset(%Message{}, %{
          space_id: space_id,
          participant_id: participant_id,
          content_type: "text",
          content: content,
          author_display_name: participant.display_name || "Backlog"
        })

      changeset = Ecto.Changeset.put_change(changeset, :inserted_at, inserted_at)

      Repo.insert!(changeset)
    end

    defp seed_message_backlog!(row_count, bytes_per_row, day_span) do
      space = insert_channel_space("backlog")
      participant = insert_user_participant(space.id, "Old Voice")

      now = DateTime.utc_now()

      # Spread rows uniformly across `day_span` days. Each row's content
      # is a fixed byte size so total = row_count * bytes_per_row.
      body = String.duplicate("x", bytes_per_row)

      Enum.each(1..row_count, fn i ->
        # Push oldest rows to the far edge of the span so cursor
        # advance walks forward chronologically.
        day_offset = day_span * (row_count - i) / row_count
        ts = DateTime.add(now, -round(day_offset * 86_400), :second)
        insert_message!(space.id, participant.id, body, ts)
      end)

      :ok
    end

    defp historian_messages(agent) do
      case Chat.get_space_by_slug("system-#{agent.slug}") do
        %Space{id: space_id} ->
          Repo.all(
            from(m in Message,
              where: m.space_id == ^space_id and m.content_type == "text",
              order_by: [asc: m.inserted_at]
            )
          )

        nil ->
          []
      end
    end

    # Task 019f5e7d: `Historian.advance_cursor(sentinel, ...)` coerces to `nil`
    # and stamps the org-scope canonical `workspace_id IS NULL` row; look there
    # when the caller passes the sentinel.
    defp messages_cursor(workspace_id) do
      sentinel = Projects.org_scope_workspace_id()

      target_query =
        if workspace_id == sentinel do
          from(c in HistorianCursor,
            where: is_nil(c.workspace_id) and c.corpus == "messages"
          )
        else
          from(c in HistorianCursor,
            where: c.workspace_id == ^workspace_id and c.corpus == "messages"
          )
        end

      Repo.one(target_query)
    end

    # Task 019f5e7d: `mark_run_started(sentinel)` coerces to `nil` and stamps
    # the canonical `workspace_id IS NULL` rows; mirror the coercion here so
    # the debounce backdate hits the same rows the debounce read queries.
    defp backdate_last_run!(workspace_id, delta_ms) do
      past = DateTime.add(DateTime.utc_now(), -delta_ms, :millisecond)
      sentinel = Projects.org_scope_workspace_id()

      target_query =
        if workspace_id == sentinel do
          from(c in HistorianCursor, where: is_nil(c.workspace_id))
        else
          from(c in HistorianCursor, where: c.workspace_id == ^workspace_id)
        end

      {_, _} = Repo.update_all(target_query, set: [last_run_at: past])

      :ok
    end

    defp attach_forwarder(handler_id, event, tag) do
      test_pid = self()

      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {tag, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    describe "windowed threshold sweep — cap enforcement" do
      test "800-message backlog dispatches at cap and advances cursor", %{agent: agent} do
        # 800 rows × 800 bytes ≈ 640 KB spread across 30 days. At
        # budget=200 tokens the per-day byte estimate forces multiple
        # halves per calendar day, giving well over 100 windows total —
        # far past the cap. The cap should stop the sweep at 20.
        seed_message_backlog!(800, 800, 30)

        assert Historian.pending_tokens(@historian_workspace_id) >= 100_000

        # Forward per-window telemetry so we can assert one event per
        # dispatched window.
        window_handler = "window-dispatched-#{System.unique_integer([:positive])}"
        attach_forwarder(window_handler, [:platform, :historian, :window_dispatched], :window)

        cap_handler = "sweep-capped-#{System.unique_integer([:positive])}"

        attach_forwarder(
          cap_handler,
          [:platform, :agents, :historian_scheduler, :threshold_sweep_capped],
          :capped
        )

        dispatched_handler = "windows-dispatched-#{System.unique_integer([:positive])}"

        attach_forwarder(
          dispatched_handler,
          [:platform, :agents, :historian_scheduler, :threshold_windows_dispatched],
          :dispatched
        )

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        assert {@historian_workspace_id, :fired} in SystemEventScheduler.run_threshold_check_now()

        # 20 windows dispatched → 20 chat_messages in the system space.
        messages = historian_messages(agent)
        cap = HistorianDispatcher.max_windows_per_pass()
        assert length(messages) == cap

        # Every dispatched message carries a "messages"-namespace cursor
        # (the other three corpora are empty in this seed) and its
        # window_index runs from 1..cap monotonically.
        indices =
          Enum.map(messages, & &1.metadata["window_index"])
          |> Enum.sort()

        assert indices == Enum.to_list(1..cap)

        # The messages cursor was created and its `last_processed_at`
        # matches the newest dispatched window's `window_end`.
        cursor = messages_cursor(@historian_workspace_id)
        assert %HistorianCursor{last_processed_at: %DateTime{}} = cursor

        # Aggregate telemetry: dispatched=cap, remaining>0, capped fired.
        assert_receive {:dispatched, %{dispatched: ^cap, remaining: remaining}, %{}}, 1_000
        assert remaining > 0

        assert_receive {:capped, %{remaining: ^remaining}, %{}}, 1_000

        # Per-window telemetry fires `cap` times, each with a `messages`
        # corpus tag and a token_count clamped at or under the budget.
        budget = HistorianDispatcher.window_budget_tokens()
        window_events = drain_window_events(cap)
        assert length(window_events) == cap

        Enum.each(window_events, fn {measurements, metadata} ->
          assert metadata.corpus == :messages
          assert metadata.workspace_id == @historian_workspace_id
          assert is_binary(metadata.day_span)
          assert String.contains?(metadata.day_span, "/")
          assert measurements.token_count <= budget
          assert measurements.window_index in 1..cap
        end)
      end
    end

    describe "windowed threshold sweep — small backlog" do
      test "single-window backlog dispatches once and reports remaining=0", %{agent: agent} do
        # Small enough that the slicer emits ONE window that fits budget.
        # 400 bytes = 100 tokens, well under the 200-token budget.
        space = insert_channel_space("small")
        participant = insert_user_participant(space.id, "Ada")

        # One recent message keeps the window range small; the cursor
        # starts at nil so lookback bounds the range at 30 days but the
        # single row keeps byte_size small enough for one window.
        insert_message!(
          space.id,
          participant.id,
          String.duplicate("a", 400),
          DateTime.add(DateTime.utc_now(), -3_600, :second)
        )

        # Not enough tokens for the threshold sweep to fire on its own,
        # so drive `dispatch_windowed/4` directly to exercise the
        # single-window path in isolation.
        {:ok, %{dispatched: dispatched, remaining: remaining}} =
          HistorianDispatcher.dispatch_windowed(
            "historian",
            "historian.threshold",
            %{trigger: "threshold"},
            @historian_workspace_id
          )

        assert dispatched == 1
        assert remaining == 0

        cursor = messages_cursor(@historian_workspace_id)
        assert %HistorianCursor{last_processed_at: %DateTime{}} = cursor

        # Exactly one chat_message landed in the historian's system space.
        assert length(historian_messages(agent)) == 1
      end
    end

    describe "windowed threshold sweep — resumes after cap-hit" do
      test "second tick past debounce dispatches the next batch", %{agent: agent} do
        # 800 rows over 30 days → cap-hit on first sweep, backlog remains.
        seed_message_backlog!(800, 800, 30)

        {:ok, _pid} =
          start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

        cap = HistorianDispatcher.max_windows_per_pass()

        # First sweep: 20 dispatched, cursor at the 20th window_end.
        SystemEventScheduler.run_threshold_check_now()

        before_second = messages_cursor(@historian_workspace_id)
        assert %DateTime{} = before_second.last_processed_at

        assert length(historian_messages(agent)) == cap

        # Backdate `last_run_at` past the debounce so the second sweep
        # is eligible. `last_processed_at` is untouched — the resume
        # cursor stays at the 20th window's end.
        backdate_last_run!(@historian_workspace_id, 61 * 60 * 1_000)

        assert {@historian_workspace_id, :fired} in SystemEventScheduler.run_threshold_check_now()

        after_second = messages_cursor(@historian_workspace_id)

        assert DateTime.compare(after_second.last_processed_at, before_second.last_processed_at) ==
                 :gt,
               "cursor must advance forward on the second sweep"

        # Second batch of 20 rides on top of the first, so the system
        # space now has 40 messages total.
        assert length(historian_messages(agent)) == 2 * cap
      end
    end

    # Drain up to `n` window_dispatched events from the mailbox, in order.
    defp drain_window_events(n), do: drain_window_events(n, [])

    defp drain_window_events(0, acc), do: Enum.reverse(acc)

    defp drain_window_events(n, acc) do
      receive do
        {:window, measurements, metadata} ->
          drain_window_events(n - 1, [{measurements, metadata} | acc])
      after
        1_000 -> Enum.reverse(acc)
      end
    end
  end
end
