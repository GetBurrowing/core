defmodule Platform.Repo.Migrations.BackfillMeetingChatSpaceSlugs do
  @moduledoc """
  Backfill a slug for every `kind = "meeting"` chat space that was created
  without one.

  ## Why

  `Meetings.create_meeting/1` historically called `Chat.create_space/1`
  without a `:slug`. The `Space` changeset only requires a slug for
  `channel`-kind spaces, so meeting spaces were inserted with a NULL/blank
  slug. The meeting discussion panel
  (`meeting_live.html.heex`) gates on `@meeting.chat_space.slug` and mounts
  the embedded chat with `chat_space_slug`, so a slug-less space renders
  "No discussion bound to this meeting." The companion code fix gives new
  meeting spaces a `"meeting-{uuid}"` slug; this migration repairs the
  rows that predate that fix.

  ## Slug expression

  We set the slug to `'meeting-' || id`. The `id` is the chat space's
  binary-id primary key, so the derived value is unique by construction
  (no scan/dedupe needed) and is also a valid, stable, URL-safe slug. This
  intentionally differs from the code path's `"meeting-{meeting_id}"`
  (derived from the *meeting's* id) only for legacy rows where re-deriving
  from the meeting would require a join; uniqueness is what the panel needs,
  and `'meeting-' || chat_space_id` guarantees it.

  ## Idempotency / safety

  The UPDATE only touches `kind = 'meeting'` rows whose slug is NULL or
  blank, so re-running is a no-op once every meeting space has a slug.
  Rows that already carry a slug (including those written by the fixed
  `create_meeting/1`) are left untouched.
  """

  use Ecto.Migration

  def up do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      """
      UPDATE chat_spaces
      SET slug = 'meeting-' || id, updated_at = NOW()
      WHERE kind = 'meeting'
        AND (slug IS NULL OR slug = '')
      """,
      []
    )
  end

  def down do
    # Non-reversible data repair: clearing the backfilled slugs would
    # re-introduce the "No discussion bound" bug, so `down/0` is a no-op.
    :ok
  end
end
