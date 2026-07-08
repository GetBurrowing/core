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

    * `up/0` calls `Platform.Roles.Seeds.seed_defaults/1` with
      `only_keys:` pinned to the five roles that are admitted by the
      `roles_key_check` CHECK constraint at THIS migration timestamp
      (designer, historian, meeting_producer, meeting_scribe,
      triage_officer). Uses `on_conflict: :nothing` on both `roles` and
      `role_responsibilities` inserts — safe to run against a DB that
      already has the four original rows.

      The `only_keys:` gate is load-bearing: after task 019f3e8e-4406
      added `security_guard` to `@default_roles`, an unqualified
      `seed_defaults/0` call here would try to insert `security_guard`
      before `20260708000000_add_security_guard_to_roles_check.exs`
      admits the key, tripping the CHECK constraint on fresh DBs (CI).
      The dedicated re-seed migration
      `20260708000100_seed_security_guard_role.exs` picks up the new
      row after its constraint update lands.
    * `down/0` deletes only the `meeting_producer` key via raw SQL
      (mirrors the pattern in
      `20260624013500_seed_default_roles.exs:34-40`); FK cascade clears
      the matching `role_responsibilities` row.
  """

  use Ecto.Migration

  # Restrict this historical seed to the keys the `roles_key_check`
  # CHECK constraint admits AT THIS MIGRATION'S TIMESTAMP. The
  # meeting_producer CHECK-extension migration
  # (`20260702000000_add_meeting_producer_to_roles_check.exs`) ran
  # earlier in the same `mix ecto.migrate` pass, so `meeting_producer`
  # is admitted here. The `architect` key (ADR-0044 stage 1, task
  # `019f3da3`) was added to `Seeds.@default_roles` LATER and its own
  # CHECK-extension migration (`20260708120150_add_architect_to_roles_check.exs`)
  # runs AFTER this one — without the filter, an unqualified call to
  # `seed_defaults/0` would try to insert `architect` here and blow up
  # on `roles_key_check`.
  @seeded_keys ~w(designer historian meeting_scribe meeting_producer triage_officer)

  def up do
    Platform.Roles.Seeds.seed_defaults(only_keys: @seeded_keys)
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["meeting_producer"]
    )
  end
end
