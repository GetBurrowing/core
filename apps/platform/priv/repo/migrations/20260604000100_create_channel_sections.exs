defmodule Platform.Repo.Migrations.CreateChannelSections do
  @moduledoc """
  Create `channel_sections` — the admin-curated default sidebar shape (chat
  sidebar v2, Stage 2). A section is a thin presentation/curation layer over
  an existing org (Dalton's no-sub_orgs constraint: reuse `orgs`, don't invent
  a parallel taxonomy). One section per org; `org_id` is unique.

  `position` is a plain integer (admin default order). Per-user ordering uses
  explicit arrays in `users.preferences` (Stage 3), so no fractional index is
  needed here — admin reordering is infrequent and renumber-on-save is cheap.

  ## Seeding (raw SQL, schema-independent)

  Seeds one section per existing org, ordered alphabetically by org name to
  match today's sub-org rail. `color` stores the scope token in CSS form
  (org slug with `_` → `-`, e.g. `vandelay_ind` → `vandelay-ind`) so the UI can build
  the existing `.text-<token>` / `.bg-<token>-dot` classes. `ON CONFLICT
  (org_id) DO NOTHING` makes the seed idempotent on replay. UUIDv7 ids match
  the app-generated shape (see `SeedRootOrgs`).

  Admitted by task 019e467d, PR #432 — customizable channel sidebar (org
  sections, per-user layout, admin curation).
  """
  use Ecto.Migration

  def up do
    create table(:channel_sections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:color, :string)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:channel_sections, [:org_id]))

    flush()

    %{rows: rows} = repo().query!("SELECT id, name, slug FROM orgs ORDER BY name ASC")

    rows
    |> Enum.with_index()
    |> Enum.each(fn {[org_id, name, slug], idx} ->
      section_id = Ecto.UUID.dump!(Platform.Types.UUIDv7.generate())
      color = String.replace(slug, "_", "-")

      repo().query!(
        """
        INSERT INTO channel_sections (id, org_id, name, color, position, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (org_id) DO NOTHING
        """,
        [section_id, org_id, name, color, idx]
      )
    end)
  end

  def down do
    drop(table(:channel_sections))
  end
end
