defmodule Platform.Repo.Migrations.BindClipApprovalRender do
  @moduledoc """
  Task 01a17e37: Binds clip approval and published posts to the specific render selected by the human approver.
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:clip_render_id, references(:social_clip_renders, type: :uuid, on_delete: :nilify_all))
    end

    alter table(:social_clips) do
      add(
        :reviewed_render_id,
        references(:social_clip_renders, type: :uuid, on_delete: :nilify_all)
      )
    end

    create(index(:social_posts, [:clip_render_id]))
    create(index(:social_clips, [:reviewed_render_id]))
    # Existing approvals predate version selection. Their identity stays unknown;
    # their already-copied post media/body remain authoritative for publishing.
  end
end
