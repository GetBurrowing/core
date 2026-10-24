defmodule Platform.Repo.Migrations.CreateSocialIdeasAndPostEvents do
  @moduledoc """
  Social authoring 2/11 (task 01a16c4e): ideas as a record, and the post
  change log.

    * `social_ideas`: one idea becomes one post per account. `org_id` and
      `profile_id` are set by `Platform.Social.Ideas`, never cast.
      `source_kind` has a NAMED CHECK (`social_ideas_source_kind_check`), so
      a later kind is a CHECK change. Exactly one of `created_by_user_id` /
      `created_by_agent_id` is set at write (the changeset); the CHECK
      allows at most one so a deleted user or agent (FK nilify) never
      blocks core's delete. At most one clip idea per clip
      (`social_ideas_one_per_clip`).
    * `social_posts.idea_id`: nullable, indexed, nilified when the idea is
      deleted. No backfill: a post with no idea is its own one-post group.
    * `social_post_events`: who did what to a post (agent, human or system).
      `actor_id` has no FK (a user OR an agent id, nil for system).
      `body_before`/`body_after` are only written for `edited`. Deleting the
      post deletes its events.

  Additive; `down/0` drops exactly what `up/0` adds.
  """

  use Ecto.Migration

  def up do
    create table(:social_ideas, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:title, :string, size: 200, null: false)
      add(:brief, :text)
      add(:source_kind, :string, null: false)
      add(:clip_id, references(:social_clips, type: :binary_id, on_delete: :nilify_all))
      add(:task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))
      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :nilify_all))
      add(:source_url, :text)
      add(:created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:archived_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:social_ideas, [:org_id]))
    create(index(:social_ideas, [:profile_id, :archived_at]))
    create(index(:social_ideas, [:task_id]))
    create(index(:social_ideas, [:meeting_id]))

    create(
      unique_index(:social_ideas, [:clip_id],
        where: "source_kind = 'clip' AND clip_id IS NOT NULL",
        name: :social_ideas_one_per_clip
      )
    )

    create(
      constraint(:social_ideas, :social_ideas_source_kind_check,
        check: "source_kind IN ('human', 'agent', 'chat', 'clip', 'task', 'meeting', 'url')"
      )
    )

    create(
      constraint(:social_ideas, :social_ideas_one_creator_check,
        check: "num_nonnulls(created_by_user_id, created_by_agent_id) <= 1"
      )
    )

    alter table(:social_posts) do
      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:social_posts, [:idea_id]))

    create table(:social_post_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:post_id, references(:social_posts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :nilify_all))
      add(:actor_kind, :string, null: false)
      add(:actor_id, :binary_id)
      add(:action, :string, null: false)
      add(:body_before, :text)
      add(:body_after, :text)
      add(:note, :text)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:social_post_events, [:post_id, :inserted_at]))
    create(index(:social_post_events, [:idea_id]))

    create(
      constraint(:social_post_events, :social_post_events_actor_kind_check,
        check: "actor_kind IN ('agent', 'human', 'system')"
      )
    )

    create(
      constraint(:social_post_events, :social_post_events_action_check,
        check:
          "action IN ('created', 'edited', 'submitted', 'approved', 'rejected', " <>
            "'revision_requested', 'published', 'failed', 'refused')"
      )
    )

    create(
      constraint(:social_post_events, :social_post_events_body_only_for_edited_check,
        check: "action = 'edited' OR (body_before IS NULL AND body_after IS NULL)"
      )
    )
  end

  def down do
    drop(table(:social_post_events))
    drop(index(:social_posts, [:idea_id]))

    alter table(:social_posts) do
      remove(:idea_id)
    end

    drop(table(:social_ideas))
  end
end
