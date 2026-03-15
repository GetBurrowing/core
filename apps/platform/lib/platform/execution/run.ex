defmodule Platform.Execution.Run do
  @moduledoc """
  In-memory representation of an execution run.

  This is the runtime-facing shape for the Execution domain introduced in
  ADR 0011. It intentionally starts as a struct + helper module before the
  database schema lands so the OTP control plane can be built incrementally.
  """

  @valid_states ~w(queued starting booting running stopping kill_requested completed failed cancelled killed stale dead)a

  @type state ::
          :queued
          | :starting
          | :booting
          | :running
          | :stopping
          | :kill_requested
          | :completed
          | :failed
          | :cancelled
          | :killed
          | :stale
          | :dead

  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t() | nil,
          runner_profile: String.t() | nil,
          state: state(),
          phase: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          last_progress_at: DateTime.t() | nil,
          last_context_ack_at: DateTime.t() | nil,
          context_requested_at: DateTime.t() | nil,
          required_context_version: non_neg_integer(),
          acknowledged_context_version: non_neg_integer(),
          heartbeat_timeout_ms: pos_integer(),
          progress_timeout_ms: pos_integer(),
          context_ack_timeout_ms: pos_integer(),
          kill_grace_ms: pos_integer(),
          stop_reason: String.t() | nil,
          stop_requested_at: DateTime.t() | nil,
          kill_requested_at: DateTime.t() | nil,
          exit_code: integer() | nil,
          runner_ref: map(),
          metadata: map()
        }

  @enforce_keys [:id]
  defstruct id: nil,
            task_id: nil,
            runner_profile: nil,
            state: :queued,
            phase: nil,
            last_heartbeat_at: nil,
            last_progress_at: nil,
            last_context_ack_at: nil,
            context_requested_at: nil,
            required_context_version: 0,
            acknowledged_context_version: 0,
            heartbeat_timeout_ms: 25_000,
            progress_timeout_ms: 120_000,
            context_ack_timeout_ms: 30_000,
            kill_grace_ms: 3_000,
            stop_reason: nil,
            stop_requested_at: nil,
            kill_requested_at: nil,
            exit_code: nil,
            runner_ref: %{},
            metadata: %{}

  @doc "Normalizes a run map/keyword/struct into `%Run{}`."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = run), do: {:ok, normalize(run)}

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    case fetch_attr(attrs, :id) do
      nil ->
        {:error, :missing_id}

      id ->
        {:ok,
         %__MODULE__{
           id: to_string(id),
           task_id: normalize_optional_string(fetch_attr(attrs, :task_id)),
           runner_profile: normalize_optional_string(fetch_attr(attrs, :runner_profile)),
           state: normalize_state(fetch_attr(attrs, :state)),
           phase: normalize_optional_string(fetch_attr(attrs, :phase)),
           last_heartbeat_at: normalize_datetime(fetch_attr(attrs, :last_heartbeat_at)),
           last_progress_at: normalize_datetime(fetch_attr(attrs, :last_progress_at)),
           last_context_ack_at: normalize_datetime(fetch_attr(attrs, :last_context_ack_at)),
           context_requested_at: normalize_datetime(fetch_attr(attrs, :context_requested_at)),
           required_context_version:
             normalize_non_neg_integer(fetch_attr(attrs, :required_context_version), 0),
           acknowledged_context_version:
             normalize_non_neg_integer(fetch_attr(attrs, :acknowledged_context_version), 0),
           heartbeat_timeout_ms:
             normalize_pos_integer(fetch_attr(attrs, :heartbeat_timeout_ms), 25_000),
           progress_timeout_ms:
             normalize_pos_integer(fetch_attr(attrs, :progress_timeout_ms), 120_000),
           context_ack_timeout_ms:
             normalize_pos_integer(fetch_attr(attrs, :context_ack_timeout_ms), 30_000),
           kill_grace_ms: normalize_pos_integer(fetch_attr(attrs, :kill_grace_ms), 3_000),
           stop_reason: normalize_optional_string(fetch_attr(attrs, :stop_reason)),
           stop_requested_at: normalize_datetime(fetch_attr(attrs, :stop_requested_at)),
           kill_requested_at: normalize_datetime(fetch_attr(attrs, :kill_requested_at)),
           exit_code: normalize_optional_integer(fetch_attr(attrs, :exit_code)),
           runner_ref: normalize_map(fetch_attr(attrs, :runner_ref)),
           metadata: normalize_map(fetch_attr(attrs, :metadata))
         }
         |> normalize()}
    end
  end

  def new(_other), do: {:error, :invalid_run}

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}) do
    state in [:completed, :failed, :cancelled, :killed, :dead]
  end

  @spec heartbeat_expired?(t(), DateTime.t()) :: boolean()
  def heartbeat_expired?(%__MODULE__{} = run, now \\ DateTime.utc_now()) do
    deadline_expired?(run.last_heartbeat_at, run.heartbeat_timeout_ms, now)
  end

  @spec progress_expired?(t(), DateTime.t()) :: boolean()
  def progress_expired?(%__MODULE__{} = run, now \\ DateTime.utc_now()) do
    deadline_expired?(run.last_progress_at, run.progress_timeout_ms, now)
  end

  @spec context_ack_expired?(t(), DateTime.t()) :: boolean()
  def context_ack_expired?(%__MODULE__{} = run, now \\ DateTime.utc_now()) do
    if run.required_context_version > run.acknowledged_context_version do
      reference_at = run.context_requested_at || run.last_context_ack_at
      deadline_expired?(reference_at, run.context_ack_timeout_ms, now)
    else
      false
    end
  end

  @spec classify(t(), DateTime.t()) :: :ok | :stale | :dead
  def classify(%__MODULE__{} = run, now \\ DateTime.utc_now()) do
    cond do
      terminal?(run) -> :ok
      heartbeat_expired?(run, now) -> :dead
      progress_expired?(run, now) -> :stale
      context_ack_expired?(run, now) -> :stale
      true -> :ok
    end
  end

  defp normalize(%__MODULE__{} = run) do
    %__MODULE__{
      run
      | runner_ref: normalize_map(run.runner_ref),
        metadata: normalize_map(run.metadata)
    }
  end

  defp deadline_expired?(nil, _timeout_ms, _now), do: false

  defp deadline_expired?(%DateTime{} = since, timeout_ms, %DateTime{} = now) do
    DateTime.diff(now, since, :millisecond) > timeout_ms
  end

  defp fetch_attr(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp normalize_state(state) when state in @valid_states, do: state

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    _ -> :queued
  else
    state when state in @valid_states -> state
    _ -> :queued
  end

  defp normalize_state(_other), do: :queued

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp normalize_datetime(_other), do: nil

  defp normalize_non_neg_integer(nil, default), do: default
  defp normalize_non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp normalize_non_neg_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_neg_integer(_value, default), do: default

  defp normalize_pos_integer(nil, default), do: default
  defp normalize_pos_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_pos_integer(_value, default), do: default

  defp normalize_optional_integer(nil), do: nil
  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_value), do: nil

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_map(nil), do: %{}
  defp normalize_map(%{} = value), do: value
  defp normalize_map(_other), do: %{}
end
