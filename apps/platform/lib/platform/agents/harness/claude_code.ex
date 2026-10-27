defmodule Platform.Agents.Harness.ClaudeCode do
  @moduledoc """
  Claude Code: `CLAUDE.md`, `.claude/skills/<name>/SKILL.md`,
  `.claude/agents/<name>.md`, `.claude/commands/<name>.md`,
  `.claude/settings.json`, and MCP servers in `.mcp.json`.

  MCP APPROVAL. burrow-cli answers Claude's "New MCP server found in this
  project" dialog with "Continue without using this MCP server"
  (burrow-cli `src/claude_dialogs.ts`), so a server in `.mcp.json` that is not
  pre-approved is silently skipped on restart. `render/1` therefore also writes
  every server name into `enabledMcpjsonServers` in `.claude/settings.local.json`.

  Burrow's own `burrow` / `burrow-channel` entries live in local scope in
  `~/.claude.json` and carry the runtime token. They are out of write scope:
  `render/1` skips any server marked `managed_by_burrow?`.

  Secret values: `env` / `headers` in `.mcp.json` are written as `${NAME}`
  references to the environment, never as values. `parse/1` keeps only the
  names, and drops `env` from settings files.

  Restart: burrow-cli relaunches with `--continue`, so the conversation resumes.
  """

  @behaviour Platform.Agents.Harness.Adapter

  alias Platform.Agents.Harness
  alias Platform.Agents.Harness.Config

  @mcp ".mcp.json"
  @settings ".claude/settings.json"
  @local ".claude/settings.local.json"
  @known_settings ~w(model permissions)

  @impl true
  def harness, do: "claude_code"

  @impl true
  def concepts, do: [:instructions, :skills, :subagents, :commands, :settings, :mcp_servers]

  @impl true
  def instructions_path, do: "CLAUDE.md"

  @impl true
  def known_paths do
    [
      {"CLAUDE.md", :plain},
      {".claude/skills/*/SKILL.md", :plain},
      {".claude/agents/*.md", :plain},
      {".claude/commands/*.md", :plain},
      {@settings, :secret_bearing},
      {@local, :secret_bearing},
      {@mcp, :secret_bearing},
      {".claude/.credentials.json", :secret}
    ]
  end

  @impl true
  def restart_resumes?, do: true

  @impl true
  def render(%Config{} = c) do
    instructions =
      if c.instructions in [nil, ""], do: [], else: [{"CLAUDE.md", c.instructions}]

    skills =
      for s <- c.skills do
        {".claude/skills/#{Harness.safe_name!(s.name)}/SKILL.md",
         Harness.frontmatter_doc([{"name", s.name}, {"description", s.description}], s.body)}
      end

    agents =
      for s <- c.subagents do
        {".claude/agents/#{Harness.safe_name!(s.name)}.md",
         Harness.frontmatter_doc([{"name", s.name}, {"description", s.description}], s.body)}
      end

    commands =
      for s <- c.commands do
        {".claude/commands/#{Harness.safe_name!(s.name)}.md",
         Harness.frontmatter_doc([{"description", s.description}], s.body)}
      end

    settings =
      case Map.merge(stringify(c.settings.raw), stringify(c.settings.known)) do
        empty when map_size(empty) == 0 -> []
        merged -> [{@settings, Harness.encode_json(merged)}]
      end

    (instructions ++
       skills ++ agents ++ commands ++ settings ++ render_mcp(Config.writable_servers(c)))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp render_mcp([]), do: []

  defp render_mcp(servers) do
    entries = Map.new(servers, fn s -> {s.name, mcp_entry(s)} end)

    [
      {@mcp, Harness.encode_json(%{"mcpServers" => entries})},
      {@local, Harness.encode_json(%{"enabledMcpjsonServers" => Enum.map(servers, & &1.name)})}
    ]
  end

  defp mcp_entry(%{transport: :http} = s) do
    %{"type" => "http", "url" => s.url}
    |> put_unless_empty(
      "headers",
      Map.new(s.header_names, &{&1, "${#{Harness.header_env_name(&1)}}"})
    )
  end

  defp mcp_entry(s) do
    %{"command" => s.command}
    |> put_unless_empty("args", s.args)
    |> put_unless_empty("env", Map.new(s.env_names, &{&1, "${#{&1}}"}))
  end

  defp put_unless_empty(map, _k, v) when v in [[], %{}], do: map
  defp put_unless_empty(map, k, v), do: Map.put(map, k, v)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @impl true
  def parse(files) do
    files = Map.new(files)

    with {:ok, settings} <- parse_settings(files[@settings]),
         {:ok, servers} <- parse_mcp(files[@mcp]) do
      {:ok,
       %Config{
         instructions: files["CLAUDE.md"],
         skills: entries(files, ~r{\A\.claude/skills/([^/]+)/SKILL\.md\z}),
         subagents: entries(files, ~r{\A\.claude/agents/([^/]+)\.md\z}),
         commands: entries(files, ~r{\A\.claude/commands/([^/]+)\.md\z}),
         settings: settings,
         mcp_servers: servers
       }}
    end
  end

  defp entries(files, re) do
    for {path, bin} <- files, [_, name] <- [Regex.run(re, path)] do
      {fm, body} = Harness.parse_frontmatter(bin)
      %{name: Map.get(fm, "name", name), description: Map.get(fm, "description", ""), body: body}
    end
    |> Enum.sort_by(& &1.name)
  end

  defp parse_settings(nil), do: {:ok, %{known: %{}, raw: %{}}}

  defp parse_settings(bin) do
    case Jason.decode(bin) do
      {:ok, %{} = m} ->
        m = Map.delete(m, "env")
        {known, raw} = Map.split(m, @known_settings)
        {:ok, %{known: known, raw: raw}}

      _ ->
        {:error, {:invalid_json, @settings}}
    end
  end

  defp parse_mcp(nil), do: {:ok, []}

  defp parse_mcp(bin) do
    case Jason.decode(bin) do
      {:ok, %{"mcpServers" => %{} = m}} ->
        {:ok, m |> Enum.map(fn {name, e} -> server(name, e) end) |> Enum.sort_by(& &1.name)}

      {:ok, _} ->
        {:ok, []}

      _ ->
        {:error, {:invalid_json, @mcp}}
    end
  end

  defp server(name, %{"url" => url} = e) when is_binary(url) do
    Config.mcp_server(%{name: name, transport: :http, url: url, header_names: keys(e["headers"])})
  end

  defp server(name, e) do
    Config.mcp_server(%{
      name: name,
      transport: :stdio,
      command: e["command"],
      args: e["args"] || [],
      env_names: keys(e["env"])
    })
  end

  defp keys(%{} = m), do: Map.keys(m)
  defp keys(_), do: []

  @impl true
  def redact(path, binary) when path in [@mcp, @settings, @local] do
    case Jason.decode(binary) do
      {:ok, %{} = m} ->
        {m, names} = redact_map(m, path)
        {Harness.encode_json(m), names |> Enum.uniq() |> Enum.sort()}

      _ ->
        {"[unparseable file not shown]\n", []}
    end
  end

  def redact(_path, binary), do: {binary, []}

  @ref ~r/\A\$\{[A-Za-z0-9_]+\}\z/

  defp redact_map(m, @mcp) do
    {servers, names} =
      Enum.map_reduce(Map.get(m, "mcpServers", %{}), [], fn {name, e}, acc ->
        {e, a1} = redact_values(e, "env")
        {e, a2} = redact_values(e, "headers")
        {{name, e}, a1 ++ a2 ++ acc}
      end)

    {Map.put(m, "mcpServers", Map.new(servers)), names}
  end

  defp redact_map(m, _), do: redact_values(m, "env")

  defp redact_values(%{} = holder, key) do
    case Map.get(holder, key) do
      %{} = vals ->
        names =
          vals
          |> Enum.reject(fn {_, v} -> is_binary(v) and Regex.match?(@ref, v) end)
          |> Enum.map(&elem(&1, 0))

        out = Map.new(vals, fn {k, v} -> {k, if(k in names, do: "[redacted]", else: v)} end)
        {Map.put(holder, key, out), names}

      _ ->
        {holder, []}
    end
  end

  defp redact_values(other, _), do: {other, []}
end
