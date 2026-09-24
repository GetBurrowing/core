defmodule Platform.Repo.Migrations.CreateMailAccountsAndSenders do
  @moduledoc """
  Task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 1 (Email integration).

  Creates the org-scoped `mail_accounts` table and its `mail_senders`
  sub-table, backing `Platform.Mail.Account` and `Platform.Mail.Sender`.

  ## No secret column

  Neither table stores a password. SMTP and IMAP secrets live in the Vault at
  scope `{:integration, account.id}`; the row carries only the slug
  (`smtp_secret_slug`, `imap_secret_slug`) naming the credential, and every
  read goes through `Platform.Vault.get_unique/2` with that explicit scope.

  ## Fail-closed defaults

    * `internal_only` defaults to TRUE — a new account sends only to members
      of its org until someone deliberately turns that off.
    * `read_enabled` defaults to FALSE — no IMAP polling until turned on.
    * `read_folders` defaults to `{}`, meaning "all folders" once reading is
      on; a non-empty list means exactly those folders.

  ## Senders

  A sender is an account-level dispatch address (e.g. `agents@<domain>`)
  keyed by `key`. There are no per-agent addresses.
  """
  use Ecto.Migration

  def change do
    create table(:mail_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)

      add(:smtp_host, :string)
      add(:smtp_port, :integer)
      add(:smtp_tls, :string, null: false, default: "starttls")
      add(:username, :string)

      add(:imap_host, :string)
      add(:imap_port, :integer)
      add(:imap_tls, :string)

      add(:send_enabled, :boolean, null: false, default: true)
      add(:internal_only, :boolean, null: false, default: true)
      add(:read_enabled, :boolean, null: false, default: false)
      add(:read_folders, {:array, :text}, null: false, default: [])

      add(
        :inbound_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :nilify_all)
      )

      add(:rate_limit_per_hour, :integer, null: false, default: 60)
      add(:smtp_secret_slug, :string)
      add(:imap_secret_slug, :string)
      add(:archived_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mail_accounts, [:org_id, :name]))

    create(
      constraint(:mail_accounts, :mail_accounts_smtp_tls_check,
        check: "smtp_tls IN ('tls', 'starttls', 'none')"
      )
    )

    create(
      constraint(:mail_accounts, :mail_accounts_imap_tls_check,
        check: "imap_tls IS NULL OR imap_tls IN ('tls', 'starttls', 'none')"
      )
    )

    create(
      constraint(:mail_accounts, :mail_accounts_rate_limit_positive,
        check: "rate_limit_per_hour > 0"
      )
    )

    create table(:mail_senders, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :account_id,
        references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:key, :string, null: false)
      add(:address, :string, null: false)
      add(:display_name, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mail_senders, [:account_id, :key]))
  end
end
