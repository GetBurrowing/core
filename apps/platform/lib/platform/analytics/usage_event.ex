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

  # The `:binary_id` fields. All optional, all sourced from client-supplied
  # payloads (runtime channel, HTTP controller) — so all four are exposed to
  # whatever a misbehaving client sends.
  @uuid_fields ~w(space_id agent_id participant_id triggered_by)a

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

  @doc "The `:binary_id` fields subject to `valid_uuid?/1`."
  def uuid_fields, do: @uuid_fields

  @doc """
  True when `value` is a canonical 36-character UUID string — the only shape
  Ecto's `:binary_id` dump accepts without raising.

  Deliberately stricter than `Ecto.UUID.cast/1`. `cast/1` also accepts a raw
  16-byte binary (it hex-encodes it), but `Ecto.UUID.dump/1` rejects that same
  binary, so any 16-character slug would pass a `cast/1`-based guard and still
  raise `Ecto.ChangeError` inside `Repo.insert`. Checking the length first
  closes that gap: a value that satisfies this predicate is guaranteed to dump.
  """
  def valid_uuid?(value) when is_binary(value) do
    byte_size(value) == 36 and match?({:ok, _}, Ecto.UUID.cast(value))
  end

  def valid_uuid?(_value), do: false

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_uuid_fields()
    |> compute_total_tokens()
    |> compute_cost()
  end

  # `cast/4` does NOT validate UUID shape for `:binary_id` — it passes any
  # binary straight through and the failure surfaces later, as a RAISED
  # `Ecto.ChangeError`, at dump time inside `Repo.insert`.
  #
  # A raise from a changeset-shaped API kills its caller. `RuntimeChannel`
  # correctly handled `{:error, changeset}` but never saw one, so when a
  # runtime sent `space_id: "higgins"` (a slug, not a UUID) the exception
  # propagated out of `handle_in/3` and took the channel process down.
  #
  # Validating here is the safety net: EVERY caller — channel, HTTP
  # controller, future ones — gets `{:error, changeset}` instead of an
  # exception, regardless of what sanitation happens upstream.
  defp validate_uuid_fields(changeset) do
    Enum.reduce(@uuid_fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        nil ->
          acc

        value ->
          if valid_uuid?(value),
            do: acc,
            else: add_error(acc, field, "is not a valid UUID")
      end
    end)
  end

  # Always recompute total_tokens from components (ignore caller-provided value)
  defp compute_total_tokens(changeset) do
    input = get_field(changeset, :input_tokens) || 0
    output = get_field(changeset, :output_tokens) || 0
    cache_read = get_field(changeset, :cache_read_tokens) || 0
    cache_write = get_field(changeset, :cache_write_tokens) || 0
    put_change(changeset, :total_tokens, input + output + cache_read + cache_write)
  end

  # Always compute cost server-side from the pricing table (ignore caller-provided cost_usd)
  defp compute_cost(changeset) do
    cost =
      Platform.Analytics.Pricing.calculate_cost(%{
        model: get_field(changeset, :model),
        input_tokens: get_field(changeset, :input_tokens) || 0,
        output_tokens: get_field(changeset, :output_tokens) || 0,
        cache_read_tokens: get_field(changeset, :cache_read_tokens) || 0,
        cache_write_tokens: get_field(changeset, :cache_write_tokens) || 0
      })

    put_change(changeset, :cost_usd, cost)
  end
end
