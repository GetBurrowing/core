defmodule Platform.Agents.ContextScope do
  @moduledoc """
  Declarative rules for parent → child context inheritance.

  The scope decides which portions of a parent session's runtime context are
  copied into a child session's immutable `Context.inherited` payload.
  """

  @valid_shares ~w(full memory_only config_only custom)a

  @type share_mode :: :full | :memory_only | :config_only | :custom

  @type t :: %__MODULE__{
          share: share_mode(),
          include_keys: [String.t()] | nil,
          exclude_keys: [String.t()] | nil,
          include_memory: boolean(),
          include_workspace: boolean(),
          max_depth: non_neg_integer() | :unlimited
        }

  @enforce_keys [:share]
  defstruct share: :full,
            include_keys: nil,
            exclude_keys: nil,
            include_memory: true,
            include_workspace: true,
            max_depth: 1

  @doc "Normalizes a scope map/keyword/struct into `%ContextScope{}`."
  @spec new(t() | map() | keyword() | atom() | String.t() | nil) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = scope), do: {:ok, normalize_scope(scope)}
  def new(nil), do: {:ok, %__MODULE__{share: :full}}
  def new(share) when is_atom(share) or is_binary(share), do: new(%{share: share})

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, share} <- normalize_share(fetch_attr(attrs, :share, :full)),
         {:ok, max_depth} <- normalize_max_depth(fetch_attr(attrs, :max_depth)) do
      scope =
        %__MODULE__{
          share: share,
          include_keys: normalize_key_list(fetch_attr(attrs, :include_keys)),
          exclude_keys: normalize_key_list(fetch_attr(attrs, :exclude_keys)),
          include_memory: normalize_boolean(fetch_attr(attrs, :include_memory)),
          include_workspace: normalize_boolean(fetch_attr(attrs, :include_workspace)),
          max_depth: max_depth || 1
        }
        |> normalize_scope()

      {:ok, scope}
    end
  end

  def new(_other), do: {:error, :invalid_scope}

  @doc "Returns the JSON-serializable filter persisted on `agent_context_shares`."
  @spec to_filter(t()) :: map()
  def to_filter(%__MODULE__{} = scope) do
    %{
      "share" => Atom.to_string(scope.share),
      "include_keys" => scope.include_keys,
      "exclude_keys" => scope.exclude_keys,
      "include_memory" => scope.include_memory,
      "include_workspace" => scope.include_workspace,
      "max_depth" => normalize_max_depth_for_json(scope.max_depth)
    }
  end

  defp normalize_scope(%__MODULE__{share: :full} = scope) do
    %__MODULE__{scope | include_memory: true, include_workspace: true}
  end

  defp normalize_scope(%__MODULE__{share: :memory_only} = scope) do
    %__MODULE__{scope | include_memory: true, include_workspace: false}
  end

  defp normalize_scope(%__MODULE__{share: :config_only} = scope) do
    %__MODULE__{scope | include_memory: false, include_workspace: true}
  end

  defp normalize_scope(%__MODULE__{} = scope), do: scope

  defp normalize_share(share) when share in @valid_shares, do: {:ok, share}

  defp normalize_share(share) when is_binary(share) do
    share
    |> String.trim()
    |> String.downcase()
    |> case do
      "full" -> {:ok, :full}
      "memory_only" -> {:ok, :memory_only}
      "config_only" -> {:ok, :config_only}
      "custom" -> {:ok, :custom}
      _ -> {:error, :invalid_scope}
    end
  end

  defp normalize_share(_other), do: {:error, :invalid_scope}

  defp fetch_attr(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp normalize_key_list(nil), do: nil
  defp normalize_key_list([]), do: []

  defp normalize_key_list(keys) when is_list(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_key_list(_other), do: nil

  defp normalize_boolean(nil), do: true
  defp normalize_boolean(value) when value in [true, false], do: value
  defp normalize_boolean(_other), do: true

  defp normalize_max_depth(nil), do: {:ok, nil}
  defp normalize_max_depth(:unlimited), do: {:ok, :unlimited}
  defp normalize_max_depth("unlimited"), do: {:ok, :unlimited}
  defp normalize_max_depth(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_max_depth(_other), do: {:error, :invalid_max_depth}

  defp normalize_max_depth_for_json(:unlimited), do: "unlimited"
  defp normalize_max_depth_for_json(value), do: value
end
