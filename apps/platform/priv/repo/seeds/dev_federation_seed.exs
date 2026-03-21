# Seeds a local dev environment for federation testing with OpenClaw node connection.
#
# Usage:
#   DATABASE_URL='postgres://postgres:postgres@127.0.0.1/platform_dev' mix run priv/repo/seeds/dev_federation_seed.exs
#

alias Platform.Repo
alias Platform.Chat.Space
alias Platform.Agents.Agent

# 1. Create a "General" channel space
{:ok, space} =
  case Repo.get_by(Space, slug: "general") do
    nil ->
      %Space{}
      |> Space.changeset(%{
        name: "General",
        slug: "general",
        kind: "channel",
        description: "Default channel for dev testing"
      })
      |> Repo.insert()

    existing ->
      {:ok, existing}
  end

IO.puts("✅ Space: #{space.id} (#{space.name} / #{space.slug})")

# 2. Create agent record for "main" (OpenClaw's default agent slug)
{:ok, agent} =
  case Repo.get_by(Agent, slug: "main") do
    nil ->
      %Agent{}
      |> Agent.changeset(%{
        slug: "main",
        name: "Zip",
        status: "active",
        runtime_type: "built_in"
      })
      |> Repo.insert()

    existing ->
      {:ok, existing}
  end

IO.puts("✅ Agent: #{agent.id} (#{agent.slug} / #{agent.name})")

# 3. Print the env vars needed for NodeClient
IO.puts("""

  ╔══════════════════════════════════════════════════════════════╗
  ║  Federation Dev Config                                      ║
  ╠══════════════════════════════════════════════════════════════╣
  ║                                                             ║
  ║  Add these to your dev server startup:                      ║
  ║                                                             ║
  ║  OPENCLAW_NODE_ENABLED=true                                 ║
  ║  OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789                 ║
  ║  OPENCLAW_GATEWAY_TOKEN=<your gateway auth token>           ║
  ║  OPENCLAW_NODE_AGENT_ID=main                                ║
  ║  OPENCLAW_NODE_SPACE_ID=#{space.id}
  ║  OPENCLAW_NODE_DISPLAY_NAME=Suite Dev                       ║
  ║                                                             ║
  ╚══════════════════════════════════════════════════════════════╝
""")
