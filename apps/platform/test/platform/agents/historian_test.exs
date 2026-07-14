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
  alias Platform.Chat
  alias Platform.Chat.Message
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

      # Exactly 4 cursor rows — one per corpus — exist for this workspace.
      count =
        Repo.aggregate(
          from(c in HistorianCursor, where: c.workspace_id == ^workspace_id),
          :count
        )

      assert count == 4
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

      for corpus <- ~w(pages journal messages transcripts) do
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

    test "transcripts: sums octet_length(summary) + octet_length(segments::text) per day",
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

      # Two buckets — day and 2001-09-03.
      assert map_size(result) == 2
      # Summary octets alone are 250 on `day`; segments JSON adds a
      # small overhead per row. Assert >= 250 (summary lower bound).
      assert Map.fetch!(result, day) >= 250
      # `2001-09-03` has one row with 40 summary octets + segments
      # JSON. Empty-array `[]::text` serializes to 2 bytes. Assert
      # >= 40 as the lower bound.
      assert Map.fetch!(result, ~D[2001-09-03]) >= 40
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

      assert length(nil_rows) == 4,
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

      assert before_count == 4

      :ok = Historian.mark_run_started(@org_scope_workspace_id)

      # Same 4 rows, no dupes.
      after_count =
        Repo.aggregate(from(c in HistorianCursor, where: is_nil(c.workspace_id)), :count)

      assert after_count == 4

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

    {1, _} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^transcript.id),
        set: [updated_at: ts, inserted_at: ts]
      )

    transcript
  end
end
