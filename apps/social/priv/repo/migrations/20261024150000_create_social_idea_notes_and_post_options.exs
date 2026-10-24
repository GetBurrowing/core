defmodule Platform.Repo.Migrations.CreateSocialIdeaNotesAndPostOptions do
  @moduledoc """
  Social authoring 7/11 (task 01a16c50-ea67): the Ideas tab.

    * `social_idea_notes`: the idea's thread, for humans and agents.
      `author_kind` has a NAMED CHECK (`social_idea_notes_author_kind_check`).
      `author_id` has no FK (a user OR an agent id). The body is at most
      4,000 characters (`social_idea_notes_body_length_check`). Deleting the
      idea deletes its notes.
    * `social_posts.platform_options`: the per-platform options a human sets
      on a version (first comment, alt text, YouTube title), only the keys
      `Platform.Social.PlatformOptions` allows for the account's platform.
      Default `{}`.

  Additive; `down/0` drops exactly what `up/0` adds.
  """

  use Ecto.Migration

  def up do
    create table(:social_idea_notes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:author_kind, :string, null: false)
      add(:author_id, :binary_id)
      add(:body, :text, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:social_idea_notes, [:idea_id, :inserted_at]))

    create(
      constraint(:social_idea_notes, :social_idea_notes_author_kind_check,
        check: "author_kind IN ('human', 'agent')"
      )
    )

    create(
      constraint(:social_idea_notes, :social_idea_notes_body_length_check,
        check: "char_length(body) BETWEEN 1 AND 4000"
      )
    )

    alter table(:social_posts) do
      add(:platform_options, :map, null: false, default: %{})
    end
  end

  def down do
    alter table(:social_posts) do
      remove(:platform_options)
    end

    drop(table(:social_idea_notes))
  end
end
