defmodule Platform.Repo.Migrations.AddMailboxOwnership do
  @moduledoc """
  Task 01a1ea5b-0012-7000-b182-827c608ef34c stage 1 (Email privacy).

  Adds mailbox ownership to `mail_accounts` and the per-mailbox
  `mail_account_grants` table backing `Platform.Mail.Ownership`.

  ## Add-only, forward-only

  No column, table, row or constraint is dropped or rewritten. Every
  existing account takes the column default `owner_kind = 'unassigned'`,
  which `Platform.Mail.Ownership` reads as "readable by nobody". No mapping
  is inferred and no grant is seeded (in particular not from inbound-space
  participation). The `down/0` below exists for a local dev database only;
  it is never run against a live install.

  ## Principal cleanup (`principal_id` has no FK)

  `mail_account_grants.principal_id` is polymorphic (`user` | `agent`), so
  no FK can cascade it. Two triggers delete a principal's grant rows in the
  same statement that deletes the principal, so no grant outlives its
  principal and an id that ever came back could inherit nothing:

    * `mail_account_grants_drop_user` BEFORE DELETE ON users: deletes the
      user's grants, deletes every grant on a mailbox the user owns (the
      owner chose those readers), AND returns that mailbox to `unassigned`
      (owner_user_id NULL). Unassigned is readable by nobody,
      so the user's mail fails closed until an admin calls `set_owner/3`.
      It runs BEFORE the row goes, so the `owner_user_id` FK (no action)
      finds nothing left to refuse.
    * `mail_account_grants_drop_agent` AFTER DELETE ON agents: deletes the
      agent's grants.

  `granted_by_user_id` is provenance only (the audit row also records the
  actor), so it is nilified, not cascaded: deleting the granter does not
  revoke what they granted.
  """
  use Ecto.Migration

  def up do
    alter table(:mail_accounts) do
      add(:owner_kind, :string, null: false, default: "unassigned")
      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :nothing))
      add(:digest_opt_in, :boolean, null: false, default: false)
    end

    create(
      constraint(:mail_accounts, :mail_accounts_owner_kind_check,
        check: "owner_kind IN ('unassigned', 'personal', 'shared')"
      )
    )

    create(
      constraint(:mail_accounts, :mail_accounts_owner_user_iff_personal,
        check: "(owner_kind = 'personal') = (owner_user_id IS NOT NULL)"
      )
    )

    create(index(:mail_accounts, [:owner_user_id]))

    create table(:mail_account_grants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:principal_type, :string, null: false)
      add(:principal_id, :binary_id, null: false)
      add(:granted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:mail_account_grants, :mail_account_grants_principal_type_check,
        check: "principal_type IN ('user', 'agent')"
      )
    )

    create(
      unique_index(:mail_account_grants, [:account_id, :principal_type, :principal_id],
        name: :mail_account_grants_account_principal_index
      )
    )

    create(index(:mail_account_grants, [:principal_type, :principal_id]))

    execute("""
    CREATE FUNCTION mail_account_grants_drop_user() RETURNS trigger AS $$
    BEGIN
      DELETE FROM mail_account_grants
        WHERE principal_type = 'user' AND principal_id = OLD.id;
      DELETE FROM mail_account_grants
        WHERE account_id IN (SELECT id FROM mail_accounts WHERE owner_user_id = OLD.id);
      UPDATE mail_accounts
        SET owner_kind = 'unassigned', owner_user_id = NULL, updated_at = now()
        WHERE owner_user_id = OLD.id;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER mail_account_grants_drop_user
    BEFORE DELETE ON users
    FOR EACH ROW EXECUTE FUNCTION mail_account_grants_drop_user()
    """)

    execute("""
    CREATE FUNCTION mail_account_grants_drop_agent() RETURNS trigger AS $$
    BEGIN
      DELETE FROM mail_account_grants
        WHERE principal_type = 'agent' AND principal_id = OLD.id;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER mail_account_grants_drop_agent
    AFTER DELETE ON agents
    FOR EACH ROW EXECUTE FUNCTION mail_account_grants_drop_agent()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS mail_account_grants_drop_agent ON agents")
    execute("DROP FUNCTION IF EXISTS mail_account_grants_drop_agent()")
    execute("DROP TRIGGER IF EXISTS mail_account_grants_drop_user ON users")
    execute("DROP FUNCTION IF EXISTS mail_account_grants_drop_user()")
    drop(table(:mail_account_grants))
    drop(constraint(:mail_accounts, :mail_accounts_owner_user_iff_personal))
    drop(constraint(:mail_accounts, :mail_accounts_owner_kind_check))

    alter table(:mail_accounts) do
      remove(:digest_opt_in)
      remove(:owner_user_id)
      remove(:owner_kind)
    end
  end
end
