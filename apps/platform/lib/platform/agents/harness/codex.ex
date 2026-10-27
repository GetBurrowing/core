defmodule Platform.Agents.Harness.Codex do
  @moduledoc """
  Codex: `AGENTS.md`, `.codex/config.toml` (known keys plus
  `[mcp_servers.<name>]` tables) and `.codex/skills/<name>/SKILL.md`.

  Paths are relative to the agent root because burrow-cli sets `CODEX_HOME` to
  `<agent root>/.codex` (burrow-cli `src/commands/codex.ts`), not `~/.codex`.
  Burrow's own MCP servers are passed as `-c mcp_servers.*` overrides on the
  app-server argv and are never written: `render/1` skips any server marked
  `managed_by_burrow?`.

  Secret values: stdio env is written as `env_vars = [names]` (names forwarded
  from the environment) and HTTP headers as `env_http_headers`, never as values.
  `parse/1` keeps only names; `bearer_token_env_var` and literal `env` /
  `http_headers` values are dropped.

  ## Which concepts are evidenced (codex-cli 0.159.2)

  burrow-cli measured and generated its protocol against codex-cli 0.159.2
  (`src/codex/app_server.ts`, `src/codex/protocol.ts`); it pins no other version.
  Evidence was taken from the published binary
  (`npm pack @openai/codex@0.159.2-darwin-arm64`, then `codex --version` ->
  `codex-cli 0.159.2`, `codex --help`, `codex mcp add --help`, `codex features list`,
  and `strings` over the binary):

    * `:instructions` (AGENTS.md): the Codex convention; read from the cwd.
    * `:settings` (`config.toml`): `--help` for `-c` says values override
      "a configuration value that would otherwise be loaded from
      `~/.codex/config.toml`"; `CODEX_HOME` relocates it.
    * `:mcp_servers`: `codex mcp add --help` shows `--env`, `--url` and
      `--bearer-token-env-var`; the binary names `[mcp_servers.`, `env_vars`,
      `env_http_headers`, `http_headers` and `bearer_token_env_var`.
    * `:skills`: the binary's bundled skill-installer text says
      "Installs into `$CODEX_HOME/skills/<skill-name>`" and skill creation
      places "discoverable skills in `$CODEX_HOME/skills`", with `SKILL.md`
      frontmatter allowing `name`, `description`, `license`, `allowed-tools`,
      `metadata`.

  Left OUT, because no evidence was found in that version: `:commands` (custom
  prompts under `$CODEX_HOME/prompts` appear nowhere in the binary or `--help`)
  and `:subagents` (the binary mentions an agent `config_file`, but not the
  file layout or schema, so nothing can be rendered faithfully).

  Restart: the bridge resumes each space's saved thread with `thread/resume`
  (burrow-cli `src/codex/bridge.ts`).
  """

  @behaviour Platform.Agents.Harness.Adapter

  alias Platform.Agents.Harness
  alias Platform.Agents.Harness.Config

  @config ".codex/config.toml"
  @known_settings ~w(model model_reasoning_effort approval_policy sandbox_mode)

  @impl true
  def harness, do: "codex"

  @impl true
  def concepts, do: [:instructions, :skills, :settings, :mcp_servers]

  @impl true
  def instructions_path, do: "AGENTS.md"

  @impl true
  def known_paths do
    [
      {"AGENTS.md", :plain},
      {".codex/skills/*/SKILL.md", :plain},
      {@config, :secret_bearing},
      {".codex/auth.json", :secret}
    ]
  end

  @impl true
  def restart_resumes?, do: true

  @impl true
  def render(%Config{} = c) do
    instructions = if c.instructions in [nil, ""], do: [], else: [{"AGENTS.md", c.instructions}]

    skills =
      for s <- c.skills do
        {".codex/skills/#{Harness.safe_name!(s.name)}/SKILL.md",
         Harness.frontmatter_doc([{"name", s.name}, {"description", s.description}], s.body)}
      end

    top = Map.merge(stringify(c.settings.raw), stringify(c.settings.known))
    servers = Config.writable_servers(c)

    config =
      if top == %{} and servers == [] do
        []
      else
        tables = Map.put(top, "mcp_servers", Map.new(servers, &{&1.name, mcp_table(&1)}))
        tables = if servers == [], do: Map.delete(tables, "mcp_servers"), else: tables
        [{@config, encode_toml(tables)}]
      end

    Enum.sort_by(instructions ++ skills ++ config, &elem(&1, 0))
  end

  defp mcp_table(%{transport: :http} = s) do
    %{"url" => s.url}
    |> put_unless_empty(
      "env_http_headers",
      Map.new(s.header_names, &{&1, Harness.header_env_name(&1)})
    )
  end

  defp mcp_table(s) do
    %{"command" => s.command}
    |> put_unless_empty("args", s.args)
    |> put_unless_empty("env_vars", s.env_names)
  end

  defp put_unless_empty(map, _k, v) when v in [[], %{}], do: map
  defp put_unless_empty(map, k, v), do: Map.put(map, k, v)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # ── parse ──────────────────────────────────────────────────────────

  @impl true
  def parse(files) do
    files = Map.new(files)

    with {:ok, toml} <- decode(files[@config]) do
      {servers, rest} = Map.pop(toml, "mcp_servers", %{})
      {known, raw} = Map.split(rest, @known_settings)

      skills =
        for {path, bin} <- files,
            [_, name] <- [Regex.run(~r{\A\.codex/skills/([^/]+)/SKILL\.md\z}, path)] do
          {fm, body} = Harness.parse_frontmatter(bin)

          %{
            name: Map.get(fm, "name", name),
            description: Map.get(fm, "description", ""),
            body: body
          }
        end

      {:ok,
       %Config{
         instructions: files["AGENTS.md"],
         skills: Enum.sort_by(skills, & &1.name),
         settings: %{known: known, raw: raw},
         mcp_servers:
           servers |> Enum.map(fn {n, t} -> server(n, t) end) |> Enum.sort_by(& &1.name)
       }}
    end
  end

  defp decode(nil), do: {:ok, %{}}

  defp decode(bin) do
    case Toml.decode(bin) do
      {:ok, m} -> {:ok, m}
      {:error, reason} -> {:error, {:invalid_toml, reason}}
    end
  end

  defp server(name, %{"url" => url} = t) do
    Config.mcp_server(%{
      name: name,
      transport: :http,
      url: url,
      header_names: Enum.uniq(keys(t["http_headers"]) ++ keys(t["env_http_headers"]))
    })
  end

  defp server(name, t) do
    Config.mcp_server(%{
      name: name,
      transport: :stdio,
      command: t["command"],
      args: t["args"] || [],
      env_names: Enum.uniq(keys(t["env"]) ++ List.wrap(t["env_vars"]))
    })
  end

  defp keys(%{} = m), do: Map.keys(m)
  defp keys(_), do: []

  # ── redact ─────────────────────────────────────────────────────────

  @impl true
  def redact(@config, binary) do
    case Toml.decode(binary) do
      {:ok, m} ->
        {servers, names} =
          m
          |> Map.get("mcp_servers", %{})
          |> Enum.map_reduce([], fn {name, t}, acc ->
            {t, n1} = redact_table(t, "env")
            {t, n2} = redact_table(t, "http_headers")
            {t, n3} = redact_literal_tokens(t)
            {{name, t}, n1 ++ n2 ++ n3 ++ acc}
          end)

        out = if servers == [], do: m, else: Map.put(m, "mcp_servers", Map.new(servers))
        {encode_toml(out), names |> Enum.uniq() |> Enum.sort()}

      _ ->
        {"[unparseable file not shown]\n", []}
    end
  end

  def redact(".codex/auth.json", _), do: {"[secret file not shown]\n", []}
  def redact(_path, binary), do: {binary, []}

  defp redact_table(%{} = t, key) do
    case Map.get(t, key) do
      %{} = vals ->
        {Map.put(t, key, Map.new(vals, fn {k, _} -> {k, "[redacted]"} end)), Map.keys(vals)}

      _ ->
        {t, []}
    end
  end

  defp redact_table(t, _), do: {t, []}

  defp redact_literal_tokens(%{} = t) do
    hits =
      for {k, v} <- t, k in ["bearer_token", "experimental_bearer_token"], is_binary(v), do: k

    {Map.new(t, fn {k, v} -> {k, if(k in hits, do: "[redacted]", else: v)} end), hits}
  end

  # ── minimal deterministic TOML writer ──────────────────────────────

  defp encode_toml(map) do
    {scalars, tables} =
      map |> Enum.sort_by(&elem(&1, 0)) |> Enum.split_with(fn {_, v} -> not table?(v) end)

    head = Enum.map_join(scalars, "", fn {k, v} -> "#{key(k)} = #{value(v)}\n" end)
    head <> Enum.map_join(tables, "", fn {k, v} -> tables_out([k], v, head != "") end)
  end

  defp tables_out(path, map, _lead) do
    {scalars, subs} =
      map |> Enum.sort_by(&elem(&1, 0)) |> Enum.split_with(fn {_, v} -> not table?(v) end)

    own =
      if scalars == [] and subs != [],
        do: "",
        else:
          "\n[#{Enum.map_join(path, ".", &key/1)}]\n" <>
            Enum.map_join(scalars, "", fn {k, v} -> "#{key(k)} = #{value(v)}\n" end)

    own <> Enum.map_join(subs, "", fn {k, v} -> tables_out(path ++ [k], v, true) end)
  end

  defp table?(v), do: is_map(v) and not is_struct(v)

  defp key(k) do
    k = to_string(k)
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, k), do: k, else: Jason.encode!(k)
  end

  defp value(v) when is_binary(v), do: Jason.encode!(v)
  defp value(v) when is_boolean(v) or is_integer(v) or is_float(v), do: to_string(v)
  defp value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &value/1) <> "]"

  defp value(%{} = m),
    do:
      "{ " <>
        Enum.map_join(Enum.sort_by(m, &elem(&1, 0)), ", ", fn {k, x} ->
          "#{key(k)} = #{value(x)}"
        end) <> " }"
end
