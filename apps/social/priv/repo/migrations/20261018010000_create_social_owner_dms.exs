defmodule Platform.Repo.Migrations.CreateSocialOwnerDms do
  @moduledoc """
  The ONE Social system-sender DM per account owner per org (task 01a14ce1,
  stage 3). An owned account's approval card for a post with no drafting
  agent lands in this DM; the unique index on `(org_id, owner_user_id)` is
  the uniqueness guard behind `Platform.Social.Approvals.owner_dm/2`, which
  also takes a transaction-scoped advisory lock, so two concurrent posts
  can never mint two DMs. Core's `Platform.Chat` find-or-create seams are
  check-then-insert and give no such guarantee under concurrency.

  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    create table(:social_owner_dms, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_owner_dms, [:org_id, :owner_user_id]))
    create(index(:social_owner_dms, [:space_id]))
  end
end
