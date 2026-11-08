defmodule Platform.Feedback.Inbox.InstallReport do
  @moduledoc """
  One (fingerprint, sharing install id) pair on the broker host (task
  01a1b678 stage 4). Unique per pair, so an install that sends the same
  report twice counts once. The id is the install's random sharing id
  (`Platform.Sharing`), linked to no account.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "feedback_inbox_installs" do
    field(:fingerprint, :string)
    field(:sharing_install_id, Ecto.UUID)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
