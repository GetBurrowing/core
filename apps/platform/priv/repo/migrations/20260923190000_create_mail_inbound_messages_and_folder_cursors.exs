defmodule Platform.Repo.Migrations.CreateMailInboundMessagesAndFolderCursors do
  @moduledoc """
  Task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3 (Email integration).

  Creates `mail_inbound_messages` and `mail_folder_cursors`, backing
  `Platform.Mail.InboundMessage` and `Platform.Mail.FolderCursor`, the tables
  of the read-only IMAP poller in `Platform.Mail.Inbound`.

  ## Dedupe lives in the database

  `UNIQUE (account_id, message_id_key)`. `message_id_key` is the Message-ID
  header with whitespace and angle brackets trimmed (case kept), or
  `"sha256:" <> hex` of the raw bytes when the header is absent. The poller
  inserts with `ON CONFLICT DO NOTHING` and posts to chat only when a row was
  actually written, so the same message seen in two folders, or seen again
  after a cursor reset, is stored and posted once.

  ## raw

  The exact bytes fetched with `BODY.PEEK[]` (never setting `\\Seen`). The
  chat post carries a sanitised, wrapped rendering; the Inbox (stage 4) reads
  the original from here.

  ## Cursors

  One row per `(account_id, folder)`: the folder's UIDVALIDITY and the highest
  UID already considered. First contact records the current maximum, so
  nothing older is ingested; a UIDVALIDITY change resets to the new maximum.
  """
  use Ecto.Migration

  def change do
    create table(:mail_inbound_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :account_id,
        references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:folder, :text, null: false)
      add(:uidvalidity, :bigint, null: false)
      add(:uid, :bigint, null: false)
      add(:message_id_key, :text, null: false)
      add(:message_id_header, :text)
      add(:raw, :binary, null: false)
      add(:from_address, :text)
      add(:to_addresses, {:array, :text}, null: false, default: [])
      add(:subject, :text)
      add(:text_body, :text)
      add(:received_at, :utc_datetime_usec, null: false)

      add(
        :chat_message_id,
        references(:chat_messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:file_id, references(:platform_files, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mail_inbound_messages, [:account_id, :message_id_key]))
    create(index(:mail_inbound_messages, [:org_id, :received_at]))

    create table(:mail_folder_cursors, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :account_id,
        references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:folder, :text, null: false)
      add(:uidvalidity, :bigint, null: false)
      add(:last_uid, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mail_folder_cursors, [:account_id, :folder]))
  end
end
