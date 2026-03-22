defmodule Platform.Analytics.UsageEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @required_fields ~w(model provider session_key)a
  @optional_fields ~w(
    space_id agent_id participant_id triggered_by
    input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens
    cost_usd latency_ms tool_calls task_id metadata
  )a

  schema "agent_usage_events" do
    field(:space_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:triggered_by, :binary_id)
    field(:model, :string)
    field(:provider, :string)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cache_read_tokens, :integer, default: 0)
    field(:cache_write_tokens, :integer, default: 0)
    field(:total_tokens, :integer, default: 0)
    field(:cost_usd, :float)
    field(:latency_ms, :integer)
    field(:tool_calls, {:array, :string}, default: [])
    field(:task_id, :string)
    field(:session_key, :string)
    field(:metadata, :map, default: %{})
    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> maybe_compute_total_tokens()
  end

  defp maybe_compute_total_tokens(changeset) do
    if get_change(changeset, :total_tokens) do
      changeset
    else
      input = get_field(changeset, :input_tokens) || 0
      output = get_field(changeset, :output_tokens) || 0
      cache_read = get_field(changeset, :cache_read_tokens) || 0
      cache_write = get_field(changeset, :cache_write_tokens) || 0
      put_change(changeset, :total_tokens, input + output + cache_read + cache_write)
    end
  end
end
