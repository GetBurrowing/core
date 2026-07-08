defmodule Platform.Repo.Migrations.SeedSecurityGuardRole do
  @moduledoc """
  Re-seeds the platform-fixed roles so the new `security_guard` row
  (task `019f3e8e-4406` stage 1 — see ADR-0043) lands on existing
  environments where the earlier seed migrations
  (`20260624013500_seed_default_roles.exs` +
  `20260702200500_seed_meeting_producer_role.exs`) already ran to `:up`.

  Fresh DBs pick up `security_guard` from `Seeds.seed_defaults/0`
  through the earlier migration — but Ecto only invokes each migration
  once per version, so the code change alone won't touch production
  or already-migrated CI caches. Mirrors
  `20260702200500_seed_meeting_producer_role.exs` in shape.

  Idempotent in both directions:

    * `up/0` calls `Platform.Roles.Seeds.seed_defaults(only_keys:
      ["security_guard"])`, which uses `on_conflict: :nothing` on both
      `roles` and `role_responsibilities` inserts. `only_keys:` scopes
      the seed to just the new row so environments running this
      migration standalone don't attempt to re-insert the earlier
      keys (safe either way — the conflict clause absorbs them — but
      the scoping keeps the log line honest).
    * `down/0` deletes only the `security_guard` key via raw SQL
      (mirrors the pattern in
      `20260624013500_seed_default_roles.exs:34-40` +
      `20260702200500_seed_meeting_producer_role.exs`); FK cascade
      clears the matching `role_responsibilities` rows.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: ["security_guard"])
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["security_guard"]
    )
  end
end
