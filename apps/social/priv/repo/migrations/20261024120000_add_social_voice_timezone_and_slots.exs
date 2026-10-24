defmodule Platform.Repo.Migrations.AddSocialVoiceTimezoneAndSlots do
  @moduledoc """
  Social authoring 4/11 (task 01a16c4f-9041): a structured home for brand
  voice, the brand's clock, and posting slots.

    * `social_profiles.timezone`: IANA name, default `"Etc/UTC"` (validated
      against the time zone database by the changeset, not the DB).
    * `social_profiles.voice`: jsonb, `Platform.Social.Voice` (`samples`,
      `banned`, `learnings`). Nullable: nil reads as the empty voice.
    * `social_profiles.notify_user_ids`: a subset of `approver_user_ids`
      (checked in `Platform.Social`).
    * `social_profiles.drafting_agent_id`: nullable FK to `agents`,
      nilified when the agent is deleted.
    * `social_accounts.posting_slots`: jsonb list of
      `%{weekday: 1..7, time: "HH:MM"}` in the PROFILE's timezone.
    * `social_accounts.weekly_goal`: nullable integer, 1..100 (named CHECK).

  Additive; `change/0` is reversible (every step is an add or a constraint).
  `voice_notes` stays as the free-text "about this brand".
  """

  use Ecto.Migration

  def change do
    alter table(:social_profiles) do
      add(:timezone, :string, null: false, default: "Etc/UTC")
      add(:voice, :map)
      add(:notify_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:drafting_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:social_profiles, [:drafting_agent_id]))

    alter table(:social_accounts) do
      add(:posting_slots, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:weekly_goal, :integer)
    end

    create(
      constraint(:social_accounts, :social_accounts_weekly_goal_check,
        check: "weekly_goal IS NULL OR (weekly_goal >= 1 AND weekly_goal <= 100)"
      )
    )
  end
end
