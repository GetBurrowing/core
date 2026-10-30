defmodule Platform.Social.ClosingAsset do
  @moduledoc "Durable non-episode identity, retained after replacing or removing the show default."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "social_closing_assets" do
    field(:org_id, :binary_id)
    field(:project_id, :binary_id)
    field(:profile_id, :binary_id)
    field(:file_id, :binary_id)
    field(:content_hash, :string)
    field(:byte_size, :integer)
    field(:duration_s, :float)
    field(:width, :integer)
    field(:height, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
