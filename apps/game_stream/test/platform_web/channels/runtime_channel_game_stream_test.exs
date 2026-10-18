defmodule PlatformWeb.RuntimeChannelGameStreamTest do
  @moduledoc """
  The play-host half of `Platform.GameStream.Protocol` over the real runtime
  socket (task 01a0db5f stage 2): a host that JOINS declaring
  `game_stream_host` is discovered, receives `play_session_start`, drives
  the session with `play_session_status` / `play_signal`, and fails its
  session by disconnecting. With the flag unset both frames are logged once
  and dropped, and the channel survives.

  NOT async: toggles `:game_stream, :enabled` (global app env).
  """

  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.GameStream
  alias Platform.Repo
  alias Platform.Tasks

  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule StubRunner do
    @moduledoc false
    def branch_head_sha(%{branch: "task/" <> _}),
      do: {:ok, "0123456789abcdef0123456789abcdef01234567"}

    def branch_head_sha(_), do: {:error, :ref_not_found}
  end

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.delete_env(:game_stream, :enabled)

    on_exit(fn ->
      stop_all_sessions()

      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    user =
      Repo.insert!(%User{
        email: "gsch-#{unique()}@example.com",
        name: "GS Channel User",
        oidc_sub: "gsch-#{unique()}"
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

  # Sessions live under a global DynamicSupervisor; one a case left running
  # would hold its host claim into the next case.
  defp stop_all_sessions do
    sup = Platform.GameStream.Supervisor.sessions()

    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  defp join_host(ctx, features \\ ["game_stream_host"]) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => ctx.runtime.runtime_id,
        "token" => ctx.token
      })

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
        "client_info" => %{"product" => "play_host", "features" => features}
      })

    socket
  end

  describe "flag unset" do
    test "play frames are logged once, dropped, and the channel lives", ctx do
      socket = join_host(ctx)

      log =
        capture_log(fn ->
          push(socket, "play_session_status", %{"session_id" => "x", "state" => "live"})
          push(socket, "play_signal", %{"session_id" => "x", "kind" => "offer", "data" => %{}})
          push(socket, "play_slot_activity", %{"session_id" => "x", "slots" => [0]})
          push(socket, "play_session_status", %{"session_id" => "x", "state" => "live"})
          # A round-trip frame so the three above have been handled.
          ref = push(socket, "pong", %{})
          assert is_reference(ref)
          :sys.get_state(socket.channel_pid)
        end)

      assert length(String.split(log, "game_stream is disabled")) == 2,
             "expected exactly one disabled log line, got:\n#{log}"

      assert Process.alive?(socket.channel_pid)
    end

    test "a play host's persisted features do not make a session startable", ctx do
      _socket = join_host(ctx)
      assert {:error, :disabled} = GameStream.start_session(ctx.task.id, runner: StubRunner)
    end
  end

  describe "flag set" do
    setup do
      Application.put_env(:game_stream, :enabled, true)
      :ok
    end

    test "a host that declared the feature at join is discovered and driven", ctx do
      socket = join_host(ctx)
      assert GameStream.host_available?()

      assert {:ok, %{session_id: id}} =
               GameStream.start_session(ctx.task.id, runner: StubRunner, linger_ms: 50)

      assert_push("play_session_start", %{session_id: ^id, sha: @sha})

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))
      {:ok, %{viewer_token: token}} = GameStream.attach_viewer(id, self())

      push(socket, "play_session_status", %{
        "session_id" => id,
        "state" => "live",
        "detail" => "Streaming",
        "elapsed_ms" => 1200
      })

      assert_receive {:game_stream, ^id, {:status, %{state: "live", detail: "Streaming"}}}

      push(socket, "play_signal", %{
        "session_id" => id,
        "kind" => "offer",
        "data" => %{"sdp" => "v=0"}
      })

      assert_receive {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0"}}}

      :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "answer"}, {self(), token})
      assert_push("play_signal", %{session_id: ^id, kind: "answer"})
    end

    test "a game_stream_multi host gets peer frames, and its peer-tagged signals and slot activity are routed (01a0dbd6)",
         ctx do
      socket = join_host(ctx, ["game_stream_host", "game_stream_multi"])

      {:ok, %{session_id: id, multi: true}} =
        GameStream.start_session(ctx.task.id, runner: StubRunner, linger_ms: 50)

      assert_push("play_session_start", %{session_id: ^id})
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))

      {:ok, %{peer_id: peer_id, viewer_token: token}} = GameStream.attach_viewer(id, self())
      assert_push("play_peer_open", %{session_id: ^id, peer_id: ^peer_id})
      assert_push("play_slots", %{session_id: ^id, peers: %{^peer_id => %{}}})

      {:ok, _} = GameStream.join(id, self(), 0)
      assert_push("play_slots", %{peers: peers})
      assert peers == %{peer_id => %{0 => 0}}

      push(socket, "play_signal", %{
        "session_id" => id,
        "kind" => "offer",
        "peer_id" => peer_id,
        "data" => %{"sdp" => "v=0 tagged"}
      })

      assert_receive {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0 tagged"}}}

      :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "a"}, {self(), token, peer_id})
      assert_push("play_signal", %{session_id: ^id, kind: "answer", peer_id: ^peer_id})

      push(socket, "play_slot_activity", %{"session_id" => id, "slots" => [0]})
      assert_receive {:game_stream, ^id, {:slot_activity, [0]}}

      # A malformed activity frame is dropped and the channel lives.
      push(socket, "play_slot_activity", %{"session_id" => id, "slots" => "zero"})
      :sys.get_state(socket.channel_pid)
      assert Process.alive?(socket.channel_pid)
    end

    test "a runtime that did not declare the feature is not a host", ctx do
      _socket = join_host(ctx, ["meeting_voice"])
      refute GameStream.host_available?()

      assert {:error, :no_play_host} =
               GameStream.start_session(ctx.task.id, runner: StubRunner)
    end

    test "the host disconnecting fails the session once the grace runs out", ctx do
      socket = join_host(ctx)

      {:ok, %{session_id: id}} =
        GameStream.start_session(ctx.task.id,
          runner: StubRunner,
          linger_ms: 5_000,
          host_grace_ms: 50
        )

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))

      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)
      close(socket)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert_receive {:game_stream, ^id,
                      {:status, %{state: "failed", detail: "The play host disconnected"}}},
                     2_000

      refute GameStream.host_available?()
    end

    # Stage 6 (01a0dbd6): a dropped runtime socket used to end the session
    # for every viewer. The host rejoins on a NEW socket and resumes it.
    test "a host that rejoins and resumes within the grace keeps its session", ctx do
      socket = join_host(ctx, ["game_stream_host", "game_stream_multi"])

      {:ok, %{session_id: id}} =
        GameStream.start_session(ctx.task.id,
          runner: StubRunner,
          linger_ms: 5_000,
          host_grace_ms: 300
        )

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))
      push(socket, "play_session_status", %{"session_id" => id, "state" => "live"})
      assert_receive {:game_stream, ^id, {:status, %{state: "live"}}}, 1_000

      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)
      close(socket)
      assert_receive {:DOWN, ^ref, :process, _, _}

      again = join_host(ctx, ["game_stream_host", "game_stream_multi"])

      push(again, "play_session_status", %{
        "session_id" => id,
        "state" => "live",
        "detail" => "Resumed",
        "resume" => true,
        "peers" => []
      })

      assert_receive {:game_stream, ^id, {:status, %{state: "live", detail: "Resumed"}}}, 1_000
      refute_receive {:game_stream, ^id, {:status, %{state: "failed"}}}, 600
      assert {:ok, %{state: "live"}} = GameStream.status(id)
    end

    test "a malformed or foreign frame does not crash the channel", ctx do
      socket = join_host(ctx)

      push(socket, "play_session_status", %{
        "session_id" => Ecto.UUID.generate(),
        "state" => "live"
      })

      push(socket, "play_session_status", %{"state" => "nope"})
      push(socket, "play_signal", %{"session_id" => "x", "kind" => "answer", "data" => %{}})
      :sys.get_state(socket.channel_pid)
      assert Process.alive?(socket.channel_pid)
    end
  end
end
