defmodule Platform.Repo.Migrations.BackfillFirstRunGoalForExistingUsers do
  @moduledoc """
  Task 01a19554-fd07-7000-b6c5-1fabb270fadf, stage 1: the first-run goal box
  (`Platform.Onboarding.FirstRunGoal`) shows only while a member's
  `users.preferences` has no `"first_run_goal"` key. Every member who exists
  when this ships is marked `"existing"`, so no current member ever sees it.

  A backfill rather than a mark at user creation: users are created on several
  paths, and one missed path would silently hide the box from a new member.

    * Only rows WITHOUT the key are touched; a stored value (e.g. `"skipped"`)
      is kept. The write is `||` of one key, so other preference keys survive.
    * `down/0` is a no-op: the backfill is not reversible (an `"existing"`
      written here cannot be told apart from one written later).
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE users
    SET preferences = COALESCE(preferences, '{}'::jsonb) || jsonb_build_object('first_run_goal', 'existing')
    WHERE NOT (COALESCE(preferences, '{}'::jsonb) ? 'first_run_goal')
    """)
  end

  def down do
    # Not reversible; see the moduledoc.
    execute("SELECT 1")
  end
end
