defmodule Platform.Repo.Migrations.LinkSocialPostsToClips do
  @moduledoc """
  Clip Studio 2/9, stage 1 (task 01a16662). Links a post to the clip it
  publishes and records what happened at the vendor:

    * `clip_id` - the clip this post publishes (FK `social_clips`, nilified
      when the clip is deleted, indexed);
    * `platform_post_id` - the platform's own id for the post, read from the
      vendor's per-account entry (`external_id` stays the vendor's post id);
    * `publish_after` - the end of the server-side undo window (written by a
      later stage); NULL means no window;
    * `publish_attempts` - one per adapter call, success or failure, never
      negative (`social_posts_publish_attempts_check`);
    * `published_at` - when the post moved to `published`.

  All are read-only to agents. Additive; `down/0` drops exactly what `up/0`
  adds.
  """

  use Ecto.Migration

  def up do
    alter table(:social_posts) do
      add(:clip_id, references(:social_clips, type: :binary_id, on_delete: :nilify_all))
      add(:platform_post_id, :string)
      add(:publish_after, :utc_datetime_usec)
      add(:publish_attempts, :integer, null: false, default: 0)
      add(:published_at, :utc_datetime_usec)
    end

    create(index(:social_posts, [:clip_id]))

    create(
      constraint(:social_posts, :social_posts_publish_attempts_check,
        check: "publish_attempts >= 0"
      )
    )
  end

  def down do
    drop(constraint(:social_posts, :social_posts_publish_attempts_check))
    drop(index(:social_posts, [:clip_id]))

    alter table(:social_posts) do
      remove(:published_at)
      remove(:publish_attempts)
      remove(:publish_after)
      remove(:platform_post_id)
      remove(:clip_id)
    end
  end
end
