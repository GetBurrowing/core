defmodule Platform.Secretary.Feedback do
  @moduledoc """
  One thing a person told the triage agent about an item or a kind of item
  (task 01a1b721): `this_matters`, `hide_kind`, `not_a_todo` or `undo`.
  Append-only; indexed on `(user_id, kind_key)` so "hide this kind" is one
  lookup.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @actions ~w(this_matters hide_kind not_a_todo undo)

  @type t :: %__MODULE__{}

  schema "secretary_feedback" do
    field(:user_id, :binary_id)
    field(:ref_type, :string)
    field(:ref_id, :binary_id)
    field(:kind_key, :string)
    field(:action, :string)
    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @doc "Valid feedback actions."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc false
  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:user_id, :ref_type, :ref_id, :kind_key, :action])
    |> validate_required([:user_id, :action])
    |> validate_inclusion(:action, @actions)
    |> foreign_key_constraint(:user_id)
  end
end
