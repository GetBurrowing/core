defmodule Platform.Chat.Section do
  @moduledoc """
  A channel sidebar section — the admin-curated default grouping (chat sidebar
  v2, Stage 2). One row per org; `org_id` is the section's owning org and the
  default-grouping key (a channel renders under the section whose `org_id`
  matches `chat_spaces.org_id`). `color` is a scope token in CSS form
  (e.g. `wayne-tech`); `position` is the admin default order.

  Per-user reordering/hiding lives in `users.preferences` (Stage 3), not here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "channel_sections" do
    field(:org_id, :binary_id)
    field(:name, :string)
    field(:color, :string)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:org_id, :name, :color, :position])
    |> validate_required([:org_id, :name])
    |> foreign_key_constraint(:org_id)
    |> unique_constraint(:org_id)
  end
end
