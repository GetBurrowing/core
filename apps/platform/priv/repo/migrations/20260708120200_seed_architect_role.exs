defmodule Platform.Repo.Migrations.SeedArchitectRole do
  @moduledoc """
  Re-seeds the platform-fixed roles so the new `architect` row
  (ADR-0044 stage 1, task `019f3da3`) lands on existing environments
  where the original stage-4 seed migration
  (`20260624013500_seed_default_roles.exs`) already ran to `:up`.

  Fresh DBs pick up `architect` from `Seeds.seed_defaults/0` through
  the earlier migration — but Ecto only invokes each migration once
  per version, so the code change alone won't touch production or
  already-migrated CI caches. This dedicated re-seed is the standard
  cutover pattern; mirrors `20260702200500_seed_meeting_producer_role.exs`
  which did the same for the `meeting_producer` role added in task
  `019f2451` stage 2.

  Idempotent in both directions:

    * `up/0` calls `Platform.Roles.Seeds.seed_defaults/0`, which uses
      `on_conflict: :nothing` on both `roles` and `role_responsibilities`
      inserts — safe to run against a DB that already has the five
      earlier rows.
    * `down/0` deletes only the `architect` key via raw SQL (mirrors
      the pattern in `20260702200500_seed_meeting_producer_role.exs`);
      FK cascade clears the matching `role_responsibilities` rows.

  Runs after `20260708120150_add_architect_to_roles_check.exs` extends
  the CHECK constraint to admit the `architect` key, so this insert
  cannot violate the constraint.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults()
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["architect"]
    )
  end
end
