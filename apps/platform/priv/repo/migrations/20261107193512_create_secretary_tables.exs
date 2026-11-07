defmodule Platform.Repo.Migrations.CreateSecretaryTables do
  @moduledoc """
  Task 01a1b721 stage 1: the triage agent's store. Five tables, every row
  owned by one person (`user_id`, deleted with them):

    * `secretary_batches` — one dispatch of a batch of items to evaluate,
      with its token reservation and outcome;
    * `secretary_evaluations` — the current verdict on one item for one
      person, unique on `(user_id, ref_type, ref_id)`;
    * `secretary_feedback` — what the person told it (this matters, hide this
      kind, not a to-do, undo);
    * `secretary_todos` — the person's own list, unique on
      `(user_id, dedupe_key)` so a heard suggestion lands once;
    * `secretary_reachouts` — each time it reached out or held back, unique
      on `(user_id, evaluation_id, kind)`.

  No row here is ever readable by another person; see
  `Platform.Secretary.Store` and `Platform.Secretary.Todos`.
  """
  use Ecto.Migration

  def change do
    create table(:secretary_batches, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:agent_id, :binary_id)
      add(:item_refs, :jsonb, null: false, default: "[]")
      add(:status, :string, null: false, default: "dispatched")
      add(:reserved_tokens, :integer, null: false, default: 0)
      add(:actual_tokens, :integer)
      add(:policy_variant_id, :binary_id)
      add(:dispatched_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:secretary_batches, [:user_id, :inserted_at]))
    create(index(:secretary_batches, [:status]))

    create(
      constraint(:secretary_batches, :secretary_batches_status_check,
        check:
          "status IN ('dispatched','submitted','failed','expired','budget_exhausted','no_ai','rejected')"
      )
    )

    create table(:secretary_evaluations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:ref_type, :string, null: false)
      add(:ref_id, :binary_id, null: false)
      add(:tag, :string, null: false)
      add(:group_key, :string, null: false, default: "none")
      add(:reason, :string, size: 200)
      add(:rank, :integer)
      add(:previous_tag, :string)
      add(:brief_rank, :integer)
      add(:brief_line, :text)
      add(:brief_action_label, :string)
      add(:brief_tag, :string)
      add(:family, :boolean, null: false, default: false)
      add(:needs_you_now, :boolean, null: false, default: false)
      add(:deadline_at, :utc_datetime_usec)
      add(:model_version, :string)
      add(:batch_id, references(:secretary_batches, type: :binary_id, on_delete: :nilify_all))
      add(:failed_attempts, :integer, null: false, default: 0)
      add(:evaluated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:secretary_evaluations, [:user_id, :ref_type, :ref_id]))
    create(index(:secretary_evaluations, [:user_id, :tag]))

    create(
      constraint(:secretary_evaluations, :secretary_evaluations_tag_check,
        check: "tag IN ('decide','waiting','fyi','not_in_space','todo','suggested','quiet')"
      )
    )

    create table(:secretary_feedback, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:ref_type, :string)
      add(:ref_id, :binary_id)
      add(:kind_key, :string)
      add(:action, :string, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:secretary_feedback, [:user_id, :kind_key]))

    create(
      constraint(:secretary_feedback, :secretary_feedback_action_check,
        check: "action IN ('this_matters','hide_kind','not_a_todo','undo')"
      )
    )

    create table(:secretary_todos, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:title, :string, size: 500, null: false)
      add(:origin, :string, null: false)
      add(:source_ref_type, :string)
      add(:source_ref_id, :binary_id)
      add(:source_space_id, :binary_id)
      add(:source_quote, :text)
      add(:goal_key, :string)
      add(:due_on, :date)
      add(:status, :string, null: false)
      add(:done_reason, :string)
      add(:dedupe_key, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:secretary_todos, [:user_id, :dedupe_key]))
    create(index(:secretary_todos, [:user_id, :status]))

    create(
      constraint(:secretary_todos, :secretary_todos_origin_check,
        check: "origin IN ('self','heard')"
      )
    )

    create(
      constraint(:secretary_todos, :secretary_todos_status_check,
        check: "status IN ('suggested','kept','dismissed','done')"
      )
    )

    create table(:secretary_reachouts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :evaluation_id,
        references(:secretary_evaluations, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:reason, :string)
      add(:at, :utc_datetime_usec, null: false)
      add(:until, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:secretary_reachouts, [:user_id, :evaluation_id, :kind]))

    create(
      constraint(:secretary_reachouts, :secretary_reachouts_kind_check,
        check: "kind IN ('sent','interrupted','held_meeting','held_evening','released')"
      )
    )
  end
end
