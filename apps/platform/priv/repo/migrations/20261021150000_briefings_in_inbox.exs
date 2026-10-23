defmodule Platform.Repo.Migrations.BriefingsInInbox do
  @moduledoc """
  The daily briefing is delivered as one Inbox row instead of a canvas in a
  DM. Task `01a15ee1-48c8-7000-a8f1-33a5586cb458`, stage 1.

    * `memory_briefings.canvas_id` and `space_id` become NULLABLE. A briefing
      delivered to the Inbox has no canvas and no space; historical rows keep
      theirs, so old canvases still render and act.
    * `receipts` (jsonb, NOT NULL, default `{}`) records how each item was
      handled from the Inbox: node key => `%{"verb", "at", "by", "ref",
      "undo"}`.

  `down` restores NOT NULL, which no Inbox-delivered row (NULL canvas) can
  satisfy, so it DELETES those rows first. A rollback therefore loses the
  Inbox briefings written since `up`; their insights stay, and the
  `inbox_items` rows that point at them are left dangling and harmless.
  """

  use Ecto.Migration

  def up do
    execute("ALTER TABLE memory_briefings ALTER COLUMN canvas_id DROP NOT NULL")
    execute("ALTER TABLE memory_briefings ALTER COLUMN space_id DROP NOT NULL")

    alter table(:memory_briefings) do
      add(:receipts, :map, null: false, default: %{})
    end
  end

  def down do
    alter table(:memory_briefings) do
      remove(:receipts)
    end

    execute("DELETE FROM memory_briefings WHERE canvas_id IS NULL OR space_id IS NULL")
    execute("ALTER TABLE memory_briefings ALTER COLUMN space_id SET NOT NULL")
    execute("ALTER TABLE memory_briefings ALTER COLUMN canvas_id SET NOT NULL")
  end
end
