defmodule Platform.Repo.Migrations.CreateAccessRolesAndMapMemberships do
  @moduledoc """
  Task 01a1386d-cb5c stage 1 (ADR 0058, stack `rbac-roles`): the built-in
  roles as data, and every org membership mapped onto one of them, with no
  behaviour change.

    * `access_roles` — one row per role. The three built-in rows (`admin`,
      `member`, `guest`) are seeded here with the permission sets from
      `0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`.
      The sets are a literal snapshot, not read from
      `Platform.Access.Registry`, so this migration means the same thing on
      every future checkout.
    * `org_memberships.access_role_key` — a GENERATED column,
      `CASE WHEN external THEN 'guest' ELSE role END`, referencing
      `access_roles(key)`.

  ## Why generated, not a backfilled writable column

  `org_memberships` has 13 writers on main (`mark_membership_external/1`,
  `apply_derived_role/1`, promote and revoke, the pending-grant apply, …). A
  backfill would map today's rows but not the next row a writer inserts, so
  one missed writer would be a silent behaviour change. A generated column
  cannot drift. `role`, `external` and `roles_locked_at` are untouched and
  stay the source of truth. When custom roles make a membership's role
  assignable (stack position 8), that member converts this column (an
  `ALTER COLUMN … DROP EXPRESSION`) or adds assignments beside it.

  ## Reversible

  `down/0` is written out: drop the column, then the table. Neither step
  touches `role`, `external` or any other original column.
  """

  use Ecto.Migration

  @member %{
    "chat.read" => "implicit_or_participant",
    "chat.write" => "implicit_or_participant",
    "tasks.read" => "all",
    "tasks.write" => "all",
    "memory.read" => "all",
    "memory.write" => "all",
    "memory.journal" => "all",
    "files.read" => "membership_org",
    "files.write" => "membership_org",
    "canvas.read" => ["participant_spaces", "membership_org"],
    "canvas.write" => ["participant_spaces", "membership_org"],
    "prototypes.read" => "membership_org",
    "experiments.read" => "all",
    "experiments.propose" => "all",
    "agents.manage_own" => "all",
    "skills.read" => "all",
    "skills.write" => "all",
    "vault.use" => "all",
    "prompts.read" => "all",
    "meetings.join" => "all",
    "mail.use" => "all",
    "inbox.read" => "all",
    "activity.read" => "all"
  }

  @admin Map.merge(@member, %{
           "access.manage" => "membership_org",
           "mail.manage" => "membership_org",
           "prototypes.publish" => "membership_org",
           "tasks.promote" => "membership_org"
         })

  @guest %{
    "chat.read" => "participant_spaces",
    "chat.write" => "participant_spaces"
  }

  def up do
    create table(:access_roles, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:key, :text, null: false)
      add(:name, :text, null: false)
      add(:builtin, :boolean, null: false, default: false)
      add(:permissions, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:access_roles, [:key]))

    # The table must exist before the seed rows go in, and the rows before
    # the FK below can be validated against them.
    flush()

    for {key, name, permissions} <- [
          {"admin", "Admin", @admin},
          {"member", "Member", @member},
          {"guest", "Guest", @guest}
        ] do
      repo().query!(
        """
        INSERT INTO access_roles (key, name, builtin, permissions, inserted_at, updated_at)
        VALUES ($1, $2, true, $3, now(), now())
        """,
        [key, name, permissions]
      )
    end

    execute("""
    ALTER TABLE org_memberships
      ADD COLUMN access_role_key text
        GENERATED ALWAYS AS (CASE WHEN external THEN 'guest' ELSE role END) STORED
        CONSTRAINT org_memberships_access_role_key_fkey REFERENCES access_roles (key)
    """)
  end

  def down do
    execute("ALTER TABLE org_memberships DROP COLUMN access_role_key")
    drop(table(:access_roles))
  end
end
