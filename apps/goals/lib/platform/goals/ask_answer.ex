defmodule Platform.Goals.AskAnswer do
  @moduledoc "Storage for goal_ask_answers (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_ask_answers" do
    field(:ask_id, :binary_id)
    field(:user_id, :binary_id)
    field(:answer, :string)
    field(:details, :map, default: %{})
    field(:answered_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:ask_id, :answer, :details, :answered_at])
    |> validate_required([:ask_id, :user_id, :answer, :details, :answered_at])
    |> validate_inclusion(:answer, ~w(used declined ignored))
    |> check_constraint(:answer, name: :goal_ask_answers_answer)
    |> unique_constraint([:ask_id, :user_id], name: :goal_ask_answers_ask_id_user_id_index)
    |> foreign_key_constraint(:ask_id)
    |> foreign_key_constraint(:user_id)
  end
end
