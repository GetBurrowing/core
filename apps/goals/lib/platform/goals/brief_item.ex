defmodule Platform.Goals.BriefItem do
  @moduledoc "A reader's delivered goal item (Goals 6/8, task 01a1dfc1-abcc). Identity comes from the context."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  schema "goal_brief_items" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:goal, Platform.Goals.Goal)
    belongs_to(:ask, Platform.Goals.Ask)
    field(:digest_date, :date)
    field(:kind, :string)
    field(:entry_ids, {:array, :binary_id}, default: [])
    field(:since_at, :utc_datetime_usec)
    field(:through_at, :utc_datetime_usec)
    field(:noted_at, :utc_datetime_usec)
    field(:ignored_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :digest_date,
      :kind,
      :entry_ids,
      :since_at,
      :through_at,
      :noted_at,
      :ignored_at
    ])
    |> validate_required([:user_id, :goal_id, :digest_date, :kind, :entry_ids])
    |> validate_inclusion(:kind, ~w(report ask))
    |> check_constraint(:kind, name: :goal_brief_items_kind)
    |> check_constraint(:ask_id, name: :goal_brief_items_shape)
    |> unique_constraint([:user_id, :ask_id], name: :goal_brief_items_user_id_ask_id_index)
    |> unique_constraint([:user_id, :goal_id, :digest_date],
      name: :goal_brief_items_user_id_goal_id_digest_date_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:ask_id)
  end
end
