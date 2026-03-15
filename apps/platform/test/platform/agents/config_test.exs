defmodule Platform.Agents.ConfigTest do
  use ExUnit.Case, async: true

  alias Platform.Agents.Config

  @config %{
    "auth" => %{
      "profiles" => %{
        "anthropic:default" => %{"provider" => "anthropic", "mode" => "token"},
        "openai-codex:default" => %{"provider" => "openai-codex", "mode" => "oauth"}
      }
    },
    "agents" => %{
      "defaults" => %{
        "model" => %{
          "primary" => "anthropic/claude-sonnet-4-6",
          "fallbacks" => ["anthropic/claude-opus-4-6"]
        },
        "models" => %{
          "anthropic/claude-sonnet-4-6" => %{},
          "openai-codex/gpt-5.4" => %{}
        },
        "tools" => %{
          "profile" => "minimal",
          "exec" => %{"ask" => "always"}
        },
        "thinkingDefault" => "high",
        "heartbeat" => %{"every" => "1h"},
        "maxConcurrent" => 4,
        "sandbox" => %{"mode" => "off"},
        "contextPruning" => %{"mode" => "cache-ttl", "ttl" => "1h"}
      },
      "list" => [
        %{
          "id" => "zip",
          "name" => "Zip",
          "workspace" => "/tmp/zip",
          "model" => %{"primary" => "openai-codex/gpt-5.4"},
          "tools" => %{"profile" => "full", "alsoAllow" => ["mcp"]},
          "subagents" => %{"allowAgents" => ["*"]}
        }
      ]
    },
    "channels" => %{"telegram" => %{"enabled" => true}}
  }

  describe "parse/2" do
    test "merges defaults into each agent entry and builds Agent attrs" do
      assert {:ok, parsed} = Config.parse(@config, workspace_id: Ecto.UUID.generate())

      assert parsed.auth_profiles["anthropic:default"] == %{
               "provider" => "anthropic",
               "mode" => "token"
             }

      assert parsed.skipped_sections == ["channels"]
      assert parsed.defaults["thinkingDefault"] == "high"

      [agent] = parsed.agents

      assert agent.id == "zip"
      assert agent.name == "Zip"
      assert agent.raw["heartbeat"] == %{"every" => "1h"}
      assert agent.raw["workspace"] == "/tmp/zip"

      assert agent.attrs.slug == "zip"
      assert agent.attrs.name == "Zip"
      assert agent.attrs.status == "active"

      assert agent.attrs.model_config == %{
               "primary" => "openai-codex/gpt-5.4",
               "fallbacks" => ["anthropic/claude-opus-4-6"],
               "models" => %{
                 "anthropic/claude-sonnet-4-6" => %{},
                 "openai-codex/gpt-5.4" => %{}
               }
             }

      assert agent.attrs.tools_config == %{
               "profile" => "full",
               "alsoAllow" => ["mcp"],
               "exec" => %{"ask" => "always"}
             }

      assert agent.attrs.thinking_default == "high"
      assert agent.attrs.heartbeat_config == %{"every" => "1h"}
      assert agent.attrs.max_concurrent == 4
      assert agent.attrs.sandbox_mode == "off"

      assert agent.attrs.metadata == %{
               "contextPruning" => %{"mode" => "cache-ttl", "ttl" => "1h"},
               "subagents" => %{"allowAgents" => ["*"]},
               "workspace" => "/tmp/zip"
             }

      assert Ecto.UUID.cast(agent.attrs.workspace_id) != :error
    end

    test "parses JSON strings and normalizes scalar heartbeat/sandbox values" do
      json =
        Jason.encode!(%{
          agents: %{
            list: [
              %{
                id: "solo",
                heartbeat: "15m",
                sandbox: "workspace-write"
              }
            ]
          }
        })

      assert {:ok, parsed} = Config.parse(json)
      [agent] = parsed.agents

      assert agent.attrs.heartbeat_config == %{"every" => "15m"}
      assert agent.attrs.sandbox_mode == "workspace-write"
      assert agent.attrs.model_config == %{}
      assert agent.attrs.tools_config == %{}
      assert agent.attrs.metadata == %{}
    end

    test "returns an error for duplicate agent ids" do
      config = %{
        "agents" => %{
          "list" => [
            %{"id" => "zip"},
            %{"id" => "zip"}
          ]
        }
      }

      assert {:error, {:duplicate_agent_ids, ["zip"]}} = Config.parse(config)
    end

    test "returns an error when an agent id is missing" do
      config = %{"agents" => %{"list" => [%{"name" => "Zip"}]}}

      assert {:error, {:invalid_agent, 0, "agent entries require a non-empty id"}} =
               Config.parse(config)
    end

    test "returns an error when agents.list is missing or not a list" do
      assert {:error, {:invalid_config, "agents.list must be a list"}} = Config.parse(%{})

      assert {:error, {:invalid_config, "agents.list must be a list"}} =
               Config.parse(%{"agents" => %{"list" => %{}}})
    end
  end

  describe "parse_file/2" do
    test "reads and parses a config file from disk" do
      path =
        Path.join(System.tmp_dir!(), "openclaw-config-#{System.unique_integer([:positive])}.json")

      File.write!(path, Jason.encode!(%{agents: %{list: [%{id: "file-agent"}]}}))

      on_exit(fn -> File.rm(path) end)

      assert {:ok, parsed} = Config.parse_file(path)
      assert [%{id: "file-agent"}] = parsed.agents
    end
  end
end
