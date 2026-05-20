defmodule Platform.Repo.Migrations.AddFrontmatterToOrgWikiPages do
  use Ecto.Migration

  # T1 stage 2: add a jsonb `frontmatter` column to org_wiki_pages so wiki pages
  # can carry structured metadata (kind, owner, tags, etc.) alongside their
  # markdown body. Default `%{}` so existing rows backfill without breaking
  # changesets that don't yet supply the field.

  def up do
    alter table(:org_wiki_pages) do
      add(:frontmatter, :map, default: %{}, null: false)
    end
  end

  def down do
    alter table(:org_wiki_pages) do
      remove(:frontmatter)
    end
  end
end
