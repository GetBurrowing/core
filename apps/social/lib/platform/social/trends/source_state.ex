defmodule Platform.Social.Trends.SourceState do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:source, :string, autogenerate: false}
  schema "social_trend_source_states" do
    field(:retry_at, :utc_datetime_usec)
    field(:status, :string)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:next_date, :date)
    field(:not_found_count, :integer, default: 0)
  end
end
