defmodule Platform.Access.Proposal do
  @moduledoc "A consent card whose grant mutation can be committed only by an authenticated human."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_change_proposals" do
    field(:org_id, :binary_id)
    field(:proposer_runtime_id, :binary_id)
    field(:space_id, :binary_id)
    field(:canvas_id, :binary_id)
    field(:kind, :string, default: "change")
    field(:action, :string)
    field(:options, {:array, :map}, default: [])
    field(:selected_option, :string)
    field(:tuple_keys, {:array, :string}, default: [])
    field(:base_state_hash, :string)
    field(:card_digest, :string)
    field(:state, :string, default: "proposed")
    field(:approval_id, Ecto.UUID)
    field(:approved_by_user_id, :binary_id)
    field(:approved_at, :utc_datetime_usec)
    field(:change_id, :binary_id)
    field(:undoes_change_id, :binary_id)
    field(:failure, :map)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, __schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> validate_required([
      :org_id,
      :space_id,
      :canvas_id,
      :kind,
      :action,
      :options,
      :base_state_hash,
      :card_digest,
      :state,
      :expires_at
    ])
    |> validate_length(:options, min: 1, max: 3)
    |> validate_inclusion(:state, ~w(proposed applying applied cancelled stale failed undone))
    |> unique_constraint(:canvas_id)
    |> unique_constraint(:approval_id)
    |> check_constraint(:state, name: :human_applied)
  end
end
