defmodule Platform.Agents.Config do
  @moduledoc """
  Compatibility parser for OpenClaw `openclaw.json` agent definitions.

  The parser reads `agents.defaults`, `agents.list`, and `auth.profiles`,
  merges agent defaults into each entry, and translates each merged agent entry
  into attrs compatible with `Platform.Agents.Agent`.

  It intentionally skips channel/gateway runtime sections that do not belong to
  the platform Agent Runtime import path.
  """

  @type parsed_agent :: %{
          id: String.t(),
          name: String.t(),
          raw: map(),
          attrs: map()
        }

  @type parsed_config :: %{
          defaults: map(),
          auth_profiles: map(),
          skipped_sections: [String.t()],
          agents: [parsed_agent()]
        }

  @skipped_sections ~w(channels hooks gateway)
  @mapped_agent_keys ~w(id name model models tools thinkingDefault heartbeat maxConcurrent sandbox)

  @doc """
  Parse an OpenClaw config map or JSON string.

  ## Options

    * `:workspace_id` - include a `workspace_id` on each generated attrs map
    * `:parent_agent_id` - include a `parent_agent_id` on each generated attrs map
    * `:status` - override the default agent status (`"active"`)
  """
  @spec parse(binary() | map(), keyword()) :: {:ok, parsed_config()} | {:error, term()}
  def parse(source, opts \\ [])

  def parse(source, opts) when is_binary(source) do
    with {:ok, decoded} <- Jason.decode(source) do
      parse(decoded, opts)
    else
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  def parse(source, opts) when is_map(source) do
    config = stringify_keys(source)
    agents_section = normalize_map(Map.get(config, "agents", %{}))
    defaults = normalize_map(Map.get(agents_section, "defaults", %{}))
    auth_profiles = normalize_map(get_in(config, ["auth", "profiles"]) || %{})
    entries = Map.get(agents_section, "list")

    with :ok <- validate_agents_list(entries),
         :ok <- validate_unique_agent_ids(entries) do
      agents =
        Enum.map(entries, fn entry ->
          entry = normalize_map(entry)
          id = Map.fetch!(entry, "id")
          merged = deep_merge(defaults, entry)

          %{
            id: id,
            name: Map.get(merged, "name", id),
            raw: merged,
            attrs: to_agent_attrs(merged, opts)
          }
        end)

      {:ok,
       %{
         defaults: defaults,
         auth_profiles: auth_profiles,
         skipped_sections: Enum.filter(@skipped_sections, &Map.has_key?(config, &1)),
         agents: agents
       }}
    end
  end

  def parse(_source, _opts), do: {:error, {:invalid_config, "openclaw.json must decode to a map"}}

  @doc """
  Parse an OpenClaw config map or JSON string, raising on invalid input.
  """
  @spec parse!(binary() | map(), keyword()) :: parsed_config()
  def parse!(source, opts \\ []) do
    case parse(source, opts) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise ArgumentError, "invalid OpenClaw config: #{inspect(reason)}"
    end
  end

  @doc """
  Parse an OpenClaw config file from disk.
  """
  @spec parse_file(Path.t(), keyword()) :: {:ok, parsed_config()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    with {:ok, contents} <- File.read(path) do
      parse(contents, opts)
    end
  end

  @doc """
  Parse an OpenClaw config file from disk, raising on invalid input.
  """
  @spec parse_file!(Path.t(), keyword()) :: parsed_config()
  def parse_file!(path, opts \\ []) do
    case parse_file(path, opts) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise ArgumentError, "invalid OpenClaw config file: #{inspect(reason)}"
    end
  end

  @doc """
  Convert a merged OpenClaw agent config into attrs suitable for
  `Platform.Agents.Agent.changeset/2`.
  """
  @spec to_agent_attrs(map(), keyword()) :: map()
  def to_agent_attrs(agent_config, opts \\ []) when is_map(agent_config) do
    agent_config = normalize_map(agent_config)
    sandbox = Map.get(agent_config, "sandbox")

    attrs = %{
      slug: Map.fetch!(agent_config, "id"),
      name: Map.get(agent_config, "name") || Map.fetch!(agent_config, "id"),
      status: Keyword.get(opts, :status, "active"),
      model_config: build_model_config(agent_config),
      tools_config: normalize_map(Map.get(agent_config, "tools", %{})),
      heartbeat_config: normalize_heartbeat(Map.get(agent_config, "heartbeat")),
      metadata: build_metadata(agent_config, sandbox)
    }

    attrs
    |> maybe_put(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put(:parent_agent_id, Keyword.get(opts, :parent_agent_id))
    |> maybe_put(:thinking_default, Map.get(agent_config, "thinkingDefault"))
    |> maybe_put(:max_concurrent, Map.get(agent_config, "maxConcurrent"))
    |> maybe_put(:sandbox_mode, sandbox_mode(sandbox))
  end

  defp build_model_config(agent_config) do
    agent_config
    |> Map.get("model", %{})
    |> normalize_map()
    |> maybe_put("models", normalize_optional_map(Map.get(agent_config, "models")))
  end

  defp build_metadata(agent_config, sandbox) do
    agent_config
    |> Map.drop(@mapped_agent_keys)
    |> maybe_put("sandbox", sandbox_metadata(sandbox))
  end

  defp validate_agents_list(entries) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      :ok
    else
      {:error, {:invalid_config, "agents.list must contain only objects"}}
    end
  end

  defp validate_agents_list(_entries),
    do: {:error, {:invalid_config, "agents.list must be a list"}}

  defp validate_unique_agent_ids(entries) do
    ids =
      Enum.with_index(entries)
      |> Enum.map(fn {entry, index} ->
        entry = normalize_map(entry)

        case Map.get(entry, "id") do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, {:invalid_agent, index, "agent entries require a non-empty id"}}
        end
      end)

    case Enum.find(ids, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        duplicate_ids =
          ids
          |> Enum.map(fn {:ok, id} -> id end)
          |> Enum.frequencies()
          |> Enum.filter(fn {_id, count} -> count > 1 end)
          |> Enum.map(fn {id, _count} -> id end)
          |> Enum.sort()

        if duplicate_ids == [] do
          :ok
        else
          {:error, {:duplicate_agent_ids, duplicate_ids}}
        end
    end
  end

  defp sandbox_mode(%{} = sandbox), do: Map.get(stringify_keys(sandbox), "mode")
  defp sandbox_mode(mode) when is_binary(mode), do: mode
  defp sandbox_mode(_), do: nil

  defp sandbox_metadata(%{} = sandbox) do
    sandbox
    |> stringify_keys()
    |> Map.drop(["mode"])
    |> empty_map_to_nil()
  end

  defp sandbox_metadata(_), do: nil

  defp normalize_heartbeat(%{} = heartbeat), do: normalize_map(heartbeat)
  defp normalize_heartbeat(heartbeat) when is_binary(heartbeat), do: %{"every" => heartbeat}
  defp normalize_heartbeat(_), do: %{}

  defp deep_merge(%{} = left, %{} = right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: stringify_keys(right)

  defp normalize_map(%{} = map), do: stringify_keys(map)
  defp normalize_map(_), do: %{}

  defp normalize_optional_map(%{} = map), do: stringify_keys(map)
  defp normalize_optional_map(_), do: nil

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {stringify_key(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)

  defp empty_map_to_nil(map) when map == %{}, do: nil
  defp empty_map_to_nil(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
