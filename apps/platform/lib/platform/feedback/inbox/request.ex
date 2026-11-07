defmodule Platform.Feedback.Inbox.Request do
  @moduledoc """
  One request in the broker host's feedback inbox (task 01a1b678 stage 4):
  a fingerprint, its sanitized title (the same text the public issue
  carries), the issue identity, and `shipped_at` once the issue closed as
  completed. Written only by `Platform.Feedback.Inbox`.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "feedback_inbox_requests" do
    field(:fingerprint, :string)
    field(:title, :string)
    field(:external_repository, :string)
    field(:external_issue_number, :integer)
    field(:shipped_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
