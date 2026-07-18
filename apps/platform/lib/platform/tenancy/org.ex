defmodule Platform.Tenancy.Org do
  @moduledoc """
  Ecto schema for the `orgs` table — two-tier MT/RBAC hierarchy.

  See `Platform.Tenancy` for the context module and `0042-mt-rbac-foundation`
  for the design rationale.

  ## Tiers

    * **Root** — `parent_org_id == nil`. Exactly one row (DB-enforced via
      the `orgs_single_root` partial unique index). For Suite, this is Fabrikam.
    * **Tenant** — `parent_org_id == root.id`. One row per tenant (Soylent,
      Wayne-Tech, SXI, Paragon, etc.).

  The `Platform.Org` namespace is the legacy single-org memory/context
  system — do not confuse the two. This module lives under
  `Platform.Tenancy.*` for that reason.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z][a-z0-9_-]*$/

  schema "orgs" do
    field(:name, :string)
    field(:slug, :string)

    belongs_to(:parent_org, __MODULE__, foreign_key: :parent_org_id)

    field(:archived_at, :utc_datetime_usec)
    field(:deletion_scheduled_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Validates `name` and `slug` presence + slug format.

  Slugs are lowercase, must start with a letter, and may contain letters,
  digits, hyphens, and underscores. Matches the convention used by
  `task_stacks` and similar resources.
  """
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug, :parent_org_id, :archived_at, :deletion_scheduled_at])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, @slug_format,
      message: "must start with a lowercase letter and contain only [a-z0-9_-]"
    )
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:parent_org_id)
  end
end
