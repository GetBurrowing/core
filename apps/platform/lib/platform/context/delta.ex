defmodule Platform.Context.Delta do
  @moduledoc """
  A versioned, scope-targeted context mutation.

  A delta describes a batch of puts + deletes applied atomically to a context
  session.  Every applied delta increments the session's monotonic `version`.

  Deltas are stored in the ETS delta-log so runners that missed an update can
  catch up by calling `Platform.Context.latest_delta/2`.

  Fields:
    - `scope_key`   — string cache key of the target session
    - `version`     — the version assigned when this delta was applied
    - `puts`        — map of `key => {value, opts}` to upsert
    - `deletes`     — list of keys to remove
    - `source`      — optional string identifying the originating process
    - `applied_at`  — wall-clock timestamp
  """

  @enforce_keys [:scope_key, :version]
  defstruct scope_key: nil,
            version: 0,
            puts: %{},
            deletes: [],
            source: nil,
            applied_at: nil

  @type t :: %__MODULE__{
          scope_key: String.t(),
          version: non_neg_integer(),
          puts: %{optional(String.t()) => {term(), keyword()}},
          deletes: [String.t()],
          source: String.t() | nil,
          applied_at: DateTime.t() | nil
        }

  @doc """
  Normalizes a raw delta map/keyword into `%Delta{}`.

  Accepts:
    - `%Platform.Context.Delta{}`
    - map with string or atom keys: `puts`, `deletes`, `source`
    - keyword list

  `scope_key` and `version` are assigned by the Cache on apply; callers may
  omit them.
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = d), do: {:ok, d}

  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    puts = fetch(attrs, :puts) |> normalize_puts()
    deletes = fetch(attrs, :deletes) |> normalize_deletes()
    source = fetch(attrs, :source) |> normalize_source()

    {:ok,
     %__MODULE__{
       scope_key: fetch(attrs, :scope_key) |> normalize_source(),
       version: fetch(attrs, :version) |> normalize_version(),
       puts: puts,
       deletes: deletes,
       source: source,
       applied_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
     }}
  end

  def new(_), do: {:error, :invalid_delta}

  @doc "Serializes a delta to a plain map for wire/storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d) do
    %{
      "scope_key" => d.scope_key,
      "version" => d.version,
      "puts" => Map.new(d.puts, fn {k, {v, _opts}} -> {k, v} end),
      "deletes" => d.deletes,
      "source" => d.source,
      "applied_at" => if(d.applied_at, do: DateTime.to_iso8601(d.applied_at), else: nil)
    }
  end

  # ---------------------------------------------------------------------------
  # Private normalizers
  # ---------------------------------------------------------------------------

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp normalize_puts(nil), do: %{}

  defp normalize_puts(map) when is_map(map) do
    Map.new(map, fn
      {k, {v, opts}} when is_list(opts) -> {to_string(k), {v, opts}}
      {k, v} -> {to_string(k), {v, []}}
    end)
  end

  defp normalize_puts(_), do: %{}

  defp normalize_deletes(nil), do: []

  defp normalize_deletes(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp normalize_deletes(_), do: []

  defp normalize_source(nil), do: nil
  defp normalize_source(s) when is_binary(s), do: s
  defp normalize_source(a) when is_atom(a), do: Atom.to_string(a)
  defp normalize_source(_), do: nil

  defp normalize_version(nil), do: 0
  defp normalize_version(v) when is_integer(v) and v >= 0, do: v
  defp normalize_version(_), do: 0
end
