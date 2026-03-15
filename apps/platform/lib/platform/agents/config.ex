defmodule Platform.Agents.Config do
  @moduledoc """
  Compatibility parser for OpenClaw `openclaw.json` agent definitions.

  The parser reads `agents.defaults`, `agents.list`, and `auth.profiles`,
  merges agent defaults into each entry, and translates each merged agent entry
  into attrs compatible with `Platform.Agents.Agent`.

  It intentionally skips channel/gateway runtime sections that do not belong to
  the platform Agent Runtime import path.
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.MemoryContext
  alias Platform.Repo

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

  @reserved_metadata_key "_openclaw"
  @memory_directory "memory"
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

  @doc """
  Import a `.openclaw` workspace folder into the platform database.

  The folder must contain an `openclaw.json` file and may include top-level
  markdown workspace files plus `memory/YYYY-MM-DD.md` daily memory logs.

  ## Options

    * `:agent_id` / `:slug` - select a specific agent entry from `agents.list`
    * `:slug_override` - persist the imported agent under a different slug
    * `:name_override` - persist the imported agent under a different name
    * `:workspace_id`, `:parent_agent_id`, `:status` - forwarded to `parse/2`
    * `:credential_values` - optional `%{"profile:name" => value}` map used to
      materialize `auth.profiles` into Vault credentials during import
    * `:credential_scope` - Vault scope tuple, default `{:platform, nil}`
  """
  @spec import_workspace(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_workspace(path, opts \\ []) do
    openclaw_path = Path.join(path, "openclaw.json")

    with {:ok, parsed} <- parse_file(openclaw_path, import_parse_opts(opts)),
         {:ok, parsed_agent} <- select_import_agent(parsed.agents, opts) do
      Repo.transaction(fn ->
        attrs =
          parsed_agent.attrs
          |> maybe_override_agent_attr(:slug, Keyword.get(opts, :slug_override))
          |> maybe_override_agent_attr(:name, Keyword.get(opts, :name_override))
          |> attach_openclaw_metadata(parsed.auth_profiles)

        agent =
          %Agent{}
          |> Agent.changeset(attrs)
          |> Repo.insert!()

        workspace_files = import_workspace_files!(agent.id, path)
        daily_memories = import_daily_memories!(agent.id, path)
        imported_credentials = import_auth_profiles!(parsed.auth_profiles, opts)

        %{
          agent: agent,
          config: parsed_agent,
          workspace_files: workspace_files,
          daily_memories: daily_memories,
          imported_credentials: imported_credentials
        }
      end)
      |> normalize_transaction_result()
    end
  end

  @doc """
  Import a `.openclaw` workspace folder, raising on failure.
  """
  @spec import_workspace!(Path.t(), keyword()) :: map()
  def import_workspace!(path, opts \\ []) do
    case import_workspace(path, opts) do
      {:ok, imported} ->
        imported

      {:error, reason} ->
        raise ArgumentError, "invalid OpenClaw workspace import: #{inspect(reason)}"
    end
  end

  @doc """
  Export an agent to the portable `.openclaw` folder format.

  The target directory will contain:

    * `openclaw.json` with a single `agents.list` entry
    * top-level workspace markdown files (`SOUL.md`, `AGENTS.md`, etc.)
    * `memory/YYYY-MM-DD.md` files reconstructed from daily agent memories
  """
  @spec export_workspace(Agent.t() | Ecto.UUID.t() | String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def export_workspace(agent_or_ref, path, opts \\ []) do
    with {:ok, agent} <- fetch_agent(agent_or_ref),
         {:ok, config} <- export_config(agent, opts),
         :ok <- File.mkdir_p(path) do
      workspace_files = MemoryContext.list_workspace_files(agent.id)
      daily_memories = list_all_memories(agent.id, :daily)
      long_term_memories = list_all_memories(agent.id, :long_term)

      config_path = Path.join(path, "openclaw.json")
      memory_dir = Path.join(path, @memory_directory)

      with :ok <-
             File.write(
               config_path,
               Jason.encode_to_iodata!(config, pretty: true) |> IO.iodata_to_binary()
             ),
           {:ok, written_workspace_files} <-
             export_workspace_files(path, workspace_files, long_term_memories),
           {:ok, written_daily_files} <- export_daily_memories(memory_dir, daily_memories) do
        {:ok,
         %{
           agent: agent,
           path: path,
           config_path: config_path,
           workspace_files: written_workspace_files,
           daily_memory_files: written_daily_files
         }}
      end
    end
  end

  @doc """
  Export an agent to the portable `.openclaw` folder format, raising on failure.
  """
  @spec export_workspace!(Agent.t() | Ecto.UUID.t() | String.t(), Path.t(), keyword()) :: map()
  def export_workspace!(agent_or_ref, path, opts \\ []) do
    case export_workspace(agent_or_ref, path, opts) do
      {:ok, exported} ->
        exported

      {:error, reason} ->
        raise ArgumentError, "invalid OpenClaw workspace export: #{inspect(reason)}"
    end
  end

  @doc """
  Build an `openclaw.json` map for a single persisted agent.
  """
  @spec export_config(Agent.t() | Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def export_config(agent_or_ref, opts \\ []) do
    with {:ok, agent} <- fetch_agent(agent_or_ref) do
      agent_metadata = normalize_map(agent.metadata || %{})
      openclaw_meta = normalize_map(Map.get(agent_metadata, @reserved_metadata_key, %{}))

      auth_profiles =
        normalize_map(Keyword.get(opts, :auth_profiles) || openclaw_meta["auth_profiles"] || %{})

      agent_entry =
        agent
        |> export_agent_entry()
        |> deep_merge(normalize_map(Keyword.get(opts, :agent_overrides, %{})))

      config =
        %{
          "agents" => %{
            "defaults" => %{},
            "list" => [agent_entry]
          }
        }
        |> maybe_put_top_level_auth(auth_profiles)

      {:ok, config}
    end
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

  defp select_import_agent([agent], _opts), do: {:ok, agent}

  defp select_import_agent(agents, opts) do
    target = Keyword.get(opts, :agent_id) || Keyword.get(opts, :slug)

    case target do
      nil ->
        {:error, {:multiple_agents, Enum.map(agents, & &1.id)}}

      target ->
        case Enum.find(agents, &(&1.id == target)) do
          nil -> {:error, {:agent_not_found, target}}
          agent -> {:ok, agent}
        end
    end
  end

  defp import_parse_opts(opts) do
    opts
    |> Keyword.take([:workspace_id, :parent_agent_id, :status])
  end

  defp maybe_override_agent_attr(attrs, _key, nil), do: attrs
  defp maybe_override_agent_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp attach_openclaw_metadata(attrs, auth_profiles) do
    reserved = %{
      @reserved_metadata_key => %{
        "auth_profiles" => normalize_map(auth_profiles)
      }
    }

    Map.update(attrs, :metadata, reserved, &deep_merge(normalize_map(&1), reserved))
  end

  defp import_workspace_files!(agent_id, path) do
    path
    |> workspace_file_paths()
    |> Enum.map(fn file_path ->
      file_key = Path.basename(file_path)

      {:ok, workspace_file} =
        MemoryContext.upsert_workspace_file(agent_id, file_key, File.read!(file_path))

      workspace_file
    end)
  end

  defp workspace_file_paths(path) do
    path
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp import_daily_memories!(agent_id, path) do
    path
    |> daily_memory_paths()
    |> Enum.map(fn file_path ->
      basename = Path.basename(file_path, ".md")
      {:ok, date} = Date.from_iso8601(basename)

      {:ok, memory} =
        MemoryContext.append_memory(agent_id, :daily, File.read!(file_path),
          date: date,
          metadata: %{
            "source" => "openclaw_import",
            "file" => Path.join(@memory_directory, Path.basename(file_path))
          }
        )

      memory
    end)
  end

  defp daily_memory_paths(path) do
    path
    |> Path.join(Path.join(@memory_directory, "*.md"))
    |> Path.wildcard()
    |> Enum.filter(fn file_path ->
      case Date.from_iso8601(Path.basename(file_path, ".md")) do
        {:ok, _date} -> true
        _ -> false
      end
    end)
    |> Enum.sort()
  end

  defp import_auth_profiles!(auth_profiles, opts) do
    credential_values = normalize_map(Keyword.get(opts, :credential_values, %{}))

    auth_profiles
    |> normalize_map()
    |> Enum.reduce([], fn {profile_name, profile}, acc ->
      profile = normalize_map(profile)

      case Map.fetch(credential_values, profile_name) do
        {:ok, value} ->
          [{profile_name, import_auth_profile!(profile_name, profile, value, opts)} | acc]

        :error ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp import_auth_profile!(profile_name, profile, value, opts) do
    provider = canonical_profile_provider(Map.get(profile, "provider"))
    mode = normalize_profile_mode(Map.get(profile, "mode"))
    slug = Map.get(profile, "slug") || default_profile_slug(provider, mode, profile_name)
    scope = Keyword.get(opts, :credential_scope, {:platform, nil})

    credential_type = credential_type_for_mode!(mode)
    payload = credential_payload(mode, value)

    {:ok, credential} =
      Platform.Vault.put(slug, credential_type, payload,
        provider: provider,
        scope: scope,
        name: profile_name,
        metadata: %{
          "openclaw_profile" => profile_name,
          "mode" => mode
        }
      )

    credential
  end

  defp canonical_profile_provider(provider) when is_binary(provider) do
    case provider do
      "openai-codex" -> "openai"
      other -> other
    end
  end

  defp canonical_profile_provider(provider), do: to_string(provider)

  defp normalize_profile_mode(nil), do: "token"

  defp normalize_profile_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
  end

  defp credential_type_for_mode!("oauth"), do: :oauth2
  defp credential_type_for_mode!("token"), do: :api_key

  defp credential_type_for_mode!(mode),
    do: raise(ArgumentError, "unsupported auth profile mode: #{inspect(mode)}")

  defp credential_payload("oauth", %{} = payload), do: Jason.encode!(payload)

  defp credential_payload("oauth", payload) when is_binary(payload) do
    trimmed = String.trim(payload)

    case Jason.decode(trimmed) do
      {:ok, %{} = _decoded} -> trimmed
      _ -> Jason.encode!(%{"access_token" => trimmed})
    end
  end

  defp credential_payload(_mode, %{} = payload), do: Jason.encode!(payload)
  defp credential_payload(_mode, payload), do: to_string(payload)

  defp default_profile_slug("anthropic", "oauth", _profile_name), do: "anthropic-oauth"
  defp default_profile_slug("openai", "oauth", _profile_name), do: "openai-oauth"
  defp default_profile_slug(provider, "oauth", _profile_name), do: "#{provider}-oauth"
  defp default_profile_slug(provider, "token", _profile_name), do: "#{provider}-api-key"

  defp export_agent_entry(%Agent{} = agent) do
    agent_metadata = normalize_map(agent.metadata || %{})

    {openclaw_reserved, metadata} = Map.pop(agent_metadata, @reserved_metadata_key)
    _ = openclaw_reserved

    model_config = normalize_map(agent.model_config || %{})
    model_section = Map.drop(model_config, ["models"])
    models_section = normalize_map(Map.get(model_config, "models", %{}))

    %{
      "id" => agent.slug,
      "name" => agent.name
    }
    |> maybe_put("model", empty_map_to_nil(model_section))
    |> maybe_put("models", empty_map_to_nil(models_section))
    |> maybe_put("tools", empty_map_to_nil(normalize_map(agent.tools_config || %{})))
    |> maybe_put("thinkingDefault", agent.thinking_default)
    |> maybe_put("heartbeat", empty_map_to_nil(normalize_map(agent.heartbeat_config || %{})))
    |> maybe_put("maxConcurrent", agent.max_concurrent)
    |> maybe_put("sandbox", export_sandbox(agent.sandbox_mode))
    |> deep_merge(export_metadata(metadata))
  end

  defp export_metadata(metadata) do
    metadata
    |> Map.drop(["workspace"])
    |> empty_map_to_nil()
    |> case do
      nil -> %{}
      map -> map
    end
  end

  defp export_sandbox(nil), do: nil
  defp export_sandbox(mode), do: %{"mode" => mode}

  defp maybe_put_top_level_auth(config, auth_profiles) when map_size(auth_profiles) == 0,
    do: config

  defp maybe_put_top_level_auth(config, auth_profiles) do
    Map.put(config, "auth", %{"profiles" => auth_profiles})
  end

  defp export_workspace_files(path, workspace_files, long_term_memories) do
    written =
      Enum.map(workspace_files, fn workspace_file ->
        file_path = Path.join(path, workspace_file.file_key)
        :ok = File.write(file_path, workspace_file.content)
        file_path
      end)

    memory_file_path = Path.join(path, "MEMORY.md")

    cond do
      Enum.any?(workspace_files, &(&1.file_key == "MEMORY.md")) ->
        {:ok, written}

      long_term_memories == [] ->
        {:ok, written}

      true ->
        contents =
          long_term_memories
          |> Enum.sort_by(&{&1.inserted_at, &1.id})
          |> Enum.map_join("\n\n", & &1.content)

        :ok = File.write(memory_file_path, contents)
        {:ok, written ++ [memory_file_path]}
    end
  end

  defp export_daily_memories(_memory_dir, []), do: {:ok, []}

  defp export_daily_memories(memory_dir, daily_memories) do
    :ok = File.mkdir_p(memory_dir)

    written =
      daily_memories
      |> Enum.group_by(& &1.date)
      |> Enum.sort_by(fn {date, _entries} -> date end)
      |> Enum.map(fn {date, entries} ->
        contents =
          entries
          |> Enum.sort_by(&{&1.inserted_at, &1.id})
          |> Enum.map_join("\n\n", & &1.content)

        file_path = Path.join(memory_dir, "#{Date.to_iso8601(date)}.md")
        :ok = File.write(file_path, contents)
        file_path
      end)

    {:ok, written}
  end

  defp list_all_memories(agent_id, memory_type) do
    MemoryContext.list_memories(agent_id, memory_type: memory_type, limit: 10_000)
  end

  defp fetch_agent(%Agent{} = agent), do: {:ok, agent}

  defp fetch_agent(value) when is_binary(value) do
    cond do
      match?({:ok, _}, Ecto.UUID.cast(value)) ->
        case Repo.get(Agent, value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end

      true ->
        case Repo.get_by(Agent, slug: value) do
          %Agent{} = agent -> {:ok, agent}
          nil -> {:error, :not_found}
        end
    end
  end

  defp fetch_agent(_other), do: {:error, :not_found}

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
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
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

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
