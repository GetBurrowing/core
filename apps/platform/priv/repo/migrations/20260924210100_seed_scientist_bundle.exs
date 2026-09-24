defmodule Platform.Repo.Migrations.SeedScientistBundle do
  @moduledoc """
  Add `experiments.scientist` to the `scientist` role's bundle on
  environments where `20260924190200_seed_scientist_role.exs` already ran to
  `:up` with the one-key bundle (task `01a0d415-b616-7001-b87d-bb5568a776d3`
  stage 5, the experimentation-layer ADR-0052,
  `docs/decisions/0052-experimentation-layer.md`).

  Ecto invokes each migration version once, so adding the key to
  `Platform.Roles.Seeds.default_roles/0` alone never reaches an
  already-migrated install. A FRESH database gets both bundle rows from
  `20260924190200_seed_scientist_role.exs` (it seeds from the current
  roster), and this migration is then a no-op for it.

  Scoped with `only_keys: ["scientist"]`: this is the only role whose bundle
  changed, and the `roles_key_check` CHECK already admits it
  (`20260924190100_add_scientist_to_roles_check.exs`), so the insert cannot
  violate it. Idempotent: `seed_defaults/1` inserts with `on_conflict:
  :nothing` on both `roles` and `role_responsibilities`.

  `down/0` deletes only the `(scientist, experiments.scientist)` bundle row,
  leaving the role and its labeler key as the previous migration left them.

  NO ASSIGNMENT IS SEEDED. Pinning an agent to `scientist` is a runtime
  `role_assignments` operation, and it is what enables the cron fire.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: ["scientist"])
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      ["scientist", "experiments.scientist"]
    )
  end
end
