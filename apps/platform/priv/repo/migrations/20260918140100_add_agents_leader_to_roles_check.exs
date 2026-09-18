defmodule Platform.Repo.Migrations.AddAgentsLeaderToRolesCheck do
  @moduledoc """
  Extend the `roles_key_check` CHECK constraint to admit the new
  `agents_leader` role (task `01a0b491-0718-7001-8bba-bf50f119bb13`
  stage 1).

  `Platform.Roles.Role` pins `@valid_keys` to a closed roster and runs
  `validate_inclusion(:key, @valid_keys)`; the same roster is enforced at
  the DB layer by `roles_key_check`. Adding a key to one without the
  other leaves a changeset that validates and an insert that raises, so
  this migration mirrors the `@valid_keys` change in the same stage —
  exactly as `20260708120150_add_architect_to_roles_check.exs` did for
  `architect`.

  The `up/0` list is the EIGHT-key roster: every key already valid at
  this migration's timestamp plus `agents_leader`. Re-creating the CHECK
  with anything less would fail against rows that already exist in prod.

  `down/0` reverts to the seven-key roster. If a `roles` row with
  `key = 'agents_leader'` exists at rollback time the restore fails —
  that is the intended failure mode; silently dropping the row would be
  worse. The seed row is inserted by
  `20260918140200_seed_agents_leader_role.exs`, so a paired rollback
  clears it first.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard','architect','agents_leader')"
      )
    )
  end

  def down do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard','architect')"
      )
    )
  end
end
