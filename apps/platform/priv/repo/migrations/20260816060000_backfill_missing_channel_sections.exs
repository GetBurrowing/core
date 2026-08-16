defmodule Platform.Repo.Migrations.BackfillMissingChannelSections do
  @moduledoc """
  Backfill one `channel_sections` row per non-archived org that has none.

  Sibling of `20260604000100_create_channel_sections`, and deliberately the
  same shape: raw SQL, schema-independent, UUIDv7 ids, `color` = org slug with
  `_` → `-`, `ON CONFLICT (org_id) DO NOTHING`.

  The seed only covered the orgs that existed on 2026-06-04, and nothing in
  `apps/platform/lib` created a section afterwards (fixed in the same task by
  `Platform.Chat.Sidebar.ensure_default_section/1`). Every org created through
  `/admin/orgs` since then — Cyberdyne among them — has no section, so
  `Sidebar.default_section_id/3` falls through to `fallback_section_id/1` and
  its channels render under whichever section holds the lowest `position`.
  This migration is what actually puts those orgs on the rail in production.

  Insert-only and conflict-guarded, so it is safe to re-run. Archived orgs are
  skipped: `list_active_default_sections/0` filters them out of the render path
  anyway, and restoring an archived org can create its section then.

  Admitted by task 01a00910 — channels render under the wrong org section.
  """
  use Ecto.Migration

  def up do
    %{rows: [[max_position]]} =
      repo().query!("SELECT COALESCE(MAX(position), -1) FROM channel_sections")

    %{rows: rows} =
      repo().query!("""
      SELECT o.id, o.name, o.slug
      FROM orgs o
      LEFT JOIN channel_sections cs ON cs.org_id = o.id
      WHERE cs.id IS NULL AND o.archived_at IS NULL
      ORDER BY o.name ASC
      """)

    rows
    |> Enum.with_index(max_position + 1)
    |> Enum.each(fn {[org_id, name, slug], position} ->
      section_id = Ecto.UUID.dump!(Platform.Types.UUIDv7.generate())
      color = String.replace(slug || "", "_", "-")

      repo().query!(
        """
        INSERT INTO channel_sections (id, org_id, name, color, position, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (org_id) DO NOTHING
        """,
        [section_id, org_id, name, color, position]
      )
    end)
  end

  def down do
    # No-op: the rows are indistinguishable from ones an admin curated, and
    # deleting them would re-create the very defect this backfills away.
    :ok
  end
end
