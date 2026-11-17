defmodule Platform.Sharing.UsageCount do
  @moduledoc """
  One stored anonymous usage count on the broker host (task 01a1b678 stage
  2): `count` occurrences of the pinned `event` in the window starting at
  `window_start`, from the install whose random sharing id is
  `sharing_install_id`. Written only by `Platform.Sharing.UsageReceiver`.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "sharing_usage_counts" do
    field(:sharing_install_id, Ecto.UUID)
    field(:window_start, :utc_datetime)
    field(:window_seconds, :integer)
    field(:event, :string)
    field(:count, :integer)

    timestamps(type: :utc_datetime_usec)
  end
end
