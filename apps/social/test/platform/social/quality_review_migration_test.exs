defmodule Platform.Social.QualityReviewMigrationTest do
  use Platform.DataCase, async: false

  @version 20_261_123_120_000
  @migration Platform.Repo.Migrations.AddSocialQualityReview
  @path Path.expand(
          "../../../priv/repo/migrations/20261123120000_add_social_quality_review.exs",
          __DIR__
        )
  @registry Path.expand("../../../../../deployment/release/irreversible-migrations.txt", __DIR__)

  test "release updater is told the quality-review schema cannot run with an older binary" do
    versions = @registry |> File.read!() |> String.split("\n", trim: true)
    assert "20261123120000" in versions
    assert File.exists?(@path)
  end

  test "down refuses even with empty review state and retains the migrated schema" do
    assert File.exists?(@path)
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@path)

    assert_raise Ecto.MigrationError, ~r/refusing to roll back AddSocialQualityReview/, fn ->
      Ecto.Migrator.down(Repo, @version, @migration,
        log: false,
        log_migrations_sql: false,
        migration_lock: false
      )
    end

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM schema_migrations WHERE version = $1",
               [@version]
             )

    assert %{rows: [[3]]} =
             Repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'social_posts' AND column_name IN ('quality_passed_by_user_id', 'quality_passed_at', 'quality_pass_fingerprint')"
             )
  end
end
