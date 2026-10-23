defmodule Platform.Repo.Migrations.AddCoverToSocialPosts do
  @moduledoc """
  A video post's cover (task 01a165ec, stage 2): EITHER an uploaded image
  (`cover_file_id`, a core Files id with no FK into core's tables, the same
  as `media_file_ids`) OR a frame of the video (`cover_offset_ms`), never
  both (`Platform.Social.Cover`). `cover_error` records a cover the
  publisher could not apply after the post went out (YouTube's
  post-publish thumbnail update, stage 3).
  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:cover_file_id, :binary_id)
      add(:cover_offset_ms, :integer)
      add(:cover_error, :text)
    end
  end
end
