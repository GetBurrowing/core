defmodule Platform.Repo.Migrations.BackfillSocialProfileProject do
  @moduledoc """
  Task 01a16532 stage 2: a profile created before profiles defaulted their
  project has `project_id` NULL, so its clip renders fail with
  `profile_needs_project`. This data step gives each such profile the
  first non-archived project in its org, ordered by name then id. A
  profile whose org has no live project stays NULL; no project is created.

  KEEP IN SYNC with `Platform.Social.default_render_project_id/1`, which
  applies the same rule to new profiles. The rule is written out in SQL
  here so this migration never depends on application code that may
  change later. `COLLATE "C"` is byte order, the order Elixir compares
  the names in; the database's default collation (en_US) is not, and
  would pick a different project for names that differ in case.

  Idempotent: `WHERE p.project_id IS NULL` means a second run updates
  nothing and a profile that already has a project (an approver's choice
  included) is never overwritten. `down/0` is a no-op: which rows this
  set cannot be known afterwards.
  """

  use Ecto.Migration

  @backfill_sql """
  UPDATE social_profiles AS p
  SET project_id = (
        SELECT pr.id FROM projects AS pr
        WHERE pr.org_id = p.org_id AND pr.archived_at IS NULL
        ORDER BY pr.name COLLATE "C", pr.id
        LIMIT 1
      ),
      updated_at = now()
  WHERE p.project_id IS NULL
    AND EXISTS (
      SELECT 1 FROM projects AS pr
      WHERE pr.org_id = p.org_id AND pr.archived_at IS NULL
    )
  """

  @doc "The data step's SQL, exposed so a test can run it directly."
  def backfill_sql, do: @backfill_sql

  def up, do: execute(@backfill_sql)

  def down, do: :ok
end
