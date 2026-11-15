defmodule Platform.Goals.Ask do
  @moduledoc "Storage for goal_asks (task 01a1dfc1-05b0). Contexts set identity fields."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_asks" do
    belongs_to(:goal, Platform.Goals.Goal)
    belongs_to(:wake_up, Platform.Goals.WakeUp)
    belongs_to(:entry, Platform.Goals.Entry)
    belongs_to(:created_by_agent, Platform.Agents.Agent)
    field(:kind, :string)
    field(:title, :string)
    field(:body, :string)
    field(:payload, :map, default: %{})
    field(:addressed_user_ids, {:array, :binary_id}, default: [])
    field(:status, :string, default: "open")
    field(:expires_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    has_many(:answers, Platform.Goals.AskAnswer)
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
      :status,
      :expires_at,
      :closed_at
    ])
    |> validate_required([:goal_id, :kind, :title, :payload, :status, :expires_at])
    |> validate_addressed()
    |> validate_length(:title, max: 200)
    |> validate_length(:body, max: 4000)
    |> validate_practice()
    |> validate_inclusion(:kind, ~w(question offer practice))
    |> check_constraint(:kind, name: :goal_asks_kind)
    |> validate_inclusion(:status, ~w(open closed expired))
    |> check_constraint(:status, name: :goal_asks_status)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:wake_up_id)
    |> foreign_key_constraint(:entry_id)
    |> foreign_key_constraint(:created_by_agent_id)
  end

  defp validate_practice(changeset) do
    if get_field(changeset, :kind) == "practice" do
      cards = get_field(changeset, :payload)["cards"]

      valid =
        is_list(cards) and length(cards) in 1..Platform.Goals.Limits.max_cards() and
          Enum.all?(cards, fn card ->
            is_map(card) and
              Enum.all?(["front", "back"], fn key ->
                is_binary(card[key]) and String.trim(card[key]) != ""
              end)
          end)

      if valid,
        do: changeset,
        else: add_error(changeset, :payload, "must contain valid practice cards")
    else
      changeset
    end
  end

  defp validate_addressed(changeset) do
    if is_nil(get_field(changeset, :addressed_user_ids)),
      do: add_error(changeset, :addressed_user_ids, "cannot be nil"),
      else: changeset
  end
end
