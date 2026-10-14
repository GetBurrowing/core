defmodule Platform.Tenancy.Org do
  @moduledoc """
  Ecto schema for the `orgs` table — two-tier MT/RBAC hierarchy.

  See `Platform.Tenancy` for the context module and `0042-mt-rbac-foundation`
  for the design rationale.

  ## Tiers

    * **Root** — `parent_org_id == nil`. Exactly one row (DB-enforced via
      the `orgs_single_root` partial unique index). Each install names its own.
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

    # OKLCH hue (degrees, 0..359) and chroma for this org's scope colour.
    # Both NULL means "no colour set" — see task 01a09287 and
    # `Platform.Tenancy.ScopeColor`, which solves the label pair from them.
    field(:color_hue, :integer)
    field(:color_chroma, :float)

    # OKLCH lightness of the org's FILL (the dot and the active pill), 0..1
    # exclusive. NULL means the runtime path's default, 72%. Only the six
    # shipped orgs carry one: they shipped at hand-picked fills (65-80%) that
    # no rule reproduces, and since task 01a09333-d374 stage 5 they are
    # coloured from this row. The admin form never writes it, and there is
    # no edit path; one that changes an org's hue must clear this too, or
    # the hand-picked lightness carries over onto a hue it was never
    # measured for.
    field(:color_lightness, :float)

    field(:archived_at, :utc_datetime_usec)
    field(:deletion_scheduled_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Validates `name` and `slug` presence + slug format.

  `color_hue` is bounded to 0..359 here AND by the `orgs_color_hue_range`
  CHECK constraint; the two are separate guards, and only the constraint
  survives a raw insert that bypasses this changeset. `color_lightness` is
  bounded to (0, 1) the same two ways (`orgs_color_lightness_range`).

  Slugs are lowercase, must start with a letter, and may contain letters,
  digits, hyphens, and underscores. Matches the convention used by
  `task_stacks` and similar resources.
  """
  def changeset(org, attrs) do
    org
    |> cast(attrs, [
      :name,
      :slug,
      :parent_org_id,
      :color_hue,
      :color_chroma,
      :color_lightness,
      :archived_at,
      :deletion_scheduled_at
    ])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, @slug_format,
      message: "must start with a lowercase letter and contain only [a-z0-9_-]"
    )
    |> validate_number(:color_hue, greater_than_or_equal_to: 0, less_than: 360)
    |> validate_number(:color_lightness, greater_than: 0, less_than: 1)
    |> unique_constraint(:slug)
    |> check_constraint(:color_hue,
      name: :orgs_color_hue_range,
      message: "must be between 0 and 359"
    )
    |> check_constraint(:color_lightness,
      name: :orgs_color_lightness_range,
      message: "must be between 0 and 1, exclusive"
    )
    |> foreign_key_constraint(:parent_org_id)
  end
end
