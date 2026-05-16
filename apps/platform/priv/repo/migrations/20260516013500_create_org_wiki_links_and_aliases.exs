defmodule Platform.Repo.Migrations.CreateOrgWikiLinksAndAliases do
  use Ecto.Migration

  @moduledoc """
  P1 stage 3 — create empty `org_wiki_links` and `org_wiki_aliases` tables
  per ADR-0041 (Org Wiki). Tables only; no Ecto schema modules. The Phase 2
  work in `Platform.Org.Wiki` will fill those in.

  - `org_wiki_links` is the page-to-page link graph. Each row records a
    link out of a source page to either a resolved target page (`target_id`)
    or just a path string (`target_path`) when the target doesn't exist
    yet. `position` keeps the link order stable within a source page.

  - `org_wiki_aliases` resolves old paths/slugs to their current page. The
    natural key is the path itself (text PK).

  IDs follow the sibling pattern in
  `20260408180000_create_org_context_tables.exs`: `:uuid` PK without a DB
  default — UUIDv7 generation lives in the application layer.
  """

  def change do
    # ── org_wiki_links ─────────────────────────────────────────────────────
    create table(:org_wiki_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :source_id,
        references(:org_wiki_pages, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:target_path, :text, null: false)

      add(
        :target_id,
        references(:org_wiki_pages, type: :uuid, on_delete: :nilify_all),
        null: true
      )

      add(:display_text, :text)
      add(:position, :integer, null: false)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:org_wiki_links, [:source_id]))
    create(index(:org_wiki_links, [:target_id]))
    create(index(:org_wiki_links, [:target_path]))
    create(unique_index(:org_wiki_links, [:source_id, :position]))

    # ── org_wiki_aliases ───────────────────────────────────────────────────
    create table(:org_wiki_aliases, primary_key: false) do
      add(:old_path, :text, primary_key: true)

      add(
        :current_id,
        references(:org_wiki_pages, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
