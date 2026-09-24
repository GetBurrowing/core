defmodule Platform.Repo.Migrations.AddScientistToRolesCheck do
  @moduledoc """
  Extend the `roles_key_check` CHECK constraint to admit the new `scientist`
  role (task `01a0d415-b616-7001-b87d-bb5568a776d3` stage 3, the
  experimentation-layer ADR-0052, `docs/decisions/0052-experimentation-layer.md`).

  `Platform.Roles.Role` pins `@valid_keys` to a closed roster and runs
  `validate_inclusion(:key, @valid_keys)`; the same roster is enforced at the
  DB layer by `roles_key_check`. Adding a key to one without the other leaves
  a changeset that validates and an insert that raises, so this migration
  mirrors the `@valid_keys` change in the same stage — exactly as
  `20260918140100_add_agents_leader_to_roles_check.exs` did for
  `agents_leader`.

  The `up/0` list is the NINE-key roster: every key already valid at this
  migration's timestamp plus `scientist`. Re-creating the CHECK with anything
  less would fail against rows that already exist in prod.

  `down/0` reverts to the eight-key roster. If a `roles` row with
  `key = 'scientist'` exists at rollback time the restore fails — that is the
  intended failure mode; silently dropping the row would be worse. The seed
  row is inserted by `20260924190200_seed_scientist_role.exs`, so a paired
  rollback clears it first.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard','architect','agents_leader','scientist')"
      )
    )
  end

  def down do
    drop(constraint(:roles, :roles_key_check))

    create(
      constraint(:roles, :roles_key_check,
        check:
          "key IN ('designer','historian','meeting_scribe','meeting_producer','triage_officer','security_guard','architect','agents_leader')"
      )
    )
  end
end
