defmodule Platform.Mail.InboundMessage do
  @moduledoc """
  One email read from an account's IMAP mailbox (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3).

  Written only by `Platform.Mail.Inbound`, with `ON CONFLICT DO NOTHING` on
  `(account_id, message_id_key)`, so a message is stored at most once per
  account however many folders or polls see it. `raw` is the untouched
  message; `text_body` is the decoded text the chat post was built from.
  `chat_message_id` is set once the channel post succeeds (nil when the
  account has no usable inbound space); `file_id` is set by the Inbox's
  "Add to files" (stage 4).

  `ingest_source` is `"poll"` for a row the live poller wrote and
  `"backfill"` for one `Platform.Mail.Inbound.Backfill` wrote (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92). A backfill row is stored exactly as
  a polled one but was never posted to chat (`chat_message_id` stays nil),
  never broadcast on `"mail:inbound"`; a consumer that reconciles against
  this table is expected to skip it. (Mail does not know its consumers.)
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mail_inbound_messages" do
    belongs_to(:account, Platform.Mail.Account)
    belongs_to(:org, Platform.Tenancy.Org)
    field(:folder, :string)
    field(:uidvalidity, :integer)
    field(:uid, :integer)
    field(:message_id_key, :string)
    field(:message_id_header, :string)
    field(:raw, :binary)
    field(:from_address, :string)
    field(:to_addresses, {:array, :string}, default: [])
    field(:subject, :string)
    field(:text_body, :string)
    field(:received_at, :utc_datetime_usec)
    field(:ingest_source, :string, default: "poll")
    belongs_to(:chat_message, Platform.Chat.Message)
    belongs_to(:file, Platform.Files.File)

    timestamps()
  end
end
