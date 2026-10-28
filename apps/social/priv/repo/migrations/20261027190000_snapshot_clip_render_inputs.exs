defmodule Platform.Repo.Migrations.SnapshotClipRenderInputs do
  @moduledoc """
  Task 01a17e37: Preserves immutable clip render inputs and output metadata so historical versions remain accurate.
  """

  use Ecto.Migration

  def up do
    alter table(:social_clip_renders) do
      add(:requested_start_s, :float)
      add(:requested_end_s, :float)
      add(:actual_start_s, :float)
      add(:actual_end_s, :float)
      add(:headline, :text)
      add(:caption, :text)
      add(:caption_fixes, :map)
      add(:candidate_id, :text)
      add(:alternate_id, :text)
      add(:source, :map)
      add(:duration_s, :float)
      add(:width, :integer)
      add(:height, :integer)
      add(:byte_size, :bigint)
      add(:provenance, :map)
      add(:completion_key, :text)
      add(:snapshot_status, :text, null: false, default: "historical_unknown")
    end

    create(unique_index(:social_clip_renders, [:clip_id, :completion_key]))

    # A file's size is provable; current clip text and timings are not facts
    # about earlier renders. In particular trim was requested, not snapped.
    execute(recover_current_sql())
    execute(backfill_sql())
  end

  # RenderJob used to replace the current file without appending a row.
  # Recover that last output when still available. Prior overwritten outputs
  # cannot be reconstructed. Its inputs remain explicitly unknown.
  def recover_current_sql do
    """
    WITH missing AS (
      SELECT c.*, GREATEST(c.rev, COALESCE((
        SELECT MAX(r.rev) + 1 FROM social_clip_renders r WHERE r.clip_id = c.id
      ), 1)) AS recovered_rev
      FROM social_clips c
      WHERE c.render_file_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM social_clip_renders r
        WHERE r.clip_id = c.id AND r.file_id = c.render_file_id
      )
    ), recovered AS (
      INSERT INTO social_clip_renders
        (id, clip_id, rev, file_id, look, duration_s, width, height, inserted_at, snapshot_status)
      SELECT gen_random_uuid(), id, recovered_rev, render_file_id, '{}',
        duration_s, width, height, COALESCE(rendered_at, inserted_at), 'historical_unknown'
      FROM missing
      RETURNING clip_id, rev
    )
    UPDATE social_clips c SET rev = r.rev FROM recovered r WHERE c.id = r.clip_id
    """
  end

  def backfill_sql do
    """
    UPDATE social_clip_renders r
    SET requested_start_s = trim_in_s, requested_end_s = trim_out_s,
        byte_size = (SELECT f.byte_size FROM platform_files f WHERE f.id = r.file_id)
    WHERE r.snapshot_status = 'historical_unknown'
    """
  end

  def down do
    drop(index(:social_clip_renders, [:clip_id, :completion_key]))

    alter table(:social_clip_renders) do
      remove(:requested_start_s)
      remove(:requested_end_s)
      remove(:actual_start_s)
      remove(:actual_end_s)
      remove(:headline)
      remove(:caption)
      remove(:caption_fixes)
      remove(:candidate_id)
      remove(:alternate_id)
      remove(:source)
      remove(:duration_s)
      remove(:width)
      remove(:height)
      remove(:byte_size)
      remove(:provenance)
      remove(:completion_key)
      remove(:snapshot_status)
    end
  end
end
