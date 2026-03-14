defmodule Platform.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    # ── chat_spaces ─────────────────────────────────────────────────────────────
    create table(:chat_spaces, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:workspace_id, :binary_id)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:description, :text)
      add(:kind, :string, null: false, default: "channel")
      add(:topic, :text)
      add(:metadata, :map, default: %{})
      add(:archived_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:chat_spaces, [:workspace_id, :slug], name: :chat_spaces_unique_slug)
    )

    # ── chat_participants ────────────────────────────────────────────────────────
    create table(:chat_participants, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:participant_type, :string, null: false)
      add(:participant_id, :binary_id, null: false)
      add(:role, :string, null: false, default: "member")
      add(:display_name, :string)
      add(:avatar_url, :string)
      add(:last_read_message_id, :bigint)
      add(:attention_mode, :string, default: "mention")
      add(:attention_config, :map, default: %{})
      add(:joined_at, :utc_datetime_usec, null: false)
      add(:left_at, :utc_datetime_usec)
    end

    create(
      unique_index(
        :chat_participants,
        [:space_id, :participant_type, :participant_id],
        name: :chat_participants_unique
      )
    )

    # ── chat_threads ─────────────────────────────────────────────────────────────
    # parent_message_id is added as a plain bigint here (no FK yet — messages table
    # does not exist yet). The FK constraint is added below after chat_messages.
    create table(:chat_threads, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:parent_message_id, :bigint)
      add(:title, :string)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    # ── chat_messages ────────────────────────────────────────────────────────────
    # Uses bigserial (integer) PK — NOT UUID.
    create table(:chat_messages) do
      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:thread_id, references(:chat_threads, type: :binary_id, on_delete: :nilify_all))

      add(
        :participant_id,
        references(:chat_participants, type: :binary_id),
        null: false
      )

      add(:content_type, :string, null: false, default: "text")
      add(:content, :text)
      add(:structured_content, :map, default: %{})
      add(:metadata, :map, default: %{})
      add(:edited_at, :utc_datetime_usec)
      add(:deleted_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:chat_messages, [:space_id, :id], order: [id: :desc], name: :chat_messages_space_idx))
    create(index(:chat_messages, [:thread_id, :id], order: [id: :desc]))
    create(index(:chat_messages, [:participant_id]))

    execute(
      "ALTER TABLE chat_messages ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED"
    )

    execute("CREATE INDEX idx_chat_messages_search ON chat_messages USING gin(search_vector)")

    # ── chat_attachments ──────────────────────────────────────────────────────────
    # message_id references the integer PK of chat_messages — type :id (bigint).
    create table(:chat_attachments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:message_id, references(:chat_messages, on_delete: :delete_all), null: false)
      add(:filename, :string, null: false)
      add(:content_type, :string, null: false)
      add(:byte_size, :bigint, null: false)
      add(:storage_key, :string, null: false)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    # ── chat_reactions ────────────────────────────────────────────────────────────
    create table(:chat_reactions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:message_id, references(:chat_messages, on_delete: :delete_all), null: false)

      add(
        :participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:emoji, :string, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(
        :chat_reactions,
        [:message_id, :participant_id, :emoji],
        name: :chat_reactions_unique
      )
    )

    # ── chat_pins ─────────────────────────────────────────────────────────────────
    create table(:chat_pins, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:message_id, references(:chat_messages, on_delete: :delete_all), null: false)

      add(
        :pinned_by,
        references(:chat_participants, type: :binary_id),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # ── chat_canvases ─────────────────────────────────────────────────────────────
    create table(:chat_canvases, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:message_id, references(:chat_messages, on_delete: :nilify_all))

      add(
        :created_by,
        references(:chat_participants, type: :binary_id),
        null: false
      )

      add(:title, :string)
      add(:canvas_type, :string, null: false)
      add(:state, :map, default: %{})
      add(:component_module, :string)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    # ── Deferred FK: chat_threads.parent_message_id -> chat_messages ──────────────
    alter table(:chat_threads) do
      modify(:parent_message_id, references(:chat_messages, on_delete: :nilify_all))
    end
  end
end
