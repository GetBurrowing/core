defmodule Platform.Repo.Migrations.CreateChatMessageAttentions do
  use Ecto.Migration

  @moduledoc """
  Task `01a1557a-a30a-7000-809a-b089740773ea` (Burrow redesign rung 12),
  stage 1: "Get someone's attention" on a message that has already been sent.

  One row per (message, participant) a member asked to look at the message.
  The message row itself is never touched by this feature, so adding
  attention can never write a `chat_message_versions` row or render
  "(edited)". This follows the reactions precedent: a separate table, read
  back onto a virtual field on `Platform.Chat.Message`.

    * `participant_id` / `added_by_participant_id` FK `chat_participants`
      with `on_delete: :nilify_all`, and the display names are snapshotted
      (ADR 0038), so the line still reads after either participant leaves.
    * The unique index on `(message_id, participant_id)` is what makes
      `Chat.add_message_attention/4` idempotent under concurrency: the
      writer inserts with `on_conflict: :nothing`.

  `down/0` drops the table.
  """

  def up do
    create table(:chat_message_attentions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all)
      )

      add(:participant_type, :string, null: false)
      add(:display_name, :string)

      add(
        :added_by_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all)
      )

      add(:added_by_display_name, :string)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:chat_message_attentions, [:message_id, :participant_id],
        name: :chat_message_attentions_message_participant_index
      )
    )

    create(index(:chat_message_attentions, [:participant_id]))
    create(index(:chat_message_attentions, [:added_by_participant_id]))
  end

  def down do
    drop(table(:chat_message_attentions))
  end
end
