defmodule Platform.Secretary.Batch do
  @moduledoc """
  One dispatch of items for one person to the triage agent (task 01a1b721).
  `item_refs` is `[%{"ref_type", "ref_id"}]`; `reserved_tokens` is what the
  budget held at dispatch, `actual_tokens` what the run reported.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(dispatched submitted failed expired budget_exhausted no_ai rejected)

  @type t :: %__MODULE__{}

  schema "secretary_batches" do
    field(:user_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:item_refs, {:array, :map}, default: [])
    field(:status, :string, default: "dispatched")
    field(:reserved_tokens, :integer, default: 0)
    field(:actual_tokens, :integer)
    field(:policy_variant_id, :binary_id)
    field(:dispatched_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid batch statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :user_id,
      :agent_id,
      :item_refs,
      :status,
      :reserved_tokens,
      :actual_tokens,
      :policy_variant_id,
      :dispatched_at,
      :finished_at
    ])
    |> validate_required([:user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:reserved_tokens, greater_than_or_equal_to: 0)
    |> validate_item_refs()
    |> foreign_key_constraint(:user_id)
  end

  defp validate_item_refs(changeset) do
    validate_change(changeset, :item_refs, fn :item_refs, refs ->
      if Enum.all?(refs, &valid_ref?/1),
        do: [],
        else: [item_refs: "each ref needs a ref_type and a UUID ref_id"]
    end)
  end

  defp valid_ref?(%{"ref_type" => type, "ref_id" => id}) when is_binary(type),
    do: Platform.UUID.valid?(id)

  defp valid_ref?(%{ref_type: type, ref_id: id}) when is_binary(type),
    do: Platform.UUID.valid?(id)

  defp valid_ref?(_ref), do: false
end
