defmodule Platform.Mail.FolderCursor do
  @moduledoc """
  How far the IMAP poller has read one folder of one account (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3).

  `last_uid` is the highest UID already considered under `uidvalidity`. It is
  created at the folder's current maximum on first contact (the live poller
  ingests nothing older) and reset to the current maximum when the server
  reports a new UIDVALIDITY.

  Only the live poller (`Platform.Mail.Inbound`) writes this table. The
  admin-triggered backfill (`Platform.Mail.Inbound.Backfill`, task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92) READS a folder's cursor once, as the
  upper bound of what it may import, and never creates, advances or resets
  it.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mail_folder_cursors" do
    belongs_to(:account, Platform.Mail.Account)
    field(:folder, :string)
    field(:uidvalidity, :integer)
    field(:last_uid, :integer)

    timestamps()
  end
end
