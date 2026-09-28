defmodule Platform.Agents.HistorianDispatcherTest do
  @moduledoc """
  DataCase coverage for the wired `dispatch_windowed/4` path added in task
  019f4f55 stage 2. Complements the pure-unit slicer tests in
  `historian_dispatcher_slice_windows_test.exs` by verifying the runtime
  side effects — chat message writes, per-window cursor advance, oversize
  truncation, and the token-budget guard at the message-body boundary.

  The pure-slicer tests fake `Historian.pending_windows_input/1` via
  `input_fn`; here we seed real corpus rows and let the slicer walk the
  DB the way `SystemEventScheduler.fire_threshold/2` will in stage 3.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.{Agent, Historian, HistorianCursor, HistorianDispatcher}
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings.Transcript
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Org.WikiJournalEntry, as: MemoryEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Projects

  # V1 org-scope sentinel (see `Platform.Tasks.Projects`). The
  # `org_historian_cursors.workspace_id` column is NOT NULL at the DB
  # level; the sentinel stands in for "the org-scope workspace" so the
  # cursor advance path doesn't blow up. All existing T6 code paths
  # (`SystemEventScheduler` fan-out, T6 e2e) use the same sentinel.
  @org_workspace Projects.org_scope_workspace_id()

  # ── WALL-CLOCK CLASSIFICATION (task 019fa633 stage 4) ───────────────────
  #
  # Every remaining `DateTime.utc_now()` in this file, classified. Referenced
  # by test name, not line number: the stage-4 plan's own line references had
  # all drifted, and a comment that names a line is wrong within a stage.
  #
  # (i) INSTANT-COMPARISON ONLY inside one seeded row set — safe, left alone.
  #     No date-valued filter, no date in an assertion or a failure message.
  #   • "dispatches N messages (one per window) with cursor metadata"
  #   • "advances the corpus cursor after each dispatched window"
  #   • "rejects an oversize rendered body without persisting a chat_messages
  #     row"
  #   • "(c) 25-day backlog: sweep-1 dispatches 20, sweep-2 dispatches
  #     remaining 5"
  #   • all three org-scope-sentinel cases ("happy path…", "mixed rows…",
  #     "messages+transcripts regression guard…")
  #   • `insert_user_participant/2`'s `joined_at:` — participant metadata, read
  #     by nothing in this file.
  #
  #     The first four and the sentinel cases DO sweep a range wider than one
  #     calendar day (the default 30-day lookback, or 25 explicit days). They
  #     are still class (i) rather than class (iii) because every instant they
  #     derive is `now - k * 86_400`, so the whole fixture translates rigidly
  #     with the clock and the calendar-day partition of the seeded set is
  #     invariant under that translation — UTC has no DST, so a set of instants
  #     exactly 86_400s apart always lands on the same number of distinct days.
  #     Measured, not assumed: the 4-row seeded-backlog geometry swept through
  #     /5 at pinned 00:05, 00:20, 00:44 and 12:00 dispatches exactly 4 windows
  #     at every instant. The sentinel cases go further and pin their rows to
  #     `~T[12:00:00]` of an explicit `Date` via `insert_page_at!` and friends,
  #     which is why those helpers are left untouched.
  #
  #     `(c)` additionally must NOT be pinned: it seeds its newest transcript at
  #     exactly `now`, and `pending_bytes_per_day/4` bounds the range
  #     end-exclusive. Under real wall-clock the dispatch happens microseconds
  #     later so the row is inside the sweep; pinning the clock would put the
  #     newest row exactly ON the exclusive bound and drop a day, breaking its
  #     `dispatched_1 + dispatched_2 == 25`.
  #
  # (ii) FEEDS A DATE-VALUED FILTER OR ASSERTION — all pinned already.
  #     Concentrated-density (a) and both original midnight-straddle cases pin
  #     via `@pinned_density_now` / `@straddle_*` (task 019fa633 stages 2–3).
  #     No unpinned `utc_now()` reaches a date filter anywhere in this file:
  #     `String.slice(0, 10)` and `Date.to_iso8601/1` appear only inside pinned
  #     cases.
  #
  # (iii) DEFINES A SWEEP RANGE WHOSE GEOMETRY IS TIME-OF-DAY DEPENDENT — all
  #     pinned by this stage. The three oversize cases each build a sub-day
  #     range (1h or 2h) hanging off `now`, so the range's position within the
  #     calendar day — not just its width — decides how many buckets the slicer
  #     produces. They now run off `@pinned_oversize_now`.
  #
  # DELIBERATELY UNPINNED, and must stay that way:
  #   • "(ii) /4 still sweeps to real wall-clock for its existing callers" —
  #     its `before_dispatch = DateTime.utc_now()` is the counterfactual half
  #     of the stage-1 pair. Pinning it would delete the only assertion that
  #     the production `SystemEventScheduler` path still sweeps to real time.
  #
  # SIBLING FILES (checked, left alone): `historian_dispatcher_telemetry_test`
  # asserts only `is_binary(md.day_span)` and never compares a date;
  # `historian_dispatcher_slice_windows_test` has injected a fixed `now` since
  # it was written — this task generalises that file's existing precedent up to
  # the integration layer.

  # No-op chat module so the `AgentResponder.maybe_dispatch/1` call at the
  # tail of each windowed post doesn't try to hit a real LLM. We don't
  # assert on agent replies here — only on the messages the dispatcher
  # itself writes into the historian's system space + the cursor advance.
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

    on_exit(fn ->
      restore_env(:chat_agent_module, previous_module)
      restore_env(:chat_agent_dispatch_mode, previous_mode)
      restore_env(:historian_window_token_budget, previous_budget)
      restore_env(:historian_max_windows_per_pass, previous_cap)
    end)

    agent = insert_historian_agent()

    {:ok, agent: agent}
  end

  # ── Happy-path multi-window dispatch ────────────────────────────────────

  describe "dispatch_windowed/4 — seeded backlog" do
    test "dispatches N messages (one per window) with cursor metadata", %{agent: agent} do
      # Set a small budget so a modestly-sized backlog splits cleanly.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      # Insert 4 messages spanning 4 different UTC calendar days. Each is
      # ~1_200 bytes → 300 tokens (above the 200-token budget), so the
      # slicer will split the total range into per-day windows.
      chat_space = insert_channel_space("historical")
      chat_participant = insert_user_participant(chat_space.id, "Old Voice")

      now = DateTime.utc_now()

      days_ago =
        Enum.map(1..4, fn d -> DateTime.add(now, -d * 86_400, :second) end)

      Enum.each(days_ago, fn ts ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("a", 1_200),
          inserted_at: ts
        })
      end)

      assert {:ok, %{dispatched: dispatched, remaining: remaining}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert dispatched >= 1
      assert remaining >= 0

      # Every persisted message in the historian's system space carries
      # windowed cursor metadata.
      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      assert %Chat.Space{} = system_space

      messages =
        Repo.all(
          from(m in Message,
            where: m.space_id == ^system_space.id and m.content_type == "text",
            order_by: [asc: m.inserted_at]
          )
        )

      assert length(messages) == dispatched

      Enum.each(messages, fn m ->
        assert m.metadata["event_type"] == "historian"
        assert m.metadata["trigger"] == "threshold"

        cursor = m.metadata["cursor"]
        assert is_map(cursor)
        assert cursor["namespace"] in ~w(pages journal messages transcripts)
        assert is_binary(cursor["window_start"])
        assert is_binary(cursor["window_end"])
        assert is_integer(m.metadata["window_index"])
        assert is_integer(m.metadata["window_of"])
      end)
    end

    test "advances the corpus cursor after each dispatched window", %{agent: _agent} do
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      chat_space = insert_channel_space("cursored")
      chat_participant = insert_user_participant(chat_space.id, "Ada")

      now = DateTime.utc_now()

      # 2 messages, one per day, ~1.2KB each — forces the messages corpus
      # into >=2 windows.
      Enum.each(1..2, fn d ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("m", 1_200),
          inserted_at: DateTime.add(now, -d * 86_400, :second)
        })
      end)

      # Precondition: no cursor row for org-scope "messages" yet.
      # Task 019f5e7d: advance_cursor coerces the sentinel to nil, so the
      # canonical row shape lives at `workspace_id IS NULL`.
      refute Repo.one(
               from(c in HistorianCursor,
                 where: is_nil(c.workspace_id) and c.corpus == "messages"
               )
             )

      {:ok, %{dispatched: dispatched}} =
        HistorianDispatcher.dispatch_windowed(
          "historian",
          "historian.threshold",
          %{},
          @org_workspace
        )

      assert dispatched >= 1

      # After the sweep, the cursor for "messages" has advanced to the
      # `window_end` of the last dispatched messages-window.
      cursor =
        Repo.one!(
          from(c in HistorianCursor,
            where: is_nil(c.workspace_id) and c.corpus == "messages"
          )
        )

      assert %DateTime{} = cursor.last_processed_at
    end
  end

  # ── Oversize truncation path ────────────────────────────────────────────

  describe "dispatch_windowed/4 — oversize window" do
    # All three cases below dispatch through `dispatch_windowed/5` with this
    # pinned instant (task 019fa633 stage 4). The describe name is left on /4
    # deliberately — stages 2 and 3 made the same call for the
    # concentrated-density block, and renaming churns the describe filters the
    # stage-5 reviewer script and prior evidence refer to.
    #
    # Mid-day, so each case runs the single-calendar-day geometry it was
    # written around. The watermark case at the bottom of this block is the
    # one that MEASURABLY broke near midnight — see the band table above its
    # straddle variant in the `dispatch_windowed/5 — UTC midnight straddle`
    # describe.
    #
    # Microsecond precision is mandatory, not stylistic — see the note at
    # `@pinned_sweep_now`. `Message.inserted_at` is `:utc_datetime_usec` and
    # Ecto raises `ArgumentError: expects microsecond precision` on a
    # second-precision sigil.
    @pinned_oversize_now ~U[2026-03-05 12:00:00.000000Z]

    # Task 01a0a12e moved this case from the transcripts corpus to messages:
    # transcripts are excluded from the digest by default, so an oversized
    # transcript no longer produces a window at all (the sibling case below
    # pins that). The skip-line / `item_skipped` / forward-progress coverage
    # is corpus-agnostic and is kept here on one oversized chat message.
    test "names the skipped row instead of cutting it, and steps past it", %{
      agent: agent
    } do
      # Budget = 500 tokens (2000 bytes). One chat message with a
      # 10_000-byte body alone forces the slicer past the halving floor
      # once the messages cursor is bounded at ~2h. The 30-day default
      # lookback would distribute the bytes too thinly per day to hit
      # oversize — pre-stamping the cursor at 2h ago tightens the slice
      # range so the halve-until-min-sub-window branch fires.
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("board-room")
      participant = insert_user_participant(space.id, "Ada")

      now = @pinned_oversize_now
      two_hours_ago = DateTime.add(now, -7_200, :second)
      posted_at = DateTime.add(now, -1_200, :second)

      # Pre-stamp the messages cursor so the slicer only walks
      # `[two_hours_ago, now)`. Under the default 30-day lookback the
      # per-day byte estimate would fall below budget and skip oversize.
      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "messages", nil, two_hours_ago)

      # Park the corpora this case does not seed AT the pinned instant so
      # their slice ranges are zero-width. Required once the clock is pinned
      # into the past: `Platform.Org.Seeds` writes nil-workspace pages at real
      # wall-clock time and `Historian.sum_corpus_bytes/3` has no upper bound,
      # so the pages corpus would otherwise report bytes > 0 while the per-day
      # query over the pinned sweep range finds none.
      Enum.each(~w(pages journal transcripts), fn corpus ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, now)
      end)

      # 10_000 bytes against a 2_000-byte cap: this single row cannot fit
      # the window budget no matter how the span is sliced.
      insert_message!(space.id, participant.id, %{
        content: String.duplicate("z ", 5_000),
        inserted_at: posted_at
      })

      test_pid = self()
      handler_id = "historian-item-skipped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :item_skipped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:item_skipped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      assert n >= 1

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      oversized =
        Enum.find(messages, fn m ->
          get_in(m.metadata, ["cursor", "namespace"]) == "messages" and
            m.metadata["oversize"] == true
        end)

      assert oversized,
             "expected a messages-corpus message with oversize: true, got: #{inspect(Enum.map(messages, & &1.metadata))}"

      # The row is NAMED, not cut at a byte offset mid-grapheme.
      assert oversized.content =~ "_(skipped —"
      refute oversized.content =~ "_No activity in this window._"
      assert String.valid?(oversized.content)
      assert oversized.metadata["truncated"] == true
      assert oversized.metadata["item_count"] == 1
      assert oversized.metadata["included_count"] == 0

      # The skip is a queryable audit signal, not a silent advance.
      assert_received {:item_skipped, %{bytes: bytes}, %{corpus: "messages"} = meta}
      assert bytes >= 10_000
      assert is_binary(meta.message_id)

      # FORWARD PROGRESS: the sweep steps past the unfittable row rather
      # than stalling on it forever. Under a "retry with a smaller span"
      # fix this assertion is what livelocks.
      cursor = messages_cursor()

      assert DateTime.compare(cursor.last_processed_at, posted_at) == :gt

      # ...and not one instant further than it needed to. The old
      # unconditional `advance_cursor(…, window.window_end)` would land at
      # or after the window end, which is `now`-ish.
      assert DateTime.compare(cursor.last_processed_at, now) == :lt
    end

    # Task 01a0a12e: the SAME oversized row as a transcript is not eligible
    # for the digest by default, so it yields no transcripts-corpus window,
    # no oversize message and no `item_skipped` — it is excluded, not
    # skipped. The size is irrelevant: a small transcript is excluded too
    # (transcript_digest_exclusion_test.exs).
    test "an oversized transcript is excluded, not skipped: no window, no item_skipped", %{
      agent: agent
    } do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("board-room-tx")

      now = @pinned_oversize_now
      two_hours_ago = DateTime.add(now, -7_200, :second)
      completed_at = DateTime.add(now, -1_200, :second)

      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "transcripts", nil, two_hours_ago)

      Enum.each(~w(pages journal messages), fn corpus ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, now)
      end)

      transcript =
        insert_transcript!(%{
          space_id: space.id,
          status: "complete",
          started_at: two_hours_ago,
          completed_at: completed_at,
          summary: String.duplicate("z ", 5_000),
          segments: []
        })

      # POSITIVE CONTROL: the row is eligible apart from the exclusion.
      assert [%{id: id}] =
               Platform.Meetings.list_transcripts_since(two_hours_ago,
                 window_end: now,
                 meeting_transcripts: :included
               )

      assert id == transcript.id

      # ...and the byte signal reads it as 0.
      assert {_, 0} = Historian.pending_windows_input(@org_workspace).transcripts

      test_pid = self()
      handler_id = "historian-item-skipped-tx-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :item_skipped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:item_skipped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      messages =
        case Chat.get_space_by_slug("system-#{agent.slug}") do
          nil -> []
          system_space -> system_space_messages(system_space)
        end

      refute Enum.any?(messages, fn m ->
               get_in(m.metadata, ["cursor", "namespace"]) == "transcripts" and
                 m.metadata["oversize"] == true
             end),
             "expected no transcripts-corpus oversize message, got: " <>
               inspect(Enum.map(messages, & &1.metadata))

      refute Enum.any?(messages, &(&1.content =~ "_(skipped —"))
      refute_received {:item_skipped, _, %{corpus: "transcripts"}}
    end

    test "a window that fits reaches window_end and emits no truncation event" do
      # The control for the two tests around it. Without it, `truncated?`
      # could be hardwired true and the cursor could be hardwired to hold
      # short, and every truncation assertion in this file would still pass.
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("fits")
      participant = insert_user_participant(space.id, "Ada")

      now = @pinned_oversize_now
      at = DateTime.add(now, -1_800, :second)

      Enum.each(~w(pages journal transcripts), fn corpus ->
        {:ok, _} =
          Historian.advance_cursor(
            @org_workspace,
            corpus,
            nil,
            DateTime.add(now, 3_600, :second)
          )
      end)

      {:ok, _} =
        Historian.advance_cursor(
          @org_workspace,
          "messages",
          nil,
          DateTime.add(now, -3_600, :second)
        )

      insert_message!(space.id, participant.id, %{
        content: String.duplicate("f", 500),
        inserted_at: at
      })

      test_pid = self()
      handler_id = "historian-fits-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :historian, :window_dispatched],
          [:platform, :historian, :window_truncated]
        ],
        fn [_, _, event], measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "fits"},
                 @org_workspace,
                 now: now
               )

      assert n >= 1

      # POSITIVE CONTROL FIRST: the window really was dispatched, and it
      # really did carry the whole corpus.
      assert_received {:window_dispatched, measurements, %{corpus: :messages} = meta}
      assert meta.truncated == false
      assert meta.oversize_empty == false
      assert measurements.item_count == 1
      assert measurements.included_count == 1

      # Paired absence — meaningful only because the control above passed.
      refute_received {:window_truncated, _, _}

      cursor = messages_cursor()
      assert DateTime.compare(cursor.last_processed_at, at) == :gt
      assert DateTime.compare(cursor.last_processed_at, now) != :lt
    end

    test "holds the messages cursor at the digested watermark and defers the rest", %{
      agent: agent
    } do
      # 200-token budget → an 800-byte cap → exactly 4 of the 200-byte rows
      # fit per dispatched window. The rest must be WITHHELD, not dropped.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("watermark")
      participant = insert_user_participant(space.id, "Ada")

      # PINNED (task 019fa633 stage 4). This case's cursor assertions below
      # are single-bucket arithmetic: they hold only when the seeded hour
      # lands inside ONE UTC calendar day. Measured, not argued — the same
      # fixture swept at 00:10–00:34:59 UTC fans into two day buckets and
      # detonates the two assertions at the "THE INVARIANT" comment. The
      # measured band and its two failure modes are tabulated above the
      # straddle variant in the `dispatch_windowed/5 — UTC midnight straddle`
      # describe.
      now = @pinned_oversize_now
      span_start = DateTime.add(now, -3_600, :second)

      # Park every other corpus in the future so only `messages` contributes
      # windows and the cursor assertions below are unambiguous.
      Enum.each(~w(pages journal transcripts), fn corpus ->
        {:ok, _} =
          Historian.advance_cursor(
            @org_workspace,
            corpus,
            nil,
            DateTime.add(now, 3_600, :second)
          )
      end)

      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, span_start)

      # Ten rows of IDENTICAL size at DISTINCT timestamps. Distinct
      # timestamps are the load-bearing part of this fixture: if every row
      # shared an instant the watermark would equal the window end and a
      # mutation swapping one for the other could not be seen.
      seeded =
        Enum.map(1..10, fn i ->
          content = String.pad_leading("#{i}", 3, "0") <> String.duplicate("x", 197)
          at = DateTime.add(span_start, i * 300, :second)
          insert_message!(space.id, participant.id, %{content: content, inserted_at: at})
          {content, at}
        end)

      timestamps = Enum.map(seeded, &elem(&1, 1))
      tags = Enum.map(1..10, &String.pad_leading("#{&1}", 3, "0"))

      test_pid = self()
      handler_id = "historian-watermark-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :historian, :window_dispatched],
          [:platform, :historian, :window_truncated]
        ],
        fn [_, _, event], measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: dispatched_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "pass-1"},
                 @org_workspace,
                 now: now
               )

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")

      pass_1_bodies = messages_corpus_bodies(system_space)

      # POSITIVE CONTROL FIRST — both would pass vacuously on `[]`.
      assert dispatched_1 >= 1
      refute Enum.empty?(pass_1_bodies)

      pass_1_text = Enum.join(pass_1_bodies, "\n")
      assert pass_1_text =~ "001"
      assert pass_1_text =~ "_(partial — "

      # Paired absence: meaningful only because the control above passed.
      # Ten 200-byte rows cannot fit an 800-byte cap however the hour is
      # sliced, so at least the last two are always withheld.
      withheld_in_pass_1 = Enum.reject(tags, &String.contains?(pass_1_text, &1))
      refute Enum.empty?(withheld_in_pass_1)

      # The audit trail must be able to say what happened WITHOUT re-reading
      # the corpus: `HistorianAudit.classify/1` branches on these flags.
      assert_received {:window_dispatched, _m, %{corpus: :messages, truncated: true} = dispatched}
      assert dispatched.oversize_empty == false

      assert_received {:window_truncated, truncated_m, %{corpus: "messages"}}
      assert truncated_m.included_count > 0
      assert truncated_m.withheld_count > 0
      assert truncated_m.item_count == truncated_m.included_count + truncated_m.withheld_count

      cursor_1 = messages_cursor()

      # THE INVARIANT. Reverting the cursor call to
      # `advance_cursor(workspace_id, corpus_string, nil, window.window_end)`
      # detonates both of these: `window_end` is `now`-ish, which is after
      # every seeded row and is never one microsecond past one of them.
      assert DateTime.compare(cursor_1.last_processed_at, List.last(timestamps)) == :lt

      assert cursor_1.last_processed_at in Enum.map(
               timestamps,
               &DateTime.add(&1, 1, :microsecond)
             ),
             "expected the cursor to land one microsecond past a digested row, got " <>
               inspect(cursor_1.last_processed_at)

      # Deferred, not lost: keep sweeping until the corpus drains, then
      # assert the UNION of every dispatched body carries all ten rows.
      # Every follow-up pass sweeps to the SAME pinned instant. Leaving these
      # on /4 would sweep to real wall-clock, silently widening the range to
      # months and changing the geometry the drain is supposed to exercise.
      Enum.each(2..6, fn pass ->
        HistorianDispatcher.dispatch_windowed(
          "historian",
          "historian.threshold",
          %{trigger: "pass-#{pass}"},
          @org_workspace,
          now: now
        )
      end)

      all_text = system_space |> messages_corpus_bodies() |> Enum.join("\n")

      missing = Enum.reject(tags, &String.contains?(all_text, &1))

      assert missing == [],
             "rows never digested across six passes: #{inspect(missing)}"

      cursor_final = messages_cursor()

      assert DateTime.compare(cursor_final.last_processed_at, List.last(timestamps)) == :gt,
             "expected the cursor to reach past the newest row once everything drained"

      # ...and never past the sweep's own end. This upper bound is what makes
      # threading `now:` into the follow-up passes above load-bearing. Measured
      # during stage 4: with only the lower bound, reverting those passes to
      # `/4` — sweeping to real wall-clock instead of the pinned instant — was
      # UNDETECTED, because a months-wide sweep drains the corpus just as
      # happily. The cursor overshooting the sweep end is the observable that
      # separates the two.
      assert DateTime.compare(cursor_final.last_processed_at, now) != :gt,
             "expected the cursor to stop at or before the pinned sweep end #{now}, got " <>
               inspect(cursor_final.last_processed_at)
    end
  end

  # ── Token-budget guard on rendered body ─────────────────────────────────

  describe "dispatch_windowed/4 — post-render body guard" do
    test "rejects an oversize rendered body without persisting a chat_messages row",
         %{agent: agent} do
      # Force a template whose static content alone blows past
      # `budget_tokens + 10_000` — no matter what digest slot value is
      # substituted, the render produces an oversized body. The
      # dispatcher's guard rejects with `{:oversize_body, tokens}` and
      # never calls `Chat.post_message/1`.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      # cap = 200 + 10_000 = 10_200 tokens → 40_800 bytes.
      # Bloat by 60_000 chars = 15_000 tokens body chrome alone.
      bloat = String.duplicate("x", 60_000)

      # `historian.threshold` is seeded by the T6 migration so we UPDATE
      # rather than create — matches the `force_update_*` migration
      # pattern the repo uses for the same slug.
      case PromptTemplates.get_template_by_slug("historian.threshold") do
        nil ->
          {:ok, _} =
            PromptTemplates.create_template(%{
              slug: "historian.threshold",
              name: "Historian Threshold (test bloat)",
              content: bloat <> "\n\n{{activity_digest}}\n\n{{trigger}}"
            })

        template ->
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: bloat <> "\n\n{{activity_digest}}\n\n{{trigger}}"
            })
      end

      chat_space = insert_channel_space("some-space")
      chat_participant = insert_user_participant(chat_space.id, "Sender")

      now = DateTime.utc_now()

      Enum.each(1..2, fn d ->
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("z", 1_200),
          inserted_at: DateTime.add(now, -d * 86_400, :second)
        })
      end)

      before_count = system_space_message_count(agent)

      assert {:error, {:oversize_body, tokens}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert tokens > HistorianDispatcher.window_budget_tokens() + 10_000

      after_count = system_space_message_count(agent)

      assert after_count == before_count,
             "guard must not persist a chat_messages row on reject"
    end
  end

  # ── Concentrated-density integration ────────────────────────────────────

  describe "dispatch_windowed/4 — concentrated-density integration" do
    # A pinned mid-day sweep instant, threaded through `dispatch_windowed/5`
    # (task 019fa633 stage 1). Mid-day so the seeded hour cannot straddle
    # UTC midnight: the cases below are written around a tight 1h range that
    # equals the halving floor, and a straddle silently fans it into two
    # calendar-day buckets and changes the geometry under test.
    #
    # Microsecond precision is mandatory, not stylistic — see the note at
    # `@pinned_sweep_now`. `Message.inserted_at` is `:utc_datetime_usec`
    # and Ecto raises `ArgumentError: expects microsecond precision` on a
    # second-precision sigil.
    @pinned_density_now ~U[2026-03-05 12:00:00.000000Z]

    # (a) End-to-end: 120KB summary concentrated inside a tight 1h window.
    # Pre-stamp the cursor at 1h ago so the corpus slice range is exactly
    # 1h — matches @min_sub_window_seconds so the halving-floor triggers
    # the oversize path AND the per-day byte histogram cleanly attributes
    # the 120KB to the seeded row's UTC date. Verifies the day_bytes
    # telemetry field is stamped onto the emitted window and the oversize
    # truncation marker is prepended to the dispatched message body.
    #
    # WHICH DAY the assertion names is load-bearing (task 019fa633). The
    # emitted `meta.day_span` is built from `window.window_start`
    # (historian_dispatcher.ex:840-842), and for a per-day bucket that is
    # UTC midnight of the bucket's date — the date the row's own corpus
    # clock falls on, per `Historian.pending_bytes_per_day/4`. For the
    # messages corpus that clock is `inserted_at`, which the fixture
    # sets to `thirty_min_ago`. So the anchor is `thirty_min_ago`'s date:
    # anchoring on `now`'s date or on `one_hour_ago`'s date each leaves a
    # 30-minute band per day where the filter looks for a date the event
    # never carries.
    #
    # Task 01a0a12e moved this case from a 120KB transcript to a 120KB chat
    # message: transcripts are excluded from the digest by default, so a
    # transcript can no longer drive the oversize path. A same-size
    # transcript is seeded alongside and must contribute nothing.
    test "(a) 120KB message, tight-range oversize path stamps day_bytes on the seeded day",
         %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("concentrated-message")
      participant = insert_user_participant(space.id, "Voice")
      transcript_space = insert_channel_space("concentrated-transcript")

      now = @pinned_density_now
      one_hour_ago = DateTime.add(now, -3_600, :second)
      thirty_min_ago = DateTime.add(now, -1_800, :second)

      # Pre-stamp the messages AND transcripts cursors at 1h ago so the
      # slice range is tightly [1h_ago, now) = 3600s span — the halving
      # floor. The transcripts cursor is live so its exclusion is observed,
      # not parked away.
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, one_hour_ago)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "transcripts", nil, one_hour_ago)

      # Park every other corpus AT the pinned instant so its slice range is
      # zero-width. Required, not cosmetic: `Platform.Org.Seeds` inserts
      # nil-workspace pages at real wall-clock time and
      # `Historian.sum_corpus_bytes/3` has no upper time bound, so under a
      # pinned past `now` the pages corpus would report bytes > 0 while the
      # per-day query over the sweep range finds none — a spurious empty
      # window that perturbs the `dispatched` count.
      Enum.each(~w(pages journal), fn corpus ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, now)
      end)

      # 120KB body — exceeds the 2000-byte budget many times over.
      # 120_000 / 4 = 30_000 tokens; budget = 500 tokens.
      insert_message!(space.id, participant.id, %{
        content: String.duplicate("x", 120_000),
        inserted_at: thirty_min_ago
      })

      transcript =
        insert_transcript!(%{
          space_id: transcript_space.id,
          status: "complete",
          started_at: one_hour_ago,
          completed_at: thirty_min_ago,
          summary: String.duplicate("x", 120_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, thirty_min_ago)

      test_pid = self()
      handler_id = "historian-dispatch-concentrated-a-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :window_dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:window_dispatched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      assert n >= 1

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      oversized =
        Enum.find(messages, fn m ->
          get_in(m.metadata, ["cursor", "namespace"]) == "messages" and
            m.metadata["oversize"] == true
        end)

      assert oversized,
             "expected an oversize messages-corpus message, got: " <>
               inspect(Enum.map(messages, & &1.metadata))

      # The 120KB body exceeds the 2_000-byte cap on its own, so it is
      # named and stepped past rather than cut at a byte offset.
      assert oversized.content =~ "_(skipped —"
      assert String.valid?(oversized.content)

      # Task 01a0a12e: the same-size transcript produced no window.
      refute Enum.any?(messages, &(get_in(&1.metadata, ["cursor", "namespace"]) == "transcripts"))

      # Drain telemetry events and locate the messages-corpus event on
      # the seeded row's day whose day_bytes matches the seeded body.
      # `octet_length` of the body is 120_000, so day_bytes >= 120_000.
      #
      # ONE binding for the day, used by the filter AND by the failure
      # message. That is the structural half of the fix: with two bindings
      # the message could — and did — name a date the filter never looked
      # for.
      events = drain_window_dispatched_events()
      expected_day = DateTime.to_date(thirty_min_ago)

      messages_events_on_day =
        Enum.filter(events, fn {_m, meta} ->
          meta.corpus == :messages and
            String.starts_with?(meta.day_span, Date.to_iso8601(expected_day))
        end)

      assert Enum.any?(messages_events_on_day, fn {m, _meta} ->
               is_map_key(m, :day_bytes) and m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "expected a messages telemetry event on #{expected_day} with day_bytes ≈ 120_000, got: " <>
               inspect(messages_events_on_day)

      refute Enum.any?(events, fn {_m, meta} -> meta.corpus == :transcripts end),
             "expected no transcripts-corpus window events, got: " <> inspect(events)
    end

    # (b) Cross-corpus independence: seed one messages row + one
    # journal row, both 30min ago inside a pre-stamped 1h cursor
    # window. Assert one dispatch per corpus, each with its own cursor
    # namespace and day_bytes attribution — no commingling of byte sums
    # across corpora.
    #
    # Task 01a0a12e: the second corpus was `transcripts`, which is now
    # excluded from the digest by default. The independence pair moves to
    # messages + journal; an equally large transcript is still seeded and
    # must dispatch nothing.
    test "(b) messages + journal dispatch independently with per-corpus day_bytes",
         %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      chat_space = insert_channel_space("crosstalk")
      chat_participant = insert_user_participant(chat_space.id, "Voice")
      transcript_space = insert_channel_space("crosstalk-transcripts")

      now = @pinned_density_now
      one_hour_ago = DateTime.add(now, -3_600, :second)
      thirty_min_ago = DateTime.add(now, -1_800, :second)

      # Pre-stamp the cursors 1h ago so the messages + journal (+ excluded
      # transcripts) slice ranges match at exactly the halving floor. This is what makes the
      # two independent single-window emissions land on one day, one per
      # corpus. The clock is pinned mid-day for that reason: this case
      # carries no date-valued filter (it groups on `meta.corpus` alone, so
      # it is NOT a second instance of the day-anchor defect), but its
      # "exactly one window per corpus at the halving floor" shape does
      # change silently when the seeded hour straddles UTC midnight.
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, one_hour_ago)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "journal", nil, one_hour_ago)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "transcripts", nil, one_hour_ago)

      # Park the corpus this case does not seed at the pinned instant —
      # same zero-width reasoning as case (a).
      {:ok, _} = Historian.advance_cursor(@org_workspace, "pages", nil, now)

      # 100KB message body → 25k tokens > 500 budget → per-day fanout →
      # halve until 1h floor → oversize. Same story for transcripts.
      message =
        insert_message!(chat_space.id, chat_participant.id, %{
          content: String.duplicate("m", 100_000),
          inserted_at: thirty_min_ago
        })

      # `insert_message!` forces `inserted_at` via put_change; verify by
      # re-reading (defence-in-depth for the timestamps callback).
      _ = message

      # 100KB org journal entry on the same instant.
      journal = insert_journal!(nil, String.duplicate("j", 100_000))

      {1, _} =
        Repo.update_all(
          from(e in MemoryEntry, where: e.id == ^journal.id),
          set: [inserted_at: thirty_min_ago]
        )

      transcript =
        insert_transcript!(%{
          space_id: transcript_space.id,
          status: "complete",
          started_at: one_hour_ago,
          completed_at: thirty_min_ago,
          summary: String.duplicate("t", 100_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, thirty_min_ago)

      test_pid = self()
      handler_id = "historian-dispatch-concentrated-b-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :window_dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:window_dispatched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      assert n >= 2, "expected at least one message per non-excluded corpus, got #{n}"

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      messages = system_space_messages(system_space)

      by_corpus = Enum.group_by(messages, &get_in(&1.metadata, ["cursor", "namespace"]))

      assert Map.has_key?(by_corpus, "messages"),
             "expected a messages-corpus dispatched message"

      assert Map.has_key?(by_corpus, "journal"),
             "expected a journal-corpus dispatched message"

      # Task 01a0a12e: the equally large transcript dispatches nothing.
      refute Map.has_key?(by_corpus, "transcripts"),
             "expected NO transcripts-corpus dispatched message"

      # Telemetry: each corpus must carry its OWN day_bytes value —
      # never the sum of both corpora. Both land on the seeded day.
      events = drain_window_dispatched_events()

      messages_evts = for {m, meta} <- events, meta.corpus == :messages, do: m.day_bytes
      journal_evts = for {m, meta} <- events, meta.corpus == :journal, do: m.day_bytes
      transcripts_evts = for {m, meta} <- events, meta.corpus == :transcripts, do: m.day_bytes

      assert Enum.any?(messages_evts, &(&1 >= 100_000 and &1 <= 110_000)),
             "expected a messages telemetry event with day_bytes ≈ 100_000, got: " <>
               inspect(messages_evts)

      assert Enum.any?(journal_evts, &(&1 >= 100_000 and &1 <= 110_000)),
             "expected a journal telemetry event with day_bytes ≈ 100_000, got: " <>
               inspect(journal_evts)

      assert transcripts_evts == [],
             "expected no transcripts telemetry events, got: " <> inspect(transcripts_evts)

      # Cross-corpus independence: no telemetry event should attribute the
      # sum of both corpora's bytes (200_000+) to a single window.
      refute Enum.any?(events, fn {m, _meta} -> m.day_bytes >= 200_000 end),
             "day_bytes commingling detected — events: #{inspect(events)}"
    end

    # Task 01a0a12e: seeded on the messages corpus (was transcripts, now
    # excluded from the digest by default). The historian's own dispatched
    # instructions land in a `kind: "system"` space, which the messages
    # eligibility seam excludes, so they cannot feed back into sweep 2.
    #
    # (c) Cap-resume: seed 25 distinct days of messages, cap at 20
    # windows per pass. First sweep drains 20; second sweep picks up the
    # remaining 5 with the per-day histogram recomputed against the
    # advanced cursor.
    test "(c) 25-day backlog: sweep-1 dispatches 20, sweep-2 dispatches remaining 5" do
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("cap-resume")
      participant = insert_user_participant(space.id, "Voice")
      now = DateTime.utc_now()

      # Pre-stamp the other cursors 1h in the future so ONLY the messages
      # corpus contributes pending windows across the two sweeps.
      future = DateTime.add(now, 3_600, :second)

      Enum.each(~w(pages journal transcripts), fn c ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, c, nil, future)
      end)

      # Seed 25 messages, one per day, at `now - offset * 24h`. Every
      # timestamp is <= now (so the range-end filter in
      # `pending_bytes_per_day` includes each row). Days are 24h apart,
      # so each row's `DateTime.to_date/1` lands on a distinct UTC
      # calendar day (except at the microsecond edge of midnight —
      # not a concern for a test bounded well within a single second).
      messages_per_day =
        Enum.map(0..24, fn offset ->
          ts = DateTime.add(now, -offset * 86_400, :second)

          row =
            insert_message!(space.id, participant.id, %{
              # 100KB body → 25k tokens per day, under 30k budget.
              content: String.duplicate("c", 100_000),
              inserted_at: ts
            })

          {ts, row}
        end)

      # Nil cursor precondition: no messages cursor row yet.
      # Task 019f5e7d: advance_cursor coerces sentinel → nil, so the org-scope
      # cursor lives at `workspace_id IS NULL`.
      refute Repo.one(
               from(c in HistorianCursor,
                 where: is_nil(c.workspace_id) and c.corpus == "messages"
               )
             )

      # First sweep — cap-hit at 20 windows.
      assert {:ok, %{dispatched: dispatched_1, remaining: remaining_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold-sweep-1"},
                 @org_workspace
               )

      assert dispatched_1 == 20
      assert remaining_1 >= 5

      cursor_after_1 = messages_cursor()

      assert %DateTime{} = cursor_after_1.last_processed_at

      # The 20th window (oldest-first) covers the day 5 days ago — its
      # window_end is midnight of the day 4 days ago. Cursor should be
      # at-or-past that boundary. We seeded messages up through today,
      # so at least 5 days of pending content remain.
      #
      # `messages_per_day` is ordered `offset = 0..24` — index 0 is
      # today, index 24 is the oldest (24d ago). The cursor should now
      # sit past the oldest but strictly before today.
      oldest_seeded = messages_per_day |> List.last() |> elem(0)
      newest_seeded = messages_per_day |> List.first() |> elem(0)

      assert DateTime.compare(cursor_after_1.last_processed_at, oldest_seeded) == :gt,
             "expected cursor to advance past the oldest seeded message, got " <>
               inspect(cursor_after_1.last_processed_at)

      assert DateTime.compare(cursor_after_1.last_processed_at, newest_seeded) == :lt,
             "expected cursor to still be behind today's message, got " <>
               inspect(cursor_after_1.last_processed_at)

      # Second sweep — drains the remaining 5. `pending_bytes_per_day`
      # recomputes over the [cursor, now) range and returns per-day
      # buckets only for un-drained days — no re-dispatch of first 20.
      assert {:ok, %{dispatched: dispatched_2, remaining: remaining_2}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold-sweep-2"},
                 @org_workspace
               )

      # Combined dispatch across the two sweeps should cover the seeded
      # non-empty days without duplicates. The exact split can shift by
      # ±1 depending on day-boundary clipping at the `now` edge, but the
      # invariants hold: sweep-2 dispatches > 0, no infinite loop, and
      # sweep-1 + sweep-2 == 25 total windows.
      assert dispatched_2 >= 1
      assert dispatched_2 <= 5
      assert remaining_2 == 0

      assert dispatched_1 + dispatched_2 == 25,
             "expected sweep-1 (#{dispatched_1}) + sweep-2 (#{dispatched_2}) == 25 total, " <>
               "got #{dispatched_1 + dispatched_2}"
    end
  end

  # ── UTC-midnight straddle (task 019fa633 stage 3) ───────────────────────

  describe "dispatch_windowed/5 — UTC midnight straddle" do
    # The deterministic regression check for the day-attribution defect that
    # took down CI run 30317846340. Both cases pin `now` through the stage-1
    # `:now` option, so the UTC boundary is exercised on EVERY invocation at
    # every hour of the day — not only when CI happens to run near midnight.
    # Neither can be satisfied by "CI is green now".
    #
    # WHICH CLOCK DECIDES THE DAY. The four corpora do not share one:
    # pages key on `updated_at`, journal and messages on `inserted_at`, and
    # transcripts on `completed_at` — `Historian.per_day_bytes_query/3`
    # groups transcripts on `date_trunc('day', t.completed_at)`
    # (historian.ex:552-563), `sum_corpus_bytes/3` filters on `completed_at`
    # (:443-451), and `Meetings.list_transcripts_since/2` bounds on it
    # (meetings.ex:1848). `updated_at` never enters the transcripts path.
    # These fixtures therefore seed `completed_at` to place the row on a
    # calendar day, and call `force_transcript_updated_at!/2` only so the
    # autogenerated `updated_at` cannot contradict it in a future reading.
    #
    # Task 01a0a12e: transcripts are excluded from the digest by default,
    # so CASES 1 and 2 now place the 120KB row on the messages corpus
    # (clock `inserted_at`) — the day-attribution logic under test lives in
    # the slicer and is corpus-agnostic. Each case still seeds the
    # transcript as it was and asserts it produced no event at all. The
    # transcripts `completed_at` clock is pinned at the seam instead
    # (historian_test.exs, via `meeting_transcripts: :included`).
    #
    # Microsecond precision is mandatory, not stylistic — see the note at
    # `@pinned_sweep_now`. Ecto raises `ArgumentError: expects microsecond
    # precision` on a second-precision sigil for `:utc_datetime_usec`.
    #
    # Each case's sweep range is [cursor, now) = exactly 1h straddling
    # midnight, which `enumerate_day_ranges/2` clips into two calendar-day
    # buckets. Only the bucket holding the row has bytes; the other is
    # dropped at the `day_bytes == 0` clause (historian_dispatcher.ex:527).
    # 120_000 bytes / 4 = 30_000 tokens against a 500-token budget forces
    # the per-day fanout, and each bucket is under the 3600s halving floor,
    # so the surviving bucket is emitted directly.

    # CASE 1 — the row lands AFTER midnight. Reproduces the geometry of CI
    # run 30317846340, which failed at 00:44 UTC.
    @straddle_after_now ~U[2026-03-06 00:45:00.000000Z]
    @straddle_after_cursor ~U[2026-03-05 23:45:00.000000Z]
    @straddle_after_completed_at ~U[2026-03-06 00:15:00.000000Z]

    test "row lands after midnight — bytes attribute to the row's day, never the sweep-start day" do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("straddle-after-midnight")

      now = @straddle_after_now

      # Sweep range [23:45 Mar-5, 00:45 Mar-6) — one hour across the
      # boundary, so both sides of midnight are live candidates.
      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "messages", nil, @straddle_after_cursor)

      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "transcripts", nil, @straddle_after_cursor)

      # Park the other three corpora AT the pinned instant so their slice
      # ranges are zero-width — same reasoning as the concentrated-density
      # cases: `Platform.Org.Seeds` writes nil-workspace pages at real
      # wall-clock time and `sum_corpus_bytes/3` has no upper bound.
      Enum.each(~w(pages journal), fn corpus ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, now)
      end)

      participant = insert_user_participant(space.id, "Voice")

      insert_message!(space.id, participant.id, %{
        content: String.duplicate("x", 120_000),
        inserted_at: @straddle_after_completed_at
      })

      transcript =
        insert_transcript!(%{
          space_id: space.id,
          status: "complete",
          started_at: @straddle_after_cursor,
          # `completed_at` is the transcripts corpus clock — this is the
          # field that decides which calendar-day bucket the bytes land in.
          completed_at: @straddle_after_completed_at,
          summary: String.duplicate("x", 120_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, @straddle_after_completed_at)

      attach_window_dispatched_handler!("historian-straddle-after")

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      assert n >= 1

      events = drain_window_dispatched_events()

      # ONE binding per day, used by both halves of the pair and by both
      # failure messages (task 019fa633 stage 2's structural fix: a filter
      # and a message that cannot name different dates).
      attributed_day = DateTime.to_date(@straddle_after_completed_at)
      other_side_of_midnight = DateTime.to_date(@straddle_after_cursor)

      # POSITIVE and NEGATIVE are a pair over the SAME drained list. The
      # negative alone is vacuous — it passes against a dispatcher that
      # emits nothing at all.
      assert Enum.any?(events, fn {m, meta} ->
               meta.corpus == :messages and
                 String.starts_with?(meta.day_span, Date.to_iso8601(attributed_day)) and
                 m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "expected a messages event on #{attributed_day} with day_bytes ≈ 120_000, got: " <>
               inspect(events)

      # Task 01a0a12e: the same-size transcript is excluded — no event at all.
      refute Enum.any?(events, fn {_m, meta} -> meta.corpus == :transcripts end),
             "expected no transcripts events, got: " <> inspect(events)

      refute Enum.any?(events, fn {m, meta} ->
               meta.corpus == :messages and
                 String.starts_with?(meta.day_span, Date.to_iso8601(other_side_of_midnight)) and
                 m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "the 120KB was attributed to #{other_side_of_midnight}, the far side of the " <>
               "midnight boundary — events: " <> inspect(events)
    end

    # CASE 2 — the mirror: the row lands BEFORE midnight while the sweep
    # ends after it.
    #
    # THIS CASE EXISTS TO BREAK A SPECIFIC FUTURE EDIT (task 019fa633).
    # The originating ticket prescribed anchoring the day filter on
    # `DateTime.to_date(now)`. Under this fixture `now` is 2026-03-06 while
    # the bytes are attributed to 2026-03-05, so that anchor makes this
    # case fail in CI rather than shipping. The ticket's fix does not
    # remove the bug — it moves the failure band from 00:30–01:00 UTC to
    # 00:00–00:30 UTC. Do not "simplify" the anchor back to `now`.
    @straddle_before_now ~U[2026-03-06 00:15:00.000000Z]
    @straddle_before_cursor ~U[2026-03-05 23:15:00.000000Z]
    @straddle_before_completed_at ~U[2026-03-05 23:45:00.000000Z]

    test "row lands before midnight — bytes attribute to the row's day, never the sweep-end day" do
      Application.put_env(:platform, :historian_window_token_budget, 500)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("straddle-before-midnight")

      now = @straddle_before_now

      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "messages", nil, @straddle_before_cursor)

      {:ok, _} =
        Historian.advance_cursor(@org_workspace, "transcripts", nil, @straddle_before_cursor)

      Enum.each(~w(pages journal), fn corpus ->
        {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, now)
      end)

      participant = insert_user_participant(space.id, "Voice")

      insert_message!(space.id, participant.id, %{
        content: String.duplicate("y", 120_000),
        inserted_at: @straddle_before_completed_at
      })

      transcript =
        insert_transcript!(%{
          space_id: space.id,
          status: "complete",
          started_at: @straddle_before_cursor,
          completed_at: @straddle_before_completed_at,
          summary: String.duplicate("y", 120_000),
          segments: []
        })

      force_transcript_updated_at!(transcript, @straddle_before_completed_at)

      attach_window_dispatched_handler!("historian-straddle-before")

      assert {:ok, %{dispatched: n, remaining: 0}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: now
               )

      assert n >= 1

      events = drain_window_dispatched_events()

      attributed_day = DateTime.to_date(@straddle_before_completed_at)
      # The day `now` falls on — i.e. exactly the ticket's `today_utc`.
      other_side_of_midnight = DateTime.to_date(@straddle_before_now)

      assert Enum.any?(events, fn {m, meta} ->
               meta.corpus == :messages and
                 String.starts_with?(meta.day_span, Date.to_iso8601(attributed_day)) and
                 m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "expected a messages event on #{attributed_day} with day_bytes ≈ 120_000, got: " <>
               inspect(events)

      # Task 01a0a12e: the same-size transcript is excluded — no event at all.
      refute Enum.any?(events, fn {_m, meta} -> meta.corpus == :transcripts end),
             "expected no transcripts events, got: " <> inspect(events)

      refute Enum.any?(events, fn {m, meta} ->
               meta.corpus == :messages and
                 String.starts_with?(meta.day_span, Date.to_iso8601(other_side_of_midnight)) and
                 m.day_bytes >= 120_000 and m.day_bytes <= 130_000
             end),
             "the 120KB was attributed to #{other_side_of_midnight} — that is the ticket's " <>
               "`today_utc` anchor, which this case exists to reject. Events: " <> inspect(events)
    end

    # CASE 3 — the straddle variant of the watermark case (task 019fa633
    # stage 4). Same fixture as "holds the messages cursor at the digested
    # watermark and defers the rest": ten 200-byte rows at `span_start +
    # i*300s` across the hour `[now-3600, now)`, under a 200-token (800-byte)
    # cap that fits exactly four rows per dispatched window.
    #
    # MEASURED FAILURE BAND FOR THAT CASE, not predicted. The plan predicted
    # roughly T ∈ (600, 1800] — 00:10–00:30 — from arithmetic. Running the
    # fixture through `dispatch_windowed/5` at pinned instants across a fixed
    # date measured this instead (T = seconds past UTC midnight):
    #
    #   00:00 PASS  00:05 PASS  00:09 PASS   ← all ten rows pre-midnight,
    #                                          one effective bucket
    #   00:10 FAIL  00:15 FAIL  00:20 FAIL   ← cursor lands AT `now`
    #   00:25 FAIL  00:26 FAIL  00:29 FAIL
    #   00:30 FAIL  00:31 FAIL  00:33 FAIL   ← cursor arithmetic HOLDS,
    #                                          rows are lost instead
    #   00:35 PASS  00:40 PASS  00:44 PASS  00:45 PASS  00:50 PASS
    #   01:00 PASS  12:00 PASS
    #
    # So the band is T ∈ [600, 2100) — 00:10:00 through 00:34:59 — 25 minutes
    # wide, closed at the lower edge, and it carries TWO distinct failure
    # modes rather than the one the plan predicted:
    #
    #   T ∈ [600, 1800): the post-midnight bucket holds ≤ 4 rows, fits the cap
    #     whole, and its `advance_cursor` lands on `window_end` — which is
    #     `now`, not one microsecond past a digested row. Both cursor
    #     assertions detonate (`… == :lt` and `… in Enum.map(timestamps, …)`).
    #   T ∈ [1800, 2100): the post-midnight bucket is itself truncated, so the
    #     cursor DOES hold at a digested watermark and both cursor assertions
    #     pass. The deferred-not-lost assertion is what fails.
    #
    # THE SECOND MODE IS A PRODUCTION DEFECT, NOT A TEST DEFECT, and it is
    # live across the whole band. `do_dispatch_windowed/7` walks every sliced
    # window in one pass and each window advances the corpus cursor
    # independently (historian_dispatcher.ex:704-730 → :904). When an EARLIER
    # calendar-day bucket truncates — holding the cursor at its digested
    # watermark, `cursor_target/2` clause 2 — and a LATER bucket in the same
    # pass is then dispatched, the later bucket's advance moves the cursor
    # past the earlier bucket's withheld rows. Those rows are never re-sliced:
    # measured at 00:20, tags 005/006/007 are absent from the union of all
    # dispatched bodies across six passes. This is not specific to midnight —
    # any corpus that fans into ≥2 day buckets in one pass with a truncation
    # in a non-final bucket loses the withheld rows. It needs its own task; it
    # is out of scope for a stage whose remit is pinning fixtures, and
    # "fixing" it here would change `dispatched` counts across this file.
    #
    # This case therefore pins 00:40 — a genuine straddle (three rows before
    # midnight, seven after, two buckets dispatched in pass 1) that sits above
    # the defect's band, and asserts what the plan asked for: the split really
    # happened, rows really were deferred, the union across six passes carries
    # all ten, and the final cursor is past the newest row. It deliberately
    # does NOT assert the single-bucket cursor arithmetic, which is
    # legitimately different once the hour is split.
    @watermark_straddle_now ~U[2026-03-06 00:40:00.000000Z]

    test "watermark straddle: a split hour defers rows across passes without losing them", %{
      agent: agent
    } do
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("watermark-straddle")
      participant = insert_user_participant(space.id, "Ada")

      now = @watermark_straddle_now
      span_start = DateTime.add(now, -3_600, :second)

      Enum.each(~w(pages journal transcripts), fn corpus ->
        {:ok, _} =
          Historian.advance_cursor(
            @org_workspace,
            corpus,
            nil,
            DateTime.add(now, 3_600, :second)
          )
      end)

      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, span_start)

      seeded =
        Enum.map(1..10, fn i ->
          content = String.pad_leading("#{i}", 3, "0") <> String.duplicate("x", 197)
          at = DateTime.add(span_start, i * 300, :second)
          insert_message!(space.id, participant.id, %{content: content, inserted_at: at})
          {content, at}
        end)

      timestamps = Enum.map(seeded, &elem(&1, 1))
      tags = Enum.map(1..10, &String.pad_leading("#{&1}", 3, "0"))

      assert {:ok, %{dispatched: dispatched_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "straddle-pass-1"},
                 @org_workspace,
                 now: now
               )

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")

      # POSITIVE CONTROL — the hour really was split. Without this the
      # deferred-not-lost assertion below would pass just as happily against a
      # single-bucket geometry, i.e. against no straddle at all.
      window_days =
        system_space
        |> system_space_messages()
        |> Enum.filter(&(get_in(&1.metadata, ["cursor", "namespace"]) == "messages"))
        |> Enum.map(&(&1.metadata["cursor"]["window_start"] |> String.slice(0, 10)))
        |> Enum.uniq()
        |> Enum.sort()

      assert window_days == ["2026-03-05", "2026-03-06"],
             "expected the hour to fan into one window per side of midnight, got #{inspect(window_days)}"

      assert dispatched_1 >= 2

      # ...and rows really were withheld, so "nothing was lost" below is a
      # statement about deferral rather than about a corpus that fit whole.
      pass_1_text = system_space |> messages_corpus_bodies() |> Enum.join("\n")
      withheld_in_pass_1 = Enum.reject(tags, &String.contains?(pass_1_text, &1))

      refute Enum.empty?(withheld_in_pass_1)
      assert pass_1_text =~ "_(partial — "

      # THE INVARIANT THAT MUST SURVIVE A SPLIT. Not the single-bucket cursor
      # arithmetic — "the cursor stopped mid-bucket" is an artifact of the
      # bucket count. Deferred-not-lost is the contract.
      Enum.each(2..6, fn pass ->
        HistorianDispatcher.dispatch_windowed(
          "historian",
          "historian.threshold",
          %{trigger: "straddle-pass-#{pass}"},
          @org_workspace,
          now: now
        )
      end)

      all_text = system_space |> messages_corpus_bodies() |> Enum.join("\n")
      missing = Enum.reject(tags, &String.contains?(all_text, &1))

      assert missing == [],
             "rows never digested across six passes of a midnight-straddling hour: " <>
               inspect(missing)

      cursor_final = messages_cursor()

      assert DateTime.compare(cursor_final.last_processed_at, List.last(timestamps)) == :gt,
             "expected the cursor to reach past the newest row once the split hour drained, got " <>
               inspect(cursor_final.last_processed_at)

      # Same upper bound as the single-bucket watermark case, and for the same
      # measured reason: it is the only assertion here that can see the
      # follow-up passes losing their pinned clock.
      assert DateTime.compare(cursor_final.last_processed_at, now) != :gt,
             "expected the cursor to stop at or before the pinned sweep end #{now}, got " <>
               inspect(cursor_final.last_processed_at)
    end
  end

  # ── Injected sweep clock (task 019fa633 stage 1) ────────────────────────

  describe "dispatch_windowed/5 — injected sweep clock" do
    # `slice_windows/2` has taken a `:now` option since it was written, so
    # the day-boundary enumeration stays deterministic under test. The
    # integration entry point was the one layer that dropped it, calling
    # `slice_windows(workspace_id)` bare — which is why every windowed
    # integration test here swept to real wall-clock time and picked up a
    # UTC-midnight dependency.
    #
    # These two cases are a COUNTERFACTUAL PAIR and must be read together.
    # (i) alone would pass unchanged against an implementation that
    # accepted `:now` and threw it away, because it only shows the sweep
    # ended at some instant. (ii) is what makes (i) load-bearing: the same
    # fixture, dispatched through the 4-arity clause, must end its sweep
    # strictly AFTER the pinned instant. The two differ in exactly one
    # thing — whether the clock was injected — so the option demonstrably
    # reaches `slice_windows/2` and decides the window geometry.
    #
    # (ii) doubles as the production-path pin: `SystemEventScheduler`
    # calls `dispatch_windowed/4`, and this asserts that clause still
    # sweeps to real `DateTime.utc_now/0`.
    # Microsecond precision is mandatory, not stylistic: `Message.
    # inserted_at` is `:utc_datetime_usec`, and Ecto raises
    # `ArgumentError: expects microsecond precision` when a second-precision
    # sigil is put on the changeset. Any later stage pinning a clock in
    # this file must write `.000000` too.
    @pinned_sweep_now ~U[2026-03-05 12:00:00.000000Z]

    setup do
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)
      seed_pinned_clock_fixture(@pinned_sweep_now)
      :ok
    end

    test "(i) /5 ends the sweep at the injected instant, not at wall-clock", %{agent: agent} do
      assert {:ok, %{dispatched: dispatched}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace,
                 now: @pinned_sweep_now
               )

      cursor = messages_window_cursor!(agent)

      window_start = parse_cursor_instant!(cursor["window_start"])
      window_end = parse_cursor_instant!(cursor["window_end"])

      # The sweep END is the injected instant, exactly. This is the value
      # `slice_windows/2` was handed; nothing downstream re-derives it.
      assert DateTime.compare(window_end, @pinned_sweep_now) == :eq,
             "expected the sweep to end at the injected #{@pinned_sweep_now}, got #{window_end}"

      # ...and the START is the parked cursor, so the emitted geometry is
      # the tight 1h range the fixture set up rather than a months-wide
      # range clipped by wall-clock.
      assert DateTime.compare(
               window_start,
               DateTime.add(@pinned_sweep_now, -3_600, :second)
             ) == :eq

      assert DateTime.diff(window_end, window_start, :second) == 3_600

      # Every other corpus has its cursor parked AT the pinned instant, so
      # under the injected clock its slice range is zero-width and emits
      # nothing. One dispatch, and it is the seeded messages window. (Drop
      # the injection and the pages corpus — seeded at real wall-clock by
      # `Platform.Org.Seeds` — wakes up and this becomes 2.)
      assert dispatched == 1
    end

    test "(ii) /4 still sweeps to real wall-clock for its existing callers", %{agent: agent} do
      before_dispatch = DateTime.utc_now()

      assert {:ok, %{dispatched: dispatched}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      assert dispatched >= 1

      cursor = messages_window_cursor!(agent)

      window_start = parse_cursor_instant!(cursor["window_start"])
      window_end = parse_cursor_instant!(cursor["window_end"])

      # Same parked cursor, so the sweep START is identical to (i) — the
      # ONLY thing that differs between the two cases is the sweep end.
      assert DateTime.compare(
               window_start,
               DateTime.add(@pinned_sweep_now, -3_600, :second)
             ) == :eq

      # The sweep end is real wall-clock time, months past the pinned
      # instant (i) produced. Without the injection actually landing,
      # (i) would have produced this value too.
      assert DateTime.compare(window_end, @pinned_sweep_now) == :gt
      assert DateTime.compare(window_end, before_dispatch) != :lt

      assert DateTime.diff(window_end, window_start, :second) > 3_600
    end
  end

  # ── HOTFIX: org-scope sentinel advances pages+journal cursors ───────────

  describe "dispatch_windowed/4 — org-scope sentinel advances pages+journal cursors" do
    # Integration coverage for the sum_corpus_bytes bug (task 019f5cf4).
    # Before the stage-1 fix, sentinel dispatches for pages+journal returned
    # 0 bytes → 0 windows → the pages/journal cursors on the sentinel
    # workspace never advanced. These tests seed nil-workspace rows and
    # verify the sentinel-scoped sweep actually walks them.
    #
    # `Platform.Org.Seeds` inserts three default nil-workspace pages
    # (`org/page/identity.md` + friends) at test-env boot totalling ~600
    # bytes. We prune them per-test so the day-bytes telemetry assertions
    # can pin exact per-day counts. The sandbox rolls back the delete so
    # other test files see the original seed set.
    setup do
      Repo.delete_all(from(p in WikiPage, where: is_nil(p.workspace_id)))
      Repo.delete_all(from(j in MemoryEntry, where: is_nil(j.workspace_id)))
      :ok
    end

    test "happy path: nil-workspace pages+journal rows dispatch and cursors advance" do
      # Budget = 30_000 tokens. Each row = 100KB (25_000 tokens < budget so a
      # single day fits in one window); total per corpus = 300KB (75_000
      # tokens > budget) so the slicer fans out to per-day windows rather
      # than emitting a single collapsed range. That per-day fanout is the
      # only path that populates the `day_bytes` telemetry field and is
      # what the sentinel bug (task 019f5cf4) prevented from ever firing.
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      now = DateTime.utc_now()
      day1 = DateTime.to_date(DateTime.add(now, -3 * 86_400, :second))
      day2 = DateTime.to_date(DateTime.add(now, -2 * 86_400, :second))
      day3 = DateTime.to_date(DateTime.add(now, -1 * 86_400, :second))

      # 3 pages × 100KB + 3 journal entries × 100KB = ~600KB spanning 3
      # days, all on the org-scope workspace (workspace_id: nil).
      insert_page_at!(nil, "org-page-1.md", String.duplicate("p", 100_000), day1)
      insert_page_at!(nil, "org-page-2.md", String.duplicate("p", 100_000), day2)
      insert_page_at!(nil, "org-page-3.md", String.duplicate("p", 100_000), day3)

      insert_journal_at!(nil, String.duplicate("j", 100_000), day1)
      insert_journal_at!(nil, String.duplicate("j", 100_000), day2)
      insert_journal_at!(nil, String.duplicate("j", 100_000), day3)

      # Precondition: no cursor rows for pages/journal at org-scope yet.
      # Task 019f5e7d: advance_cursor coerces sentinel → nil, so the org-scope
      # cursor lives at `workspace_id IS NULL`.
      for corpus <- ~w(pages journal) do
        refute Repo.one(
                 from(c in HistorianCursor,
                   where: is_nil(c.workspace_id) and c.corpus == ^corpus
                 )
               )
      end

      assert {:ok, %{dispatched: dispatched, remaining: _}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      # 3 days × 2 corpora = 6 pages+journal windows (each fits in budget).
      # Pre-fix, this branch dispatched 0 windows — the bug's observable
      # symptom on prod. Assert >= 6 to allow for messages/transcripts
      # windows on unrelated corpus data (shouldn't happen with a clean
      # sandbox, but the invariant we care about is the pages+journal
      # dispatch happening at all).
      assert dispatched >= 6,
             "expected >= 6 windows (3 days × pages + journal), got #{dispatched}"

      # Cursor rows for pages+journal at the org-scope workspace now exist
      # (workspace_id IS NULL post-019f5e7d) with last_processed_at populated
      # past the newest seeded day. `advance_cursor` stamps `window.window_end`,
      # which is the end of the calendar day (start-of-next-day at UTC midnight).
      newest_day_end = DateTime.new!(Date.add(day3, 1), ~T[00:00:00], "Etc/UTC")

      for corpus <- ~w(pages journal) do
        cursor =
          Repo.one!(
            from(c in HistorianCursor,
              where: is_nil(c.workspace_id) and c.corpus == ^corpus
            )
          )

        assert %DateTime{} = cursor.last_processed_at

        assert DateTime.compare(cursor.last_processed_at, newest_day_end) != :lt,
               "expected #{corpus} cursor to reach or pass day3 end (#{newest_day_end}), " <>
                 "got #{cursor.last_processed_at}"
      end
    end

    test "mixed rows: sentinel dispatch's day_bytes reflects only nil-workspace rows" do
      Application.put_env(:platform, :historian_window_token_budget, 30_000)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      now = DateTime.utc_now()
      day1 = DateTime.to_date(DateTime.add(now, -3 * 86_400, :second))
      day2 = DateTime.to_date(DateTime.add(now, -2 * 86_400, :second))
      day3 = DateTime.to_date(DateTime.add(now, -1 * 86_400, :second))

      other_ws = Ecto.UUID.generate()

      # Nil-workspace rows — 100KB per row across 3 days (300KB/corpus, above
      # the 30_000-token budget so the per-day fanout branch fires and
      # populates day_bytes on each emitted window).
      insert_page_at!(nil, "nil-page-1.md", String.duplicate("p", 100_000), day1)
      insert_page_at!(nil, "nil-page-2.md", String.duplicate("p", 100_000), day2)
      insert_page_at!(nil, "nil-page-3.md", String.duplicate("p", 100_000), day3)

      insert_journal_at!(nil, String.duplicate("j", 100_000), day1)
      insert_journal_at!(nil, String.duplicate("j", 100_000), day2)
      insert_journal_at!(nil, String.duplicate("j", 100_000), day3)

      # Distinct-workspace rows on the SAME days — 200KB per row so a broken
      # filter that folded these into the sentinel bucket would produce
      # day_bytes = 300_000 (100k nil + 200k other_ws) instead of the
      # correct 100_000.
      insert_page_at!(other_ws, "ws-page-1.md", String.duplicate("w", 200_000), day1)
      insert_page_at!(other_ws, "ws-page-2.md", String.duplicate("w", 200_000), day2)
      insert_journal_at!(other_ws, String.duplicate("v", 200_000), day1)
      insert_journal_at!(other_ws, String.duplicate("v", 200_000), day2)

      test_pid = self()
      handler_id = "historian-sentinel-mixed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :window_dispatched],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:window_dispatched, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: _}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "threshold"},
                 @org_workspace
               )

      events = drain_window_dispatched_events()

      # Every pages/journal window emitted for the sentinel workspace must
      # carry day_bytes == 30_000 (the nil rows) — never 80_000, which is
      # what a broken sentinel filter would produce by folding other_ws
      # rows into the sentinel sweep.
      sentinel_wiki_events =
        Enum.filter(events, fn {_measurements, meta} ->
          meta[:corpus] in [:pages, :journal] and meta[:workspace_id] == @org_workspace
        end)

      assert length(sentinel_wiki_events) >= 6,
             "expected >= 6 pages/journal windows for the sentinel (3 days × 2 corpora), " <>
               "got #{length(sentinel_wiki_events)}: " <> inspect(sentinel_wiki_events)

      Enum.each(sentinel_wiki_events, fn {measurements, meta} ->
        assert measurements.day_bytes == 100_000,
               "expected #{meta[:corpus]} window on #{meta[:day_span]} to carry day_bytes=100_000 " <>
                 "(nil-workspace only), got #{measurements.day_bytes}"
      end)
    end

    test "messages+transcripts regression guard: byte sums identical across sentinel/nil/random" do
      # Defence-in-depth against a future refactor that widens the sentinel
      # coercion beyond pages+journal. Stage 1's historian_test covers the
      # underlying byte-sum path; here we re-assert it from the dispatcher
      # test context on top of a live nil-workspace pages+journal seed.

      now = DateTime.utc_now()
      day1 = DateTime.to_date(DateTime.add(now, -3 * 86_400, :second))
      day2 = DateTime.to_date(DateTime.add(now, -2 * 86_400, :second))
      day3 = DateTime.to_date(DateTime.add(now, -1 * 86_400, :second))

      # Nil-workspace pages+journal so the DB state matches what a real
      # sentinel sweep would encounter alongside messages/transcripts.
      insert_page_at!(nil, "org-page-1.md", String.duplicate("p", 30_000), day1)
      insert_journal_at!(nil, String.duplicate("j", 30_000), day1)

      # Messages: 5 × 200 bytes on day2 = 1_000 bytes total.
      chat_space = insert_channel_space("regression-msg")
      chat_participant = insert_user_participant(chat_space.id, "Voice")

      for _ <- 1..5 do
        insert_message_at!(chat_space.id, chat_participant.id, String.duplicate("m", 200), day2)
      end

      # Transcripts: 1 × 300-byte summary on day3.
      transcript_space = insert_channel_space("regression-tx")

      insert_transcript_at!(
        %{
          space_id: transcript_space.id,
          summary: String.duplicate("s", 300),
          segments: []
        },
        day3
      )

      start_at = DateTime.new!(day1, ~T[00:00:00], "Etc/UTC")
      end_at = DateTime.new!(Date.add(day3, 1), ~T[00:00:00], "Etc/UTC")

      random_ws = Ecto.UUID.generate()

      for corpus <- ~w(messages transcripts) do
        sentinel = Historian.pending_bytes_per_day(corpus, start_at, end_at, @org_workspace)
        nil_result = Historian.pending_bytes_per_day(corpus, start_at, end_at, nil)
        random = Historian.pending_bytes_per_day(corpus, start_at, end_at, random_ws)

        assert sentinel == nil_result,
               "#{corpus}: sentinel #{inspect(sentinel)} != nil #{inspect(nil_result)}"

        assert sentinel == random,
               "#{corpus}: sentinel #{inspect(sentinel)} != random #{inspect(random)}"

        case corpus do
          "messages" ->
            refute sentinel == %{},
                   "#{corpus}: expected non-empty per-day sums after seeding"

          # Task 01a0a12e: transcripts are excluded from the digest by
          # default, so the per-day sums are empty for every workspace
          # variant. The sentinel/nil/random agreement above is therefore
          # vacuous for this corpus until a caller can opt in.
          "transcripts" ->
            assert sentinel == %{},
                   "transcripts: expected empty per-day sums (excluded by default), got #{inspect(sentinel)}"
        end
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp insert_historian_agent do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "historian-#{System.unique_integer([:positive])}",
        name: "Historian",
        status: "active"
      })
      |> Repo.insert!()

    # Pin the historian role — mirrors production wiring so
    # `agent_for_event/1` resolves to this agent.
    case Roles.assign_role("historian", agent.id) do
      {:ok, _} -> :ok
      {:error, _} -> Roles.unassign_role("historian") && Roles.assign_role("historian", agent.id)
    end

    agent
  end

  defp insert_channel_space(name_suffix) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{name_suffix}",
        slug: "channel-#{System.unique_integer([:positive])}",
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

  defp insert_message!(space_id, participant_id, %{content: content} = attrs) do
    participant = Repo.get!(Chat.Participant, participant_id)

    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: participant.display_name || "Test"
    }

    params = Map.drop(attrs, [:inserted_at])
    changeset = Message.changeset(%Message{}, Map.merge(defaults, params))

    changeset =
      case Map.get(attrs, :inserted_at) do
        nil -> changeset
        ts -> Ecto.Changeset.put_change(changeset, :inserted_at, ts)
      end

    Repo.insert!(changeset)
  end

  defp insert_transcript!(attrs) do
    defaults = %{room_id: "room-#{System.unique_integer([:positive])}", status: "complete"}

    %Platform.Meetings.Transcript{}
    |> Platform.Meetings.Transcript.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp system_space_messages(%Chat.Space{id: space_id}) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space_id and m.content_type == "text",
        order_by: [asc: m.inserted_at]
      )
    )
  end

  # Bodies of every instruction message dispatched for the `messages`
  # corpus, oldest first.
  defp messages_corpus_bodies(system_space) do
    system_space
    |> system_space_messages()
    |> Enum.filter(&(get_in(&1.metadata, ["cursor", "namespace"]) == "messages"))
    |> Enum.map(& &1.content)
  end

  defp messages_cursor do
    Repo.one!(
      from(c in HistorianCursor,
        where: is_nil(c.workspace_id) and c.corpus == "messages"
      )
    )
  end

  defp system_space_message_count(agent) do
    case Chat.get_space_by_slug("system-#{agent.slug}") do
      nil ->
        0

      %Chat.Space{id: id} ->
        Repo.aggregate(from(m in Message, where: m.space_id == ^id), :count)
    end
  end

  # Fixture for the injected-sweep-clock pair. Parks pages/journal/
  # transcripts cursors AT `pinned` so their slice range is zero-width
  # (`corpus_start_at/2` clamps a cursor >= now to now, and a non-`:lt`
  # range emits nothing), leaving `messages` as the only corpus that can
  # dispatch. The messages cursor is parked 1h before `pinned` and one
  # small row is seeded halfway through that hour, so the emitted window
  # geometry is a tight, fully determined `[pinned - 1h, pinned)`.
  #
  # Parking the quiet corpora is required, not cosmetic: `Platform.Org.
  # Seeds` inserts nil-workspace pages at real wall-clock time and
  # `Historian.sum_corpus_bytes/3` has no upper time bound, so a pinned
  # past sweep would otherwise see pages bytes > 0 and emit a window whose
  # per-day query finds nothing.
  defp seed_pinned_clock_fixture(%DateTime{} = pinned) do
    Enum.each(~w(pages journal transcripts), fn corpus ->
      {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, pinned)
    end)

    one_hour_before = DateTime.add(pinned, -3_600, :second)
    {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, one_hour_before)

    space = insert_channel_space("pinned-sweep-clock")
    participant = insert_user_participant(space.id, "Pinned Voice")

    insert_message!(space.id, participant.id, %{
      content: String.duplicate("t", 400),
      inserted_at: DateTime.add(pinned, -1_800, :second)
    })

    :ok
  end

  # The `cursor` metadata map off the single dispatched `messages`-corpus
  # instruction in the historian's system space.
  defp messages_window_cursor!(%Agent{} = agent) do
    system_space = Chat.get_space_by_slug("system-#{agent.slug}")
    assert %Chat.Space{} = system_space

    cursors =
      system_space
      |> system_space_messages()
      |> Enum.map(& &1.metadata["cursor"])
      |> Enum.filter(&(is_map(&1) and &1["namespace"] == "messages"))

    assert [cursor] = cursors,
           "expected exactly one dispatched messages-corpus window, got: #{inspect(cursors)}"

    cursor
  end

  defp parse_cursor_instant!(iso8601) when is_binary(iso8601) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso8601)
    dt
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

  # `Transcript` autogenerates `updated_at` via `timestamps/1`. To simulate
  # a fully backdated row we push that timestamp back with a raw
  # `update_all`. Test-only escape hatch — production never sets
  # `updated_at` directly.
  #
  # CORRECTION (task 019fa633 stage 2, verified against the queries): the
  # transcripts corpus clock is `completed_at`, NOT `updated_at`, at every
  # layer — `Historian.per_day_bytes_query("transcripts", ...)` groups on
  # `date_trunc('day', t.completed_at)` (historian.ex:558-563),
  # `sum_corpus_bytes("transcripts", ...)` filters on `completed_at`
  # (:448-451), and `Meetings.list_transcripts_since/2` bounds on it
  # (meetings.ex:1848). So seeding `completed_at` is what decides the day
  # a transcript's bytes are attributed to; this helper only keeps
  # `updated_at` from contradicting it. Do not rely on this call to move a
  # row between calendar-day buckets — set `completed_at`.
  defp force_transcript_updated_at!(%Transcript{id: id}, %DateTime{} = ts) do
    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^id),
        set: [updated_at: ts]
      )

    :ok
  end

  # Attach a `[:platform, :historian, :window_dispatched]` handler that
  # forwards into the calling test's mailbox, detached on exit. The events
  # are read back with `drain_window_dispatched_events/1` — the single drain
  # helper in this file (task 019fa633 stage 3).
  defp attach_window_dispatched_handler!(prefix) do
    test_pid = self()
    handler_id = "#{prefix}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :historian, :window_dispatched],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:window_dispatched, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # Drain telemetry events sent by the per-test attached handler. Blocks
  # up to 100ms per event; returns the full list once the mailbox is
  # empty. Structured as `{measurements, metadata}` tuples.
  defp drain_window_dispatched_events(acc \\ []) do
    receive do
      {:window_dispatched, measurements, metadata} ->
        drain_window_dispatched_events([{measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # Sandbox.allow the AttentionRouter GenServer so any downstream chat
  # writes triggered by AgentResponder → attention scan can reach the
  # test's checked-out connection. Not currently used but kept as a
  # note in case the sync-mode dispatch grows a router hop.
  @doc false
  def _sandbox_allow_attention_router do
    router = Process.whereis(Platform.Chat.AttentionRouter)
    if router, do: Sandbox.allow(Repo, self(), router)
  end

  # Silence the unused-alias warning while keeping the alias handy for
  # future test scaffolding.
  @doc false
  def _touch_historian, do: Historian.pending_bytes(nil)

  # ── Day-forcing fixture helpers ─────────────────────────────────────────
  #
  # Copied verbatim from `historian_test.exs` (helpers section) so the
  # sentinel-dispatch integration tests can seed rows with a specific
  # calendar-day `inserted_at`/`updated_at`. Kept in this file (rather
  # than extracted to a Support module) per the task 019f5cf4 plan —
  # copy is fine for a hotfix; extraction is a follow-up.

  defp insert_page_at!(workspace_id, file_key, content, %Date{} = day) do
    {:ok, page} =
      %WikiPage{}
      |> WikiPage.changeset(%{
        workspace_id: workspace_id,
        file_key: "#{file_key}-#{System.unique_integer([:positive])}",
        content: content
      })
      |> Repo.insert()

    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(p in WikiPage, where: p.id == ^page.id),
        set: [updated_at: ts, inserted_at: ts]
      )

    page
  end

  defp insert_journal!(workspace_id, content) do
    %MemoryEntry{}
    |> MemoryEntry.changeset(%{
      workspace_id: workspace_id,
      content: content,
      date: Date.utc_today()
    })
    |> Repo.insert!()
  end

  defp insert_journal_at!(workspace_id, content, %Date{} = day) do
    row = insert_journal!(workspace_id, content)
    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(e in MemoryEntry, where: e.id == ^row.id),
        set: [inserted_at: ts]
      )

    row
  end

  defp insert_message_at!(space_id, participant_id, content, %Date{} = day) do
    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content,
        author_display_name: "Test"
      })
      |> Repo.insert()

    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: ts]
      )

    message
  end

  defp insert_transcript_at!(attrs, %Date{} = day) do
    defaults = %{
      room_id: "room-#{System.unique_integer([:positive])}",
      status: "complete"
    }

    {:ok, transcript} =
      %Transcript{}
      |> Transcript.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

    # `completed_at` is the transcripts corpus clock on BOTH the digest
    # accessor (`Meetings.list_transcripts_since/2`) and the Historian byte
    # signal (task 019fa1cc stage 2 unified them onto
    # `Meetings.digest_eligible_transcripts_query/1`). A `status: "complete"`
    # row with `completed_at: nil` is a row the digest can never render, so
    # stamping it here is what makes this fixture a transcript the Historian
    # would actually see rather than a byte-count-only phantom.
    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^transcript.id),
        set: [updated_at: ts, inserted_at: ts, completed_at: ts]
      )

    transcript
  end
end
