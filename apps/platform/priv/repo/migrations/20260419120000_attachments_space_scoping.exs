defmodule Platform.Repo.Migrations.AttachmentsSpaceScoping do
  @moduledoc "ADR 0039 phase 1a: space-scope chat_attachments, relax message_id NOT NULL."

  use Ecto.Migration

  def up do
    alter table(:chat_attachments) do
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :nilify_all))
      add(:uploaded_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:content_hash, :string, size: 64)
      add(:state, :string, size: 16, default: "ready", null: false)
      add(:upload_expires_at, :utc_datetime_usec)
    end

    execute("ALTER TABLE chat_attachments ALTER COLUMN message_id DROP NOT NULL")

    flush()

    execute("""
    UPDATE chat_attachments a
    SET space_id = m.space_id
    FROM chat_messages m
    WHERE a.message_id = m.id
      AND a.space_id IS NULL
    """)

    create(index(:chat_attachments, [:space_id]))

    create(
      index(:chat_attachments, [:canvas_id],
        where: "canvas_id IS NOT NULL",
        name: :chat_attachments_canvas_id_idx
      )
    )

    create(
      index(:chat_attachments, [:space_id, :content_hash],
        where: "content_hash IS NOT NULL AND state = 'ready'",
        name: :chat_attachments_space_content_hash_idx
      )
    )
  end

  def down do
    drop_if_exists(
      index(:chat_attachments, [:space_id, :content_hash],
        name: :chat_attachments_space_content_hash_idx
      )
    )

    drop_if_exists(
      index(:chat_attachments, [:canvas_id], name: :chat_attachments_canvas_id_idx)
    )

    drop_if_exists(index(:chat_attachments, [:space_id]))

    execute("ALTER TABLE chat_attachments ALTER COLUMN message_id SET NOT NULL")

    alter table(:chat_attachments) do
      remove(:upload_expires_at)
      remove(:state)
      remove(:content_hash)
      remove(:uploaded_by_agent_id)
      remove(:canvas_id)
      remove(:space_id)
    end
  end
end
