defmodule Platform.Secretary.Todo do
  @moduledoc """
  One entry on a person's own list (task 01a1b721, folding task 01a1b714).
  `origin` is `self` (they added it) or `heard` (suggested from something
  said in a room they are in). Unique on `(user_id, dedupe_key)`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @origins ~w(self heard)
  @statuses ~w(suggested kept dismissed done)
  @unique_index :secretary_todos_user_id_dedupe_key_index

  @type t :: %__MODULE__{}

  schema "secretary_todos" do
    field(:user_id, :binary_id)
    field(:title, :string)
    field(:origin, :string)
    field(:source_ref_type, :string)
    field(:source_ref_id, :binary_id)
    field(:source_space_id, :binary_id)
    field(:source_quote, :string)
    field(:goal_key, :string)
    field(:due_on, :date)
    field(:status, :string)
    field(:done_reason, :string)
    field(:dedupe_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The unique index name."
  @spec unique_index() :: atom()
  def unique_index, do: @unique_index

  @doc false
  def changeset(todo, attrs) do
    todo
    |> cast(attrs, [
      :user_id,
      :title,
      :origin,
      :source_ref_type,
      :source_ref_id,
      :source_space_id,
      :source_quote,
      :goal_key,
      :due_on,
      :status,
      :done_reason,
      :dedupe_key
    ])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:user_id, :title, :origin, :status, :dedupe_key])
    |> validate_length(:title, max: 500)
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :dedupe_key], name: @unique_index)
  end
end
