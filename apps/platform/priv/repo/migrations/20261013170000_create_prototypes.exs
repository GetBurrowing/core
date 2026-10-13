defmodule Platform.Repo.Migrations.CreatePrototypes do
  @moduledoc """
  Task 01a1316b-4e46 stage 1 (ADR 0057 Decision 1 and 5): versioned,
  multi-file prototype bundles and the per-install settings that gate them.

    * `prototypes` — one row per prototype. `latest_version` is a POINTER:
      rollback repoints it, it never copies bytes.
    * `prototype_versions` — one row per publish. A version is immutable once
      written; `(prototype_id, version)` is unique so two concurrent publishes
      cannot both claim the same number. `removed_at` is set by
      `Platform.Prototypes.Purger` when retention deletes the bytes.
    * `install_prototype_settings` — a singleton, enforced by the database
      exactly as `install_branding` is (CHECK on `singleton` plus a unique
      index), so two rows can never disagree about whether publishing is on.
      The default row ships here so `Settings.get/0` never handles an empty
      table. Publishing defaults OFF.

  No `Platform.Audit.record/1`, no PubSub: migrations run before the
  supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:prototypes, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :nilify_all))
      add(:name, :string, null: false)
      add(:created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:latest_version, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:prototypes, [:org_id]))
    create(index(:prototypes, [:space_id]))

    create table(:prototype_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:prototype_id, references(:prototypes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:version, :integer, null: false)
      # One jsonb per file: %{path, content_type, byte_size, storage_key, sha256}.
      add(:manifest, {:array, :map}, null: false, default: [])
      add(:total_bytes, :bigint, null: false, default: 0)
      add(:entry_path, :string, null: false, default: "index.html")
      # %{"kind" => "agent" | "user", "id" => uuid}
      add(:published_by, :map, null: false, default: %{})
      add(:removed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:prototype_versions, [:prototype_id, :version]))

    create(
      index(:prototype_versions, [:inserted_at],
        where: "removed_at IS NULL",
        name: :prototype_versions_live_inserted_at_index
      )
    )

    create table(:install_prototype_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:singleton, :boolean, null: false, default: true)
      add(:enabled, :boolean, null: false, default: false)
      add(:who_may_publish, :string, null: false, default: "members")
      add(:max_bundle_bytes, :bigint, null: false, default: 26_214_400)
      add(:max_files, :integer, null: false, default: 500)
      # NULL = keep forever.
      add(:retention_days, :integer, default: 90)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:install_prototype_settings, :install_prototype_settings_singleton_true,
        check: "singleton"
      )
    )

    create(
      constraint(:install_prototype_settings, :install_prototype_settings_who_may_publish,
        check: "who_may_publish IN ('members', 'admins', 'agents_only')"
      )
    )

    create(unique_index(:install_prototype_settings, [:singleton]))

    execute(
      """
      INSERT INTO install_prototype_settings
        (id, singleton, enabled, who_may_publish, max_bundle_bytes, max_files,
         retention_days, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), true, false, 'members', 26214400, 500, 90, now(), now())
      """,
      "DELETE FROM install_prototype_settings"
    )
  end
end
