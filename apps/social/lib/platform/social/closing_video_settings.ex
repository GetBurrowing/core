defmodule Platform.Social.ClosingVideoSettings do
  @moduledoc "Typed show default. Written exclusively through ClipClosingVideo, never profile attrs."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    field(:file_id, Platform.Types.UUIDv7)
    field(:enabled, :boolean, default: false)
    field(:audio, Ecto.Enum, values: [:keep, :mute], default: :mute)
  end

  def changeset(settings, attrs) do
    changeset =
      settings
      |> cast(attrs, [:file_id, :enabled, :audio])
      |> validate_required([:enabled, :audio])

    if get_field(changeset, :enabled) and is_nil(get_field(changeset, :file_id)),
      do: add_error(changeset, :file_id, "is required when enabled"),
      else: changeset
  end
end
