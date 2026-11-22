defmodule Platform.Repo.Migrations.AddStudioDraftDiscard do
  @moduledoc """
  PR #267: Retain discarded Studio drafts and their audit history while keeping
  discarded state limited to drafts and recording discard and restore events.
  """
  use Ecto.Migration

  @old "'created', 'edited', 'submitted', 'approved', 'rejected', 'revision_requested', " <>
         "'published', 'failed', 'refused', 'version_saved', 'approval_revoked', " <>
         "'planned', 'plan_cancelled', 'retargeted'"
  @new @old <> ", 'discarded', 'restored'"

  # The updater's irreversible list blocks its own rollback after a release
  # crosses this migration. An old binary ignores discarded_at and can expose
  # discarded drafts; manual binary/image swaps are not protected by that gate.
  def up do
    alter table(:social_posts) do
      add(:discarded_at, :utc_datetime_usec)
    end

    create(
      constraint(:social_posts, :social_posts_discarded_draft_check,
        check: "discarded_at IS NULL OR (flow = 'studio' AND status = 'draft')"
      )
    )

    drop(constraint(:social_post_events, :social_post_events_action_check))

    create(
      constraint(:social_post_events, :social_post_events_action_check,
        check: "action IN (#{@new})"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM social_posts WHERE discarded_at IS NOT NULL)
         OR EXISTS (SELECT 1 FROM social_post_events WHERE action IN ('discarded', 'restored')) THEN
        RAISE EXCEPTION 'cannot roll back Studio draft discard while discard state or events exist';
      END IF;
    END $$;
    """)

    drop(constraint(:social_post_events, :social_post_events_action_check))

    create(
      constraint(:social_post_events, :social_post_events_action_check,
        check: "action IN (#{@old})"
      )
    )

    drop(constraint(:social_posts, :social_posts_discarded_draft_check))

    alter table(:social_posts) do
      remove(:discarded_at)
    end
  end
end
