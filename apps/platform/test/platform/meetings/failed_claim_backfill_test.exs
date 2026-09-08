defmodule Platform.Meetings.FailedClaimBackfillTest do
  @moduledoc """
  Task 01a0826f stage 4 — the backfill that releases router claims
  stranded on transcripts which already reached `failed`.

  This test loads the *actual migration file* off the repo's migration
  path and executes it via `Ecto.Migrator.up/4`, rather than re-issuing a
  copy of its UPDATE. A
  copy would pass even if the migration file carried a typo, a different
  WHERE clause, or were deleted outright — it would only assert that a
  string in this file does what that string says.

  The migration is already applied in the test database, so each run
  deletes its `schema_migrations` row first to make the migrator willing
  to run it again. Both that delete and the migration's own writes happen
  inside the SQL sandbox transaction and are rolled back with the test.

  The `complete` and `processing` assertions are the blast-radius guard:
  they are what catches an over-broad WHERE clause that would clear a
  claim out from under a live dispatch.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  @migration_version 20_260_908_120_000
  @migration_module Platform.Repo.Migrations.ReleaseRouterClaimOnFailedTranscripts

  setup_all do
    # Migration files are not compiled into the app, so load the real one
    # off the migration path. `require_file` is a no-op once loaded.
    [path] =
      Path.wildcard(
        Path.join(:code.priv_dir(:platform), "repo/migrations/#{@migration_version}_*.exs")
      )

    unless Code.ensure_loaded?(@migration_module), do: Code.require_file(path)

    :ok
  end

  defp create_transcript!(status, router_dispatched_at) do
    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: "space-#{Ecto.UUID.generate()}",
        space_id: Ecto.UUID.generate(),
        segments: [],
        status: "processing"
      })

    {1, nil} =
      Repo.update_all(
        from(t in Transcript, where: t.id == ^transcript.id),
        set: [status: status, router_dispatched_at: router_dispatched_at]
      )

    transcript.id
  end

  defp run_migration! do
    # The migration ships in this repo's migration path and is already
    # recorded as applied in the test DB; drop the version row so the
    # migrator runs the real module again. Rolled back with the sandbox.
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@migration_version])

    Ecto.Migrator.up(Repo, @migration_version, @migration_module,
      log: false,
      log_migrations_sql: false,
      migration_lock: false
    )
  end

  defp claim(id), do: Repo.get!(Transcript, id).router_dispatched_at

  describe "release_router_claim_on_failed_transcripts migration" do
    test "clears the stranded claim on failed rows and leaves every other status alone" do
      stamp = ~U[2026-09-02 10:00:00.000000Z]

      failed_id = create_transcript!("failed", stamp)
      complete_id = create_transcript!("complete", stamp)
      processing_id = create_transcript!("processing", stamp)

      assert :ok = run_migration!()

      assert claim(failed_id) == nil

      # Blast radius: a wider WHERE would strip the claim off a completed
      # row, or worse, off a dispatch still in flight.
      assert claim(complete_id) == stamp
      assert claim(processing_id) == stamp

      # Statuses themselves are untouched.
      assert Repo.get!(Transcript, failed_id).status == "failed"
      assert Repo.get!(Transcript, complete_id).status == "complete"
      assert Repo.get!(Transcript, processing_id).status == "processing"
    end

    test "is idempotent — a second run changes nothing" do
      stamp = ~U[2026-09-02 10:00:00.000000Z]

      failed_id = create_transcript!("failed", stamp)
      complete_id = create_transcript!("complete", stamp)
      processing_id = create_transcript!("processing", stamp)

      assert :ok = run_migration!()
      assert claim(failed_id) == nil

      assert :ok = run_migration!()

      assert claim(failed_id) == nil
      assert claim(complete_id) == stamp
      assert claim(processing_id) == stamp
    end

    test "a failed row that never carried a claim is left as-is" do
      untouched_id = create_transcript!("failed", nil)

      assert :ok = run_migration!()

      assert claim(untouched_id) == nil
      assert Repo.get!(Transcript, untouched_id).status == "failed"
    end
  end
end
