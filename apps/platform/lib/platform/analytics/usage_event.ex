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

  Delegates to `Platform.UUID.valid?/1`, which is the canonical boundary
  predicate for the whole app. This function shipped first (PR #613) and is
  kept as a named alias because `validate_uuid_fields/1` below reads better
  with it; the rationale for being stricter than `Ecto.UUID.cast/1` — the raw
  16-byte-binary gap — now lives in `Platform.UUID`.
  """
  defdelegate valid_uuid?(value), to: Platform.UUID, as: :valid?

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_uuid_fields()
    |> normalize_dispatch_metadata()
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

  # Task 01a114a8 stage 1: the dispatch keys a client may report in
  # `metadata`, read by `Platform.Orchestration.DispatchMetrics`. Each is
  # kept (under its string key) only when well-formed and DROPPED otherwise.
  # A malformed key never rejects the event: the tokens are still worth
  # recording. No new columns; `metadata.stage_id` is expression-indexed.
  @dispatch_integer_keys ~w(turns wall_ms client_tool_calls)
  @max_harness_length 64

  @doc "The `metadata` keys DispatchMetrics reads."
  def dispatch_metadata_keys, do: ["stage_id", "harness" | @dispatch_integer_keys]

  defp normalize_dispatch_metadata(changeset) do
    case get_change(changeset, :metadata) do
      %{} = metadata ->
        put_change(
          changeset,
          :metadata,
          Enum.reduce(dispatch_metadata_keys(), metadata, &normalize_dispatch_key/2)
        )

      _ ->
        changeset
    end
  end

  # Literal atoms, so an internal caller's atom-keyed map is read too and no
  # atom is ever minted from input.
  @dispatch_atom_keys %{
    "stage_id" => :stage_id,
    "harness" => :harness,
    "turns" => :turns,
    "wall_ms" => :wall_ms,
    "client_tool_calls" => :client_tool_calls
  }

  defp normalize_dispatch_key(key, metadata) do
    atom_key = Map.fetch!(@dispatch_atom_keys, key)
    value = Map.get(metadata, key, Map.get(metadata, atom_key))
    metadata = Map.drop(metadata, [key, atom_key])

    case dispatch_value(key, value) do
      {:ok, normalized} -> Map.put(metadata, key, normalized)
      :drop -> metadata
    end
  end

  defp dispatch_value(_key, nil), do: :drop

  defp dispatch_value("stage_id", value) when is_binary(value),
    do: if(valid_uuid?(value), do: {:ok, value}, else: :drop)

  defp dispatch_value("harness", value) when is_binary(value) and value != "",
    do: {:ok, String.slice(value, 0, @max_harness_length)}

  defp dispatch_value(key, value)
       when key in @dispatch_integer_keys and is_integer(value) and value >= 0,
       do: {:ok, value}

  defp dispatch_value(_key, _value), do: :drop

  # Always recompute total_tokens from components (ignore caller-provided value)
  defp compute_total_tokens(changeset) do
    input = get_field(changeset, :input_tokens) || 0
    output = get_field(changeset, :output_tokens) || 0
    cache_read = get_field(changeset, :cache_read_tokens) || 0
    cache_write = get_field(changeset, :cache_write_tokens) || 0
    put_change(changeset, :total_tokens, input + output + cache_read + cache_write)
  end

  # Cost is authoritative from the pricing table for models the table
  # covers. Models it does not cover keep the caller-provided cost_usd when
  # there is one: the dsh and OpenClaw federation plugins price OpenRouter
  # models from pi-ai's catalog at push time, and zeroing that value threw
  # away the one number that was actually right — the runtime holds the
  # provider's receipt, the table just does not list every model on it.
  defp compute_cost(changeset) do
    cost =
      if Platform.Analytics.Pricing.known_model?(get_field(changeset, :model)) do
        Platform.Analytics.Pricing.calculate_cost(%{
          model: get_field(changeset, :model),
          input_tokens: get_field(changeset, :input_tokens) || 0,
          output_tokens: get_field(changeset, :output_tokens) || 0,
          cache_read_tokens: get_field(changeset, :cache_read_tokens) || 0,
          cache_write_tokens: get_field(changeset, :cache_write_tokens) || 0
        })
      else
        get_field(changeset, :cost_usd) || 0.0
      end

    put_change(changeset, :cost_usd, cost)
  end
end
