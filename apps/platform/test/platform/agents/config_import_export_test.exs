defmodule Platform.Agents.ConfigImportExportTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{Agent, Config, MemoryContext}
  alias Platform.Repo
  alias Platform.Vault

  defp tmp_dir!(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "platform-agents-config-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf(path)
    end)

    path
  end

  defp create_agent(attrs) do
    default = %{
      slug: "agent-config-#{System.unique_integer([:positive, :monotonic])}",
      name: "Config Agent",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"},
      tools_config: %{"profile" => "minimal"},
      heartbeat_config: %{"every" => "1h"},
      sandbox_mode: "off",
      max_concurrent: 1,
      metadata: %{}
    }

    {:ok, agent} =
      default
      |> Map.merge(attrs)
      |> then(&Agent.changeset(%Agent{}, &1))
      |> Repo.insert()

    agent
  end

  describe "import_workspace/2" do
    test "imports config, workspace files, daily memories, and auth profiles" do
      workspace_id = Ecto.UUID.generate()
      dir = tmp_dir!("import")
      memory_dir = Path.join(dir, "memory")

      File.mkdir_p!(memory_dir)

      openclaw = %{
        "auth" => %{
          "profiles" => %{
            "anthropic:default" => %{"provider" => "anthropic", "mode" => "oauth"},
            "openai-codex:default" => %{"provider" => "openai-codex", "mode" => "token"}
          }
        },
        "agents" => %{
          "defaults" => %{
            "model" => %{
              "primary" => "anthropic/claude-sonnet-4-6",
              "fallbacks" => ["openai-codex/gpt-5.4"]
            },
            "tools" => %{"profile" => "minimal"},
            "heartbeat" => %{"every" => "30m"},
            "sandbox" => %{"mode" => "workspace-write"}
          },
          "list" => [
            %{
              "id" => "zip",
              "name" => "Zip",
              "thinkingDefault" => "high",
              "tools" => %{"profile" => "full"}
            }
          ]
        },
        "channels" => %{"telegram" => %{"enabled" => true}}
      }

      File.write!(Path.join(dir, "openclaw.json"), Jason.encode!(openclaw))
      File.write!(Path.join(dir, "SOUL.md"), "calm and steady")
      File.write!(Path.join(dir, "USER.md"), "Operator")
      File.write!(Path.join(dir, "MEMORY.md"), "curated memory")
      File.write!(Path.join(memory_dir, "2026-03-14.md"), "daily memory")
      File.write!(Path.join(memory_dir, "not-a-date.md"), "ignored")

      assert {:ok, imported} =
               Config.import_workspace(dir,
                 workspace_id: workspace_id,
                 credential_values: %{
                   "anthropic:default" => %{"access_token" => "sk-ant-oat01-import"},
                   "openai-codex:default" => "sk-openai-import"
                 }
               )

      agent = imported.agent

      assert agent.slug == "zip"
      assert agent.name == "Zip"
      assert agent.workspace_id == workspace_id
      assert agent.thinking_default == "high"

      assert agent.model_config == %{
               "primary" => "anthropic/claude-sonnet-4-6",
               "fallbacks" => ["openai-codex/gpt-5.4"]
             }

      assert agent.tools_config == %{"profile" => "full"}
      assert agent.heartbeat_config == %{"every" => "30m"}
      assert agent.sandbox_mode == "workspace-write"

      assert get_in(agent.metadata, ["_openclaw", "auth_profiles", "anthropic:default"]) == %{
               "provider" => "anthropic",
               "mode" => "oauth"
             }

      assert Enum.map(imported.workspace_files, & &1.file_key) == [
               "MEMORY.md",
               "SOUL.md",
               "USER.md"
             ]

      assert [%{date: ~D[2026-03-14], content: "daily memory"}] =
               MemoryContext.list_memories(agent.id, memory_type: :daily, limit: 10)

      assert [{"anthropic:default", _}, {"openai-codex:default", _}] =
               imported.imported_credentials

      assert {:ok, oauth_payload} = Vault.get("anthropic-oauth", accessor: {:platform, nil})
      assert Jason.decode!(oauth_payload)["access_token"] == "sk-ant-oat01-import"

      assert {:ok, "sk-openai-import"} =
               Vault.get("openai-api-key", accessor: {:platform, nil})
    end
  end

  describe "export_workspace/3" do
    test "exports openclaw config, workspace files, synthesized MEMORY.md, and daily logs" do
      dir = tmp_dir!("export")

      agent =
        create_agent(%{
          slug: "export-agent-#{System.unique_integer([:positive, :monotonic])}",
          name: "Export Agent",
          model_config: %{
            "primary" => "anthropic/claude-sonnet-4-6",
            "fallbacks" => ["openai-codex/gpt-5.4"],
            "models" => %{
              "openai-codex/gpt-5.4" => %{"credential_slug" => "openai-oauth"}
            }
          },
          tools_config: %{"profile" => "full"},
          heartbeat_config: %{"every" => "15m"},
          sandbox_mode: "workspace-write",
          max_concurrent: 3,
          thinking_default: "high",
          metadata: %{
            "workspace" => "/tmp/ignored-on-export",
            "subagents" => %{"allowAgents" => ["*"]},
            "_openclaw" => %{
              "auth_profiles" => %{
                "anthropic:default" => %{"provider" => "anthropic", "mode" => "oauth"}
              }
            }
          }
        })

      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", "steady")
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "USER.md", "Operator")
      {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "curated one")
      {:ok, _} = MemoryContext.append_memory(agent.id, :long_term, "curated two")
      {:ok, _} = MemoryContext.append_memory(agent.id, :daily, "day one", date: ~D[2026-03-14])
      {:ok, _} = MemoryContext.append_memory(agent.id, :daily, "day two", date: ~D[2026-03-14])
      {:ok, _} = MemoryContext.append_memory(agent.id, :daily, "day three", date: ~D[2026-03-15])

      assert {:ok, exported} = Config.export_workspace(agent.id, dir)

      assert exported.agent.id == agent.id
      assert File.exists?(exported.config_path)

      config = Jason.decode!(File.read!(exported.config_path))
      assert get_in(config, ["auth", "profiles", "anthropic:default", "provider"]) == "anthropic"

      [entry] = get_in(config, ["agents", "list"])
      assert entry["id"] == agent.slug
      assert entry["name"] == "Export Agent"

      assert entry["model"] == %{
               "primary" => "anthropic/claude-sonnet-4-6",
               "fallbacks" => ["openai-codex/gpt-5.4"]
             }

      assert entry["models"] == %{
               "openai-codex/gpt-5.4" => %{"credential_slug" => "openai-oauth"}
             }

      assert entry["tools"] == %{"profile" => "full"}
      assert entry["thinkingDefault"] == "high"
      assert entry["heartbeat"] == %{"every" => "15m"}
      assert entry["maxConcurrent"] == 3
      assert entry["sandbox"] == %{"mode" => "workspace-write"}
      assert entry["subagents"] == %{"allowAgents" => ["*"]}
      refute Map.has_key?(entry, "workspace")

      assert File.read!(Path.join(dir, "SOUL.md")) == "steady"
      assert File.read!(Path.join(dir, "USER.md")) == "Operator"
      assert File.read!(Path.join(dir, "MEMORY.md")) == "curated one\n\ncurated two"
      assert File.read!(Path.join(dir, "memory/2026-03-14.md")) == "day one\n\nday two"
      assert File.read!(Path.join(dir, "memory/2026-03-15.md")) == "day three"
    end
  end
end
