defmodule Platform.Social.Trends.Snapshot do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "social_trend_snapshots" do
    field(:source, :string)
    field(:sample_limit, :integer)
    field(:observed_at, :utc_datetime_usec)
    field(:reporting_date, :date)
    field(:payload, :map)
  end
end
