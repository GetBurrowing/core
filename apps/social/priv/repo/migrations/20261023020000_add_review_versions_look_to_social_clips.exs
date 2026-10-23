defmodule Platform.Repo.Migrations.AddReviewVersionsLookToSocialClips do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234): a clip's review state, its render
  versions, its look, and the show default it starts from.

  `social_clips` gains:

    * `title`, `episode_code`: nullable. Under the clip tool's
      `[privacy] mode = "local"` nothing transcript-derived arrives.
    * `origin` (`burrow` | `external`, CHECK) and `source_label`. An external
      clip was rendered outside Burrow (htc-clip-tool) and names no footage,
      so `social_clips_one_source_check` is replaced by an origin-aware one.
    * the review state: `review_status` (`pending` | `approved` | `rejected`,
      CHECK, NULL = never rendered), `review_note`, `reviewed_by_user_id`
      (FK users, nilified), `reviewed_at`. Approved or rejected needs
      `reviewed_at` (CHECK); rejected needs a non-blank note (CHECK). The
      reviewer is NOT in a CHECK: its FK nilifies on user delete, so such a
      CHECK would block deleting the user. `Clip.review_changeset` requires it.
    * `submitted_by_agent_id` (FK agents, nilified).
    * `rev` (>= 1), `look` (jsonb, `{}`), `trim_in_s` / `trim_out_s` (source
      seconds; in >= 0, out after in when both are set).

  Existing rendered clips are backfilled to review `pending`.

  `social_profiles` gains `show_look` (jsonb, `{}`).

  `social_clip_renders` keeps one row per rendered rev of a clip (unique
  `(clip_id, rev)`), backfilled with a rev-1 row for each clip that already
  has a render file.

  The down restores `social_clips_one_source_check` exactly as
  20261015192048 defined it. It fails if an external clip exists, since
  such a row has no source; delete those first.
  """

  use Ecto.Migration

  def up do
    alter table(:social_clips) do
      add(:title, :string)
      add(:episode_code, :string)
      add(:origin, :string, null: false, default: "burrow")
      add(:source_label, :string)
      add(:review_status, :string)
      add(:review_note, :text)
      add(:reviewed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:reviewed_at, :utc_datetime_usec)
      add(:submitted_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:rev, :integer, null: false, default: 1)
      add(:look, :map, null: false, default: %{})
      add(:trim_in_s, :float)
      add(:trim_out_s, :float)
    end

    create(index(:social_clips, [:profile_id, :review_status, :inserted_at]))
    create(index(:social_clips, [:reviewed_by_user_id]))
    create(index(:social_clips, [:submitted_by_agent_id]))

    create(
      constraint(:social_clips, :social_clips_origin_check,
        check: "origin IN ('burrow', 'external')"
      )
    )

    create(
      constraint(:social_clips, :social_clips_review_status_check,
        check: "review_status IS NULL OR review_status IN ('pending', 'approved', 'rejected')"
      )
    )

    create(constraint(:social_clips, :social_clips_rev_check, check: "rev >= 1"))

    create(
      constraint(:social_clips, :social_clips_trim_check,
        check:
          "(trim_in_s IS NULL OR trim_in_s >= 0) AND " <>
            "(trim_in_s IS NULL OR trim_out_s IS NULL OR trim_out_s > trim_in_s)"
      )
    )

    drop(constraint(:social_clips, :social_clips_one_source_check))

    create(
      constraint(:social_clips, :social_clips_one_source_check,
        check:
          "(origin <> 'external' OR (source_url IS NULL AND source_file_id IS NULL)) AND " <>
            "(origin <> 'burrow' OR num_nonnulls(source_url, source_file_id) = 1)"
      )
    )

    create(
      constraint(:social_clips, :social_clips_review_needs_reviewer_check,
        check:
          "review_status IS NULL OR review_status NOT IN ('approved', 'rejected') OR " <>
            "reviewed_at IS NOT NULL"
      )
    )

    create(
      constraint(:social_clips, :social_clips_reject_needs_note_check,
        check: "review_status IS DISTINCT FROM 'rejected' OR btrim(coalesce(review_note, '')) <> ''"
      )
    )

    execute("UPDATE social_clips SET review_status = 'pending' WHERE status = 'rendered'")

    alter table(:social_profiles) do
      add(:show_look, :map, null: false, default: %{})
    end

    create table(:social_clip_renders, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:clip_id, references(:social_clips, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:rev, :integer, null: false)
      add(:file_id, references(:platform_files, type: :binary_id, on_delete: :nilify_all))
      add(:look, :map, null: false, default: %{})
      add(:trim_in_s, :float)
      add(:trim_out_s, :float)
      add(:submitted_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:social_clip_renders, [:clip_id, :rev]))
    create(index(:social_clip_renders, [:file_id]))
    create(index(:social_clip_renders, [:submitted_by_agent_id]))

    execute("""
    INSERT INTO social_clip_renders
      (id, clip_id, rev, file_id, look, trim_in_s, trim_out_s, submitted_by_agent_id, inserted_at)
    SELECT gen_random_uuid(), c.id, 1, c.render_file_id, c.look, c.trim_in_s, c.trim_out_s,
           c.submitted_by_agent_id, coalesce(c.rendered_at, c.updated_at)
    FROM social_clips c
    WHERE c.render_file_id IS NOT NULL
    """)
  end

  def down do
    drop(table(:social_clip_renders))

    alter table(:social_profiles) do
      remove(:show_look)
    end

    drop(constraint(:social_clips, :social_clips_reject_needs_note_check))
    drop(constraint(:social_clips, :social_clips_review_needs_reviewer_check))
    drop(constraint(:social_clips, :social_clips_one_source_check))

    create(
      constraint(:social_clips, :social_clips_one_source_check,
        check: "num_nonnulls(source_url, source_file_id) = 1"
      )
    )

    drop(constraint(:social_clips, :social_clips_trim_check))
    drop(constraint(:social_clips, :social_clips_rev_check))
    drop(constraint(:social_clips, :social_clips_review_status_check))
    drop(constraint(:social_clips, :social_clips_origin_check))

    drop(index(:social_clips, [:submitted_by_agent_id]))
    drop(index(:social_clips, [:reviewed_by_user_id]))
    drop(index(:social_clips, [:profile_id, :review_status, :inserted_at]))

    alter table(:social_clips) do
      remove(:trim_out_s)
      remove(:trim_in_s)
      remove(:look)
      remove(:rev)
      remove(:submitted_by_agent_id)
      remove(:reviewed_at)
      remove(:reviewed_by_user_id)
      remove(:review_status)
      remove(:review_note)
      remove(:source_label)
      remove(:origin)
      remove(:episode_code)
      remove(:title)
    end
  end
end
