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
        Platform.TestTemp.path("platform-chat-presence")

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

  # ── safe_* helpers ─────────────────────────────────────────────────────────
  #
  # The tracker is VM-global, so these cases are `async: false` (module-wide)
  # and every induction is undone before the test returns. A leaked dead
  # tracker reds unrelated presence cases in the same run and looks like flake.
  #
  # Both failures are induced for REAL against the shipped call path. Nothing
  # is stubbed and no error tuple is hand-written: an injected shape would only
  # prove the assertion matches the thing injected.

  defp kill_tracker! do
    # The shutdown propagates as an exit signal to whatever is linked into the
    # tracker's tree; trap it so the assertions below actually get to run.
    Process.flag(:trap_exit, true)
    on_exit(&restart_tracker!/0)
    :ok = Supervisor.terminate_child(Platform.Supervisor, ChatPresence)
    :ok
  end

  defp restart_tracker! do
    case Supervisor.restart_child(Platform.Supervisor, ChatPresence) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    wait_for_tracker!(100)
  end

  defp wait_for_tracker!(0), do: raise("presence tracker did not come back up")

  defp wait_for_tracker!(attempts) do
    if is_pid(Process.whereis(ChatPresence)) do
      :ok
    else
      :timer.sleep(20)
      wait_for_tracker!(attempts - 1)
    end
  end

  # Make the shard for `space_id` unreachable BY NAME while leaving the tracker
  # (and therefore its `pool_size` ETS table) alive, so `GenServer.call/3` is
  # the thing that dies and the failure arrives as an `:exit`, not a raise.
  # Deliberately not `Process.exit/2` on the shard: the tracker supervisor
  # restarts it, so a terminate-based induction races the restart and would be
  # flaky in exactly the way this module must not be.
  defp orphan_shard!(space_id) do
    topic = Platform.Chat.PubSub.space_topic(space_id)
    [{:pool_size, pool_size}] = :ets.lookup(ChatPresence, :pool_size)
    shard = Phoenix.Tracker.Shard.name_for_topic(ChatPresence, topic, pool_size)
    pid = Process.whereis(shard)
    assert is_pid(pid), "expected a live shard for the topic before orphaning it"
    true = Process.unregister(shard)
    on_exit(fn -> if is_nil(Process.whereis(shard)), do: Process.register(pid, shard) end)
    :ok
  end

  describe "safe_track_in_space/4" do
    test "returns {:ok, ref} against a healthy tracker" do
      space_id = Ecto.UUID.generate()

      assert {:ok, ref} =
               ChatPresence.safe_track_in_space(self(), space_id, Ecto.UUID.generate(), %{
                 participant_type: "user"
               })

      assert is_binary(ref)
    end

    test "a terminated tracker returns {:error, %ArgumentError{}}, never a bare {:ok, _}" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      # Positive control on the same ids: the healthy call succeeds, so the
      # error below is the guard firing rather than the helper being broken.
      assert {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})

      kill_tracker!()

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})
        end)

      assert {:error, %ArgumentError{}} = result
      assert log =~ "presence track_in_space failed"
    end

    test "an unreachable shard returns {:error, {:exit, _}} — the mode rescue cannot catch" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      assert {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})

      orphan_shard!(space_id)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})
        end)

      assert {:error, {:exit, reason}} = result,
             "expected an :exit-shaped error; a rescue-only guard would have crashed the caller"

      assert match?({:noproc, _}, reason), "expected a :noproc exit, got #{inspect(reason)}"
      assert log =~ "presence track_in_space failed"
    end
  end

  describe "safe_untrack_in_space/3" do
    test "returns :ok against a healthy tracker" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})
      assert :ok = ChatPresence.safe_untrack_in_space(self(), space_id, participant_id)
    end

    test "a terminated tracker returns {:error, %ArgumentError{}} rather than a false :ok" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})
      assert :ok = ChatPresence.safe_untrack_in_space(self(), space_id, participant_id)

      kill_tracker!()

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ChatPresence.safe_untrack_in_space(self(), space_id, participant_id)
        end)

      assert {:error, %ArgumentError{}} = result
      assert log =~ "presence untrack_in_space failed"
    end

    test "an unreachable shard returns {:error, {:exit, _}}" do
      space_id = Ecto.UUID.generate()
      participant_id = Ecto.UUID.generate()

      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, participant_id, %{})
      assert :ok = ChatPresence.safe_untrack_in_space(self(), space_id, participant_id)

      orphan_shard!(space_id)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ChatPresence.safe_untrack_in_space(self(), space_id, participant_id)
        end)

      assert {:error, {:exit, reason}} = result,
             "expected an :exit-shaped error; a rescue-only guard would have crashed the caller"

      assert match?({:noproc, _}, reason), "expected a :noproc exit, got #{inspect(reason)}"
      assert log =~ "presence untrack_in_space failed"
    end
  end

  describe "safe_online_count/1" do
    test "an empty space is {:ok, 0} — a real answer about an empty room" do
      assert ChatPresence.safe_online_count(Ecto.UUID.generate()) == {:ok, 0}
    end

    test "a tracked participant is counted" do
      space_id = Ecto.UUID.generate()
      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, Ecto.UUID.generate(), %{})
      assert ChatPresence.safe_online_count(space_id) == {:ok, 1}
    end

    test "a terminated tracker returns {:error, _} and NOT {:ok, 0}" do
      space_id = Ecto.UUID.generate()
      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, Ecto.UUID.generate(), %{})
      assert ChatPresence.safe_online_count(space_id) == {:ok, 1}

      kill_tracker!()

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> ChatPresence.safe_online_count(space_id) end)

      assert {:error, %ArgumentError{}} = result

      refute result == {:ok, 0},
             "a broken presence read must not be indistinguishable from an empty room"

      assert log =~ "presence online_count failed"
    end

    test "an unreachable shard returns {:error, {:exit, _}} and NOT {:ok, 0}" do
      space_id = Ecto.UUID.generate()
      {:ok, _} = ChatPresence.safe_track_in_space(self(), space_id, Ecto.UUID.generate(), %{})
      assert ChatPresence.safe_online_count(space_id) == {:ok, 1}

      orphan_shard!(space_id)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> ChatPresence.safe_online_count(space_id) end)

      assert {:error, {:exit, reason}} = result,
             "expected an :exit-shaped error; a rescue-only guard would have crashed the caller"

      assert match?({:noproc, _}, reason), "expected a :noproc exit, got #{inspect(reason)}"

      refute result == {:ok, 0},
             "a broken presence read must not be indistinguishable from an empty room"

      assert log =~ "presence online_count failed"
    end
  end
end
