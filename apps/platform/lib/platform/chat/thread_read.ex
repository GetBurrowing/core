defmodule Platform.Chat.ThreadRead do
  @moduledoc """
  One participant's read cursor on one thread (task 01a174f5 stage 1).

  `last_read_message_id` is a UUIDv7 watermark: every reply with a greater
  id is unseen. Written only by `Platform.Chat.mark_thread_read/3`, which
  only ever moves it forward.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_thread_reads" do
    field(:participant_id, :binary_id)
    field(:thread_id, :binary_id)
    field(:last_read_message_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end
end
