defmodule Platform.Repo.Migrations.UniqueSocialAccountProviderRef do
  @moduledoc """
  One vendor account id maps to one live account row (task 01a14807).

  Zernio's account ids (`_id`) are install-wide, so the index is not scoped
  to a profile: a partial unique index on `social_accounts.provider_account_ref`
  over rows that hold a ref and are not archived. An archived row keeps its
  ref for history and does not block a reconnect. Every existing row has a
  NULL ref (nothing wrote one before this task), so the index builds on
  existing data. `Platform.Social`'s connect changeset carries the matching
  `unique_constraint/3`, which turns a collision into `{:error, :ref_in_use}`.
  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    create(
      unique_index(:social_accounts, [:provider_account_ref],
        name: :social_accounts_provider_account_ref_live_index,
        where: "provider_account_ref IS NOT NULL AND archived_at IS NULL"
      )
    )
  end
end
