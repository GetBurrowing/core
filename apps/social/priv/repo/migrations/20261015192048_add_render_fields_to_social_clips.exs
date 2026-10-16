defmodule Platform.Repo.Migrations.AddRenderFieldsToSocialClips do
  @moduledoc """
  The clip pipeline's columns (task 01a140a9-69b7, Social 5/7). The version,
  20261015192048, is the one the task router reserved for this member.

  `social_clips` gains:

    * the second source kind: `source_file_id` (a video in core's Files) and
      `transcript_file_id` (its VTT, SRT or JSON transcript). Both reference
      `platform_files` with `nilify_all`, like member 1's `render_file_id`.
      A CHECK keeps EXACTLY ONE of `source_url` / `source_file_id` set, so a
      clip always names where its footage comes from, and never two places.
    * `requested_start_s` / `requested_end_s`: the agent's original times.
      `start_s` / `end_s` become the sentence-snapped ones the render used.
    * what the render produced: `duration_s`, `width`, `height`, `byte_size`
      (`platform_files` stores no duration or dimensions, so the clip row is
      where member 2's MediaRules finds them).
    * `platforms`: the targets checked against MediaRules at render time.
    * `crop_x`: the static v1 crop centre, 0..1 (CHECK), default the middle.
    * `error`, `attempts`, `render_started_at`, `rendered_at`: the render
      queue's bookkeeping.

  `social_profiles` gains `brand` (jsonb, default `{}`): per-profile caption
  and end-card values that `Platform.Social.Brand` merges over placeholders.

  Additive: new nullable or defaulted columns plus CHECKs. The one-source
  CHECK assumes every existing clip names a `source_url`; the stack has not
  shipped, so no production row predates it.
  """

  use Ecto.Migration

  def change do
    alter table(:social_clips) do
      add(:source_file_id, references(:platform_files, type: :binary_id, on_delete: :nilify_all))

      add(
        :transcript_file_id,
        references(:platform_files, type: :binary_id, on_delete: :nilify_all)
      )

      add(:requested_start_s, :float)
      add(:requested_end_s, :float)
      add(:duration_s, :float)
      add(:width, :integer)
      add(:height, :integer)
      add(:byte_size, :bigint)
      add(:platforms, {:array, :string}, null: false, default: [])
      add(:crop_x, :float, null: false, default: 0.5)
      add(:error, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:render_started_at, :utc_datetime_usec)
      add(:rendered_at, :utc_datetime_usec)
    end

    create(index(:social_clips, [:source_file_id]))
    create(index(:social_clips, [:transcript_file_id]))
    create(index(:social_clips, [:status]))

    create(
      constraint(:social_clips, :social_clips_one_source_check,
        check: "num_nonnulls(source_url, source_file_id) = 1"
      )
    )

    create(
      constraint(:social_clips, :social_clips_crop_x_check, check: "crop_x >= 0 AND crop_x <= 1")
    )

    alter table(:social_profiles) do
      add(:brand, :map, null: false, default: %{})
    end
  end
end
