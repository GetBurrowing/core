defmodule Platform.Repo.Migrations.CreateAgentDelegationExclusions do
  @moduledoc """
  Create `agent_delegation_exclusions` — the table that records WHY an
  agent is not delegated work (task `01a0b491-0718-7001-8bba-bf50f119bb13`
  stage 2).

  ## Why this is not a boolean column on `agents`

  The two agents excluded today are excluded for DIFFERENT causes: one is
  a capability judgement (a local model whose output quality does not
  clear the bar for delegated stages), the other is a role conflict (an
  architect whose responsibilities preclude picking up immediate
  execution). A bare `delegatable: false` flag collapses those into one
  fact and invites a future reader to flip it back because the agent
  "looks idle". The reason sentence is the thing that survives that
  reader, so the reason — not the exclusion — is what is stored.

  `reason_kind` is an open `:string` column with a CLOSED validation in
  `Platform.Agents.DelegationExclusion` (`capability_judgement` |
  `role_conflict`). Deliberately not a DB CHECK: a third cause should be
  a code change somebody has to justify in review, not a migration that
  blocks a prod insert at 3am. The column is `null: false` so a row that
  names no cause cannot exist at all.

  `unique_index` on `agent_id`: an agent is either excluded or it is not.
  Two rows would mean two reasons, and a reader with two reasons has to
  pick one — which is the boolean problem again, one level up.

  `on_delete: :delete_all`: a deleted agent's exclusion is meaningless,
  and there is no reader for whom a dangling reason is better than none.
  """

  use Ecto.Migration

  def change do
    create table(:agent_delegation_exclusions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :agent_id,
        references(:agents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:reason_kind, :string, null: false)
      add(:reason, :text, null: false)
      add(:decided_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_delegation_exclusions, [:agent_id]))
  end
end
