defmodule Platform.Goals.Ask do
  @moduledoc "Storage for goal_asks (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_asks" do
    field(:goal_id, :binary_id)
    field(:wake_up_id, :binary_id)
    field(:entry_id, :binary_id)
    field(:created_by_agent_id, :binary_id)
    field(:kind, :string)
    field(:title, :string)
    field(:body, :string)
    field(:payload, :map, default: %{})
    field(:addressed_user_ids, {:array, :binary_id}, default: [])
    field(:status, :string, default: "open")
    field(:expires_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :wake_up_id,
      :entry_id,
      :kind,
      :title,
      :body,
      :payload,
      :addressed_user_ids,
      :status,
      :expires_at,
      :closed_at
    ])
    |> validate_required([:goal_id, :kind, :title, :payload, :status, :expires_at])
    |> validate_change(:addressed_user_ids, fn :addressed_user_ids, value ->
      if is_nil(value), do: [addressed_user_ids: "cannot be nil"], else: []
    end)
    |> validate_inclusion(:kind, ~w(question offer practice))
    |> check_constraint(:kind, name: :goal_asks_kind)
    |> validate_inclusion(:status, ~w(open closed expired))
    |> check_constraint(:status, name: :goal_asks_status)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:wake_up_id)
    |> foreign_key_constraint(:entry_id)
    |> foreign_key_constraint(:created_by_agent_id)
  end
end
