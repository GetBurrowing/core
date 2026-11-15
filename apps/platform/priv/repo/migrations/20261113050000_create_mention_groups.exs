defmodule Platform.Repo.Migrations.CreateMentionGroups do
  use Ecto.Migration
  # old-code-compatible: additive tables and server-owned snapshots only.
  def change do
    create table(:mention_groups, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:name, :string, null: false)
      add(:normalized_name, :string, null: false)
      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:mention_groups, [:org_id, :normalized_name],
        where: "deleted_at IS NULL",
        name: :mention_groups_active_name_index
      )
    )

    create table(:mention_group_members, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:group_id, references(:mention_groups, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all))
    end

    create(
      constraint(:mention_group_members, :mention_group_members_one_principal,
        check: "(user_id IS NOT NULL)::integer + (agent_id IS NOT NULL)::integer = 1"
      )
    )

    create(
      unique_index(:mention_group_members, [:group_id, :user_id], where: "user_id IS NOT NULL")
    )

    create(
      unique_index(:mention_group_members, [:group_id, :agent_id], where: "agent_id IS NOT NULL")
    )

    # Even an empty resolution is final: edits/retries cannot expand it later.
    create table(:chat_message_group_snapshots, primary_key: false) do
      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )
    end

    create table(:chat_message_mention_groups, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:group_id, :binary_id, null: false)
      add(:name, :text, null: false)
    end

    create(unique_index(:chat_message_mention_groups, [:message_id, :group_id]))

    create table(:chat_message_group_recipients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:principal_type, :string, null: false)
      # Deliberately no principal/participant FK: removal cannot erase the
      # original identity, or make a replacement participant an old recipient.
      add(:principal_id, :binary_id, null: false)
      add(:participant_id, :binary_id, null: false)
      add(:group_ids, {:array, :binary_id}, null: false)
    end

    create(
      constraint(:chat_message_group_recipients, :chat_message_group_recipients_type,
        check: "principal_type IN ('user', 'agent')"
      )
    )

    create(
      unique_index(:chat_message_group_recipients, [:message_id, :principal_type, :principal_id],
        name: :chat_message_group_recipients_identity_index
      )
    )

    create(index(:chat_message_group_recipients, [:participant_id, :message_id]))
  end
end
