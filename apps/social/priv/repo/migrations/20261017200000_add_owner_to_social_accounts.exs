defmodule Platform.Repo.Migrations.AddOwnerToSocialAccounts do
  @moduledoc """
  The person an account posts as (task 01a14ce1, stage 1): a nullable
  `owner_user_id` on `social_accounts`. NULL means the account belongs to
  the profile and any profile approver may approve its posts; a set owner
  means only that user may (`Platform.Social.post_approver_check/4`).
  Archiving the owner leaves the column set, so their posts are not handed
  to the profile approvers; only a hard delete (users are never hard-deleted)
  nilifies it.
  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    alter table(:social_accounts) do
      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:social_accounts, [:owner_user_id]))
  end
end
