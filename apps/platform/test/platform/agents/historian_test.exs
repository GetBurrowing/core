defmodule Platform.Agents.HistorianTest do
  @moduledoc """
  Tests for `Platform.Agents.Historian` — the context module that tracks
  per-workspace, per-corpus progress for the Historian agent.

  Five test cases per T6 stage 2 plan:

    (i)   `pending_tokens/1` returns 0 on empty workspace.
    (ii)  `pending_tokens/1` sums across corpora (journal + messages).
    (iii) `pending_tokens/1` walks past the cursor — insert 10 rows,
          advance cursor past 7, assert 3 rows' bytes / 4.
    (iv)  `mark_run_started/1` is idempotent (no UNIQUE violation;
          `last_run_at` advances on each call).
    (v)   `advance_cursor/4` upserts — inserts if missing, updates if
          present, preserves other corpora's rows.
  """

  use Platform.DataCase, async: true

  alias Platform.Agents.Historian
  alias Platform.Agents.HistorianCursor
  alias Platform.Agents.HistorianDispatcher
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Org.WikiJournalEntry, as: MemoryEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks.Projects

  @org_scope_workspace_id Projects.org_scope_workspace_id()

  # Use a fresh workspace UUID per test so async cases don't collide.
  setup do
    {:ok, workspace_id: Ecto.UUID.generate()}
  end

  # ── (i) Empty workspace → 0 tokens ──────────────────────────────────────

  describe "pending_tokens/1 — empty workspace" do
    test "returns 0 when no corpora have content", %{workspace_id: workspace_id} do
      assert Historian.pending_tokens(workspace_id) == 0
      assert Historian.pending_bytes(workspace_id) == 0
    end
  end

  # ── (ii) Sums across corpora ────────────────────────────────────────────

  describe "pending_tokens/1 — sums across corpora" do
    test "journal entries contribute their content byte_size / 4", %{
      workspace_id: workspace_id
    } do
      # 80 bytes ASCII → 80 octets → 20 tokens.
      content = String.duplicate("a", 80)
      insert_journal!(workspace_id, content)

      assert Historian.pending_bytes(workspace_id) == 80
      assert Historian.pending_tokens(workspace_id) == 20
    end

    test "multiple corpora sum together", %{workspace_id: workspace_id} do
      # journal: 40 bytes
      insert_journal!(workspace_id, String.duplicate("j", 40))
      # journal: another 40 bytes — total 80 in this corpus
      insert_journal!(workspace_id, String.duplicate("k", 40))

      # 80 / 4 = 20 tokens from journal alone.
      assert Historian.pending_tokens(workspace_id) == 20
    end
  end

  # ── (iii) Walks past cursor ─────────────────────────────────────────────

  describe "pending_tokens/1 — walks past cursor" do
    test "advance cursor past N of 10 rows leaves 10-N rows pending", %{
      workspace_id: workspace_id
    } do
      # Insert 10 journal rows of 40 bytes each, spaced out in time so we
      # can advance the cursor between rows 7 and 8.
      base = DateTime.utc_now() |> DateTime.add(-3600, :second)

      rows =
        for i <- 1..10 do
          inserted_at = DateTime.add(base, i, :second)
          row = insert_journal!(workspace_id, String.duplicate("x", 40))
          force_inserted_at!(row, inserted_at)
          {i, inserted_at}
        end

      # All 10 pending → 400 bytes / 4 = 100 tokens.
      assert Historian.pending_tokens(workspace_id) == 100

      # Advance cursor to the timestamp of row 7. Rows 1–7 should be excluded,
      # rows 8, 9, 10 should remain.
      {_idx, row7_at} = Enum.at(rows, 6)

      {:ok, _} =
        Historian.advance_cursor(workspace_id, "journal", "row-7", row7_at)

      # 3 rows × 40 bytes = 120 bytes / 4 = 30 tokens.
      assert Historian.pending_bytes(workspace_id) == 120
      assert Historian.pending_tokens(workspace_id) == 30
    end
  end

  # ── (iv) mark_run_started idempotency ───────────────────────────────────

  describe "mark_run_started/1 — idempotency" do
    test "calling twice in <1s advances last_run_at without UNIQUE violation", %{
      workspace_id: workspace_id
    } do
      :ok = Historian.mark_run_started(workspace_id)
      first = Historian.last_run_at(workspace_id)
      assert %DateTime{} = first

      # Sleep a measurable µs to guarantee monotonic advance on the second call.
      Process.sleep(5)

      :ok = Historian.mark_run_started(workspace_id)
      second = Historian.last_run_at(workspace_id)
      assert %DateTime{} = second

      assert DateTime.compare(second, first) == :gt,
             "expected #{inspect(second)} > #{inspect(first)} on second mark_run_started"

      # Exactly one cursor row per registered corpus exists for this
      # workspace. Derived from `Historian.corpora/0` rather than a literal:
      # a corpus added to `@corpora` but rejected by
      # `HistorianCursor.@valid_corpora` writes no row and `mark_run_started/1`
      # still returns `:ok`, so a hardcoded count would need editing in the
      # same commit that introduced the silent failure.
      count =
        Repo.aggregate(
          from(c in HistorianCursor, where: c.workspace_id == ^workspace_id),
          :count
        )

      assert count == length(Historian.corpora())
    end
  end

  # ── (v) advance_cursor upserts ──────────────────────────────────────────

  describe "advance_cursor/4 — upsert semantics" do
    test "inserts when cursor row is missing", %{workspace_id: workspace_id} do
      now = DateTime.utc_now()

      assert {:ok, cursor} =
               Historian.advance_cursor(workspace_id, "journal", "row-1", now)

      assert cursor.workspace_id == workspace_id
      assert cursor.corpus == "journal"
      assert cursor.last_processed_id == "row-1"
      assert DateTime.compare(cursor.last_processed_at, now) == :eq
    end

    test "updates when cursor row exists", %{workspace_id: workspace_id} do
      now1 = DateTime.utc_now()
      now2 = DateTime.add(now1, 60, :second)

      {:ok, _} =
        Historian.advance_cursor(workspace_id, "journal", "row-1", now1)

      {:ok, updated} =
        Historian.advance_cursor(workspace_id, "journal", "row-2", now2)

      assert updated.last_processed_id == "row-2"
      assert DateTime.compare(updated.last_processed_at, now2) == :eq

      # Still exactly one row for (workspace_id, "journal").
      count =
        Repo.aggregate(
          from(c in HistorianCursor,
            where: c.workspace_id == ^workspace_id and c.corpus == "journal"
          ),
          :count
        )

      assert count == 1
    end

    test "preserves other corpora's rows", %{workspace_id: workspace_id} do
      now = DateTime.utc_now()

      {:ok, _} =
        Historian.advance_cursor(workspace_id, "journal", "j-1", now)

      {:ok, _} =
        Historian.advance_cursor(workspace_id, "messages", "m-1", now)

      # Update only the journal cursor.
      {:ok, _} =
        Historian.advance_cursor(
          workspace_id,
          "journal",
          "j-2",
          DateTime.add(now, 60)
        )

      messages_cursor =
        Repo.one!(
          from(c in HistorianCursor,
            where: c.workspace_id == ^workspace_id and c.corpus == "messages"
          )
        )

      assert messages_cursor.last_processed_id == "m-1"
    end
  end

  # ── pending_bytes_per_day/3-4 — grouped byte sums ───────────────────────

  describe "pending_bytes_per_day/3-4 — grouped byte sums" do
    test "empty range returns %{}", %{workspace_id: workspace_id} do
      # Point the query at a range we know contains no rows.
      start_at = ~U[2001-01-01 00:00:00Z]
      end_at = ~U[2001-01-08 00:00:00Z]

      for corpus <- Historian.corpora() do
        assert Historian.pending_bytes_per_day(corpus, start_at, end_at, workspace_id) == %{}
        assert Historian.pending_bytes_per_day(corpus, start_at, end_at) == %{}
      end
    end

    test "journal: three rows on three different days each get their own bucket",
         %{workspace_id: workspace_id} do
      # 40 bytes per row → each row contributes 40 to its day bucket.
      day1 = ~D[2001-02-01]
      day2 = ~D[2001-02-05]
      day3 = ~D[2001-02-09]

      insert_journal_at!(workspace_id, String.duplicate("a", 40), day1)
      insert_journal_at!(workspace_id, String.duplicate("b", 40), day2)
      insert_journal_at!(workspace_id, String.duplicate("c", 40), day3)

      start_at = ~U[2001-02-01 00:00:00Z]
      end_at = ~U[2001-02-10 00:00:00Z]

      assert Historian.pending_bytes_per_day("journal", start_at, end_at, workspace_id) ==
               %{day1 => 40, day2 => 40, day3 => 40}
    end

    test "journal: two rows on the SAME day sum into one bucket",
         %{workspace_id: workspace_id} do
      day = ~D[2001-03-01]

      insert_journal_at!(workspace_id, String.duplicate("a", 30), day)
      insert_journal_at!(workspace_id, String.duplicate("b", 70), day)

      start_at = ~U[2001-03-01 00:00:00Z]
      end_at = ~U[2001-03-02 00:00:00Z]

      assert Historian.pending_bytes_per_day("journal", start_at, end_at, workspace_id) ==
               %{day => 100}
    end

    test "journal: boundary rows — inserted_at == start_at included, == end_at excluded",
         %{workspace_id: workspace_id} do
      start_day = ~D[2001-04-01]
      end_day = ~D[2001-04-03]

      start_at = ~U[2001-04-01 00:00:00Z]
      end_at = ~U[2001-04-03 00:00:00Z]

      # Row exactly at start_at — included.
      row_a = insert_journal!(workspace_id, String.duplicate("a", 25))
      force_inserted_at!(row_a, start_at)

      # Row exactly at end_at — excluded.
      row_b = insert_journal!(workspace_id, String.duplicate("b", 999))
      force_inserted_at!(row_b, end_at)

      # Row inside the range.
      row_c = insert_journal!(workspace_id, String.duplicate("c", 10))
      force_inserted_at!(row_c, DateTime.new!(~D[2001-04-02], ~T[12:00:00], "Etc/UTC"))

      result = Historian.pending_bytes_per_day("journal", start_at, end_at, workspace_id)

      assert Map.get(result, start_day) == 25
      assert Map.get(result, ~D[2001-04-02]) == 10
      refute Map.has_key?(result, end_day)
    end

    test "journal: rows outside [start_at, end_at) are omitted",
         %{workspace_id: workspace_id} do
      # Row before the range.
      before_row = insert_journal!(workspace_id, String.duplicate("b", 500))
      force_inserted_at!(before_row, ~U[2001-05-01 00:00:00Z])

      # Row inside the range.
      insert_journal_at!(workspace_id, String.duplicate("i", 60), ~D[2001-05-10])

      # Row after the range.
      after_row = insert_journal!(workspace_id, String.duplicate("a", 500))
      force_inserted_at!(after_row, ~U[2001-06-01 00:00:00Z])

      result =
        Historian.pending_bytes_per_day(
          "journal",
          ~U[2001-05-05 00:00:00Z],
          ~U[2001-05-15 00:00:00Z],
          workspace_id
        )

      assert result == %{~D[2001-05-10] => 60}
    end

    test "pages: grouped per updated_at day, workspace_id-scoped",
         %{workspace_id: workspace_id} do
      day = ~D[2001-07-04]
      other_day = ~D[2001-07-05]

      insert_page_at!(workspace_id, "page-a.md", String.duplicate("p", 100), day)
      insert_page_at!(workspace_id, "page-b.md", String.duplicate("q", 250), day)
      insert_page_at!(workspace_id, "page-c.md", String.duplicate("r", 40), other_day)

      # A different workspace's row on the same day must not commingle.
      other_workspace = Ecto.UUID.generate()
      insert_page_at!(other_workspace, "page-x.md", String.duplicate("z", 9_999), day)

      result =
        Historian.pending_bytes_per_day(
          "pages",
          ~U[2001-07-04 00:00:00Z],
          ~U[2001-07-06 00:00:00Z],
          workspace_id
        )

      assert result == %{day => 350, other_day => 40}
    end

    test "messages: grouped per inserted_at day (no workspace filter)",
         %{workspace_id: workspace_id} do
      # `messages` corpus does not filter on workspace_id — mirror
      # the sum_corpus_bytes("messages", ...) shape. Use a range so
      # far in the past that no other test's chat_messages inserts
      # land in it (sandbox rollback still isolates us, but we belt
      # + brace with a distant baseline).
      day = ~D[2001-08-10]

      space = insert_channel_space("hist-per-day")
      participant = insert_user_participant(space.id, "Old Voice")

      insert_message_at!(space.id, participant.id, String.duplicate("m", 200), day)
      insert_message_at!(space.id, participant.id, String.duplicate("n", 55), day)

      result =
        Historian.pending_bytes_per_day(
          "messages",
          ~U[2001-08-01 00:00:00Z],
          ~U[2001-08-31 00:00:00Z],
          workspace_id
        )

      assert result == %{day => 255}
    end

    # Task 01a0a12e: the transcripts corpus is excluded from the digest by
    # default at `Meetings.digest_eligible_transcripts_query/1`, and the
    # byte signal composes that seam, so every day sums to nothing.
    # `pending_bytes_per_day/4` takes no opts, so the summary+segments
    # arithmetic is unreachable while the corpus is excluded.
    test "transcripts: excluded by default — no per-day bytes for eligible rows",
         %{workspace_id: workspace_id} do
      day = ~D[2001-09-01]

      # Two transcripts on the same day, each with distinct summary +
      # segments. octet_length(segments::text) counts the JSON
      # serialization bytes; the assertion is on the shape (>= sum of
      # summary bytes, day-grouped) rather than an exact byte total
      # because JSONB serialization exact bytes vary with formatting.
      insert_transcript_at!(
        %{summary: String.duplicate("s", 100), segments: [%{text: "hi"}]},
        day
      )

      insert_transcript_at!(
        %{summary: String.duplicate("t", 150), segments: [%{text: "there"}]},
        day
      )

      # Row on a different day.
      insert_transcript_at!(
        %{summary: String.duplicate("u", 40), segments: []},
        ~D[2001-09-03]
      )

      result =
        Historian.pending_bytes_per_day(
          "transcripts",
          ~U[2001-09-01 00:00:00Z],
          ~U[2001-09-05 00:00:00Z],
          workspace_id
        )

      assert result == %{}

      # POSITIVE CONTROL: all three rows are eligible apart from the
      # exclusion — the seam admits them when opted in.
      included =
        Meetings.list_transcripts_since(~U[2001-09-01 00:00:00Z],
          window_end: ~U[2001-09-05 00:00:00Z],
          meeting_transcripts: :included
        )

      assert length(included) == 3
    end
  end

  # ── Digest-eligibility seam (task 019fa1cc stage 2) ──────────────────────
  #
  # The byte signal and the digest accessor must select the same rows. Before
  # this stage they each carried their own copy of the predicate and the copies
  # had drifted by five filters, which produced 86 oversize digest windows on
  # prod — 56 of them spurious, 55 of those dispatching the empty stub with an
  # eligible row count of exactly 0.

  describe "byte signal composes the digest-eligibility predicate" do
    test "messages: only rows the digest can render contribute bytes" do
      day = ~D[2001-11-11]
      start_at = ~U[2001-11-11 00:00:00Z]
      end_at = ~U[2001-11-12 00:00:00Z]

      live = insert_channel_space("seam-live")
      live_p = insert_user_participant(live.id, "Voice")

      # (1) 30 execution-kind messages — the exact shape that drove every
      # spurious oversize window measured on prod: a busy hour of agent
      # chatter that reads as a large day to the slicer and as an empty
      # window to the renderer.
      exec = insert_space_of_kind!("execution", "seam-exec")
      exec_p = insert_user_participant(exec.id, "Runner")

      for _ <- 1..30 do
        insert_message_with!(exec.id, exec_p.id, %{content: String.duplicate("x", 500)}, day)
      end

      # (2) 5 log_only rows in a live channel.
      for _ <- 1..5 do
        insert_message_with!(
          live.id,
          live_p.id,
          %{content: String.duplicate("l", 400), log_only: true},
          day
        )
      end

      # (3) 3 non-conversational content_type rows in a live channel.
      for _ <- 1..3 do
        insert_message_with!(
          live.id,
          live_p.id,
          %{content: String.duplicate("s", 300), content_type: "system"},
          day
        )
      end

      # (4) 2 rows in an archived channel.
      archived = insert_channel_space("seam-archived")
      archived_p = insert_user_participant(archived.id, "Ghost")

      for _ <- 1..2 do
        insert_message_with!(
          archived.id,
          archived_p.id,
          %{content: String.duplicate("v", 600)},
          day
        )
      end

      archive_space!(archived.id)

      # (5) 1 soft-deleted row in a live channel.
      insert_message_with!(
        live.id,
        live_p.id,
        %{content: String.duplicate("d", 700), deleted_at: DateTime.utc_now()},
        day
      )

      # (6) 2 live channel rows of known byte length — the only eligible rows.
      a = insert_message_with!(live.id, live_p.id, %{content: String.duplicate("a", 111)}, day)
      b = insert_message_with!(live.id, live_p.id, %{content: String.duplicate("b", 222)}, day)

      eligible_bytes = byte_size(a.content) + byte_size(b.content)

      # CONTROL ON THE FIXTURE, not on the code. Without this, "only 333
      # bytes counted" would pass just as well against a fixture that seeded
      # nothing to exclude. The pre-fix schemaless query is reproduced here
      # so the assertion below is a measured 50x gap, not a hope.
      raw_bytes = raw_message_bytes(start_at, end_at)
      assert raw_bytes > eligible_bytes * 10

      result = Historian.pending_bytes_per_day("messages", start_at, end_at, nil)

      # POSITIVE CONTROL before the exclusion assertion: the map is non-empty
      # and the day's value is > 0. A query returning 0 for everything would
      # otherwise satisfy every assertion that follows.
      assert map_size(result) == 1
      assert Map.fetch!(result, day) > 0

      assert Map.fetch!(result, day) == eligible_bytes

      # The unbounded `sum_corpus_bytes` path must agree with the per-day
      # path — both compose the same seam, so pin both.
      {_last_at, summed} = Historian.pending_windows_input(nil).messages
      assert summed == eligible_bytes

      # The byte signal must equal what the digest accessor actually returns.
      # This is the invariant itself, asserted against the renderer's own
      # accessor rather than a second copy of the filter list.
      rendered =
        start_at
        |> Chat.list_messages_since(window_end: end_at, scope: :internal)
        |> Enum.map(&byte_size(&1.content))
        |> Enum.sum()

      assert rendered == eligible_bytes

      # DELTA CONTROL: a third live channel row must raise the total by
      # exactly its own byte length.
      c = insert_message_with!(live.id, live_p.id, %{content: String.duplicate("c", 77)}, day)

      after_result = Historian.pending_bytes_per_day("messages", start_at, end_at, nil)
      assert Map.fetch!(after_result, day) == eligible_bytes + byte_size(c.content)
    end

    # Task 01a0a12e: transcripts are excluded by default, so the byte signal
    # is 0 for every row. The status and `completed_at` clock filters are
    # still pinned at the seam, through the renderer's accessor with
    # `meeting_transcripts: :included`; the byte-signal half of the clock
    # pin is unreachable while the corpus is excluded (the Historian byte
    # functions take no opts).
    test "transcripts: incomplete and never-completed rows contribute no bytes" do
      day = ~D[2001-12-12]
      start_at = ~U[2001-12-12 00:00:00Z]
      end_at = ~U[2001-12-13 00:00:00Z]
      ts = ~U[2001-12-12 12:00:00Z]

      # Eligible: status "complete" with a completed_at inside the span.
      eligible = insert_transcript_at!(%{summary: String.duplicate("e", 500), segments: []}, day)

      # Ineligible (1): still recording. `completed_at` stamped anyway so the
      # only thing keeping it out is the status filter.
      recording =
        insert_transcript_at!(%{summary: String.duplicate("r", 900), segments: []}, day)

      set_transcript_fields!(recording.id, status: "recording")

      # Ineligible (2): status "complete" but `completed_at` never stamped —
      # `updated_at` alone used to pull this into the byte signal while the
      # accessor could never render it.
      orphan = insert_transcript_at!(%{summary: String.duplicate("o", 900), segments: []}, day)
      set_transcript_fields!(orphan.id, completed_at: nil)

      # Ineligible (3): completed on an EARLIER day but edited inside this
      # span — segments accumulate after completion, so `completed_at <=
      # updated_at` always. This is the row that discriminates the corpus
      # clock: the accessor bounds on `completed_at` and will render it in
      # the earlier window, so a byte signal keyed on `updated_at` charges
      # its bytes to a window that renders nothing. Without this row the
      # fixture has `completed_at == updated_at` throughout and keying the
      # byte signal on `updated_at` survives every assertion below.
      late_edit =
        insert_transcript_at!(%{summary: String.duplicate("z", 900), segments: []}, day)

      set_transcript_fields!(late_edit.id, completed_at: ~U[2001-12-10 12:00:00Z])

      # CONTROL ON THE FIXTURE: the ineligible rows really are in the span.
      assert raw_transcript_summary_bytes(start_at, end_at) >= 500 + 900 + 900 + 900

      # ...and the late-edited one is genuinely eligible, just in an earlier
      # window — proving it was excluded here by the clock, not by the
      # eligibility filters.
      earlier =
        Historian.pending_bytes_per_day(
          "transcripts",
          ~U[2001-12-10 00:00:00Z],
          ~U[2001-12-11 00:00:00Z],
          nil
        )

      assert earlier == %{}

      earlier_included =
        Meetings.list_transcripts_since(~U[2001-12-10 00:00:00Z],
          window_end: ~U[2001-12-11 00:00:00Z],
          meeting_transcripts: :included
        )

      assert Enum.map(earlier_included, & &1.id) == [late_edit.id]

      result = Historian.pending_bytes_per_day("transcripts", start_at, end_at, nil)
      assert result == %{}

      # The renderer's accessor agrees: nothing by default...
      assert Meetings.list_transcripts_since(start_at, window_end: end_at, scope: :internal) ==
               []

      # ...and, opted in, exactly the eligible row — the status and clock
      # filters are still in the seam.
      rendered =
        Meetings.list_transcripts_since(start_at,
          window_end: end_at,
          scope: :internal,
          meeting_transcripts: :included
        )

      assert length(rendered) == 1
      assert hd(rendered).id == eligible.id

      # The unbounded `sum_corpus_bytes` path walks the cursor rather than a
      # range, so its clock is pinned separately. Parked between the
      # late-edited row's `completed_at` (12-10) and its `updated_at` (12-12),
      # this cursor only excludes that row if the sum path reads
      # `completed_at` — which is what the accessor bounds on.
      {:ok, _} =
        Historian.advance_cursor(nil, "transcripts", nil, ~U[2001-12-11 00:00:00Z])

      {cursor_at, summed} = Historian.pending_windows_input(nil).transcripts
      assert DateTime.compare(cursor_at, ~U[2001-12-11 00:00:00Z]) == :eq
      assert summed == 0

      # DELTA CONTROL: completing the recording transcript inside the span
      # makes it eligible on the seam's other filters, and still adds no
      # bytes by default.
      set_transcript_fields!(recording.id, status: "complete", completed_at: ts)

      assert Historian.pending_bytes_per_day("transcripts", start_at, end_at, nil) == %{}

      assert length(
               Meetings.list_transcripts_since(start_at,
                 window_end: end_at,
                 meeting_transcripts: :included
               )
             ) == 2
    end
  end

  # ── pending_bytes_in_range/3-4 — measured sub-day spans (stage 3) ──────

  describe "pending_bytes_in_range/3-4 — ungrouped span sums" do
    test "messages: each sub-range is measured on its own rows, not the day's" do
      day = ~D[2001-10-10]
      day_start = ~U[2001-10-10 00:00:00Z]
      day_end = ~U[2001-10-11 00:00:00Z]

      live = insert_channel_space("range-live")
      live_p = insert_user_participant(live.id, "Voice")

      # Ineligible agent chatter parked in the QUIET hours — the exact shape
      # that drove the spurious oversize windows on prod. It is here so the
      # "quiet hours measure zero" assertions below are about eligibility and
      # bounds rather than about an empty table.
      exec = insert_space_of_kind!("execution", "range-exec")
      exec_p = insert_user_participant(exec.id, "Runner")

      for hour <- [1, 8, 15, 22] do
        insert_message_at_time!(
          exec.id,
          exec_p.id,
          String.duplicate("x", 5_000),
          DateTime.new!(day, Time.new!(hour, 0, 0), "Etc/UTC")
        )
      end

      # All the ELIGIBLE mass inside [04:00, 05:00), unevenly split between
      # the two halves of that hour. Uneven is load-bearing: with equal
      # halves a smear-vs-measure mutation is invisible.
      a =
        insert_message_at_time!(
          live.id,
          live_p.id,
          String.duplicate("a", 1_111),
          ~U[2001-10-10 04:10:00Z]
        )

      b =
        insert_message_at_time!(
          live.id,
          live_p.id,
          String.duplicate("b", 2_222),
          ~U[2001-10-10 04:40:00Z]
        )

      eligible = byte_size(a.content) + byte_size(b.content)
      refute byte_size(a.content) == byte_size(b.content)

      # POSITIVE CONTROL first: the whole day measures non-zero, and equals
      # exactly the eligible bytes.
      whole_day = Historian.pending_bytes_in_range("messages", day_start, day_end)
      assert whole_day > 0
      assert whole_day == eligible

      # FIXTURE CONTROL: the quiet hours are NOT empty of raw rows — the
      # pre-stage-2 byte query sees 20k+ bytes there.
      assert raw_message_bytes(day_start, ~U[2001-10-10 04:00:00Z]) >= 5_000

      # The busy hour owns all of it; the quiet hours own none of it.
      assert Historian.pending_bytes_in_range(
               "messages",
               ~U[2001-10-10 04:00:00Z],
               ~U[2001-10-10 05:00:00Z]
             ) == eligible

      assert Historian.pending_bytes_in_range("messages", day_start, ~U[2001-10-10 04:00:00Z]) ==
               0

      assert Historian.pending_bytes_in_range("messages", ~U[2001-10-10 05:00:00Z], day_end) == 0

      # Each HALF of the busy hour owns its own row — this is the assertion
      # the `div(total_bytes, 2)` smear cannot satisfy, since it would give
      # both halves (1_111 + 2_222) / 2 = 1_666.
      assert Historian.pending_bytes_in_range(
               "messages",
               ~U[2001-10-10 04:00:00Z],
               ~U[2001-10-10 04:30:00Z]
             ) == byte_size(a.content)

      assert Historian.pending_bytes_in_range(
               "messages",
               ~U[2001-10-10 04:30:00Z],
               ~U[2001-10-10 05:00:00Z]
             ) == byte_size(b.content)

      # It is the same query as the grouped twin, so it must agree with it.
      per_day = Historian.pending_bytes_per_day("messages", day_start, day_end, nil)
      assert Map.fetch!(per_day, day) == whole_day

      # Degenerate ranges are 0, not a crash and not the whole corpus. These
      # two go to the DB — there is deliberately no short-circuit guard in
      # front of them, so they pin the half-open bound rather than an
      # early-return branch that would make them trivially true.
      assert Historian.pending_bytes_in_range("messages", day_end, day_start) == 0
      assert Historian.pending_bytes_in_range("messages", day_start, day_start) == 0
    end

    # Task 01a0a12e: transcripts are excluded by default, so every range sums
    # to 0. `pending_bytes_in_range/3` takes no opts; the completed_at clock
    # is still pinned at the seam via `meeting_transcripts: :included`.
    test "transcripts: the range sum is 0 by default; the seam's clock is completed_at" do
      day = ~D[2001-10-20]
      hour_start = ~U[2001-10-20 04:00:00Z]
      hour_end = ~U[2001-10-20 05:00:00Z]

      # Eligible: completed inside the hour. All three summaries are DIFFERENT
      # lengths on purpose — with equal-size rows a clock/status mutation that
      # merely SUBSTITUTES one row for another is invisible to a
      # "measured is about 900 bytes" assertion.
      eligible = insert_transcript_at!(%{summary: String.duplicate("e", 900)}, day)
      set_transcript_fields!(eligible.id, completed_at: ~U[2001-10-20 04:10:00Z])

      # Ineligible (a): still recording inside the hour.
      recording = insert_transcript_at!(%{summary: String.duplicate("r", 700)}, day)

      set_transcript_fields!(recording.id,
        status: "recording",
        completed_at: ~U[2001-10-20 04:20:00Z]
      )

      # Ineligible (b): completed on an EARLIER day but edited inside the
      # hour. Bounding on `updated_at` instead of `completed_at` would pull
      # this in — the same clock-swap mutation stage 2 pinned.
      late_edit = insert_transcript_at!(%{summary: String.duplicate("l", 1_500)}, day)

      set_transcript_fields!(late_edit.id,
        completed_at: ~U[2001-10-19 09:00:00Z],
        updated_at: ~U[2001-10-20 04:30:00Z]
      )

      included = fn from, to ->
        from
        |> Meetings.list_transcripts_since(window_end: to, meeting_transcripts: :included)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      assert Historian.pending_bytes_in_range("transcripts", hour_start, hour_end) == 0
      # POSITIVE CONTROL: opted in, the seam admits ONLY the eligible row.
      assert included.(hour_start, hour_end) == [eligible.id]

      # FIXTURE CONTROL (a): the still-recording row really is inside the
      # hour — completing it makes the seam admit it. Bytes stay 0.
      set_transcript_fields!(recording.id, status: "complete")

      assert Historian.pending_bytes_in_range("transcripts", hour_start, hour_end) == 0
      assert included.(hour_start, hour_end) == Enum.sort([eligible.id, recording.id])

      # FIXTURE CONTROL (b): the late-edited row is owned by the day it
      # COMPLETED on, not the day it was edited on.
      assert Historian.pending_bytes_in_range(
               "transcripts",
               ~U[2001-10-19 00:00:00Z],
               ~U[2001-10-20 00:00:00Z]
             ) == 0

      assert included.(~U[2001-10-19 00:00:00Z], ~U[2001-10-20 00:00:00Z]) == [late_edit.id]

      assert raw_transcript_summary_bytes(hour_start, hour_end) >= byte_size(late_edit.summary)
    end

    test "slice_windows/2 wires the real range measurement by default" do
      # END-TO-END: no `per_day_fn`, no `range_bytes_fn`, no `input_fn` —
      # every byte figure in this test comes from the DB through the
      # stage-2 seam. Proves the default closure is wired; a stubbed-only
      # unit test cannot see a default that returns garbage.
      day = ~D[2001-10-25]
      day_end = ~U[2001-10-26 00:00:00Z]

      live = insert_channel_space("wire-live")
      live_p = insert_user_participant(live.id, "Voice")

      exec = insert_space_of_kind!("execution", "wire-exec")
      exec_p = insert_user_participant(exec.id, "Runner")

      for hour <- [1, 8, 15, 22] do
        insert_message_at_time!(
          exec.id,
          exec_p.id,
          String.duplicate("x", 5_000),
          DateTime.new!(day, Time.new!(hour, 0, 0), "Etc/UTC")
        )
      end

      a =
        insert_message_at_time!(
          live.id,
          live_p.id,
          String.duplicate("a", 1_111),
          ~U[2001-10-25 04:10:00Z]
        )

      b =
        insert_message_at_time!(
          live.id,
          live_p.id,
          String.duplicate("b", 2_222),
          ~U[2001-10-25 04:40:00Z]
        )

      # Scoped to the messages corpus: the shared test DB carries seeded
      # org wiki rows whose own (unbounded) pending bytes emit a `pages`
      # window here, which this test says nothing about.
      windows =
        nil
        |> HistorianDispatcher.slice_windows(now: day_end, budget_tokens: 200)
        |> Enum.filter(&(&1.corpus == :messages))

      # POSITIVE CONTROL before the absence assertions.
      refute Enum.empty?(windows)

      # Both eligible messages are covered by an emitted window.
      for at <- [~U[2001-10-25 04:10:00Z], ~U[2001-10-25 04:40:00Z]] do
        assert Enum.any?(windows, fn w ->
                 DateTime.compare(at, w.window_start) != :lt and
                   DateTime.compare(at, w.window_end) == :lt
               end),
               "expected an emitted window covering #{at}"
      end

      # Exactly two windows — the two 45-minute leaves that own `a` and `b`.
      # Pre-stage-3 this day produced 32 leaves, every one of them oversize,
      # including leaves covering the hours where only execution chatter
      # lives.
      assert length(windows) == 2
      assert Enum.count(windows, & &1.oversize) == 2

      refute Enum.any?(windows, fn w ->
               DateTime.compare(w.window_start, ~U[2001-10-25 08:00:00Z]) != :gt and
                 DateTime.compare(w.window_end, ~U[2001-10-25 08:00:00Z]) == :gt
             end)

      # Telemetry field still carries the whole day's eligible bytes.
      day_bytes = byte_size(a.content) + byte_size(b.content)
      assert Enum.all?(windows, &(&1.day_bytes == day_bytes))
    end
  end

  # ── pending_bytes/1 — org-scope sentinel routes to nil-workspace rows ───

  describe "pending_bytes/1 — org-scope sentinel routes to nil-workspace rows" do
    test "pages+journal per-day byte-sum for the sentinel matches nil-workspace rows" do
      day = ~D[2001-10-15]

      # 40-byte journal entry and 40-byte page at the null workspace.
      insert_journal_at!(nil, String.duplicate("j", 40), day)
      insert_page_at!(nil, "org-page-a.md", String.duplicate("p", 40), day)

      start_at = ~U[2001-10-15 00:00:00Z]
      end_at = ~U[2001-10-16 00:00:00Z]

      # Before the fix these both returned %{} for the sentinel — the
      # `workspace_id == type(sentinel, :binary_id)` filter never matched
      # actual nil-workspace rows.
      assert Historian.pending_bytes_per_day(
               "pages",
               start_at,
               end_at,
               @org_scope_workspace_id
             ) == %{day => 40}

      assert Historian.pending_bytes_per_day(
               "journal",
               start_at,
               end_at,
               @org_scope_workspace_id
             ) == %{day => 40}
    end

    test "sentinel and explicit nil produce identical pending_bytes_per_day for pages" do
      day = ~D[2001-10-01]

      insert_page_at!(nil, "org-page-a.md", String.duplicate("a", 60), day)
      insert_page_at!(nil, "org-page-b.md", String.duplicate("b", 40), day)

      start_at = ~U[2001-10-01 00:00:00Z]
      end_at = ~U[2001-10-02 00:00:00Z]

      sentinel_result =
        Historian.pending_bytes_per_day("pages", start_at, end_at, @org_scope_workspace_id)

      nil_result = Historian.pending_bytes_per_day("pages", start_at, end_at)

      assert sentinel_result == %{day => 100}
      assert sentinel_result == nil_result
    end

    test "mixed nil + workspace-scoped rows: sentinel sees only nil rows" do
      day = ~D[2001-11-01]
      workspace_id = Ecto.UUID.generate()

      # 3 nil-workspace pages @ 30 bytes each = 90 bytes org-scope.
      for i <- 1..3 do
        insert_page_at!(nil, "nil-page-#{i}.md", String.duplicate("n", 30), day)
      end

      # 2 workspace-scoped pages @ 100 bytes each = 200 bytes for that workspace.
      for i <- 1..2 do
        insert_page_at!(workspace_id, "ws-page-#{i}.md", String.duplicate("w", 100), day)
      end

      start_at = ~U[2001-11-01 00:00:00Z]
      end_at = ~U[2001-11-02 00:00:00Z]

      assert Historian.pending_bytes_per_day(
               "pages",
               start_at,
               end_at,
               @org_scope_workspace_id
             ) == %{day => 90}

      assert Historian.pending_bytes_per_day("pages", start_at, end_at, workspace_id) ==
               %{day => 200}
    end

    test "messages regression guard: sentinel/random/nil counts all identical" do
      # chat_messages has no workspace_id column; the sentinel guard must
      # NOT coerce those clauses. All three calls should observe the same
      # messages bytes (the fix must not regress this).
      space = insert_channel_space("hist-sentinel-msgs")
      participant = insert_user_participant(space.id, "Voice")

      day = ~D[2001-12-01]
      # 5 messages × 20 bytes = 100 bytes.
      for _i <- 1..5 do
        insert_message_at!(space.id, participant.id, String.duplicate("m", 20), day)
      end

      start_at = ~U[2001-12-01 00:00:00Z]
      end_at = ~U[2001-12-02 00:00:00Z]

      baseline_sentinel =
        Historian.pending_bytes_per_day("messages", start_at, end_at, @org_scope_workspace_id)

      baseline_random =
        Historian.pending_bytes_per_day("messages", start_at, end_at, Ecto.UUID.generate())

      baseline_nil = Historian.pending_bytes_per_day("messages", start_at, end_at)

      assert baseline_sentinel == %{day => 100}
      assert baseline_sentinel == baseline_random
      assert baseline_sentinel == baseline_nil
    end
  end

  # ── Org-scope sentinel coercion — cursor read/write functions ───────────
  #
  # PR #537 (task 019f5cf4) added sentinel-to-nil coercion for
  # `sum_corpus_bytes/3` + `per_day_bytes_query/4` on the corpus tables.
  # Task 019f5e7d stage 1 extends the same pattern to the cursor read/write
  # functions so the sentinel resolves to `workspace_id IS NULL` rows on
  # both sides of the read/write cycle (debounce reads the same rows
  # `mark_run_started/1` stamps).
  #
  # Migration `20260714000000_relax_org_historian_cursors_null_workspace`
  # relaxes the cursor table's NOT NULL + PK on `workspace_id` so nil-workspace
  # cursor rows are legal to persist.

  describe "org-scope sentinel coercion — read side" do
    test "last_run_at(sentinel) returns the nil-workspace cursor's last_run_at" do
      nil_at = ~U[2001-01-01 12:00:00.000000Z]
      sentinel_at = ~U[2020-01-01 12:00:00.000000Z]

      # Canonical on-disk shape: workspace_id IS NULL for org-scope.
      Repo.insert!(%HistorianCursor{
        workspace_id: nil,
        corpus: "journal",
        last_run_at: nil_at
      })

      # Legacy accidental shape: sentinel string in workspace_id (pre-fix
      # write path stamped this). Coerced reads must NOT return this row.
      Repo.insert!(%HistorianCursor{
        workspace_id: @org_scope_workspace_id,
        corpus: "journal",
        last_run_at: sentinel_at
      })

      result = Historian.last_run_at(@org_scope_workspace_id)
      assert %DateTime{} = result
      assert DateTime.compare(result, nil_at) == :eq
    end

    test "pending_windows_input(sentinel).journal uses the nil-workspace cursor timestamp" do
      # Nil-workspace cursor is older than every journal row we insert, so
      # sum_corpus_bytes will count every seeded row. If cursor_last_processed_at
      # were routed to the SENTINEL row (with a much newer timestamp), the sum
      # would come back 0 and the assertion would fail.
      old_at = ~U[2001-01-01 12:00:00.000000Z]
      new_sentinel_at = ~U[2099-01-01 12:00:00.000000Z]

      Repo.insert!(%HistorianCursor{
        workspace_id: nil,
        corpus: "journal",
        last_processed_at: old_at,
        last_run_at: old_at
      })

      Repo.insert!(%HistorianCursor{
        workspace_id: @org_scope_workspace_id,
        corpus: "journal",
        last_processed_at: new_sentinel_at,
        last_run_at: new_sentinel_at
      })

      # Seed a nil-workspace journal row AFTER old_at but well before
      # new_sentinel_at → visible under nil-cursor, invisible under
      # sentinel-cursor.
      insert_journal_at!(nil, String.duplicate("j", 80), ~D[2050-05-01])

      %{journal: {last_at, bytes}} =
        Historian.pending_windows_input(@org_scope_workspace_id)

      assert %DateTime{} = last_at
      assert DateTime.compare(last_at, old_at) == :eq

      assert bytes == 80,
             "expected 80 bytes visible past the nil-workspace cursor, got #{bytes}"
    end
  end

  describe "org-scope sentinel coercion — write side (mark_run_started)" do
    test "mark_run_started(sentinel) writes cursor rows with workspace_id IS NULL" do
      :ok = Historian.mark_run_started(@org_scope_workspace_id)

      nil_rows =
        Repo.all(from(c in HistorianCursor, where: is_nil(c.workspace_id)))

      assert length(nil_rows) == length(Historian.corpora()),
             "expected one nil-workspace cursor row per corpus, got #{length(nil_rows)}"

      assert Enum.map(nil_rows, & &1.corpus) |> Enum.sort() ==
               Enum.sort(Historian.corpora())

      sentinel_count =
        Repo.aggregate(
          from(c in HistorianCursor,
            where: c.workspace_id == ^@org_scope_workspace_id
          ),
          :count
        )

      assert sentinel_count == 0,
             "expected zero sentinel-workspace rows written, got #{sentinel_count}"
    end

    test "mark_run_started(sentinel) advances existing nil-workspace last_run_at" do
      old_at = ~U[2001-01-01 12:00:00.000000Z]

      # Pre-seed nil-workspace rows for every corpus at an old timestamp.
      for corpus <- Historian.corpora() do
        Repo.insert!(%HistorianCursor{
          workspace_id: nil,
          corpus: corpus,
          last_run_at: old_at
        })
      end

      before_count =
        Repo.aggregate(from(c in HistorianCursor, where: is_nil(c.workspace_id)), :count)

      assert before_count == length(Historian.corpora())

      :ok = Historian.mark_run_started(@org_scope_workspace_id)

      # Same 4 rows, no dupes.
      after_count =
        Repo.aggregate(from(c in HistorianCursor, where: is_nil(c.workspace_id)), :count)

      assert after_count == length(Historian.corpora())

      # last_run_at advanced past old_at.
      new_at = Historian.last_run_at(nil)
      assert %DateTime{} = new_at
      assert DateTime.compare(new_at, old_at) == :gt

      # And the coerced read sees the same value.
      via_sentinel = Historian.last_run_at(@org_scope_workspace_id)
      assert DateTime.compare(via_sentinel, new_at) == :eq
    end

    test "mark_run_started(sentinel) does NOT touch a legacy sentinel cursor row" do
      sentinel_at = ~U[2020-01-01 12:00:00.000000Z]

      # Legacy accidental shape (pre-fix write path).
      Repo.insert!(%HistorianCursor{
        workspace_id: @org_scope_workspace_id,
        corpus: "journal",
        last_run_at: sentinel_at
      })

      :ok = Historian.mark_run_started(@org_scope_workspace_id)

      # Sentinel row unchanged.
      sentinel_row =
        Repo.one!(
          from(c in HistorianCursor,
            where: c.workspace_id == ^@org_scope_workspace_id and c.corpus == "journal"
          )
        )

      assert DateTime.compare(sentinel_row.last_run_at, sentinel_at) == :eq

      # And a new nil-workspace journal row was created.
      nil_journal =
        Repo.one!(
          from(c in HistorianCursor,
            where: is_nil(c.workspace_id) and c.corpus == "journal"
          )
        )

      assert %DateTime{} = nil_journal.last_run_at
      assert DateTime.compare(nil_journal.last_run_at, sentinel_at) == :gt
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp insert_journal!(workspace_id, content) do
    %MemoryEntry{}
    |> MemoryEntry.changeset(%{
      workspace_id: workspace_id,
      content: content,
      date: Date.utc_today()
    })
    |> Repo.insert!()
  end

  # MemoryEntry has autogenerate on inserted_at via `timestamps`, so we have
  # to force a specific timestamp through a raw update to test the cursor
  # walk. This is a test-only escape hatch — production code never sets
  # inserted_at directly.
  defp force_inserted_at!(%MemoryEntry{id: id}, %DateTime{} = inserted_at) do
    {1, _} =
      Repo.update_all(
        from(e in MemoryEntry, where: e.id == ^id),
        set: [inserted_at: inserted_at]
      )

    :ok
  end

  # Insert a journal entry and stamp its `inserted_at` to midday UTC
  # on the given calendar day. Midday avoids TZ-boundary confusion.
  defp insert_journal_at!(workspace_id, content, %Date{} = day) do
    row = insert_journal!(workspace_id, content)
    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")
    force_inserted_at!(row, ts)
    row
  end

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

  # `insert_message_at!/4` stamped at an exact instant rather than midday,
  # so a fixture can put genuinely uneven density inside a single day —
  # the only shape in which a uniform-density bug is observable.
  defp insert_message_at_time!(space_id, participant_id, content, %DateTime{} = at) do
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

    {1, _} =
      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: at]
      )

    message
  end

  defp insert_space_of_kind!(kind, name_suffix) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{name_suffix}",
        slug: "#{kind}-#{System.unique_integer([:positive])}",
        kind: kind
      })

    space
  end

  defp archive_space!(space_id) do
    {1, _} =
      Repo.update_all(
        from(s in Space, where: s.id == ^space_id),
        set: [archived_at: DateTime.utc_now()]
      )

    :ok
  end

  # `insert_message_at!/4` with arbitrary message attrs merged in, so a test
  # can seed the ineligible shapes (log_only, non-conversational
  # content_type, soft-deleted) without four near-identical helpers.
  defp insert_message_with!(space_id, participant_id, attrs, %Date{} = day) do
    base = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      author_display_name: "Test"
    }

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    ts = DateTime.new!(day, ~T[12:00:00], "Etc/UTC")

    {1, _} =
      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: ts]
      )

    message
  end

  defp set_transcript_fields!(transcript_id, fields) do
    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^transcript_id),
        set: fields
      )

    :ok
  end

  # The pre-unification byte query, reproduced verbatim as a FIXTURE control:
  # it counts every chat_messages row minus external spaces, which is what
  # `sum_corpus_bytes("messages", ...)` did before this stage. Used only to
  # prove the ineligible rows were really seeded.
  defp raw_message_bytes(start_at, end_at) do
    from(m in "chat_messages",
      where: m.inserted_at >= ^start_at and m.inserted_at < ^end_at,
      select: sum(fragment("coalesce(octet_length(?), 0)", m.content))
    )
    |> Repo.one()
    |> then(&(&1 || 0))
    |> then(fn
      %Decimal{} = d -> Decimal.to_integer(d)
      n -> n
    end)
  end

  defp raw_transcript_summary_bytes(start_at, end_at) do
    from(t in "meeting_transcripts",
      where: t.updated_at >= ^start_at and t.updated_at < ^end_at,
      select: sum(fragment("coalesce(octet_length(?), 0)", t.summary))
    )
    |> Repo.one()
    |> then(&(&1 || 0))
    |> then(fn
      %Decimal{} = d -> Decimal.to_integer(d)
      n -> n
    end)
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
    # would actually see rather than a byte-count-only phantom. The
    # ineligible shapes are asserted on directly in the seam test below.
    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^transcript.id),
        set: [updated_at: ts, inserted_at: ts, completed_at: ts]
      )

    transcript
  end

  # ── External-space exclusion in byte-sizing (M12, rbac-external-users) ───

  # Creates a real external user (org_memberships.external == true) and adds
  # them as a participant of `space_id`, so `Chat.external_space_ids/0`
  # classifies that space external. Returns the participant.
  defp insert_external_participant(space_id) do
    n = System.unique_integer([:positive])

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "hx-#{n}@example.com",
        name: "Ext #{n}",
        oidc_sub: "hx-#{n}"
      })
      |> Repo.insert!()

    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.tenant_org_id("sxi")
      })

    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: "Ext",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  describe "byte-sizing excludes external-user spaces (M12)" do
    test "pending_windows_input omits external message/transcript bytes; pages/journal untouched" do
      ws = Ecto.UUID.generate()
      today = Date.utc_today()

      internal = insert_channel_space("acme-eng")
      ip = insert_user_participant(internal.id, "Acme")
      insert_message_at!(internal.id, ip.id, "internal-msg", today)
      insert_transcript_at!(%{space_id: internal.id, summary: "internal-mtg"}, today)

      external = insert_channel_space("sxi-support")
      ep = insert_external_participant(external.id)
      insert_message_at!(external.id, ep.id, String.duplicate("E", 200), today)
      insert_transcript_at!(%{space_id: external.id, summary: String.duplicate("X", 200)}, today)

      # Space-scoped corpora that must NOT be touched by the external filter.
      insert_journal!(ws, "journal-body")
      insert_page_at!(ws, "pg", "page-body", today)

      input = Historian.pending_windows_input(ws)

      {_, mbytes} = input.messages
      assert mbytes == byte_size("internal-msg")

      # Task 01a0a12e: transcripts are excluded by default — internal AND
      # external contribute 0. The scope partition on this corpus is pinned
      # at the seam (transcript_digest_scope_test.exs).
      {_, tbytes} = input.transcripts
      assert tbytes == 0

      {_, jbytes} = input.journal
      assert jbytes == byte_size("journal-body")

      {_, pbytes} = input.pages
      assert pbytes == byte_size("page-body")
    end

    test "pending_bytes_per_day('messages') excludes external-space bytes" do
      today = Date.utc_today()
      start_at = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
      end_at = DateTime.new!(Date.add(today, 1), ~T[00:00:00], "Etc/UTC")

      internal = insert_channel_space("acme-eng")
      ip = insert_user_participant(internal.id, "Acme")
      insert_message_at!(internal.id, ip.id, "internal-msg", today)

      external = insert_channel_space("sxi-support")
      ep = insert_external_participant(external.id)
      insert_message_at!(external.id, ep.id, String.duplicate("E", 200), today)

      per_day = Historian.pending_bytes_per_day("messages", start_at, end_at)
      total = per_day |> Map.values() |> Enum.sum()

      assert total == byte_size("internal-msg")
    end

    test "zero external users → sums identical (NOT IN ^[] is a no-op)" do
      ws = Ecto.UUID.generate()
      today = Date.utc_today()

      internal = insert_channel_space("acme-eng")
      ip = insert_user_participant(internal.id, "Acme")
      insert_message_at!(internal.id, ip.id, "internal-msg", today)
      insert_transcript_at!(%{space_id: internal.id, summary: "internal-mtg"}, today)

      assert Chat.external_space_ids() == []

      input = Historian.pending_windows_input(ws)

      {_, mbytes} = input.messages
      assert mbytes == byte_size("internal-msg")

      # Task 01a0a12e: transcripts are excluded by default.
      {_, tbytes} = input.transcripts
      assert tbytes == 0
    end
  end
end
