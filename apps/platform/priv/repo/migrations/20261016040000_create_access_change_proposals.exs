defmodule Platform.Repo.Migrations.CreateAccessChangeProposals do
  @moduledoc "Human consent proposals for access grants, task 01a1386e-72e1; the existing grant ledger remains the sole writer."
  use Ecto.Migration

  def up do
    create table(:access_change_proposals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :proposer_runtime_id,
        references(:agent_runtimes, type: :binary_id, on_delete: :nilify_all)
      )

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:action, :text, null: false)
      add(:options, {:array, :map}, null: false)
      add(:selected_option, :text)
      add(:tuple_keys, {:array, :text}, null: false)
      add(:base_state_hash, :text, null: false)
      add(:card_digest, :text, null: false)
      add(:state, :text, null: false, default: "proposed")
      add(:approval_id, :uuid)
      add(:approved_by_user_id, references(:users, type: :binary_id))
      add(:approved_at, :utc_datetime_usec)
      add(:change_id, references(:access_grant_changes, type: :binary_id))
      add(:undoes_change_id, references(:access_grant_changes, type: :binary_id))
      add(:failure, :map)
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:access_change_proposals, [:canvas_id]))
    create(unique_index(:access_change_proposals, [:approval_id]))

    create(
      constraint(:access_change_proposals, :proposal_kind,
        check: "kind IN ('change','undo','reset')"
      )
    )

    create(
      constraint(:access_change_proposals, :proposal_action,
        check: "action IN ('grant','deny','revoke','undo')"
      )
    )

    create(
      constraint(:access_change_proposals, :proposal_state,
        check: "state IN ('proposed','applying','applied','cancelled','stale','failed','undone')"
      )
    )

    create(
      constraint(:access_change_proposals, :human_applied,
        check:
          "state NOT IN ('applied','undone') OR (approved_by_user_id IS NOT NULL AND change_id IS NOT NULL)"
      )
    )
  end

  def down, do: drop(table(:access_change_proposals))
end
