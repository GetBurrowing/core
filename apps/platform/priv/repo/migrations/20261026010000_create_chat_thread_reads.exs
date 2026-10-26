defmodule Platform.Repo.Migrations.CreateChatThreadReads do
  use Ecto.Migration

  @moduledoc """
  Task `01a174f5-1ee2-7000-b2b8-f2c54e656fa7`, stage 1: a per-thread read
  cursor, so the main log can show "↳ N new replies to …" for a thread the
  viewer has not opened since its latest reply.

  One row per (participant, thread). `last_read_message_id` is a UUIDv7
  watermark compared the way `chat_participants.last_read_message_id` is.
  The unique index on `(participant_id, thread_id)` is what lets
  `Chat.mark_thread_read/3` upsert.

  BACKFILL. Without it every existing thread would read as new for every
  member on deploy. Each existing participant gets a cursor at the newest
  non-deleted reply of every thread in its space. Ids are minted in SQL as
  UUIDv7 (millisecond clock in the first 48 bits, version nibble 7) because
  PostgreSQL 16 has no `uuidv7()`.

  `down/0` drops the table.
  """

  def up do
    create table(:chat_thread_reads, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:thread_id, references(:chat_threads, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:last_read_message_id, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:chat_thread_reads, [:participant_id, :thread_id],
        name: :chat_thread_reads_participant_thread_index
      )
    )

    create(index(:chat_thread_reads, [:thread_id]))

    execute("""
    INSERT INTO chat_thread_reads
      (id, participant_id, thread_id, last_read_message_id, inserted_at, updated_at)
    SELECT
      encode(
        set_bit(
          set_bit(
            overlay(uuid_send(gen_random_uuid())
              placing substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
              FROM 1 FOR 6),
            52, 1),
          53, 1),
        'hex')::uuid,
      p.id,
      t.thread_id,
      t.max_reply_id,
      now(),
      now()
    FROM (
      SELECT m.space_id, m.thread_id, max(m.id::text)::uuid AS max_reply_id
      FROM chat_messages m
      WHERE m.thread_id IS NOT NULL AND m.deleted_at IS NULL
      GROUP BY m.space_id, m.thread_id
    ) t
    JOIN chat_participants p ON p.space_id = t.space_id
    ON CONFLICT (participant_id, thread_id) DO NOTHING
    """)
  end

  def down do
    drop(table(:chat_thread_reads))
  end
end
