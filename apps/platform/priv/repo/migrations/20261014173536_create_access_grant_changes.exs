defmodule Platform.Repo.Migrations.CreateAccessGrantChanges do
  @moduledoc """
  Task 01a1386e-30bd stage 1 (stack `rbac-roles`, member 6), recorded in
  `0058-rbac-v2-roles-scopes-and-agent-capping.md`: the
  `access_grant_changes` ledger. One row per committed change to
  `access_grants`, written by `Platform.Access.Changes.commit/4` in the SAME
  transaction as the change, so undo has the exact before-set.

    * `actor_type` is `user`, `agent` or `system`, with `actor_id` (nil for
      system). `via_agent_id` is the agent runtime that applied the change on
      a human's behalf. `bypass` is `root_admin` when the install-level
      bypass authorized it.
    * `action` is `grant`, `deny`, `revoke`, `undo` or `system_repoint`.
    * `before` and `after` are JSON arrays of `Platform.Access.Grant.snapshot/1`
      maps: every column of every affected row.
    * `tuple_keys` names every (principal, permission, resource) tuple the
      change touched. Its GIN index serves the "superseded" check of undo.
    * `undoes_change_id` points at the change an `undo` reversed. A partial
      unique index means a change is undone at most once.

  ## Nothing existing changes

  The table is new and empty. No existing table, column or row is touched,
  so no production data changes meaning. `down/0` drops the table.
  """

  use Ecto.Migration

  def up do
    create table(:access_grant_changes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:actor_type, :text, null: false)
      add(:actor_id, :uuid)
      add(:via_agent_id, :uuid)
      add(:bypass, :text)
      add(:action, :text, null: false)
      add(:before, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:after, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:tuple_keys, {:array, :text}, null: false)

      add(
        :undoes_change_id,
        references(:access_grant_changes, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:access_grant_changes, :access_grant_changes_actor_type_check,
        check: "actor_type IN ('user', 'agent', 'system')"
      )
    )

    create(
      constraint(:access_grant_changes, :access_grant_changes_action_check,
        check: "action IN ('grant', 'deny', 'revoke', 'undo', 'system_repoint')"
      )
    )

    create(
      constraint(:access_grant_changes, :access_grant_changes_bypass_check,
        check: "bypass IS NULL OR bypass IN ('root_admin')"
      )
    )

    create(index(:access_grant_changes, [:tuple_keys], using: :gin))
    create(index(:access_grant_changes, [:org_id, :inserted_at]))

    create(
      unique_index(:access_grant_changes, [:undoes_change_id],
        where: "undoes_change_id IS NOT NULL",
        name: :access_grant_changes_undoes_change_id_index
      )
    )
  end

  def down do
    drop(table(:access_grant_changes))
  end
end
