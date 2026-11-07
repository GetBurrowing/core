defmodule Platform.Repo.Migrations.SeedUxFrictionWatchBundle do
  @moduledoc """
  Add `ux.friction_watch` to the `designer` role's bundle on existing
  databases (task `01a1af00-86ac-7000-94ba-a121d5cb8116` stage 1).

  Ecto runs each version once, so appending the key to
  `Platform.Roles.Seeds.default_roles/0` alone never reaches an install that
  has already migrated. This re-runs `seed_defaults(only_keys: ["designer"])`,
  as `20261105070000_seed_hr_profile_template_and_bundle.exs` does for the
  historian. NO new role: the roster is CLOSED by the `roles_key_check` CHECK
  and this file does not touch it. Idempotent: the seed inserts use
  `on_conflict: :nothing`.

  NO ASSIGNMENT IS SEEDED. Whoever holds `designer` holds the friction watch.

  `down/0` deletes the one `role_responsibilities` row and leaves the rest of
  the designer bundle as it was.
  """

  use Ecto.Migration

  @role "designer"
  @keys ["ux.friction_watch"]

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: [@role])
    :ok
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = ANY($2)",
      [@role, @keys]
    )

    :ok
  end

  @doc "The bundle rows this migration adds."
  def bundle_keys, do: @keys
end
