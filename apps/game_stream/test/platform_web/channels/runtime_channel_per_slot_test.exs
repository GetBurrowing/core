defmodule PlatformWeb.RuntimeChannelPerSlotTest do
  @moduledoc """
  The per-slot half of the play-host protocol (task 01a1a34c stage 3), driven
  end to end through the real runtime socket by `PlatformWeb.FakePlayHost`: a
  fake host that declares `game_stream_per_slot` and answers `play_slots` with
  `play_peer_view`. No real play host, git or network is involved.

  NOT async: toggles `:game_stream, :enabled` (global app env).
  """

  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.GameStream
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.FakePlayHost

  defmodule StubRunner do
    @moduledoc false
    def branch_head_sha(%{branch: "task/" <> _}),
      do: {:ok, "0123456789abcdef0123456789abcdef01234567"}

    def branch_head_sha(_), do: {:error, :ref_not_found}
  end

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      stop_all_sessions()

      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    user =
      Repo.insert!(%User{
        email: "gsps-#{unique()}@example.com",
        name: "GS PerSlot User",
        oidc_sub: "gsps-#{unique()}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "play-host-#{unique()}",
        tool_profile: []
      })

    {:ok, runtime, token} = Federation.activate_runtime(runtime)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Voltron #{unique()}",
        repo_url: "https://github.com/example/voltron"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Play #{unique()}"})
    task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()

    %{runtime: runtime, token: token, task: task}
  end

  defp unique, do: System.unique_integer([:positive])

  defp stop_all_sessions do
    sup = Platform.GameStream.Supervisor.sessions()

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  # A viewer is any live process; the session monitors it.
  defp viewer do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp start(ctx, opts \\ []) do
    {:ok, %{session_id: id} = started} =
      GameStream.start_session(
        ctx.task.id,
        Keyword.merge([runner: StubRunner, linger_ms: 5_000], opts)
      )

    assert_push("play_session_start", %{session_id: ^id})
    {id, started}
  end

  # Waits for a `play_slots` push whose `peers` satisfies `fun`, returns it.
  defp await_slots(fun, timeout \\ 1_000) do
    receive do
      %Phoenix.Socket.Message{event: "play_slots", payload: %{peers: peers} = payload} ->
        if fun.(peers), do: payload, else: await_slots(fun, timeout)
    after
      timeout -> flunk("no play_slots push satisfied the predicate")
    end
  end

  # Barrier: every frame the test pushed has been handled by the channel.
  defp settle(socket), do: :sys.get_state(socket.channel_pid)

  defp views(id) do
    {:ok, %{views: views}} = GameStream.roster(id)
    views
  end

  describe "per-slot host" do
    test "two players and one spectator get slot 0, slot 1 and shared views", ctx do
      socket = FakePlayHost.join(ctx)
      {id, %{per_slot: true}} = start(ctx)
      FakePlayHost.drive(socket, id)

      {p0, p1, spec} = {viewer(), viewer(), viewer()}
      {:ok, %{peer_id: id0}} = GameStream.attach_viewer(id, p0)
      {:ok, %{peer_id: id1}} = GameStream.attach_viewer(id, p1)
      {:ok, %{peer_id: id_spec}} = GameStream.attach_viewer(id, spec)
      {:ok, _} = GameStream.join(id, p0, 0)
      {:ok, _} = GameStream.join(id, p1, 0)

      payload = await_slots(&(&1 == %{id0 => %{0 => 0}, id1 => %{0 => 1}, id_spec => %{}}))
      :ok = FakePlayHost.answer_slots(socket, payload)
      settle(socket)

      assert {:ok, roster} = GameStream.roster(id)
      assert roster.per_slot == true

      assert roster.views == %{
               id0 => %{view: "slot", slot: 0},
               id1 => %{view: "slot", slot: 1},
               id_spec => %{view: "shared"}
             }
    end

    test "a player leaving and a new viewer taking slot 0: new peer slot 0, old peer shared",
         ctx do
      socket = FakePlayHost.join(ctx)
      {id, _} = start(ctx)
      FakePlayHost.drive(socket, id)

      {old, new} = {viewer(), viewer()}
      {:ok, %{peer_id: old_id}} = GameStream.attach_viewer(id, old)
      {:ok, %{peer_id: new_id}} = GameStream.attach_viewer(id, new)
      {:ok, _} = GameStream.join(id, old, 0)

      payload = await_slots(&(&1 == %{old_id => %{0 => 0}, new_id => %{}}))
      FakePlayHost.answer_slots(socket, payload)
      settle(socket)
      assert views(id)[old_id] == %{view: "slot", slot: 0}

      {:ok, _} = GameStream.leave(id, old)
      {:ok, _} = GameStream.join(id, new, 0)

      # The slot change cleared both views until the host re-reports.
      payload = await_slots(&(&1 == %{old_id => %{}, new_id => %{0 => 0}}))
      assert views(id)[old_id] == nil
      FakePlayHost.answer_slots(socket, payload)
      settle(socket)

      assert views(id) == %{
               new_id => %{view: "slot", slot: 0},
               old_id => %{view: "shared"}
             }
    end

    test "a host that closes and rejoins within the grace re-reports every view", ctx do
      socket = FakePlayHost.join(ctx)
      {id, _} = start(ctx, host_grace_ms: 5_000)
      FakePlayHost.drive(socket, id)

      {p0, p1, spec} = {viewer(), viewer(), viewer()}
      {:ok, %{peer_id: id0}} = GameStream.attach_viewer(id, p0)
      {:ok, %{peer_id: id1}} = GameStream.attach_viewer(id, p1)
      {:ok, %{peer_id: id_spec}} = GameStream.attach_viewer(id, spec)
      {:ok, _} = GameStream.join(id, p0, 0)
      {:ok, _} = GameStream.join(id, p1, 0)

      expected = %{id0 => %{0 => 0}, id1 => %{0 => 1}, id_spec => %{}}
      payload = await_slots(&(&1 == expected))
      FakePlayHost.answer_slots(socket, payload)
      settle(socket)
      assert map_size(views(id)) == 3

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))
      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)
      close(socket)
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert_receive {:game_stream, ^id, {:roster, %{views: dropped}}}, 1_000
      assert dropped == %{}

      again = FakePlayHost.join(ctx)
      :ok = FakePlayHost.resume(again, id, payload.peers)
      settle(again)

      assert views(id) == %{
               id0 => %{view: "slot", slot: 0},
               id1 => %{view: "slot", slot: 1},
               id_spec => %{view: "shared"}
             }

      assert {:ok, %{state: "live"}} = GameStream.status(id)
    end

    test "a 65-byte peer_id or slot 32 is refused and nothing in the roster changes", ctx do
      socket = FakePlayHost.join(ctx)
      {id, _} = start(ctx)
      FakePlayHost.drive(socket, id)

      p0 = viewer()
      {:ok, %{peer_id: id0}} = GameStream.attach_viewer(id, p0)
      {:ok, _} = GameStream.join(id, p0, 0)
      payload = await_slots(&(&1 == %{id0 => %{0 => 0}}))
      FakePlayHost.answer_slots(socket, payload)
      settle(socket)

      {:ok, before} = GameStream.roster(id)
      assert before.views == %{id0 => %{view: "slot", slot: 0}}

      long = String.duplicate("p", 65)
      assert byte_size(long) == 65

      push(socket, "play_peer_view", %{"session_id" => id, "peer_id" => long, "view" => "shared"})

      push(socket, "play_peer_view", %{
        "session_id" => id,
        "peer_id" => long,
        "view" => "slot",
        "slot" => 0
      })

      push(socket, "play_peer_view", %{
        "session_id" => id,
        "peer_id" => id0,
        "view" => "slot",
        "slot" => 32
      })

      settle(socket)
      assert Process.alive?(socket.channel_pid)
      assert {:ok, ^before} = GameStream.roster(id)
    end
  end

  describe "host without game_stream_per_slot" do
    test "keeps today's behaviour: no per_slot, no views, view frames dropped", ctx do
      socket = FakePlayHost.join(ctx, ["game_stream_host", "game_stream_multi"])

      {:ok, %{session_id: id} = started} =
        GameStream.start_session(ctx.task.id, runner: StubRunner, linger_ms: 5_000)

      refute started.per_slot

      assert_push("play_session_start", start_payload)

      assert start_payload |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
               ~w(branch encoder ice_servers idle_timeout_s repo_url session_id sha task_id)

      FakePlayHost.drive(socket, id)

      viewer = viewer()
      {:ok, %{peer_id: peer_id}} = GameStream.attach_viewer(id, viewer)
      {:ok, _} = GameStream.join(id, viewer, 0)
      {:ok, before} = GameStream.roster(id)
      assert before.per_slot == false
      assert before.views == %{}

      FakePlayHost.report(socket, id, peer_id, %{0 => 0})
      settle(socket)
      assert Process.alive?(socket.channel_pid)

      {:ok, after_roster} = GameStream.roster(id)
      assert after_roster.per_slot == false
      assert after_roster.views == %{}
      assert after_roster == before
    end
  end
end
