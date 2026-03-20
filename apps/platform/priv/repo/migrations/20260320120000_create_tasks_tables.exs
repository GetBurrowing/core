defmodule Platform.Repo.Migrations.CreateTasksTables do
  use Ecto.Migration

  def change do
    # ── projects ───────────────────────────────────────────────────────────────
    create table(:projects, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:workspace_id, :binary_id)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:repo_url, :string)
      add(:default_branch, :string, default: "main")
      add(:tech_stack, :map, default: %{})
      add(:deploy_config, :map, default: %{})
      add(:config, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:projects, [:slug]))

    # ── epics ──────────────────────────────────────────────────────────────────
    create table(:epics, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :project_id,
        references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:description, :text)
      add(:acceptance_criteria, :text)
      add(:status, :string, null: false, default: "open")

      timestamps(type: :utc_datetime_usec)
    end

    # ── tasks ──────────────────────────────────────────────────────────────────
    create table(:tasks, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:epic_id, references(:epics, type: :binary_id, on_delete: :nilify_all))

      add(
        :project_id,
        references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:title, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "backlog")
      add(:priority, :string, default: "medium")
      add(:assignee_type, :string)
      add(:assignee_id, :binary_id)
      add(:dependencies, :map, default: fragment("'[]'::jsonb"))
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:tasks, [:status]))
    create(index(:tasks, [:project_id]))
    create(index(:tasks, [:epic_id]))

    # ── plans ──────────────────────────────────────────────────────────────────
    create table(:plans, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:status, :string, null: false, default: "draft")
      add(:version, :integer, null: false)
      add(:approved_by, :binary_id)
      add(:approved_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:plans, [:task_id, :version]))
    create(index(:plans, [:task_id]))

    # ── stages ─────────────────────────────────────────────────────────────────
    create table(:stages, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :plan_id,
        references(:plans, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "pending")
      add(:expected_artifacts, :map, default: fragment("'[]'::jsonb"))
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:stages, [:plan_id]))

    # ── validations ────────────────────────────────────────────────────────────
    create table(:validations, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :stage_id,
        references(:stages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:evidence, :map, default: %{})
      add(:evaluated_by, :string)
      add(:evaluated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:validations, [:stage_id]))
  end
end
