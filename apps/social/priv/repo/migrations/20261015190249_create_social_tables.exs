defmodule Platform.Repo.Migrations.CreateSocialTables do
  @moduledoc """
  Social's four tables (task 01a140a8, Social 1/7): profiles, the platform
  accounts under them, the posts drafted for an account, and the clip
  candidates cut from a profile's episodes. One file because the stack
  reserved one migration version for this member (20261015190249).

  `0055-extension-contract-and-build-time-modules.md § 6. Migrations`: a
  module's migration references only stable core tables
  (orgs, projects, users, tasks, meetings, platform_files) and core never
  references a `social_*` table.

  **There is no secret column.** As with `mail_accounts`, a platform
  credential lives in the Vault at scope `{:integration, account.id}`;
  `social_accounts.secret_slug` only names it, and the context sets it.

  `social_posts.approved_by_user_id` references USERS: users and agents are
  separate tables, so the FK refuses an agent id at the database level, and
  a CHECK refuses an approved/scheduled/published post with no approver.
  Additive only: four new tables, no change to an existing one.
  """

  use Ecto.Migration

  def change do
    create table(:social_profiles, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :restrict), null: false)
      add(:project_id, references(:projects, type: :binary_id, on_delete: :nilify_all))
      add(:name, :string, null: false)
      add(:home_url, :string)
      add(:voice_notes, :text)
      add(:default_hashtags, {:array, :string}, null: false, default: [])
      add(:approver_user_ids, {:array, :binary_id}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_profiles, [:org_id, :name]))
    create(index(:social_profiles, [:project_id]))

    create table(:social_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:platform, :string, null: false)
      add(:handle, :string)
      add(:provider, :string)
      add(:provider_account_ref, :string)
      add(:approval_mode, :string, null: false, default: "approve_first")
      add(:secret_slug, :string)
      # Null until the publisher (Social 2/7) has connected the account.
      add(:status, :string)
      add(:archived_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:social_accounts, [:profile_id]))

    create(
      constraint(:social_accounts, :social_accounts_platform_check,
        check: "platform IN ('linkedin', 'x', 'tiktok', 'instagram', 'youtube')"
      )
    )

    create(
      constraint(:social_accounts, :social_accounts_approval_mode_check,
        check: "approval_mode IN ('draft_only', 'approve_first')"
      )
    )

    create(
      constraint(:social_accounts, :social_accounts_status_check,
        check: "status IN ('connected', 'reauth_needed')"
      )
    )

    create table(:social_posts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:social_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:body, :text)
      add(:media_file_ids, {:array, :binary_id}, null: false, default: [])
      add(:link_url, :string)
      add(:scheduled_at, :utc_datetime_usec)
      add(:status, :string, null: false, default: "draft")

      add(:approved_by_user_id, references(:users, type: :binary_id, on_delete: :restrict))

      add(:approved_at, :utc_datetime_usec)
      add(:external_url, :string)
      add(:external_id, :string)
      add(:error, :text)

      add(:task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))
      add(:segment_ids, {:array, :string}, null: false, default: [])
      add(:episode_url, :string)
      add(:start_s, :float)
      add(:end_s, :float)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:social_posts, [:account_id, :status]))
    create(index(:social_posts, [:status, :scheduled_at]))
    create(index(:social_posts, [:approved_by_user_id]))
    create(index(:social_posts, [:task_id]))
    create(index(:social_posts, [:meeting_id]))

    create(
      constraint(:social_posts, :social_posts_status_check,
        check:
          "status IN ('draft', 'needs_approval', 'approved', 'scheduled', 'published', 'failed')"
      )
    )

    create(
      constraint(:social_posts, :social_posts_approved_needs_approver_check,
        check:
          "status NOT IN ('approved', 'scheduled', 'published') OR " <>
            "(approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL)"
      )
    )

    create table(:social_clips, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:profile_id, references(:social_profiles, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:source_url, :string)
      add(:start_s, :float)
      add(:end_s, :float)
      add(:caption, :text)
      add(:speaker, :string)

      add(:render_file_id, references(:platform_files, type: :binary_id, on_delete: :nilify_all))

      add(:status, :string, null: false, default: "candidate")

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:social_clips, [:profile_id]))
    create(index(:social_clips, [:render_file_id]))

    create(
      constraint(:social_clips, :social_clips_status_check,
        check: "status IN ('candidate', 'rendering', 'rendered', 'failed')"
      )
    )

    create(
      constraint(:social_clips, :social_clips_span_check,
        check: "start_s IS NULL OR end_s IS NULL OR end_s > start_s"
      )
    )
  end
end
