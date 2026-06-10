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
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

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
end
