defmodule Platform.Chat.PresenceTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo

  describe "track_in_space/4 and list_space/1" do
    test "tracked participant appears in list_space" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _ref} =
        ChatPresence.track_in_space(self(), space_id, participant_id, %{
          participant_type: "user",
          display_name: "Test User"
        })

      presences = ChatPresence.list_space(space_id)
      assert Map.has_key?(presences, participant_id)
      [meta] = presences[participant_id].metas
      assert meta.display_name == "Test User"
    end

    test "online_count reflects tracked participants" do
      space_id = Ecto.UUID.generate()
      assert ChatPresence.online_count(space_id) == 0

      p1 = Ecto.UUID.generate()
      p2 = Ecto.UUID.generate()

      parent = self()

      t1 =
        spawn(fn ->
          {:ok, _} = ChatPresence.track_in_space(self(), space_id, p1, %{})
          send(parent, :tracked)

          receive do
            :done -> :ok
          after
            2000 -> :ok
          end
        end)

      assert_receive :tracked, 500

      t2 =
        spawn(fn ->
          {:ok, _} = ChatPresence.track_in_space(self(), space_id, p2, %{})
          send(parent, :tracked)

          receive do
            :done -> :ok
          after
            2000 -> :ok
          end
        end)

      assert_receive :tracked, 500

      # Give presence time to settle
      :timer.sleep(100)
      assert ChatPresence.online_count(space_id) == 2

      Process.exit(t1, :kill)
      Process.exit(t2, :kill)
    end
  end

  describe "untrack_in_space/3" do
    test "untracked participant is removed from list_space" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _ref} = ChatPresence.track_in_space(self(), space_id, participant_id, %{})
      :ok = ChatPresence.untrack_in_space(self(), space_id, participant_id)

      # Give presence time to process
      :timer.sleep(50)
      presences = ChatPresence.list_space(space_id)
      refute Map.has_key?(presences, participant_id)
    end
  end

  describe "native_agent_presence/2" do
    test "reports runtime reachability for the configured agent" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "platform-chat-presence-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      slug = "zip-#{System.unique_integer([:positive, :monotonic])}"

      File.write!(
        Path.join(workspace, "openclaw.json"),
        Jason.encode!(%{
          "agents" => %{
            "list" => [
              %{
                "id" => slug,
                "name" => "Zip",
                "model" => %{"primary" => "anthropic/claude-sonnet-4-6"}
              }
            ]
          }
        })
      )

      File.write!(Path.join(workspace, "SOUL.md"), "steady")

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          slug: slug,
          name: "Zip",
          status: "active",
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        })
        |> Repo.insert()

      {:ok, space} =
        Chat.create_space(%{name: "General", slug: "presence-agent", kind: "channel"})

      {:ok, _participant} = Chat.add_agent_participant(space.id, agent)

      offline = ChatPresence.native_agent_presence(space.id, workspace_path: workspace)
      assert offline.configured?
      refute offline.reachable?
      assert offline.indicator == :offline

      {:ok, pid} = AgentServer.start_agent(agent)
      on_exit(fn -> AgentServer.stop_agent(pid) end)

      case Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid) do
        :ok -> :ok
        {:already, _} -> :ok
      end

      online = ChatPresence.native_agent_presence(space.id, workspace_path: workspace)
      assert online.reachable?
      assert online.indicator == :online
      assert online.joined?
    end
  end
end
