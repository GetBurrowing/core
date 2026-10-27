defmodule Platform.Agents.HarnessTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Harness
  alias Platform.Agents.Harness.{ClaudeCode, Codex, Config}
  alias Platform.HarnessFixture

  @golden Path.expand("../../../support/fixtures/harness_golden", __DIR__)
  @harnesses [claude_code: ClaudeCode, codex: Codex]

  describe "adapter_for/1" do
    test "resolves the two harnesses that have adapters" do
      assert {:ok, ClaudeCode} = Harness.adapter_for("claude_code")
      assert {:ok, Codex} = Harness.adapter_for("codex")
    end

    test "every other kind is :unsupported" do
      for h <- ["hermes", "deepseek", "openclaw", "claude", "", nil, :codex] do
        assert Harness.adapter_for(h) == :unsupported
      end
    end

    test "NativeAgents.instructions_key/1 delegates and no longer defaults to CLAUDE.md" do
      alias Platform.Agents.NativeAgents
      assert NativeAgents.instructions_key("codex") == "AGENTS.md"
      assert NativeAgents.instructions_key("claude_code") == "CLAUDE.md"
      assert NativeAgents.instructions_key("hermes") == :unsupported
      assert NativeAgents.instructions_key(nil) == :unsupported
    end
  end

  for {name, mod} <- @harnesses do
    describe "#{name}" do
      @name name
      @mod mod

      test "golden: fixture config renders the exact file tree, byte for byte" do
        dir = Path.join(@golden, Atom.to_string(@name))
        rendered = @mod.render(HarnessFixture.config(@name))

        expected =
          dir
          |> Path.join("**")
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&{Path.relative_to(&1, dir), File.read!(&1)})
          |> Enum.sort()

        assert Enum.sort(rendered) == expected
      end

      test "parse(render(c)) == c" do
        c = HarnessFixture.config(@name)
        assert {:ok, ^c} = @mod.parse(@mod.render(c))
      end

      test "every concept in concepts/0 renders at least one path" do
        full = HarnessFixture.full(@name)

        for concept <- @mod.concepts() do
          only = only_concept(full, concept)
          assert Config.populated_concepts(only) == [concept]

          assert @mod.render(only) != [],
                 "#{inspect(@mod)} lists #{concept} but renders nothing for it"
        end
      end

      test "no rendered path is outside known_paths/0, and none is :secret" do
        for {path, _} <- @mod.render(HarnessFixture.full(@name)) do
          tag = Harness.path_tag(@mod, path)
          assert tag in [:plain, :secret_bearing], "#{path} has tag #{inspect(tag)}"
        end
      end

      test "unsupported concepts are reported, never rendered as empty or placeholder files" do
        full = HarnessFixture.full(@name)
        missing = Harness.unsupported_concepts(@mod, full)
        assert missing == Config.concepts() -- @mod.concepts()

        for {_path, bin} <- @mod.render(full), do: assert(bin != "")

        assert @mod.render(%Config{}) == []
      end

      test "Burrow's own MCP servers are never written" do
        c = %Config{mcp_servers: [HarnessFixture.burrow_server()]}
        assert Config.populated_concepts(c) == [:mcp_servers]
        assert @mod.render(c) == []
      end

      test "restart resumes" do
        assert @mod.restart_resumes?()
        assert @mod.harness() == Atom.to_string(@name)
      end

      test "unsafe entry names are refused" do
        c = %Config{skills: [%{name: "../evil", description: "x", body: "y"}]}
        assert_raise ArgumentError, fn -> @mod.render(c) end
      end
    end
  end

  describe "claude_code approval" do
    test "every rendered MCP server is pre-approved in settings.local.json" do
      c = HarnessFixture.config(:claude_code)
      files = Map.new(ClaudeCode.render(c))

      servers =
        files[".mcp.json"]
        |> Jason.decode!()
        |> Map.fetch!("mcpServers")
        |> Map.keys()
        |> Enum.sort()

      approved =
        files[".claude/settings.local.json"]
        |> Jason.decode!()
        |> Map.fetch!("enabledMcpjsonServers")
        |> Enum.sort()

      assert servers == ["docs", "files"]
      assert approved == servers
    end

    test "no servers, no .mcp.json and no approval file" do
      c = %{HarnessFixture.config(:claude_code) | mcp_servers: []}
      paths = ClaudeCode.render(c) |> Enum.map(&elem(&1, 0))
      refute ".mcp.json" in paths
      refute ".claude/settings.local.json" in paths
    end
  end

  describe "codex specifics" do
    test "settings and MCP go to .codex/config.toml, relative to the agent root" do
      paths = Codex.render(HarnessFixture.config(:codex)) |> Enum.map(&elem(&1, 0))
      assert ".codex/config.toml" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "~"))
    end

    test "subagents and commands are not in concepts" do
      refute :subagents in Codex.concepts()
      refute :commands in Codex.concepts()
    end
  end

  describe "secrets" do
    test "Config has no value field, and an MCP server has no env/header value" do
      fields = %Config{} |> Map.keys() |> MapSet.new()
      refute Enum.any?(fields, &(&1 in [:env, :headers, :secrets, :values, :token]))

      keys = HarnessFixture.burrow_server() |> Map.keys() |> MapSet.new()
      assert MapSet.subset?(MapSet.new([:env_names, :header_names]), keys)
      refute Enum.any?(keys, &(&1 in [:env, :headers, :values, :token, :secrets]))
    end

    test "mcp_server/1 drops unknown keys, so a value cannot ride along" do
      s = Config.mcp_server(%{name: "x", env: %{"A" => "sekret"}, headers: %{"B" => "sekret"}})
      refute inspect(s) =~ "sekret"
    end

    test "parse keeps names, never values" do
      mcp =
        ~s({"mcpServers":{"a":{"command":"c","env":{"TOK":"sekret-value"}},"b":{"url":"https://x.test","headers":{"X-K":"sekret-value"}}}})

      {:ok, c} = ClaudeCode.parse([{".mcp.json", mcp}])
      refute inspect(c) =~ "sekret-value"
      assert Enum.map(c.mcp_servers, & &1.env_names) == [["TOK"], []]

      toml = ~s([mcp_servers.a]\ncommand = "c"\n[mcp_servers.a.env]\nTOK = "sekret-value"\n)
      {:ok, c} = Codex.parse([{".codex/config.toml", toml}])
      refute inspect(c) =~ "sekret-value"
      assert [%{env_names: ["TOK"]}] = c.mcp_servers

      {:ok, c} =
        ClaudeCode.parse([
          {".claude/settings.json", ~s({"model":"m","env":{"K":"sekret-value"}})}
        ])

      refute inspect(c) =~ "sekret-value"
    end

    test "redact hides values and reports the names" do
      mcp = ~s({"mcpServers":{"a":{"command":"c","env":{"TOK":"sekret-value","OK":"${OK}"}}}})
      {out, names} = ClaudeCode.redact(".mcp.json", mcp)
      refute out =~ "sekret-value"
      assert names == ["TOK"]
      assert out =~ "${OK}"

      toml =
        ~s([mcp_servers.a]\nurl = "https://x.test"\nbearer_token = "sekret-value"\n[mcp_servers.a.http_headers]\nX-K = "sekret-value"\n)

      {out, names} = Codex.redact(".codex/config.toml", toml)
      refute out =~ "sekret-value"
      assert names == ["X-K", "bearer_token"]

      assert {"AGENTS.md body", []} = Codex.redact("AGENTS.md", "AGENTS.md body")
      {out, _} = Codex.redact(".codex/auth.json", ~s({"k":"sekret-value"}))
      refute out =~ "sekret-value"
    end

    test "fixtures hold no host, name or secret-looking value" do
      for f <- Path.wildcard(Path.join(@golden, "**"), match_dot: true), File.regular?(f) do
        body = File.read!(f)
        refute body =~ ~r/sk-[A-Za-z0-9]{8}|Bearer /i, f

        for [host] <- Regex.scan(~r{https?://([^/"\s]+)}, body, capture: :all_but_first),
            do: assert(String.ends_with?(host, ".example.test"), f)
      end
    end
  end

  defp only_concept(%Config{} = full, concept) do
    blank = %Config{}

    case concept do
      :instructions -> %{blank | instructions: full.instructions}
      :settings -> %{blank | settings: full.settings}
      other -> Map.put(blank, other, Map.fetch!(full, other))
    end
  end
end
