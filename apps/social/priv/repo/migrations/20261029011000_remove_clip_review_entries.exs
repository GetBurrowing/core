defmodule Platform.Repo.Migrations.RemoveClipReviewEntries do
  @moduledoc """
  Task 01a1851b: records human removal of clips and render versions while
  retaining immutable identities, post references and stored media.
  """
  use Ecto.Migration

  def change do
    for table <- [:social_clips, :social_clip_renders] do
      alter table(table) do
        add(:removed_at, :utc_datetime_usec)
        add(:removed_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      end
    end
  end
end
