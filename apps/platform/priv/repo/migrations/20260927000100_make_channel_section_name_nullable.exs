defmodule Platform.Repo.Migrations.MakeChannelSectionNameNullable do
  @moduledoc """
  Make `channel_sections.name` a nullable, sidebar-only label OVERRIDE
  (task 01a08212 stage 1: renaming an org left its section row naming the
  old one, forever).

  Until now every section stored a COPY of its org's name, taken when the
  row was created, and nothing refreshed it. After this migration the rail
  header renders `section.name || org.name` (`Platform.Chat.Section.display_name/1`),
  so a NULL name means "follow the org" and a rename of the org row is
  picked up at read time with no sync step. That is the point of the design:
  a future org-rename path (admin UI or MCP) needs to do nothing here.

  ## This is NOT a backfill of stale data

  The data step nulls only the rows whose name EQUALS their org's current
  name. That is behaviour-preserving: those rows render identically before
  and after, and simply start following the org from now on.

  Rows whose name DIFFERS from the org are left alone on purpose. A
  deliberate custom label and a stale copy of a former org name (for
  example a section still reading 'Fabrikam' after its org was renamed) are
  indistinguishable in the data, so no migration can tell which to clear.
  An admin clears a stale one with 'Use organisation name' in the rail's
  admin-edit mode (stage 2), which writes NULL.

  ## Raw SQL, schema-independent

  Mirrors `20260604000100_create_channel_sections`: no Ecto schema is
  referenced, so a later change to `Platform.Chat.Section` cannot change
  what this migration does on replay.

  `down` restores every NULL name from its org, then sets NOT NULL again.
  The two data steps are public so their test can drive them against the
  sandboxed repo.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE channel_sections ALTER COLUMN name DROP NOT NULL")
    flush()
    follow_org_where_equal(repo())
  end

  def down do
    restore_from_org(repo())
    execute("ALTER TABLE channel_sections ALTER COLUMN name SET NOT NULL")
  end

  @doc "Null every section name that exactly equals its org's current name."
  def follow_org_where_equal(repo) do
    repo.query!("""
    UPDATE channel_sections s SET name = NULL
    FROM orgs o
    WHERE o.id = s.org_id AND s.name = o.name
    """)
  end

  @doc "Write the org's current name into every section whose name is NULL."
  def restore_from_org(repo) do
    repo.query!("""
    UPDATE channel_sections s SET name = o.name
    FROM orgs o
    WHERE o.id = s.org_id AND s.name IS NULL
    """)
  end
end
