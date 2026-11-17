defmodule Platform.Chat.MentionGroup do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "mention_groups" do
    field(:org_id, :binary_id)
    field(:created_by_user_id, :binary_id)
    field(:name, :string)
    field(:normalized_name, :string)
    field(:deleted_at, :utc_datetime_usec)
    field(:members, {:array, :map}, virtual: true, default: [])
    field(:eligible_count, :integer, virtual: true)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_format(:name, ~r/^[^\[\]\r\n]+$/u)
    |> normalize_name()
    |> unique_constraint(:name, name: :mention_groups_active_name_index)
  end

  defp normalize_name(cs) do
    case get_field(cs, :name) do
      name when is_binary(name) ->
        put_change(
          cs,
          :normalized_name,
          name |> String.normalize(:nfc) |> String.downcase() |> String.split() |> Enum.join(" ")
        )

      _ ->
        cs
    end
  end
end
