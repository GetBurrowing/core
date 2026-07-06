defmodule Platform.DataMigrations.CleanupLivekitPhantomFloodTest do
  @moduledoc """
  Regression coverage for
  `20260706120000_cleanup_livekit_phantom_flood_2026_07_04` (task
  019f3312 stage 4).

  Drives the migration's `delete_orphans/1` helper directly against
  `Platform.Repo` inside the sandbox transaction — the test hook that
  the migration module exposes for exactly this purpose. Migrations
  run to `:up` before ExUnit boots, so we cannot exercise `up/0` via
  `Ecto.Migrator`. `delete_orphans/1` is the same SQL, wrapped for
  direct invocation without the migration Runner scaffolding.

  The seven-row matrix mirrors the plan's spec:

    (i)   in-window, empty segments, `recording`  → DELETED
    (ii)  in-window, empty segments, `processing` → DELETED
    (iii) in-window, empty segments, `complete`   → PRESERVED (status)
    (iv)  in-window, non-empty segments, `recording` → PRESERVED (segments)
    (v)   before-window, empty segments, `recording` → PRESERVED (window)
    (vi)  after-window, empty segments, `recording`  → PRESERVED (window)
    (vii) boundary (01:15:00Z exactly), empty segments, `recording` → DELETED

  Case (vii) exists because the plan explicitly calls out inclusive
  window boundaries — the predicate uses SQL `BETWEEN` and Postgres
  treats `BETWEEN` as `>= AND <=`, so the boundary row must be caught.

  The Idempotence case re-invokes `delete_orphans/1` on the
  post-cleanup state and asserts zero additional deletes; the
  predicate is inherently monotonic (no new orphans re-appear) so
  re-running the migration on an already-cleaned DB is a proven no-op.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings.Transcript
  alias Platform.Repo

  # Migration source lives under `priv/repo/migrations/` and is not on
  # the compile path — walk up from `test/platform/data_migrations/<this>.exs`
  # to `apps/platform/` and back down into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260706120000_cleanup_livekit_phantom_flood_2026_07_04.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  setup do
    # Every seed lives inside this test's sandbox transaction; roll-back
    # on exit means the phantom rows never leak between tests. Nothing
    # to prune manually.
    Repo.delete_all(Transcript)
    :ok
  end

  # ── seeding helpers ────────────────────────────────────────────────

  defp seed_row!(label, inserted_at, segments, status) do
    id = Ecto.UUID.dump!(Platform.Types.UUIDv7.generate())

    # Pass the segments term natively so Postgrex encodes with the jsonb
    # OID. A pre-serialized `Jason.encode!/1` string round-trips through
    # the text→jsonb cast as a JSON *string* (`"[]"`), not the empty
    # array we need for the migration's `= '[]'::jsonb` predicate.
    Repo.query!(
      """
      INSERT INTO meeting_transcripts
        (id, room_id, segments, status, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, $5)
      """,
      [id, "room-#{label}", segments, status, inserted_at]
    )

    id
  end

  defp existing_ids do
    %{rows: rows} = Repo.query!("SELECT id FROM meeting_transcripts", [])
    rows |> List.flatten() |> Enum.sort()
  end

  # ── the predicate matrix ───────────────────────────────────────────

  test "seven-row matrix: 3 deleted (i, ii, vii), 4 preserved (iii, iv, v, vi)" do
    in_window = ~U[2026-07-04 01:22:00.000000Z]
    boundary_start = ~U[2026-07-04 01:15:00.000000Z]
    before_window = ~U[2026-07-04 00:00:00.000000Z]
    after_window = ~U[2026-07-04 02:00:00.000000Z]

    id_i = seed_row!("i", in_window, [], "recording")
    id_ii = seed_row!("ii", in_window, [], "processing")
    id_iii = seed_row!("iii", in_window, [], "complete")
    id_iv = seed_row!("iv", in_window, [%{"text" => "hi"}], "recording")
    id_v = seed_row!("v", before_window, [], "recording")
    id_vi = seed_row!("vi", after_window, [], "recording")
    id_vii = seed_row!("vii", boundary_start, [], "recording")

    # Sanity: all seven rows landed.
    assert length(existing_ids()) == 7

    {n_deleted, deleted_ids} =
      Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704.delete_orphans(Repo)

    assert n_deleted == 3, "expected 3 phantom rows to be deleted, got #{n_deleted}"

    assert Enum.sort(deleted_ids) == Enum.sort([id_i, id_ii, id_vii]),
           """
           delete_orphans/1 removed the wrong rows.
           Expected: (i) in-window/empty/recording,
                     (ii) in-window/empty/processing,
                     (vii) boundary/empty/recording
           Got: #{inspect(deleted_ids)}
           """

    survivors = existing_ids()

    assert Enum.sort(survivors) == Enum.sort([id_iii, id_iv, id_v, id_vi]),
           """
           The wrong rows survived cleanup.
           Expected survivors:
             (iii) in-window/empty/complete  — protected by status filter
             (iv)  in-window/non-empty        — protected by segments filter
             (v)   before-window              — protected by window filter
             (vi)  after-window               — protected by window filter
           Got: #{inspect(survivors)}
           """
  end

  # ── idempotence ────────────────────────────────────────────────────

  test "re-invoking delete_orphans/1 on the post-cleanup state is a no-op" do
    in_window = ~U[2026-07-04 01:22:00.000000Z]
    seed_row!("i", in_window, [], "recording")
    seed_row!("ii", in_window, [], "processing")
    _survivor = seed_row!("iv", in_window, [%{"text" => "hi"}], "recording")

    {first_pass, first_ids} =
      Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704.delete_orphans(Repo)

    assert first_pass == 2
    assert length(first_ids) == 2

    {second_pass, second_ids} =
      Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704.delete_orphans(Repo)

    assert second_pass == 0,
           "second invocation should delete zero rows, got #{second_pass}"

    assert second_ids == [],
           "second invocation should return an empty id list, got #{inspect(second_ids)}"

    # The non-phantom row is still present.
    assert length(existing_ids()) == 1
  end

  # ── module surface ─────────────────────────────────────────────────

  describe "migration module surface" do
    test "module loads and both up/0 and down/0 are defined" do
      assert Code.ensure_loaded?(Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704)

      assert function_exported?(
               Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704,
               :up,
               0
             )

      assert function_exported?(
               Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704,
               :down,
               0
             )

      assert function_exported?(
               Platform.Repo.Migrations.CleanupLivekitPhantomFlood20260704,
               :delete_orphans,
               1
             )
    end
  end
end
