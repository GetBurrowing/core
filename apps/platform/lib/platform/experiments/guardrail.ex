defmodule Platform.Experiments.Guardrail do
  @moduledoc """
  Per-org limits on experimentation. Task 01a0d415, the experimentation-layer
  ADR-0052.

  ## One row per org, and exactly ONE install-wide row

  `org_id` NULL is THE install-wide row — the fallback when an org has none
  of its own. The unique index on `org_id` is built `NULLS NOT DISTINCT`
  (`nulls_distinct: false`), so a second install-wide row is a constraint
  violation rather than a silent duplicate. Under the Postgres default two
  NULLs never compare equal, both rows would insert, and "the" install-wide
  row would be whichever the planner returned first.

  ## Launch approval is opt-in

  `require_human_approval` defaults to FALSE (Rowan, 2026-09-24). It is a
  guardrail an admin can switch on per org; the UI controls (approve, stop,
  promote, revert) are present whatever it says.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @unique_index_name :experiment_guardrails_org_id_index

  @type t :: %__MODULE__{}

  schema "experiment_guardrails" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:max_live, :integer, default: 3)
    field(:allowed_surfaces, {:array, :string}, default: [])
    field(:require_human_approval, :boolean, default: false)
    field(:allow_auto_promote, :boolean, default: false)
    field(:updated_by_user_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Name of the NULLS NOT DISTINCT singleton index."
  @spec unique_index_name() :: atom()
  def unique_index_name, do: @unique_index_name

  @doc "Builds a changeset for a guardrail row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(guardrail, attrs) do
    guardrail
    |> cast(attrs, [
      :org_id,
      :max_live,
      :allowed_surfaces,
      :require_human_approval,
      :allow_auto_promote,
      :updated_by_user_id
    ])
    |> validate_required([:max_live])
    |> validate_number(:max_live, greater_than_or_equal_to: 0)
    |> validate_registered_surfaces()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:updated_by_user_id)
    |> unique_constraint(:org_id, name: @unique_index_name)
  end

  # Only a key in the surfaces registry can be stored (task 01a0d415 stage 2).
  # The registry holds no send-path surface, so a `mail.send*` key cannot be
  # allowed at all — the refusal is structural, not a list of forbidden names.
  defp validate_registered_surfaces(changeset) do
    validate_change(changeset, :allowed_surfaces, fn :allowed_surfaces, keys ->
      keys
      |> Enum.reject(fn key ->
        Platform.Experiments.Surfaces.get(key) != nil and
          not Platform.Experiments.Guardrails.send_path?(key)
      end)
      |> Enum.map(&{:allowed_surfaces, "#{inspect(&1)} is not a registered surface"})
    end)
  end
end
