defmodule Platform.Repo.Migrations.SeedDefaultRoles do
  @moduledoc """
  Seeds the four platform-fixed roles + their responsibility bundles
  (M4 stage 4 of task `019ef65b-a361-7873-871b-3375bf60ead7`).

  Per precedent `20260519143620_seed_root_orgs.exs`, this migration
  defers the insert work to a dedicated context module
  (`Platform.Roles.Seeds`) which goes through Ecto schemas. The
  alternative — inlining the schema struct or raw SQL — would either
  couple the migration to today's schema (`schema "roles"` could be
  renamed years from now) or duplicate the role/bundle table contract.

  Calling `Platform.Roles.Seeds.seed_defaults/0` is safe here because
  the M4 stage 1 and stage 2 migrations
  (`20260624011500_create_roles_and_bundles.exs`,
  `20260624012842_create_role_assignments_and_overrides.exs`) ran
  earlier in the same `mix ecto.migrate` pass — by the time this
  migration runs the `roles` and `role_responsibilities` tables exist
  in the canonical shape `Platform.Roles.Seeds` expects.

  Idempotent in both directions: `up/0` uses `on_conflict: :nothing`
  on both inserts; `down/0` deletes only the four seeded keys
  (cascade clears their `role_responsibilities` rows via the FK).
  """

  use Ecto.Migration

  @seeded_keys ~w(designer historian meeting_scribe triage_officer)

  def up do
    Platform.Roles.Seeds.seed_defaults()
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = ANY($1)",
      [@seeded_keys]
    )
  end
end
