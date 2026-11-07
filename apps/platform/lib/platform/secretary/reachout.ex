defmodule Platform.Secretary.Reachout do
  @moduledoc """
  One time the triage agent reached out about an evaluation, or held back
  (task 01a1b721): `sent`, `interrupted`, `held_meeting`, `held_evening`,
  `released`. Unique on `(user_id, evaluation_id, kind)` so a retry never
  reaches out twice.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(sent interrupted held_meeting held_evening released)
  @unique_index :secretary_reachouts_user_id_evaluation_id_kind_index

  @type t :: %__MODULE__{}

  schema "secretary_reachouts" do
    field(:user_id, :binary_id)
    field(:evaluation_id, :binary_id)
    field(:kind, :string)
    field(:reason, :string)
    field(:at, :utc_datetime_usec)
    field(:until, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The unique index name."
  @spec unique_index() :: atom()
  def unique_index, do: @unique_index

  @doc false
  def changeset(reachout, attrs) do
    reachout
    |> cast(attrs, [:user_id, :evaluation_id, :kind, :reason, :at, :until])
    |> validate_required([:user_id, :evaluation_id, :kind, :at])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:evaluation_id)
    |> unique_constraint([:user_id, :evaluation_id, :kind], name: @unique_index)
  end
end
