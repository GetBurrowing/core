defmodule Platform.Repo.Migrations.ExtendSocialPostEvents do
  @moduledoc """
  Social Studio slice A: the change log records which version and which
  account an entry is about (`post_version`, `account_id`; nullable, no
  backfill, no FK: an entry outlives a retarget and goes with its post), and
  its action list gains `version_saved`, `approval_revoked`, `planned`,
  `plan_cancelled`, `retargeted`. `social_post_events_body_only_for_edited_check`
  is untouched.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # old-code-compatible: additive and widening: two nullable columns and an action CHECK that is
  # a superset of the old one (the execute is only in down/0). With Studio events
  # present, old code would read actions it does not know.
  # Safe for the previous release only while no Studio rows exist; once they do,
  # rollback is barred by listing 20261114100000 in
  # deployment/release/irreversible-migrations.txt (the updater refuses to roll
  # back from the release that crossed it, once the crossing run completes; an
  # interrupted crossing run is not covered). This waiver depends on that listing.

  # extend_social_post_events.

  @old "'created', 'edited', 'submitted', 'approved', 'rejected', " <>
         "'revision_requested', 'published', 'failed', 'refused'"
  @new @old <> ", 'version_saved', 'approval_revoked', 'planned', 'plan_cancelled', 'retargeted'"

  def up do
    alter table(:social_post_events) do
      add(:post_version, :integer)
      add(:account_id, :binary_id)
    end

    drop(constraint(:social_post_events, :social_post_events_action_check))

    create(
      constraint(:social_post_events, :social_post_events_action_check,
        check: "action IN (#{@new})"
      )
    )
  end

  def down do
    execute("DELETE FROM social_post_events WHERE action NOT IN (#{@old})")
    drop(constraint(:social_post_events, :social_post_events_action_check))

    create(
      constraint(:social_post_events, :social_post_events_action_check,
        check: "action IN (#{@old})"
      )
    )

    alter table(:social_post_events) do
      remove(:account_id)
      remove(:post_version)
    end
  end
end
