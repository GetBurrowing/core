defmodule Platform.HarnessFixture do
  @moduledoc "The one abstract config the harness golden tests render. Placeholder names only."

  alias Platform.Agents.Harness.Config

  @skill %{
    name: "release-notes",
    description: "Draft release notes: terse, grouped by area",
    body: "Summarise merged changes.\n\n- group by area\n- skip chores\n"
  }
  @subagent %{
    name: "reviewer",
    description: "Reviews a diff",
    body: "Read the diff and list risks.\n"
  }
  @command %{
    name: "triage",
    description: "Triage the inbox",
    body: "Go through new items and label them.\n"
  }

  @servers Enum.map(
             [
               %{
                 name: "files",
                 transport: :stdio,
                 command: "npx",
                 args: ["-y", "example-files-server"],
                 url: nil,
                 env_names: ["FILES_TOKEN", "FILES_ROOT"],
                 header_names: [],
                 managed_by_burrow?: false
               },
               %{
                 name: "docs",
                 transport: :http,
                 command: nil,
                 args: [],
                 url: "https://mcp.example.test/mcp",
                 env_names: [],
                 header_names: ["X-Api-Key"],
                 managed_by_burrow?: false
               }
             ],
             &Config.mcp_server/1
           )
           |> Enum.sort_by(& &1.name)

  @doc "The fixture config for a harness (`:claude_code` or `:codex`)."
  def config(:claude_code) do
    %Config{
      instructions: "# Fixture agent\n\nBe brief.\n",
      skills: [@skill],
      subagents: [@subagent],
      commands: [@command],
      settings: %{
        known: %{
          "model" => "fixture-model",
          "permissions" => %{"allow" => ["Read"], "deny" => ["Bash(rm:*)"]}
        },
        raw: %{"theme" => "dark"}
      },
      mcp_servers: @servers
    }
  end

  def config(:codex) do
    %Config{
      instructions: "# Fixture agent\n\nBe brief.\n",
      skills: [@skill],
      settings: %{
        known: %{"model" => "fixture-model", "sandbox_mode" => "workspace-write"},
        raw: %{"tui" => %{"notifications" => true}}
      },
      mcp_servers: @servers
    }
  end

  @doc "Every concept populated, for the every-concept test."
  def full(harness), do: %{config(harness) | subagents: [@subagent], commands: [@command]}

  @doc "A Burrow-managed server entry; it must never be rendered."
  def burrow_server do
    Config.mcp_server(%{
      name: "burrow",
      transport: :http,
      url: "https://burrow.example.test/mcp",
      header_names: ["Authorization"]
    })
  end
end
