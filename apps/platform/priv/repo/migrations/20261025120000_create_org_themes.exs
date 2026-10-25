defmodule Platform.Repo.Migrations.CreateOrgThemes do
  @moduledoc """
  Task 01a1557a-fe9b (Burrow redesign 24, admin theme editor), stage 1:
  `org_themes`, the colour themes a root admin authors for an org.

  A row is one named theme: a `light` and a `dark` palette (master key =>
  lowercase `#rrggbb`), a mode-independent `shape` map, and a `status` that is
  `draft` until `Platform.Theming.publish/2` clears every contrast pair in both
  modes. The schema (`Platform.Theming.OrgTheme`) refuses unknown keys; the
  table only stores what the changeset admitted.

  Distinct from `install_branding`: that is install-wide and styles the Burrow
  preset only. This table is per org, and adds no column to `orgs`.

  Additive and reversible: `down` drops the table and nothing else.
  """

  use Ecto.Migration

  def up do
    create table(:org_themes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, size: 80, null: false)
      add(:status, :string, null: false, default: "draft")
      add(:default_mode, :string, null: false, default: "dark")
      add(:light, :map, null: false, default: %{})
      add(:dark, :map, null: false, default: %{})
      add(:shape, :map, null: false, default: %{})
      add(:published_at, :utc_datetime_usec)
      add(:published_by_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:org_themes, :org_themes_status_check,
        check: "status IN ('draft', 'published')"
      )
    )

    create(
      constraint(:org_themes, :org_themes_default_mode_check,
        check: "default_mode IN ('dark', 'light')"
      )
    )

    create(unique_index(:org_themes, [:org_id, :name]))
    create(index(:org_themes, [:org_id, :status]))
  end

  def down do
    drop(table(:org_themes))
  end
end
