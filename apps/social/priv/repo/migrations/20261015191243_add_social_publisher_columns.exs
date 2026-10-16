defmodule Platform.Repo.Migrations.AddSocialPublisherColumns do
  @moduledoc """
  The columns the publisher needs (task 01a140a9, Social 2/7). Version
  20261015191243 is the one the stack reserved for this member.

    * `social_posts.is_aigc` / `ai_disclosure` / `generated_by_agent_id`: the
      AI-disclosure flags sent to each platform. `generated_by_agent_id`
      references `agents` (nilify on delete); the changeset forces `is_aigc`
      on while it is set.
    * `social_posts.media_meta`: per-file media facts core's `platform_files`
      does not carry (`duration_s`, `width`, `height`), keyed by file id.
      Read by `Platform.Social.MediaRules` before any vendor call.
    * `social_accounts.platform_account_type`: personal | business | creator
      (Instagram Reels need business or creator).
    * `social_profiles.provider_profile_ref`: the vendor's profile or
      workspace id, needed to start an account connection.

  Still no secret column: credentials and webhook secrets live in the Vault.
  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:is_aigc, :boolean, null: false, default: false)
      add(:ai_disclosure, :text)
      add(:generated_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:media_meta, :map, null: false, default: %{})
    end

    create(index(:social_posts, [:generated_by_agent_id]))
    # The webhook finds a post by the vendor's id.
    create(index(:social_posts, [:external_id]))

    alter table(:social_accounts) do
      add(:platform_account_type, :string)
    end

    create(
      constraint(:social_accounts, :social_accounts_platform_account_type_check,
        check: "platform_account_type IN ('personal', 'business', 'creator')"
      )
    )

    alter table(:social_profiles) do
      add(:provider_profile_ref, :string)
    end
  end
end
