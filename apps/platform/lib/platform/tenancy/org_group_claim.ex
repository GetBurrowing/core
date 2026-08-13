defmodule Platform.Tenancy.OrgGroupClaim do
  @moduledoc """
  Ecto schema for the `org_group_claims` table — the IdP group-claim value
  that names an org.

  Mapping rows live in the DATABASE, not in application config: adding a
  client must never require a deploy.

  `claim_value` is normalized to trimmed lowercase on cast, so `"Group-A"`
  and `"group-a"` cannot both be stored. The unique index on `claim_value`
  then guarantees one group value never names two orgs.

  See `Platform.Tenancy.resolve_org_from_groups/1` for the resolver that
  reads these rows, and why it refuses to guess.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_group_claims" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:claim_value, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for an org group-claim mapping.

  Casts `:org_id` and `:claim_value`, normalizes the claim value
  (`String.trim/1` then `String.downcase/1`), requires both, and enforces
  the unique index on `claim_value` plus the FK on `:org_id`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:org_id, :claim_value])
    |> update_change(:claim_value, &normalize/1)
    |> validate_required([:org_id, :claim_value])
    |> unique_constraint(:claim_value)
    |> foreign_key_constraint(:org_id)
  end

  @doc """
  Normalize a claim value to its stored form: trimmed, lowercased.

  Non-binary input passes through untouched so `validate_required/2` (not a
  FunctionClauseError) is what reports it.
  """
  @spec normalize(term()) :: term()
  def normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  def normalize(value), do: value
end
