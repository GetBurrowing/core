defmodule Platform.Access.SpaceRestriction do
  @moduledoc "Channel restriction rows owned by Access (task 01a1386e-59d1 stage 2)."
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id
  schema "access_space_restrictions" do
    belongs_to :space, Platform.Chat.Space, primary_key: true
    field :role_key, :string, primary_key: true
    field :restricted_by, :binary_id
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
