defmodule Platform.Execution.ContextSession do
  @moduledoc """
  Runner-facing view of the shared execution context plane.

  A context session is scoped to a specific run and captures the current
  snapshot version the runner is expected to consume and acknowledge.
  """

  @type t :: %__MODULE__{
          run_id: String.t(),
          scope: map(),
          version: non_neg_integer(),
          required_version: non_neg_integer(),
          snapshot: map(),
          issued_at: DateTime.t(),
          last_ack_at: DateTime.t() | nil,
          metadata: map()
        }

  @enforce_keys [:run_id]
  defstruct run_id: nil,
            scope: %{},
            version: 0,
            required_version: 0,
            snapshot: %{},
            issued_at: nil,
            last_ack_at: nil,
            metadata: %{}

  @doc "Build a normalized context session struct."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = session), do: {:ok, normalize(session)}

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    case fetch_attr(attrs, :run_id) do
      nil ->
        {:error, :missing_run_id}

      run_id ->
        {:ok,
         %__MODULE__{
           run_id: to_string(run_id),
           scope: normalize_map(fetch_attr(attrs, :scope)),
           version: normalize_non_neg_integer(fetch_attr(attrs, :version), 0),
           required_version: normalize_non_neg_integer(fetch_attr(attrs, :required_version), 0),
           snapshot: normalize_map(fetch_attr(attrs, :snapshot)),
           issued_at: normalize_datetime(fetch_attr(attrs, :issued_at)) || DateTime.utc_now(),
           last_ack_at: normalize_datetime(fetch_attr(attrs, :last_ack_at)),
           metadata: normalize_map(fetch_attr(attrs, :metadata))
         }
         |> normalize()}
    end
  end

  def new(_other), do: {:error, :invalid_context_session}

  @doc "Return a new context session with an acknowledged version recorded."
  @spec acknowledge(t(), non_neg_integer(), DateTime.t()) :: t()
  def acknowledge(%__MODULE__{} = session, version, at \\ DateTime.utc_now())
      when is_integer(version) do
    %__MODULE__{
      session
      | version: max(session.version, version),
        required_version: max(session.required_version, version),
        last_ack_at: at
    }
  end

  defp normalize(%__MODULE__{} = session) do
    %__MODULE__{
      session
      | scope: normalize_map(session.scope),
        snapshot: normalize_map(session.snapshot),
        metadata: normalize_map(session.metadata)
    }
  end

  defp fetch_attr(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp normalize_non_neg_integer(nil, default), do: default
  defp normalize_non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp normalize_non_neg_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_neg_integer(_value, default), do: default

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp normalize_datetime(_other), do: nil

  defp normalize_map(nil), do: %{}
  defp normalize_map(%{} = value), do: value
  defp normalize_map(_other), do: %{}
end
