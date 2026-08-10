defmodule Platform.Chat.PresenceTest do
  use Platform.DataCase, async: false

  alias Platform.Agents.{Agent, AgentServer}
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

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

  # ── list_online_for_viewer/1 fixtures ────────────────────────────────────
  #
  # Every absence assertion in the describe below shares a run with a positive
  # control: a function that returned `{:ok, []}` unconditionally would satisfy
  # every refute on its own, so each one sits beside a colleague who MUST
  # appear.

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: name, oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp org_member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp space!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Chan",
        slug: "chan-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  defp participant!(space, user, display_name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp online!(space, user, meta) do
    {:ok, _} = ChatPresence.track_in_space(self(), space.id, user.id, meta)
    :ok
  end

  describe "list_online_for_viewer/1" do
    setup do
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = create_user!("Vera Viewer")
      colleague = create_user!("Cora Colleague")
      org_member!(viewer, home)
      org_member!(colleague, home)

      shared = space!(home)
      participant!(shared, viewer, "Vera Viewer")
      participant!(shared, colleague, "Cora Colleague")

      %{home: home, foreign: foreign, viewer: viewer, colleague: colleague, shared: shared}
    end

    test "an offline participant is absent while an online colleague is present", ctx do
      offline_user = create_user!("Otto Offline")
      org_member!(offline_user, ctx.home)
      participant!(ctx.shared, offline_user, "Otto Offline")

      online!(ctx.shared, ctx.colleague, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

      assert {:ok, list} = ChatPresence.list_online_for_viewer(ctx.viewer)

      names = Enum.map(list, & &1.name)
      # Positive control first — without it the refutes below prove nothing.
      assert "Cora Colleague" in names
      refute "Otto Offline" in names
      refute offline_user.id in Enum.map(list, & &1.user_id)
    end

    test "a user online in a foreign-org space is absent while the colleague is present", ctx do
      stranger = create_user!("Fiona Foreign")
      org_member!(stranger, ctx.foreign)
      foreign_space = space!(ctx.foreign)
      participant!(foreign_space, stranger, "Fiona Foreign")
      # The viewer even holds a participant row there — membership alone must
      # not be enough to leak a name across the org fence.
      participant!(foreign_space, ctx.viewer, "Vera Viewer")

      online!(foreign_space, stranger, %{participant_type: "user", display_name: "Fiona Foreign"})

      online!(ctx.shared, ctx.colleague, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

      assert {:ok, list} = ChatPresence.list_online_for_viewer(ctx.viewer)

      names = Enum.map(list, & &1.name)
      assert "Cora Colleague" in names
      refute "Fiona Foreign" in names
    end

    test "the viewer's own presence is excluded while the colleague's is kept", ctx do
      online!(ctx.shared, ctx.viewer, %{participant_type: "user", display_name: "Vera Viewer"})

      online!(ctx.shared, ctx.colleague, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

      assert {:ok, list} = ChatPresence.list_online_for_viewer(ctx.viewer)

      ids = Enum.map(list, & &1.user_id)
      assert ctx.colleague.id in ids
      refute ctx.viewer.id in ids
    end

    test "length(list) is the number the badge renders, and agents do not inflate it", ctx do
      second = create_user!("Bea Both")
      org_member!(second, ctx.home)
      participant!(ctx.shared, second, "Bea Both")
      agent_id = Ecto.UUID.generate()

      online!(ctx.shared, ctx.colleague, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

      online!(ctx.shared, second, %{participant_type: "user", display_name: "Bea Both"})

      {:ok, _} =
        ChatPresence.track_in_space(self(), ctx.shared.id, agent_id, %{
          participant_type: "agent",
          display_name: "Robo"
        })

      assert {:ok, list} = ChatPresence.list_online_for_viewer(ctx.viewer)

      # The template consumes exactly this value for the badge.
      assert length(list) == 2
      assert Enum.map(list, & &1.name) == ["Bea Both", "Cora Colleague"]
    end

    test "a presence with no display_name falls back to the participant row name", ctx do
      online!(ctx.shared, ctx.colleague, %{participant_type: "user"})

      assert {:ok, [entry]} = ChatPresence.list_online_for_viewer(ctx.viewer)
      assert entry.user_id == ctx.colleague.id
      assert entry.name == "Cora Colleague"
    end

    test "nobody online is {:ok, []} — a real answer, not a failure", ctx do
      assert ChatPresence.list_online_for_viewer(ctx.viewer) == {:ok, []}
    end

    test "a raise inside the read returns {:error, _} rather than {:ok, []}", ctx do
      # Positive control on the same fixture: the healthy read returns the
      # colleague, so the {:error, _} below is the rescue firing rather than
      # the function being broken outright.
      online!(ctx.shared, ctx.colleague, %{
        participant_type: "user",
        display_name: "Cora Colleague"
      })

      assert {:ok, [%{name: "Cora Colleague"}]} = ChatPresence.list_online_for_viewer(ctx.viewer)

      # A viewer id the scoping query cannot cast makes the resolution raise.
      broken = %{ctx.viewer | id: "not-a-uuid"}

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> ChatPresence.list_online_for_viewer(broken) end)

      assert {:error, reason} = result
      assert is_exception(reason)
      # The rescue was observed to fire, not merely assumed to exist.
      assert log =~ "presence union read failed"
    end
  end
end
