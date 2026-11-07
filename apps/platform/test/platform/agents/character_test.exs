defmodule Platform.Agents.CharacterTest do
  @moduledoc """
  `Platform.Agents.Character.create/3` and `update/3` against the database:
  one transaction that writes the agent, its three workspace files and the
  creator's DM, or nothing.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.{Agent, Character, MemoryContext, WorkspaceBootstrap, WorkspaceFile}
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Builder User #{n}",
      email: "character-#{n}@example.com",
      oidc_sub: "character-#{n}"
    })
  end

  defp lark do
    Character.new("scout")
    |> Map.merge(%{
      n: "Lark #{System.unique_integer([:positive])}",
      color: "indigo",
      portrait: "fox",
      sl: %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
      traits: ["skeptic", "tidy", "night owl"],
      vc: %{p: 3, ov: %{"emoji" => 1}, q: "pr", free: nil}
    })
  end

  defp counts do
    %{
      agents: Repo.aggregate(Agent, :count),
      files: Repo.aggregate(WorkspaceFile, :count),
      dms: Repo.aggregate(from(s in Space, where: s.kind == "dm"), :count)
    }
  end

  describe "create/3" do
    test "writes the agent, colour, toolkit, character metadata, three files and the DM" do
      user = user!()
      b = lark()

      assert {:ok, %{agent: agent, files: files, dm: dm}} = Character.create(b, user)

      agent = Repo.reload!(agent)
      assert agent.name == b.n
      assert agent.slug == Character.slugify(b.n)
      assert agent.color == "indigo"

      assert agent.tools_config == %{
               "profile" => "minimal",
               "allow" => ["web_search", "web_fetch", "pdf", "group:fs"],
               "toolkit" => ["read", "canvases", "web", "memory"]
             }

      assert agent.model_config["primary"] == "anthropic/claude-opus-4-6"

      assert agent.metadata["character"] == %{
               "archetype" => "scout",
               "template_id" => "researcher",
               "portrait" => "fox",
               "sliders" => %{"chatty" => 20, "bold" => 80, "playful" => 10, "collab" => 90},
               "traits" => ["skeptic", "tidy", "night owl"],
               "voice" => %{"preset" => "professional", "overrides" => %{"emoji" => 1}}
             }

      # Voice is SOUL.md's, never the TTS config.
      assert agent.voice_config == %{}

      stored =
        agent.id |> MemoryContext.list_workspace_files() |> Map.new(&{&1.file_key, &1})

      assert Map.keys(stored) == ["IDENTITY.md", "SOUL.md", "TOOLS.md"]
      assert stored["SOUL.md"].content == Character.soul_md(b)
      assert stored["IDENTITY.md"].content == Character.identity_md(b)
      assert stored["TOOLS.md"].content == Character.tools_md(b)
      assert Enum.all?(Map.values(stored), &(&1.version == 1))
      assert Map.keys(files) |> Enum.sort() == Map.keys(stored)

      assert stored["SOUL.md"].content =~ "Voice: professional."
      assert stored["SOUL.md"].content =~ "Emoji sparingly, at most one per reply."
      assert stored["IDENTITY.md"].content =~ "@" <> b.n

      roster =
        Repo.all(
          from(p in Participant,
            where: p.space_id == ^dm.id,
            select: {p.participant_type, p.participant_id}
          )
        )

      assert Enum.sort(roster) == Enum.sort([{"user", user.id}, {"agent", agent.id}])
      assert Repo.reload!(dm).kind == "dm"
    end

    test "a Wildcard has no template: minimal profile, nothing allowed, no model" do
      user = user!()
      b = Character.new("wildcard") |> Map.put(:n, "Jinx #{System.unique_integer([:positive])}")

      assert {:ok, %{agent: agent}} = Character.create(b, user)

      assert agent.tools_config == %{
               "profile" => "minimal",
               "allow" => [],
               "toolkit" => ["read", "canvases"]
             }

      assert agent.model_config == %{}
      assert agent.metadata["character"]["template_id"] == nil
    end

    for step <- [:agent, :soul, :identity, :tools, :dm] do
      test "a failure after #{step} leaves no agent, no file and no DM" do
        user = user!()
        before = counts()

        assert {:error, :forced_failure, {:forced_after, unquote(step)}} =
                 Character.create(lark(), user, fail_after: unquote(step))

        assert counts() == before
      end
    end

    test "a name already taken gets the comp's \" II\"" do
      user = user!()
      b = lark()
      assert {:ok, %{agent: first}} = Character.create(b, user)
      assert {:ok, %{agent: second}} = Character.create(b, user)
      assert second.name == first.name <> " II"
      assert second.slug == first.slug <> "-ii"
    end

    test "an invalid character writes nothing" do
      user = user!()
      before = counts()

      for bad <- [
            %{lark() | cls: "bard"},
            %{lark() | portrait: "dragon"},
            %{lark() | traits: ["tidy", "skeptic", "optimist", "night owl"]},
            %{lark() | traits: ["polite"]},
            %{lark() | toolkit: ["teleport"]},
            %{lark() | sl: %{"chatty" => 101, "bold" => 0, "playful" => 0, "collab" => 0}},
            %{lark() | vc: %{p: 5, ov: %{}}},
            %{lark() | vc: %{p: 1, ov: %{"len" => 3}}}
          ] do
        assert {:error, :validate, {:invalid, _}} = Character.create(bad, user)
      end

      assert counts() == before
    end

    test "booting a mounted workspace never overwrites a builder agent's files" do
      user = user!()
      assert {:ok, %{agent: agent}} = Character.create(lark(), user)
      before = MemoryContext.list_workspace_files(agent.id)

      workspace = Platform.TestTemp.path("character-boot-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      File.write!(
        Path.join(workspace, "openclaw.json"),
        Jason.encode!(%{
          "agents" => %{
            "list" => [
              %{
                "id" => "mounted-#{System.unique_integer([:positive])}",
                "name" => "Mounted",
                "model" => %{"primary" => "anthropic/claude-sonnet-4-6"}
              }
            ]
          }
        })
      )

      for key <- Character.files(), do: File.write!(Path.join(workspace, key), "mounted #{key}")

      assert {:ok, mounted} = WorkspaceBootstrap.ensure_agent(workspace_path: workspace)
      refute mounted.id == agent.id
      assert MemoryContext.list_workspace_files(agent.id) == before
    end
  end

  describe "update/3" do
    setup do
      user = user!()
      {:ok, %{agent: agent}} = Character.create(lark(), user)
      %{agent: agent}
    end

    test "a dial change rewrites SOUL.md at version 2 and the metadata", %{agent: agent} do
      sl = %{"chatty" => 20, "bold" => 30, "playful" => 10, "collab" => 90}

      assert {:ok, %{agent: updated, files: files}} =
               Character.update(agent, %{sl: sl}, expected_versions: %{"SOUL.md" => 1})

      assert files["SOUL.md"].version == 2
      assert files["SOUL.md"].content =~ "- Careful ↔ Bold: 30 (Careful)"
      # Unchanged files are not rewritten.
      assert files["IDENTITY.md"].version == 1
      assert files["TOOLS.md"].version == 1
      assert updated.metadata["character"]["sliders"] == sl
      assert Repo.reload!(updated).metadata["character"]["sliders"] == sl
      assert updated.slug == agent.slug
    end

    test "a stale version is refused and nothing is written", %{agent: agent} do
      assert {:ok, %{agent: agent}} =
               Character.update(agent, %{traits: ["tidy"]}, expected_versions: %{"SOUL.md" => 1})

      sl = %{"chatty" => 99, "bold" => 99, "playful" => 99, "collab" => 99}

      assert {:error, :stale_workspace_file} =
               Character.update(agent, %{sl: sl}, expected_versions: %{"SOUL.md" => 1})

      soul = MemoryContext.get_workspace_file(agent.id, "SOUL.md")
      assert soul.version == 2
      refute soul.content =~ "99"
      assert Repo.reload!(agent).metadata["character"]["traits"] == ["tidy"]
    end

    test "a stale version on a file the change leaves alone still refuses the whole write",
         %{agent: agent} do
      # The change touches only SOUL.md; the caller's IDENTITY.md version is stale.
      assert {:error, :stale_workspace_file} =
               Character.update(agent, %{traits: ["tidy"]},
                 expected_versions: %{"SOUL.md" => 1, "IDENTITY.md" => 7}
               )

      assert MemoryContext.get_workspace_file(agent.id, "SOUL.md").version == 1

      assert Repo.reload!(agent).metadata["character"]["traits"] == [
               "skeptic",
               "tidy",
               "night owl"
             ]
    end

    test "a rename and recolour rewrite IDENTITY.md and the row, not the slug", %{agent: agent} do
      assert {:ok, %{agent: updated, files: files}} =
               Character.update(agent, %{n: "Wren", color: "lime", toolkit: ["read", "prs"]})

      assert updated.name == "Wren"
      assert updated.color == "lime"
      assert updated.slug == agent.slug
      assert updated.tools_config["toolkit"] == ["read", "prs"]
      assert updated.tools_config["allow"] == agent.tools_config["allow"]
      assert files["IDENTITY.md"].version == 2
      assert files["IDENTITY.md"].content =~ "- Handle: @Wren"
      assert files["TOOLS.md"].content =~ "Open PRs"
    end

    test "an invalid change writes nothing", %{agent: agent} do
      assert {:error, {:invalid, :color}} = Character.update(agent, %{color: "chartreuse"})
      assert MemoryContext.get_workspace_file(agent.id, "SOUL.md").version == 1
    end

    test "an agent not built as a character is refused" do
      agent =
        Repo.insert!(%Agent{slug: "plain-#{System.unique_integer([:positive])}", name: "Plain"})

      assert {:error, :not_a_character} = Character.update(agent, %{color: "lime"})
    end
  end
end
