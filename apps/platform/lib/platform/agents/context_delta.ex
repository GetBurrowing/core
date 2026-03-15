defmodule Platform.Agents.ContextDelta do
  @moduledoc """
  Child → parent context promotion payload.

  The delta captures local additions/removals plus optional memory writes that a
  parent may choose to merge back into its own active session state.
  """

  @type memory_update :: %{
          required(:memory_type) => atom() | String.t(),
          required(:content) => String.t(),
          optional(:date) => Date.t(),
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          from_agent: Ecto.UUID.t(),
          from_session: Ecto.UUID.t(),
          additions: map(),
          removals: [String.t()],
          memory_updates: [memory_update()],
          promote: boolean()
        }

  @enforce_keys [:from_agent, :from_session]
  defstruct from_agent: nil,
            from_session: nil,
            additions: %{},
            removals: [],
            memory_updates: [],
            promote: false

  @doc "Normalizes a delta map/keyword/struct into `%ContextDelta{}`."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = delta), do: {:ok, normalize_delta(delta)}

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    from_agent = fetch_attr(attrs, :from_agent)
    from_session = fetch_attr(attrs, :from_session)

    cond do
      is_nil(from_agent) ->
        {:error, :missing_from_agent}

      is_nil(from_session) ->
        {:error, :missing_from_session}

      true ->
        {:ok,
         %__MODULE__{
           from_agent: to_string(from_agent),
           from_session: to_string(from_session),
           additions: normalize_map(fetch_attr(attrs, :additions)),
           removals: normalize_removals(fetch_attr(attrs, :removals)),
           memory_updates: normalize_memory_updates(fetch_attr(attrs, :memory_updates)),
           promote: normalize_promote(fetch_attr(attrs, :promote))
         }
         |> normalize_delta()}
    end
  end

  def new(_other), do: {:error, :invalid_delta}

  @doc "Returns a JSON-serializable delta map for storage or telemetry."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = delta) do
    %{
      "from_agent" => delta.from_agent,
      "from_session" => delta.from_session,
      "additions" => delta.additions,
      "removals" => delta.removals,
      "memory_updates" => Enum.map(delta.memory_updates, &stringify_map/1),
      "promote" => delta.promote
    }
  end

  defp normalize_delta(%__MODULE__{} = delta) do
    %__MODULE__{
      delta
      | additions: normalize_map(delta.additions),
        removals: normalize_removals(delta.removals),
        memory_updates: normalize_memory_updates(delta.memory_updates),
        promote: normalize_promote(delta.promote)
    }
  end

  defp fetch_attr(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp normalize_map(nil), do: %{}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_map(_other), do: %{}

  defp normalize_value(map) when is_map(map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_value(%Date{} = date), do: date
  defp normalize_value(value), do: value

  defp normalize_removals(nil), do: []

  defp normalize_removals(removals) when is_list(removals) do
    removals
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_removals(_other), do: []

  defp normalize_memory_updates(nil), do: []

  defp normalize_memory_updates(memory_updates) when is_list(memory_updates) do
    Enum.flat_map(memory_updates, fn
      %{} = update -> [normalize_memory_update(update)]
      _other -> []
    end)
  end

  defp normalize_memory_updates(_other), do: []

  defp normalize_memory_update(update) do
    %{
      memory_type:
        Map.get(update, :memory_type) ||
          Map.get(update, "memory_type") || "long_term",
      content: to_string(Map.get(update, :content) || Map.get(update, "content") || ""),
      date: Map.get(update, :date) || Map.get(update, "date"),
      metadata: normalize_map(Map.get(update, :metadata) || Map.get(update, "metadata"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_promote(value) when value in [true, false], do: value
  defp normalize_promote(_other), do: false

  defp stringify_map(map) when is_map(map), do: normalize_map(map)
end
