defmodule Platform.Repo.Migrations.CreateSocialTaskRequests do
  @moduledoc """
  The meeting/chat to social task bridge (task 01a140a9-831e, Social 6/7).
  The version, 20261015193031, is the one the stack's router reserved for
  this member (the plan's 20261016070000 was superseded by the router).

  `social_task_requests` is one row per social task Social filed (or
  adopted from the live meeting pipeline):

    * `profile_id` (`delete_all`) and `task_id` (`delete_all`, UNIQUE): a
      task carries at most one social request.
    * `request_key` (UNIQUE): sha256 of the profile id, the canonical sorted
      refs and the sorted platforms, so a repeated ask is idempotent.
    * `platforms`, `refs` and `ask`: what was asked for, and from where
      (`meeting_id` + `segment_ids`, or `episode_url` + `start_s`/`end_s`).
    * `requested_by_agent_id` and `requested_in_space_id` (`nilify_all`):
      who asked and in which space; the space comes from the tool context,
      never from tool arguments.
    * `adopted_candidate_id`: the meeting candidate whose already-filed task
      was adopted. No FK: candidates are a core table whose shape is not
      stable.
    * `settled_digest` / `settled_at`: the write-back record's digest, so a
      replayed settlement writes nothing.
  """

  use Ecto.Migration

  def change do
    create table(:social_task_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false)
      add(:request_key, :text, null: false)
      add(:platforms, {:array, :string}, null: false)
      add(:refs, :map, null: false)
      add(:ask, :text)

      add(
        :requested_by_agent_id,
        references(:agents, type: :binary_id, on_delete: :nilify_all)
      )

      add(
        :requested_in_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :nilify_all)
      )

      add(:adopted_candidate_id, :binary_id)
      add(:settled_digest, :text)
      add(:settled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_task_requests, [:task_id]))
    create(unique_index(:social_task_requests, [:request_key]))
    create(index(:social_task_requests, [:profile_id]))
  end
end
