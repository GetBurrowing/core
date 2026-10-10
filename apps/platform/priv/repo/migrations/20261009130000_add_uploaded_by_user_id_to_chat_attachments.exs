defmodule Platform.Repo.Migrations.AddUploadedByUserIdToChatAttachments do
  @moduledoc """
  Task 01a120be stage 2: a user's chunked large-file upload reserves a
  `chat_attachments` row before any byte moves. The uploader is a column, not
  a metadata key, because ownership is what authorizes cancel and what the
  reaper and audit queries filter on (architect note on plan 01a120c2).
  Nullable: agent reservations and every existing row have no user uploader.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_attachments) do
      add(:uploaded_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:chat_attachments, [:uploaded_by_user_id]))
  end
end
