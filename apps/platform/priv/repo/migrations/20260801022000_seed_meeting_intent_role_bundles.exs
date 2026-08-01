defmodule Platform.Repo.Migrations.SeedMeetingIntentRoleBundles do
  use Ecto.Migration

  @moduledoc """
  Land the five mid-meeting intent bundle rows on an ALREADY-MIGRATED
  database. Extends task `019fb90f-36e3`'s live-meeting responsibility
  path to the rest of the classifier's intents; no task of its own.

  ## What boot does not cover

  The `responsibilities` rows need nothing here — the Registry upserts
  every module in the configured provider list on boot. **The role
  bundles do.** `Platform.Roles.Seeds.seed_defaults/0` runs from
  `20260624013500_seed_default_roles.exs`, and Ecto invokes a migration
  exactly once per version, so a bundle key added to `@default_roles`
  afterwards never reaches an environment that already ran it. Exactly
  the gap `20260726051346_seed_design_task_direction.exs` and
  `20260708120200_seed_architect_role.exs` were written to close, for
  the same reason.

  ## Measured, not anticipated

  This was found on production after the deploy, not before it. All five
  responsibility rows were present and enabled, the Router was
  subscribed to all five topics, and every prompt row was correct — and
  `Platform.Roles.assignee_for/1` still answered `nil` for all five,
  because `role_responsibilities` had no rows for them.

  That combination is worth naming, because it is the quiet one: the
  dispatcher forks correctly, the Router receives the broadcast, and
  then resolves nobody. `Router.fire/2` answers `{:ok, :unfilled}`,
  which reads like success and means the intent reached no one. The
  meeting's serial cursor is released either way, so nothing stalls and
  nothing errors — the feature is simply inert.

  No `roles_key_check` change is needed: every role named here already
  exists, and that CHECK constrains role keys rather than bundle keys.

  ## Idempotency

  `seed_defaults/0` inserts with `on_conflict: :nothing` against
  `roles_pkey` and `role_responsibilities_pair_idx`, so re-running
  against a database that already holds some or all of these pairs is a
  no-op. Called unqualified — all seven role keys are admitted by the
  CHECK constraint at this timestamp, so the `only_keys:` escape hatch
  the older migrations needed does not apply here.

  `down/0` removes only the five pairs this migration introduces. It
  deliberately does not unwind the rest of the seed set, and does not
  touch the roles themselves.
  """

  @pairs [
    {"designer", "meetings.visual_adjust"},
    {"designer", "meetings.interaction_design"},
    {"meeting_scribe", "meetings.brief_worthy"},
    {"historian", "meetings.decision_recorded"},
    {"triage_officer", "meetings.open_question"}
  ]

  def up do
    Platform.Roles.Seeds.seed_defaults()
    :ok
  end

  def down do
    Enum.each(@pairs, fn {role_key, responsibility_key} ->
      Ecto.Adapters.SQL.query!(
        Platform.Repo,
        "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
        [role_key, responsibility_key]
      )
    end)

    :ok
  end
end
