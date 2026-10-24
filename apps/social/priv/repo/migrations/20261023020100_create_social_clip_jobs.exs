defmodule Platform.Repo.Migrations.CreateSocialClipJobs do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234) stage 3: the studio's own job list
  (the htc-clip-tool contract's "render queue"). A human enqueues; a runner
  agent claims a job, reports progress and completes or fails it.

    * `kind` is a plain string with a NAMED CHECK,
      `social_clip_jobs_kind_check` (`new_clip`, `rerender`,
      `save_default`), never a Postgres enum: a later migration drops and
      re-adds the CHECK to open another kind (trim).
    * `status` (`queued` -> `claimed` -> `running` -> `done` | `failed`).
    * `clip_id` is required unless `kind = 'save_default'`.
    * at most one OPEN job (queued, claimed, running) per clip: a partial
      unique index, `social_clip_jobs_one_open_per_clip`.
    * `progress` 0..1, `eta_s` >= 0.
    * `claimed_by_agent_id` (FK agents) and `requested_by_user_id` (FK
      users) nilify on delete; profile and clip deletes delete the job.
  """

  use Ecto.Migration

  def up do
    create table(:social_clip_jobs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:clip_id, references(:social_clips, type: :binary_id, on_delete: :delete_all))
      add(:kind, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:progress, :float)
      add(:eta_s, :integer)
      add(:payload, :map, null: false, default: %{})
      add(:result, :map)
      add(:error, :text)
      add(:claimed_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:claimed_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:requested_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_kind_check,
        check: "kind IN ('new_clip', 'rerender', 'save_default')"
      )
    )

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_status_check,
        check: "status IN ('queued', 'claimed', 'running', 'done', 'failed')"
      )
    )

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_progress_check,
        check: "progress IS NULL OR (progress >= 0 AND progress <= 1)"
      )
    )

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_eta_check,
        check: "eta_s IS NULL OR eta_s >= 0"
      )
    )

    create(
      constraint(:social_clip_jobs, :social_clip_jobs_clip_needed_check,
        check: "clip_id IS NOT NULL OR kind = 'save_default'"
      )
    )

    create(
      unique_index(:social_clip_jobs, [:clip_id],
        where: "status IN ('queued', 'claimed', 'running')",
        name: :social_clip_jobs_one_open_per_clip
      )
    )

    create(index(:social_clip_jobs, [:profile_id, :status, :inserted_at]))
    create(index(:social_clip_jobs, [:clip_id]))
    create(index(:social_clip_jobs, [:claimed_by_agent_id]))
    create(index(:social_clip_jobs, [:requested_by_user_id]))
  end

  def down do
    drop(table(:social_clip_jobs))
  end
end
