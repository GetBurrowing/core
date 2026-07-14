defmodule Platform.DataMigrations.CleanupHistorianNoOpJournalEntries20260713Test do
  @moduledoc """
  Regression coverage for
  `20260714000100_cleanup_historian_no_op_journal_entries_20260713`
  (task 019f5e7d stage 3).

  Drives the migration's `delete_no_op_entries/1` and
  `record_cleanup_audit/1` helpers directly against `Platform.Repo`
  inside the sandbox transaction — the test hook the migration module
  exposes for exactly this purpose. Migrations run to `:up` before
  ExUnit boots so we cannot exercise `up/0` via `Ecto.Migrator`;
  these helpers are the same SQL / audit write wrapped for direct
  invocation without the migration Runner scaffolding.

  The five-row matrix mirrors the plan's e2e_behavior spec:

    (a) 2026-07-13, "Historn: backlog-drain pass. No new entries. ..."   → DELETED
    (b) 2026-07-13, "Historn: backlog-drain pass. Backlog drained. ..." → DELETED
    (c) 2026-07-13, "Wiki current. No changes this pass."                → DELETED
    (d) 2026-07-13, "Historn: backlog-drain pass. Applied: ..."          → PRESERVED (Applied:)
    (e) 2026-07-12, "Backlog drained. No new entries."                   → PRESERVED (date)
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo
  alias Platform.Repo.Migrations.CleanupHistorianNoOpJournalEntries20260713

  # Migration source lives under `priv/repo/migrations/` and is not on
  # the compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260714000100_cleanup_historian_no_op_journal_entries_20260713.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    Repo.delete_all(WikiJournalEntry)

    Repo.delete_all(
      from(e in Platform.Audit.Event,
        where: e.event_type == "platform.historian.cleanup"
      )
    )

    :ok
  end

  # ── seed helper ────────────────────────────────────────────────────

  defp seed_entry!(content, date) do
    {:ok, %WikiJournalEntry{id: id}} =
      Journal.append(%{content: content, date: date})

    id
  end

  defp existing_ids do
    from(e in WikiJournalEntry, select: e.id)
    |> Repo.all()
    |> Enum.sort()
  end

  # ── the predicate matrix ───────────────────────────────────────────

  test "five-row matrix: deletes no-op signature rows, preserves Applied: + out-of-window" do
    id_a =
      seed_entry!(
        "Historn: backlog-drain pass. No new entries. Nothing to promote.",
        ~D[2026-07-13]
      )

    id_b =
      seed_entry!(
        "Historn: backlog-drain pass. Backlog drained. Wiki current.",
        ~D[2026-07-13]
      )

    id_c =
      seed_entry!(
        "Wiki current. No changes this pass.",
        ~D[2026-07-13]
      )

    id_d =
      seed_entry!(
        "Historn: backlog-drain pass. Applied: kickoff-followup-meeting.md updates for decisions X,Y,Z. Created saru.md.",
        ~D[2026-07-13]
      )

    id_e =
      seed_entry!(
        "Backlog drained. No new entries.",
        ~D[2026-07-12]
      )

    # Sanity: all five rows landed.
    assert length(existing_ids()) == 5

    {n_deleted, deleted_ids} =
      CleanupHistorianNoOpJournalEntries20260713.delete_no_op_entries(Repo)

    assert n_deleted == 3, "expected 3 no-op rows to be deleted, got #{n_deleted}"

    assert Enum.sort(deleted_ids) == Enum.sort([id_a, id_b, id_c]),
           """
           delete_no_op_entries/1 removed the wrong rows.
           Expected: (a) 2026-07-13/no-new-entries,
                     (b) 2026-07-13/backlog-drained,
                     (c) 2026-07-13/wiki-current
           Got: #{inspect(deleted_ids)}
           """

    survivors = existing_ids()

    assert Enum.sort(survivors) == Enum.sort([id_d, id_e]),
           """
           The wrong rows survived cleanup.
           Expected survivors:
             (d) 2026-07-13/Applied: — protected by Applied: filter
             (e) 2026-07-12          — protected by date filter
           Got: #{inspect(survivors)}
           """
  end

  # ── idempotence ────────────────────────────────────────────────────

  test "re-invoking delete_no_op_entries/1 on the post-cleanup state is a no-op" do
    seed_entry!("Backlog drained.", ~D[2026-07-13])
    seed_entry!("No new entries. Wiki current.", ~D[2026-07-13])
    _survivor = seed_entry!("Applied: real-doc.md.", ~D[2026-07-13])

    {first_pass, first_ids} =
      CleanupHistorianNoOpJournalEntries20260713.delete_no_op_entries(Repo)

    assert first_pass == 2
    assert length(first_ids) == 2

    {second_pass, second_ids} =
      CleanupHistorianNoOpJournalEntries20260713.delete_no_op_entries(Repo)

    assert second_pass == 0,
           "second invocation should delete zero rows, got #{second_pass}"

    assert second_ids == [],
           "second invocation should return an empty id list, got #{inspect(second_ids)}"

    # The Applied: row is still present.
    assert length(existing_ids()) == 1
  end

  # ── audit trail ────────────────────────────────────────────────────

  describe "record_cleanup_audit/1" do
    test "writes one audit event with deleted_entry_ids + deleted_count in metadata" do
      ids = [
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate()
      ]

      assert :ok = CleanupHistorianNoOpJournalEntries20260713.record_cleanup_audit(ids)

      [event] = Audit.list(event_type: "platform.historian.cleanup", limit: 10)

      assert event.event_type == "platform.historian.cleanup"
      assert event.actor_type == "system"
      assert event.action == "execute"
      assert event.resource_type == "wiki_journal"
      assert event.resource_id == "2026-07-13"

      assert event.metadata["deleted_count"] == 3
      assert Enum.sort(event.metadata["deleted_entry_ids"]) == Enum.sort(ids)
      assert event.metadata["migration"] == "20260714000100"
      assert event.metadata["date"] == "2026-07-13"
    end

    test "empty id list is a no-op — no audit row written" do
      assert :ok = CleanupHistorianNoOpJournalEntries20260713.record_cleanup_audit([])

      assert Audit.list(event_type: "platform.historian.cleanup", limit: 10) == []
    end
  end

  # ── module surface ─────────────────────────────────────────────────

  describe "migration module surface" do
    test "module loads and both up/0 and down/0 are defined" do
      assert Code.ensure_loaded?(CleanupHistorianNoOpJournalEntries20260713)

      assert function_exported?(CleanupHistorianNoOpJournalEntries20260713, :up, 0)
      assert function_exported?(CleanupHistorianNoOpJournalEntries20260713, :down, 0)

      assert function_exported?(
               CleanupHistorianNoOpJournalEntries20260713,
               :delete_no_op_entries,
               1
             )

      assert function_exported?(
               CleanupHistorianNoOpJournalEntries20260713,
               :record_cleanup_audit,
               1
             )
    end
  end
end
