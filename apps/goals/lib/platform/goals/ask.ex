defmodule Platform.Goals.Ask do
  @moduledoc """
  Storage for goal_asks (task 01a1dfc1-05b0). Contexts set identity fields.
  Task 01a1dfc1-abcc extends questions with moved lines and suggestions, and
  offers with an idea's why, measure and steps to support the briefing screens.
  """
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
    |> validate_brief_payload()
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

  defp validate_brief_payload(changeset) do
    payload = get_field(changeset, :payload) || %{}
    kind = get_field(changeset, :kind)

    valid =
      case kind do
        "question" ->
          optional_list(payload, "moved", Platform.Goals.Limits.max_moved(), fn item ->
            is_map(item) and item["direction"] in ~w(up flat down) and nonblank?(item["text"])
          end) and
            optional_list(
              payload,
              "suggestions",
              Platform.Goals.Limits.max_suggestions(),
              fn item ->
                is_map(item) and nonblank?(item["title"]) and optional_text?(item, "why") and
                  optional_text?(item, "takeaway_id")
              end
            )

        "offer" ->
          not Map.has_key?(payload, "idea") or valid_idea?(payload["idea"])

        _ ->
          true
      end

    if valid, do: changeset, else: add_error(changeset, :payload, "has an invalid briefing shape")
  end

  defp valid_idea?(idea) when is_map(idea) do
    nonblank?(idea["why"]) and nonblank?(idea["measure"]) and
      is_list(idea["steps"]) and
      length(idea["steps"]) in 1..Platform.Goals.Limits.max_idea_steps() and
      Enum.all?(idea["steps"], &nonblank?/1) and optional_text?(idea, "takeaway_id")
  end

  defp valid_idea?(_), do: false

  defp optional_list(payload, key, maximum, valid?) do
    case Map.fetch(payload, key) do
      :error -> true
      {:ok, list} when is_list(list) -> length(list) <= maximum and Enum.all?(list, valid?)
      _ -> false
    end
  end

  defp optional_text?(map, key), do: not Map.has_key?(map, key) or nonblank?(map[key])
  defp nonblank?(text), do: is_binary(text) and String.trim(text) != ""

  defp validate_addressed(changeset) do
    if is_nil(get_field(changeset, :addressed_user_ids)),
      do: add_error(changeset, :addressed_user_ids, "cannot be nil"),
      else: changeset
  end
end
