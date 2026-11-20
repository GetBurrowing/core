defmodule Platform.Repo.Migrations.AddMailAccountGrantPurpose do
  @moduledoc """
  Task 01a1f5cc-e196-7000-9835-add8069c51cf stage 1 (Flag important email).

  Adds a grant PURPOSE to `mail_account_grants`:

    * `"access"` (the default, and every existing row): an ordinary read
      grant, written by `Platform.Mail.Ownership.grant/3`;
    * `"flag_important"`: the ONE agent a mailbox's owner chose to read new
      mail and flag what is important, written only by
      `Platform.Mail.Ownership.set_flag_important_agent/3`.

  The uniqueness moves from (account, principal) to (account, principal,
  purpose), so an agent may hold both an access grant and the flag grant on
  one mailbox and Off can delete the flag row alone. A partial unique index
  keeps at most one flag agent per mailbox, and a check keeps the flag grant
  on agents.

  The delete-principal triggers of `20261118010000_add_mailbox_ownership`
  delete grant rows of every purpose, so no new trigger is needed.
  """
  use Ecto.Migration

  # old-code-compatible: the new column has a default ('access'), so old code inserts and reads grants unchanged, and every existing row becomes an access grant. The new unique index is created BEFORE the old one is dropped, so no window runs without a uniqueness rule. Waived: during a rolling deploy, old code inserting a duplicate access grant hits the new index name (`mail_account_grants_account_principal_purpose_index`), which its changeset does not name, so it raises instead of returning :already_granted. That is a refused duplicate either way; nothing is written twice. Old code never writes a flag_important row; while old and new nodes overlap, an old node reading an agent that holds both rows may list it twice, or raise on revoke (Repo.one sees two rows), until it is replaced. The only `drop` in `up/0` is the superseded index, replaced first; the `drop`/`remove`/`execute` in `down/0` run only on a local dev rollback.

  def up do
    alter table(:mail_account_grants) do
      add(:purpose, :string, null: false, default: "access")
    end

    create(
      constraint(:mail_account_grants, :mail_account_grants_purpose_check,
        check:
          "purpose IN ('access', 'flag_important') AND " <>
            "(purpose <> 'flag_important' OR principal_type = 'agent')"
      )
    )

    create(
      unique_index(
        :mail_account_grants,
        [:account_id, :principal_type, :principal_id, :purpose],
        name: :mail_account_grants_account_principal_purpose_index
      )
    )

    drop(
      index(:mail_account_grants, [:account_id, :principal_type, :principal_id],
        name: :mail_account_grants_account_principal_index
      )
    )

    create(
      unique_index(:mail_account_grants, [:account_id],
        name: :mail_account_grants_one_flag_agent_index,
        where: "purpose = 'flag_important'"
      )
    )
  end

  def down do
    drop(index(:mail_account_grants, [:account_id], name: :mail_account_grants_one_flag_agent_index))

    execute("DELETE FROM mail_account_grants WHERE purpose <> 'access'")

    create(
      unique_index(:mail_account_grants, [:account_id, :principal_type, :principal_id],
        name: :mail_account_grants_account_principal_index
      )
    )

    drop(
      index(:mail_account_grants, [:account_id, :principal_type, :principal_id, :purpose],
        name: :mail_account_grants_account_principal_purpose_index
      )
    )

    drop(constraint(:mail_account_grants, :mail_account_grants_purpose_check))

    alter table(:mail_account_grants) do
      remove(:purpose)
    end
  end
end
