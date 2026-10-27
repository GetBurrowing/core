defmodule Platform.Repo.Migrations.AddEpisodeClipJobs do
  @moduledoc "Automatic source-level clip jobs and durable discovery activation (task 01a17e37)."
  use Ecto.Migration

  def up do
    create table(:social_episode_pipelines, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:version, :string, null: false)
      add(:activated_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_episode_pipelines, [:profile_id, :version]))

    alter table(:social_clip_jobs) do
      add(:source_file_id, references(:platform_files, type: :binary_id, on_delete: :delete_all))

      add(
        :episode_pipeline_id,
        references(:social_episode_pipelines, type: :binary_id, on_delete: :delete_all)
      )
    end

    drop(constraint(:social_clip_jobs, :social_clip_jobs_kind_check))

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_kind_check,
        check: "kind IN ('new_clip', 'rerender', 'save_default', 'episode')"
      )
    )

    drop(constraint(:social_clip_jobs, :social_clip_jobs_clip_needed_check))

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_clip_needed_check,
        check: "clip_id IS NOT NULL OR kind IN ('save_default', 'episode')"
      )
    )

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_episode_source_check,
        check:
          "(kind = 'episode' AND source_file_id IS NOT NULL AND episode_pipeline_id IS NOT NULL AND clip_id IS NULL AND requested_by_user_id IS NULL) OR (kind <> 'episode' AND source_file_id IS NULL AND episode_pipeline_id IS NULL)"
      )
    )

    create(
      unique_index(:social_clip_jobs, [:profile_id, :source_file_id, :episode_pipeline_id],
        name: :social_clip_jobs_one_per_episode
      )
    )
  end

  def down do
    # A rollback cannot represent source jobs in the old contract.
    execute("DELETE FROM social_clip_jobs WHERE kind = 'episode'")

    drop(
      index(:social_clip_jobs, [:profile_id, :source_file_id, :episode_pipeline_id],
        name: :social_clip_jobs_one_per_episode
      )
    )

    drop(constraint(:social_clip_jobs, :social_clip_jobs_episode_source_check))
    drop(constraint(:social_clip_jobs, :social_clip_jobs_kind_check))

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_kind_check,
        check: "kind IN ('new_clip', 'rerender', 'save_default')"
      )
    )

    drop(constraint(:social_clip_jobs, :social_clip_jobs_clip_needed_check))

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_clip_needed_check,
        check: "clip_id IS NOT NULL OR kind = 'save_default'"
      )
    )

    alter table(:social_clip_jobs) do
      remove(:episode_pipeline_id)
      remove(:source_file_id)
    end

    drop(table(:social_episode_pipelines))
  end
end
