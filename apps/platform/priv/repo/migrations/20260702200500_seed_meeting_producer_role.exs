defmodule Platform.Repo.Migrations.SeedMeetingProducerRole do
  @moduledoc """
  Re-seeds the platform-fixed roles so the new `meeting_producer` row
  (task `019f2451-6728` stage 2) lands on existing environments where
  the original stage-4 seed migration
  (`20260624013500_seed_default_roles.exs`) already ran to `:up`.

  Fresh DBs pick up `meeting_producer` from `Seeds.seed_defaults/0`
  through the earlier migration — but Ecto only invokes each migration
  once per version, so the code change alone won't touch production
  or already-migrated CI caches. This dedicated re-seed is the standard
  cutover pattern; mirrors `20260326190000_seed_deploying_prompt_template.exs`
  which re-invokes `PromptTemplates.seed_defaults/0` to backfill a new
  row on existing envs.

  Idempotent in both directions:

    * `up/0` calls `Platform.Roles.Seeds.seed_defaults/0`, which uses
      `on_conflict: :nothing` on both `roles` and `role_responsibilities`
      inserts — safe to run against a DB that already has the four
      original rows.
    * `down/0` deletes only the `meeting_producer` key via raw SQL
      (mirrors the pattern in
      `20260624013500_seed_default_roles.exs:34-40`); FK cascade clears
      the matching `role_responsibilities` row.
  """

  use Ecto.Migration

  def up do
    Platform.Roles.Seeds.seed_defaults()
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["meeting_producer"]
    )
  end
end
