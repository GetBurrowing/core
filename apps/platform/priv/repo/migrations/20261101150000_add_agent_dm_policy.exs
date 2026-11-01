defmodule Platform.Repo.Migrations.AddAgentDmPolicy do
  @moduledoc """
  Per-agent DM permission (task 01a19776 stage 1): who in the org may open a
  direct message with each agent.

  ## `agents.dm_policy`

  `everyone | admins | specific`, NOT NULL DEFAULT `'everyone'`. The default
  IS the backfill: every existing agent reads "everyone", which is exactly
  today's behaviour (any internal member may DM any active agent), so nothing
  changes until someone edits the setting. A CHECK constraint pins the three
  values in the database, because `validate_inclusion/3` only guards the one
  changeset that writes the column.

  ## `agent_dm_allowed_users`

  The "specific people" list: one row per `(agent_id, user_id)`. Both FKs
  cascade on delete, so removing a user or an agent removes its rows. Rows are
  kept when the policy flips away from "specific" and are consulted only while
  it is "specific". Mirrors `20260722000002_create_external_dm_allowlist_entries`.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:dm_policy, :string, null: false, default: "everyone")
    end

    create(
      constraint(:agents, :agents_dm_policy_check,
        check: "dm_policy IN ('everyone', 'admins', 'specific')"
      )
    )

    create table(:agent_dm_allowed_users, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :agent_id,
        references(:agents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_dm_allowed_users, [:agent_id, :user_id]))
    create(index(:agent_dm_allowed_users, [:user_id]))
  end
end
