defmodule Platform.Repo.Migrations.AddReviewRequests do
  use Ecto.Migration

  def change do
    # ── review_requests ────────────────────────────────────────────────────
    create table(:review_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :validation_id,
        references(:validations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :execution_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :nilify_all)
      )

      add(:status, :string, null: false, default: "pending")
      add(:submitted_by, :string)
      add(:resolved_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:review_requests, [:validation_id]))
    create(index(:review_requests, [:task_id]))
    create(index(:review_requests, [:status]))

    # ── review_items ───────────────────────────────────────────────────────
    create table(:review_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :review_request_id,
        references(:review_requests, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:label, :string, null: false)
      add(:canvas_id, :string)
      add(:content, :text)
      add(:status, :string, null: false, default: "pending")
      add(:feedback, :text)
      add(:reviewed_by, :string)
      add(:reviewed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:review_items, [:review_request_id]))
  end
end
