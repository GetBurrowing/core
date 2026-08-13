defmodule Platform.Repo.Migrations.CreateOrgGroupClaims do
  @moduledoc """
  Create `org_group_claims` — the IdP group-claim value → org mapping that
  `Platform.Tenancy.resolve_org_from_groups/1` reads.

  Admitted by task 019ff7ff-ef10-7f6f-886e-a920f8e0189a stage 1. The
  mapping lives in the database rather than application config so that
  adding a client never requires a deploy. The unique index on
  `claim_value` enforces that one group value can never name two orgs.
  """

  use Ecto.Migration

  def change do
    create table(:org_group_claims, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, on_delete: :delete_all, type: :binary_id), null: false)
      add(:claim_value, :string, null: false)

      timestamps()
    end

    # One group value cannot name two orgs — the resolver's ambiguity case
    # exists for two DISTINCT values pointing at two orgs, never for one
    # value pointing at two.
    create(unique_index(:org_group_claims, [:claim_value]))
    create(index(:org_group_claims, [:org_id]))
  end
end
