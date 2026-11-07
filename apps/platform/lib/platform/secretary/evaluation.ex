defmodule Platform.Secretary.Evaluation do
  @moduledoc """
  The current verdict on one item for one person (task 01a1b721). Unique on
  `(user_id, ref_type, ref_id)`: a re-evaluation replaces the row and keeps
  the old tag in `previous_tag`.

  `model_version` is `host:<agent_id>:<harness>` for a model verdict or
  `fallback` for the deterministic one. `group_key` is `"none"` or a goal key
  (`"space_goal:<space_id>:<index>"`, see `Platform.Secretary.Context`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @tags ~w(decide waiting fyi not_in_space todo suggested quiet)
  # The brief line's tag (task 01a1b721 stage 3): "You may not know", "Risk",
  # "Nobody flagged this", "Family".
  @brief_tags ~w(may_not_know risk nobody_flagged family)
  @unique_index :secretary_evaluations_user_id_ref_type_ref_id_index

  @type t :: %__MODULE__{}

  schema "secretary_evaluations" do
    field(:user_id, :binary_id)
    field(:ref_type, :string)
    field(:ref_id, :binary_id)
    field(:tag, :string)
    field(:group_key, :string, default: "none")
    field(:reason, :string)
    field(:rank, :integer)
    field(:previous_tag, :string)
    field(:brief_rank, :integer)
    field(:brief_line, :string)
    field(:brief_action_label, :string)
    field(:brief_tag, :string)
    field(:family, :boolean, default: false)
    field(:needs_you_now, :boolean, default: false)
    field(:deadline_at, :utc_datetime_usec)
    field(:model_version, :string)
    field(:batch_id, :binary_id)
    field(:failed_attempts, :integer, default: 0)
    field(:evaluated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(user_id ref_type ref_id tag group_key reason rank previous_tag brief_rank
             brief_line brief_action_label brief_tag family needs_you_now deadline_at
             model_version batch_id failed_attempts evaluated_at)a

  @doc "Valid tags."
  @spec tags() :: [String.t()]
  def tags, do: @tags

  @doc "Valid brief-line tags."
  @spec brief_tags() :: [String.t()]
  def brief_tags, do: @brief_tags

  @doc "The fields `Platform.Secretary.Store.upsert_evaluation/2` writes."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "The unique index name."
  @spec unique_index() :: atom()
  def unique_index, do: @unique_index

  @doc false
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :ref_type, :ref_id, :tag, :group_key])
    |> validate_inclusion(:tag, @tags)
    |> validate_inclusion(:brief_tag, @brief_tags)
    |> validate_inclusion(:previous_tag, @tags)
    |> validate_length(:reason, max: 200)
    |> validate_format(:model_version, ~r/\A(fallback|host:[^:]+:[^:]+)\z/)
    |> validate_number(:failed_attempts, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :ref_type, :ref_id], name: @unique_index)
  end
end
