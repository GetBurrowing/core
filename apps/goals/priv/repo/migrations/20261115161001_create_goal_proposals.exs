defmodule Platform.Repo.Migrations.CreateGoalProposals do
  @moduledoc """
  Goals 5/8, task 01a1dfc1-7625: the New goal conversation's proposal, ADR
  0055 section 6. One new table; no existing table is altered.
  """
  use Ecto.Migration

  # old-code-compatible: creates the new goal_proposals table only; no existing table changes and the previous release does not read it
  def change do
    create table(:goal_proposals, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:first_message_id, :binary_id, null: false)
      add(:status, :string, null: false, default: "open")
      add(:revision, :integer, null: false, default: 0)
      add(:draft, :map, null: false, default: %{})
      add(:replies, {:array, :string}, null: false, default: [])
      add(:settled, :map, null: false, default: %{})
      add(:ready, :boolean, null: false, default: false)
      add(:goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all))
      add(:confirmed_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:delivery, :string, null: false, default: "pending")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:goal_proposals, :goal_proposals_status,
        check: "status IN ('open', 'confirmed', 'cancelled', 'expired')"
      )
    )

    create(
      constraint(:goal_proposals, :goal_proposals_delivery,
        check: "delivery IN ('pending', 'sent', 'offline', 'failed', 'no_runtime')"
      )
    )

    create(
      unique_index(:goal_proposals, [:user_id],
        where: "status = 'open'",
        name: :goal_proposals_one_open
      )
    )

    create(index(:goal_proposals, [:agent_id, :status]))
  end
end
