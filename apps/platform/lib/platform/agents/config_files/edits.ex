defmodule Platform.Agents.ConfigFiles.Edits do
  @moduledoc """
  Pure helpers the configuration screen (task 01a17b1c stage 5) uses to turn
  an adapter and a file list into sections, and an edit into the bytes
  `Platform.Agents.ConfigFiles.write/5` receives. No I/O, no access checks:
  every byte still goes through `ConfigFiles`, which authorizes and audits.

  Everything here works on what a read returns, i.e. REDACTED content. A
  `[redacted]` placeholder written back means "unchanged": the store backend
  restores it (`Redaction.restore/3`) and the host keeps the on-disk value.
  """

  alias Platform.Agents.Harness
  alias Platform.Agents.Harness.Config

  @labels %{
    instructions: "Instructions",
    skills: "Skills",
    subagents: "Subagents",
    commands: "Commands",
    settings: "Settings",
    mcp_servers: "MCP servers"
  }

  @entry_concepts [:skills, :subagents, :commands]

  @known_settings %{
    "claude_code" => [{"model", "Model"}],
    "codex" => [
      {"model", "Model"},
      {"model_reasoning_effort", "Reasoning effort"},
      {"approval_policy", "When to ask before acting"},
      {"sandbox_mode", "What it may touch on the machine"}
    ]
  }

  @name_re ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @doc "Concepts listed as entries (a list of files, one per item)."
  def entry_concepts, do: @entry_concepts

  @doc "The plain label for a concept."
  def label(concept), do: Map.fetch!(@labels, concept)

  @doc """
  The sections for `adapter`, in the canvas order, each
  `%{id, label, path, count}`. Only the adapter's `concepts/0` appear: no
  empty or placeholder section for anything the harness does not have.
  """
  @spec sections(module(), [map()], non_neg_integer()) :: [map()]
  def sections(adapter, file_entries, mcp_count) do
    for concept <- [:instructions, :skills, :subagents, :commands, :settings, :mcp_servers],
        concept in adapter.concepts() do
      count =
        cond do
          concept in @entry_concepts -> length(entries(adapter, concept, file_entries))
          concept == :mcp_servers -> mcp_count
          true -> nil
        end

      %{id: concept, label: label(concept), path: path_hint(adapter, concept), count: count}
    end
  end

  @doc "The real path shown under a section label."
  def path_hint(adapter, :instructions), do: adapter.instructions_path()
  def path_hint(adapter, :settings), do: adapter.settings_path()
  def path_hint(adapter, :mcp_servers), do: mcp_path(adapter)

  def path_hint(adapter, concept) when concept in @entry_concepts,
    do: adapter |> entry_glob(concept) |> String.split("*") |> hd()

  @doc "The file MCP servers live in: `.mcp.json` for Claude Code, `config.toml` for Codex."
  def mcp_path(adapter) do
    if Enum.any?(adapter.known_paths(), &(elem(&1, 0) == ".mcp.json")),
      do: ".mcp.json",
      else: adapter.settings_path()
  end

  @doc "The file MCP approvals live in, when the harness has one (Claude Code)."
  def approval_path(adapter) do
    if Enum.any?(adapter.known_paths(), &(elem(&1, 0) == ".claude/settings.local.json")),
      do: ".claude/settings.local.json"
  end

  @doc "The glob of one entry concept, from the adapter's known paths."
  def entry_glob(adapter, concept) do
    match =
      case concept do
        :skills -> &String.ends_with?(&1, "/*/SKILL.md")
        :subagents -> &String.contains?(&1, "/agents/*")
        :commands -> &String.contains?(&1, "/commands/*")
      end

    Enum.find_value(adapter.known_paths(), fn {glob, _} -> if match.(glob), do: glob end)
  end

  @doc "Entries of `concept` among the listed files: `[%{name, path, sha256}]`, by name."
  def entries(adapter, concept, file_entries) do
    glob = entry_glob(adapter, concept)
    [prefix, suffix] = String.split(glob, "*", parts: 2)

    for %{path: path} = e <- file_entries, Harness.glob_match?(glob, path) do
      name = path |> String.replace_prefix(prefix, "") |> String.replace_suffix(suffix, "")
      %{name: name, path: path, sha256: e.sha256}
    end
    |> Enum.sort_by(& &1.name)
  end

  @doc "The path a new entry called `name` is written to, or an error for a bad name."
  @spec entry_path(module(), atom(), String.t()) :: {:ok, String.t()} | {:error, :invalid_name}
  def entry_path(adapter, concept, name) do
    name = String.trim(name || "")

    if Regex.match?(@name_re, name),
      do: {:ok, String.replace(entry_glob(adapter, concept), "*", name)},
      else: {:error, :invalid_name}
  end

  @doc "What a new entry starts with: frontmatter naming it, and an empty description."
  def entry_seed(name), do: Harness.frontmatter_doc([{"name", name}, {"description", ""}], "\n")

  @doc "The one-line description from an entry's frontmatter (\"\" when none)."
  def description(content) when is_binary(content) do
    {fm, _} = Harness.parse_frontmatter(content)
    fm |> Map.get("description", "") |> to_string() |> String.split("\n") |> hd()
  end

  def description(_), do: ""

  @doc "True for a markdown file (Edit / Preview)."
  def markdown?(path), do: String.ends_with?(path, ".md")

  @doc "The language a raw editor holds: :json, :toml or :markdown."
  def language(path) do
    cond do
      String.ends_with?(path, ".json") -> :json
      String.ends_with?(path, ".toml") -> :toml
      true -> :markdown
    end
  end

  @doc """
  The 1-based line of the first parse error in a JSON or TOML file, or nil
  when it parses (or is markdown). Save stays disabled while it is not nil.
  """
  @spec parse_error_line(String.t(), binary()) :: pos_integer() | nil
  def parse_error_line(path, content) do
    case language(path) do
      :json ->
        case Platform.Agents.NativeAgents.check_json(path, content) do
          :ok -> nil
          {:error, {:invalid_json, line}} -> line
        end

      :toml ->
        case Toml.decode(content) do
          {:ok, _} ->
            nil

          {:error, {:invalid_toml, msg}} when is_binary(msg) ->
            case Regex.run(~r/on line (\d+)/, msg) do
              [_, n] -> String.to_integer(n)
              _ -> 1
            end

          {:error, _} ->
            1
        end

      :markdown ->
        nil
    end
  end

  # ── settings ───────────────────────────────────────────────────────

  @doc "The known settings keys for a harness, with plain-language labels."
  def known_settings(adapter), do: Map.get(@known_settings, adapter.harness(), [])

  @doc "Current values of the known keys, as strings (\"\" when unset or not a string)."
  def known_values(adapter, content) do
    doc =
      case decode(adapter.settings_path(), content || "") do
        {:ok, m} -> m
        _ -> %{}
      end

    Map.new(known_settings(adapter), fn {key, _} ->
      {key, if(is_binary(doc[key]), do: doc[key], else: "")}
    end)
  end

  @doc """
  Apply `values` (key => string; "" removes the key) to a settings file.
  JSON is re-encoded; TOML is edited line by line so comments and order
  survive.
  """
  @spec put_known(module(), binary() | nil, map()) :: {:ok, binary()} | {:error, :unparseable}
  def put_known(adapter, content, values) do
    path = adapter.settings_path()
    keys = Enum.map(known_settings(adapter), &elem(&1, 0))
    values = Map.take(values, keys)

    case language(path) do
      :json ->
        with {:ok, doc} <- decode(path, content || "") do
          doc =
            Enum.reduce(values, doc, fn
              {k, ""}, acc -> Map.delete(acc, k)
              {k, v}, acc -> Map.put(acc, k, v)
            end)

          {:ok, Harness.encode_json(doc)}
        end

      :toml ->
        with {:ok, _} <- decode(path, content || "") do
          {:ok, Enum.reduce(values, content || "", fn {k, v}, acc -> toml_put(acc, k, v) end)}
        end
    end
  end

  # A top-level key lives before the first table header.
  defp toml_put(content, key, value) do
    lines = String.split(content, "\n")
    {head, tail} = Enum.split_while(lines, &(not Regex.match?(~r/\A\s*\[/, &1)))
    re = ~r/\A\s*#{Regex.escape(key)}\s*=/
    line = "#{key} = #{Jason.encode!(value)}"

    head =
      cond do
        Enum.any?(head, &Regex.match?(re, &1)) and value == "" ->
          Enum.reject(head, &Regex.match?(re, &1))

        Enum.any?(head, &Regex.match?(re, &1)) ->
          Enum.map(head, &if(Regex.match?(re, &1), do: line, else: &1))

        value == "" ->
          head

        true ->
          {comments, rest} = Enum.split_while(head, &String.starts_with?(&1, "#"))
          comments ++ [line] ++ rest
      end

    Enum.join(head ++ tail, "\n")
  end

  defp decode(path, content) do
    case language(path) do
      :json when content == "" ->
        {:ok, %{}}

      :json ->
        case Jason.decode(content) do
          {:ok, %{} = m} -> {:ok, m}
          _ -> {:error, :unparseable}
        end

      :toml ->
        case Toml.decode(content) do
          {:ok, m} -> {:ok, m}
          _ -> {:error, :unparseable}
        end
    end
  end

  # ── MCP servers ────────────────────────────────────────────────────

  @doc "The MCP servers in a (redacted) file, Burrow's own left out."
  @spec mcp_servers(module(), binary() | nil) :: [map()]
  def mcp_servers(adapter, content) do
    case adapter.parse([{mcp_path(adapter), content || ""}]) do
      {:ok, %Config{} = c} -> Config.writable_servers(c)
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  The secret rows of one server: `[%{name, kind, pointer}]`, where `pointer` is
  what `ConfigFiles.set_secret/5` takes for `mcp_path/1`.
  """
  def server_secrets(adapter, server) do
    root = if mcp_path(adapter) == ".mcp.json", do: "mcpServers", else: "mcp_servers"
    headers = if root == "mcpServers", do: "headers", else: "http_headers"

    Enum.map(
      server.env_names,
      &%{name: &1, kind: :env, pointer: "#{root}/#{server.name}/env/#{&1}"}
    ) ++
      Enum.map(
        server.header_names,
        &%{name: &1, kind: :header, pointer: "#{root}/#{server.name}/#{headers}/#{&1}"}
      )
  end

  @doc """
  The writes that add an MCP server: `{:ok, [{path, new_content}]}` against
  the current (redacted) contents in `files` (path => content or nil).
  Claude Code also gets the approval in `.claude/settings.local.json`, or
  burrow-cli would skip the server on restart. Codex gets a
  `[mcp_servers.<name>]` table appended, so the rest of the file is untouched.
  """
  @spec add_mcp_server(module(), map(), map()) ::
          {:ok, [{String.t(), binary()}]} | {:error, atom()}
  def add_mcp_server(adapter, files, attrs) do
    name = String.trim(attrs["name"] || "")
    command = String.trim(attrs["command"] || "")
    url = String.trim(attrs["url"] || "")
    args = attrs["args"] |> to_string() |> String.split(~r/\s+/, trim: true)
    existing = adapter |> mcp_servers(files[mcp_path(adapter)]) |> Enum.map(& &1.name)

    cond do
      not Regex.match?(@name_re, name) ->
        {:error, :invalid_name}

      name in Config.burrow_server_names() or name in existing ->
        {:error, :name_taken}

      command == "" and url == "" ->
        {:error, :command_or_url}

      mcp_path(adapter) == ".mcp.json" ->
        add_claude_server(adapter, files, name, command, args, url)

      true ->
        add_codex_server(adapter, files, name, command, args, url)
    end
  end

  defp add_claude_server(adapter, files, name, command, args, url) do
    entry =
      if url != "",
        do: %{"type" => "http", "url" => url},
        else: %{"command" => command, "args" => args}

    approval = approval_path(adapter)

    with {:ok, mcp} <- decode(".mcp.json", files[".mcp.json"] || ""),
         {:ok, local} <- decode(approval, files[approval] || "") do
      servers = Map.get(mcp, "mcpServers", %{}) |> then(&if(is_map(&1), do: &1, else: %{}))
      enabled = List.wrap(local["enabledMcpjsonServers"])

      {:ok,
       [
         {".mcp.json",
          Harness.encode_json(Map.put(mcp, "mcpServers", Map.put(servers, name, entry)))},
         {approval,
          Harness.encode_json(
            Map.put(local, "enabledMcpjsonServers", Enum.uniq(enabled ++ [name]))
          )}
       ]}
    end
  end

  defp add_codex_server(adapter, files, name, command, args, url) do
    path = mcp_path(adapter)
    current = files[path] || ""

    with {:ok, _} <- decode(path, current) do
      body =
        if url != "",
          do: "url = #{Jason.encode!(url)}\n",
          else:
            "command = #{Jason.encode!(command)}\n" <>
              if(args == [], do: "", else: "args = #{Jason.encode!(args)}\n")

      sep = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
      {:ok, [{path, current <> sep <> "\n[mcp_servers.#{name}]\n" <> body}]}
    end
  end
end
