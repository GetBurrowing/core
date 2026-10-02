defmodule Platform.GameStreamTest do
  @moduledoc """
  `Platform.GameStream` — review-build resolution, host discovery, one
  session per host, status transitions, host disconnect and viewer takeover
  (task 01a0db5f stage 2); peers, player slots, spectators and the per-peer
  signal owner check (task 01a0dbd6 stage 2).

  NOT async: cases toggle `:game_stream, :enabled` (global app env)
  and track runtimes in the global `RuntimePresence` map.

  ## The review sha is observed at the runner, not inferred

  A stub runner stands in for GitHub and SENDS every `branch_head_sha/1` it
  is asked to the test process (`ReviewBuild` calls it in the caller's
  process). So "never falls back to main" is asserted as "the runner was
  asked about `task/<full uuid>` and about nothing else", and "nothing is
  started" as "no `play_session_start` reached the host topic" — both
  observable, neither a restatement of the code.
  """

  use Platform.DataCase, async: false

  alias Phoenix.Socket.Broadcast
  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.GameStream
  alias Platform.GameStream.SessionRecord
  alias Platform.Repo
  alias Platform.Tasks

  @sha "0123456789abcdef0123456789abcdef01234567"
  @sha2 "89abcdef0123456789abcdef0123456789abcdef"

  defmodule StubRunner do
    @moduledoc false
    # `heads` is read from the CALLER's process dictionary: `ReviewBuild`
    # runs in the process that called `start_session/2`.
    def branch_head_sha(%{repo: repo, branch: branch} = args) do
      send(self(), {:branch_head_sha, args})

      case Map.get(Process.get(:stub_heads, %{}), {repo, branch}, :missing) do
        :missing -> {:error, :ref_not_found}
        {:error, _} = err -> err
        sha -> {:ok, sha}
      end
    end
  end

  # A dropped host is waited for this long before its session fails (stage 6
  # resume); short here so the "not back in time" cases stay fast.
  @grace_ms 80

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)
    previous_grace = Application.get_env(:platform, :game_stream_host_grace_ms)
    Application.put_env(:platform, :game_stream_host_grace_ms, @grace_ms)

    on_exit(fn ->
      stop_all_sessions()

      if is_nil(previous_grace),
        do: Application.delete_env(:platform, :game_stream_host_grace_ms),
        else: Application.put_env(:platform, :game_stream_host_grace_ms, previous_grace)

      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    user =
      Repo.insert!(%User{
        email: "gs-#{unique()}@example.com",
        name: "GS User",
        oidc_sub: "gs-#{unique()}"
      })

    {:ok, project} =
      Tasks.create_project(%{
        name: "Voltron #{unique()}",
        repo_url: "https://github.com/rowanellis/voltron"
      })

    %{user: user, project: project}
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

  defp task!(project, status) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Game task #{unique()}"})
    task |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  defp heads!(map), do: Process.put(:stub_heads, map)

  defp frame(id, state, extra \\ %{}),
    do: Map.merge(%{"session_id" => id, "state" => state, "elapsed_ms" => 10}, extra)

  defp branch(task), do: "task/" <> task.id

  # A present runtime that declares `game_stream_host`. The host topic is
  # subscribed so the test observes what core broadcasts to the host.
  defp host!(user, features \\ ["game_stream_host"]) do
    runtime_id = "play-host-#{unique()}"

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: runtime_id,
        allowed_bundles: [],
        metadata: %{"client_info" => %{"features" => features}}
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)
    RuntimePresence.track(runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime_id) end)
    :ok = PlatformWeb.Endpoint.subscribe("runtime:" <> runtime_id)
    runtime
  end

  defp start!(task, opts \\ []) do
    GameStream.start_session(task.id, Keyword.merge([runner: StubRunner, linger_ms: 50], opts))
  end

  describe "the flag" do
    test "every entry point is refused while GAME_STREAM_ENABLED is unset", ctx do
      Application.delete_env(:game_stream, :enabled)
      task = task!(ctx.project, "in_review")

      assert {:error, :disabled} = start!(task)
      refute_received {:branch_head_sha, _}
      assert {:error, :disabled} = GameStream.status(Ecto.UUID.generate())
      assert {:error, :disabled} = GameStream.stop_session(Ecto.UUID.generate())
      assert {:error, :disabled} = GameStream.handle_host_status("x", %{})
      assert {:error, :disabled} = GameStream.relay_to_viewer("x", %{})
      assert :ok = GameStream.host_disconnected("x")
      refute GameStream.host_available?()
    end

    test "only \"true\" or \"1\" in runtime.exs turns it on" do
      Application.put_env(:game_stream, :enabled, "true")
      refute GameStream.enabled?()
      Application.put_env(:game_stream, :enabled, true)
      assert GameStream.enabled?()
    end
  end

  describe "review build resolution" do
    test "an in_review task starts at its branch tip sha", ctx do
      runtime = host!(ctx.user)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      assert {:ok, status} = start!(task)
      assert status.review_sha == @sha
      assert status.branch == branch(task)
      assert status.state == "building"
      assert status.host_runtime_id == runtime.runtime_id

      assert_receive %Broadcast{event: "play_session_start", payload: payload}
      assert payload.sha == @sha
      assert payload.branch == branch(task)
      assert payload.repo_url == "https://github.com/rowanellis/voltron"
      assert payload.session_id == status.session_id
      assert payload.task_id == task.id
      assert payload.encoder == Platform.Experiments.Surfaces.GameStreamEncoder.control()
      assert payload.ice_servers == []
      assert payload.idle_timeout_s == 600
    end

    test "a task not in_review is refused before the branch is even asked", ctx do
      host!(ctx.user)

      for status <- ~w(backlog in_progress done) do
        task = task!(ctx.project, status)
        heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
        assert {:error, :not_in_review} = start!(task)
      end

      refute_received {:branch_head_sha, _}
      refute_received %Broadcast{event: "play_session_start"}
    end

    test "a branchless task is refused with no_review_branch and NEVER falls back to main",
         ctx do
      host!(ctx.user)
      task = task!(ctx.project, "in_review")
      # main exists and has a tip; a fallback would find it.
      heads!(%{{"rowanellis/voltron", "main"} => @sha2})

      assert {:error, :no_review_branch} = start!(task)

      assert_received {:branch_head_sha, %{branch: asked}}
      assert asked == branch(task)
      refute_received {:branch_head_sha, _}
      refute_receive %Broadcast{event: "play_session_start"}, 100
      assert Repo.aggregate(SessionRecord, :count) == 0
    end

    test "a lookup that fails for another reason is reported, and still never main", ctx do
      host!(ctx.user)
      task = task!(ctx.project, "in_review")

      heads!(%{
        {"rowanellis/voltron", branch(task)} => {:error, :gh_unavailable},
        {"rowanellis/voltron", "main"} => @sha2
      })

      assert {:error, {:review_branch_unresolved, :gh_unavailable}} = start!(task)
      refute_receive %Broadcast{event: "play_session_start"}, 100
    end

    test "the branch is StackDeployer.member_branch_for/1, the full task uuid", ctx do
      host!(ctx.user)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      assert {:ok, status} = start!(task)
      assert status.branch == Platform.Tasks.StackDeployer.member_branch_for(task)
      assert status.branch =~ ~r/\Atask\/[0-9a-f-]{36}\z/
    end

    test "a project without a repo is refused", ctx do
      host!(ctx.user)
      {:ok, bare} = Tasks.create_project(%{name: "No repo #{unique()}"})
      task = task!(bare, "in_review")
      assert {:error, :no_repo} = start!(task)
    end
  end

  describe "hosts" do
    test "no present host is no_play_host", ctx do
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      refute GameStream.host_available?()
      assert {:error, :no_play_host} = start!(task)
    end

    test "a present runtime that does not declare the feature is not a host", ctx do
      host!(ctx.user, ["meeting_voice"])
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      assert {:error, :no_play_host} = start!(task)
    end

    test "a declared host that is not connected is not a host", ctx do
      runtime = host!(ctx.user)
      RuntimePresence.untrack(runtime.runtime_id)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      assert {:error, :no_play_host} = start!(task)
    end

    test "one session per host: a second start is host_busy", ctx do
      host!(ctx.user)
      a = task!(ctx.project, "in_review")
      b = task!(ctx.project, "in_review")

      heads!(%{
        {"rowanellis/voltron", branch(a)} => @sha,
        {"rowanellis/voltron", branch(b)} => @sha2
      })

      assert GameStream.host_available?()
      assert {:ok, _} = start!(a)
      assert {:error, :host_busy} = start!(b)
      assert {:error, :host_busy} = start!(a)
    end
  end

  describe "status transitions" do
    setup ctx do
      runtime = host!(ctx.user)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      {:ok, status} = start!(task)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(status.session_id))
      %{runtime: runtime, task: task, session_id: status.session_id}
    end

    test "building → connecting → live, each published to the viewer topic", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id

      for state <- ~w(building connecting live) do
        assert :ok = GameStream.handle_host_status(rid, frame(id, state, %{"detail" => state}))
        assert_receive {:game_stream, ^id, {:status, %{state: ^state, detail: ^state}}}
      end

      assert {:ok, %{state: "live"}} = GameStream.status(id)
    end

    test "a frame from a runtime that is not the session's host is dropped", ctx do
      other = host!(ctx.user)
      id = ctx.session_id

      assert {:error, :not_host} =
               GameStream.handle_host_status(other.runtime_id, frame(id, "failed"))

      assert {:ok, %{state: "building"}} = GameStream.status(id)
    end

    test "an unknown state or malformed frame is refused", ctx do
      rid = ctx.runtime.runtime_id

      assert {:error, :unknown_state} =
               GameStream.handle_host_status(rid, frame(ctx.session_id, "zzz"))

      assert {:error, :malformed} = GameStream.handle_host_status(rid, %{"state" => "live"})
    end

    test "ended is terminal, frees the host, and writes the row with the last stats", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id

      :ok = GameStream.handle_host_status(rid, frame(id, "live"))

      :ok =
        GameStream.report_stats(id, %{
          "rtt_p50_ms" => 31,
          "rtt_p95_ms" => 48.5,
          "fps_avg" => 59.9,
          "connection_path" => "lan",
          "bogus" => 1
        })

      :ok = GameStream.handle_host_status(rid, frame(id, "ended", %{"detail" => "idle"}))

      # The host's bare "idle" is worded as the design words it (stage 6),
      # from this session's idle_timeout_s (the default, 600 s).
      assert_receive {:game_stream, ^id,
                      {:status,
                       %{
                         state: "ended",
                         detail: "Session ended after 10 minutes idle",
                         ended_reason: "Session ended after 10 minutes idle"
                       }}}

      assert {:error, :terminal} = GameStream.handle_host_status(rid, frame(id, "live"))

      row = Repo.get!(SessionRecord, id)
      assert row.task_id == ctx.task.id
      assert row.review_sha == @sha
      assert row.ended_state == "ended"
      assert row.ended_reason == "Session ended after 10 minutes idle"
      assert row.rtt_p50_ms == 31.0
      assert row.rtt_p95_ms == 48.5
      assert row.connection_path == "lan"
      assert row.host_runtime_id == rid

      # The host is free again immediately, before the ended session lingers out.
      other = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(other)} => @sha2})
      assert {:ok, _} = start!(other)
    end

    test "a 60 s idle end is worded 'Session ended after 1 minute idle' on the canvas and the row",
         ctx do
      GameStream.stop_session(ctx.session_id)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      {:ok, %{session_id: id}} = start!(task, idle_timeout_s: 60)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(id))
      rid = ctx.runtime.runtime_id

      :ok = GameStream.handle_host_status(rid, frame(id, "ended", %{"detail" => "idle"}))
      reason = "Session ended after 1 minute idle"

      assert_receive {:game_stream, ^id,
                      {:status, %{state: "ended", detail: ^reason, ended_reason: ^reason}}}

      assert Repo.get!(SessionRecord, id).ended_reason == reason

      # What the canvas renders for it (a reload after the end).
      assert {"ended", ^reason, _} =
               Platform.Chat.Canvas.Kinds.GameStream.initial_view(id, GameStream.status(id))
    end

    test "idle_reason/1 words singular, plural and odd timeouts" do
      alias Platform.GameStream.Session
      assert Session.idle_reason(60) == "Session ended after 1 minute idle"
      assert Session.idle_reason(600) == "Session ended after 10 minutes idle"
      assert Session.idle_reason(90) == "Session ended after 90 seconds idle"
      assert Session.idle_reason(nil) == "Session ended after a period idle"
    end

    test "only an ENDED 'idle' is reworded; other details pass through", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id
      :ok = GameStream.handle_host_status(rid, frame(id, "building", %{"detail" => "idle"}))
      assert_receive {:game_stream, ^id, {:status, %{state: "building", detail: "idle"}}}
      :ok = GameStream.handle_host_status(rid, frame(id, "failed", %{"detail" => "boom"}))
      assert_receive {:game_stream, ^id, {:status, %{state: "failed", ended_reason: "boom"}}}
    end

    test "stop_session tells the host, ends the session and records it", ctx do
      id = ctx.session_id
      assert {:ok, %{state: "ended", ended_reason: "done"}} = GameStream.stop_session(id, "done")
      assert_receive %Broadcast{event: "play_session_stop", payload: %{session_id: ^id}}
      assert %SessionRecord{ended_state: "ended", rtt_p50_ms: nil} = Repo.get!(SessionRecord, id)
      # idempotent
      assert {:ok, %{state: "ended"}} = GameStream.stop_session(id, "again")
    end

    test "a host that drops and is not back within the grace fails the session", ctx do
      id = ctx.session_id
      assert :ok = GameStream.host_disconnected(ctx.runtime.runtime_id)
      # Not at once: the session waits for the host to resume it.
      refute_receive {:game_stream, ^id, {:status, %{state: "failed"}}}, div(@grace_ms, 2)

      assert_receive {:game_stream, ^id,
                      {:status, %{state: "failed", detail: "The play host disconnected"}}},
                     1_000

      assert %SessionRecord{ended_state: "failed"} = Repo.get!(SessionRecord, id)
    end

    # Stage 6 (01a0dbd6): the review saw the runtime socket drop twice in
    # about 35 minutes, and each drop ended the session for every viewer.
    test "a host that drops and resumes within the grace keeps the session", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id
      :ok = GameStream.handle_host_status(rid, frame(id, "live", %{"detail" => "Streaming"}))
      assert_receive {:game_stream, ^id, {:status, %{state: "live"}}}

      assert :ok = GameStream.host_disconnected(rid)

      assert :ok =
               GameStream.handle_host_status(
                 rid,
                 frame(id, "live", %{"detail" => "Streaming", "resume" => true, "peers" => []})
               )

      refute_receive {:game_stream, ^id, {:status, %{state: "failed"}}}, @grace_ms * 3
      assert {:ok, %{state: "live", detail: "Streaming"}} = GameStream.status(id)
      assert is_nil(Repo.get(SessionRecord, id))
    end

    test "a drop from an older channel is ignored once the host spoke on a newer one", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id
      # The test process is the host's current channel (it spoke last).
      :ok = GameStream.handle_host_status(rid, frame(id, "live"))
      assert_receive {:game_stream, ^id, {:status, %{state: "live"}}}

      old_channel = spawn(fn -> :ok end)
      assert :ok = Platform.GameStream.Session.call(id, {:host_disconnected, old_channel})
      refute_receive {:game_stream, ^id, {:status, %{state: "failed"}}}, @grace_ms * 3
      assert {:ok, %{state: "live"}} = GameStream.status(id)

      # Positive control: the SAME call from the current channel does fail it.
      assert :ok = Platform.GameStream.Session.call(id, {:host_disconnected, self()})

      assert_receive {:game_stream, ^id,
                      {:status, %{state: "failed", detail: "The play host disconnected"}}},
                     1_000
    end

    test "a resume for a session core no longer runs is answered with play_session_stop",
         ctx do
      rid = ctx.runtime.runtime_id
      gone = Ecto.UUID.generate()
      flush_host_frames()

      # A plain status for an unknown session is only dropped...
      assert {:error, :not_found} = GameStream.handle_host_status(rid, frame(gone, "live"))
      refute_receive %Broadcast{event: "play_session_stop"}, 50

      # ...a resume is told to stop.
      resume = %{"resume" => true, "peers" => ["p1"]}

      assert {:error, :not_found} =
               GameStream.handle_host_status(rid, frame(gone, "live", resume))

      assert_receive %Broadcast{
        event: "play_session_stop",
        payload: %{session_id: ^gone, reason: "The play host disconnected"}
      }

      # A session that already ended, likewise.
      id = ctx.session_id
      {:ok, _} = GameStream.stop_session(id)
      flush_host_frames()
      assert {:error, :terminal} = GameStream.handle_host_status(rid, frame(id, "live", resume))
      assert_receive %Broadcast{event: "play_session_stop", payload: %{session_id: ^id}}
    end

    test "a resume must list its peers as peer ids", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id

      for peers <- [nil, "p1", [1], [""], List.duplicate("p", 65)] do
        assert {:error, :bad_resume_peers} =
                 GameStream.handle_host_status(
                   rid,
                   frame(id, "live", %{"resume" => true, "peers" => peers})
                 )
      end

      # Without resume, peers is ignored.
      assert :ok = GameStream.handle_host_status(rid, frame(id, "live", %{"peers" => "junk"}))
    end

    test "an ended session lingers, then is not_found", ctx do
      id = ctx.session_id
      {:ok, _} = GameStream.stop_session(id)
      assert {:ok, _} = GameStream.status(id)
      Process.sleep(150)
      assert {:error, :not_found} = GameStream.status(id)
    end
  end

  # A process standing in for a LiveView: it forwards everything it is sent
  # to the test process, tagged with its own pid.
  defp viewer! do
    parent = self()

    pid =
      spawn(fn ->
        loop = fn loop ->
          receive do
            :stop -> :ok
            msg -> send(parent, {:viewer_got, self(), msg}) && loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  defp offer_from_host(rid, id, extra \\ %{}) do
    GameStream.relay_to_viewer(
      rid,
      Map.merge(%{"session_id" => id, "kind" => "offer", "data" => %{"sdp" => "v=0"}}, extra)
    )
  end

  defp roster_default!(payload) do
    Repo.insert!(
      Platform.Experiments.SurfaceDefault.changeset(%Platform.Experiments.SurfaceDefault{}, %{
        surface_key: "game_stream.roster",
        surface_target: "play_session.start",
        seq: 1,
        kind: "promote",
        payload: payload
      })
    )
  end

  describe "signalling on a v1 host (no game_stream_multi)" do
    setup ctx do
      runtime = host!(ctx.user)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      {:ok, status} = start!(task)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(status.session_id))
      %{runtime: runtime, session_id: status.session_id}
    end

    test "the host's offer reaches the viewer; the viewer's answer reaches the host untagged",
         ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id
      {:ok, %{viewer: true, viewer_token: token}} = GameStream.attach_viewer(id, self())

      assert :ok = offer_from_host(rid, id)
      assert_receive {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0"}}}

      assert :ok =
               GameStream.relay_to_host(id, "answer", %{"sdp" => "v=0 answer"}, {self(), token})

      assert_receive %Broadcast{event: "play_signal", payload: payload}
      assert payload == %{session_id: id, kind: "answer", data: %{"sdp" => "v=0 answer"}}
      # A v1 host is sent none of the peer frames.
      refute_received %Broadcast{event: "play_peer_open"}
      refute_received %Broadcast{event: "play_slots"}
    end

    test "directions are enforced: a viewer cannot offer and a host cannot answer", ctx do
      id = ctx.session_id
      assert {:error, :bad_signal_kind} = GameStream.relay_to_host(id, "offer", %{}, {self(), 1})

      assert {:error, :bad_signal_kind} =
               GameStream.relay_to_viewer(ctx.runtime.runtime_id, %{
                 "session_id" => id,
                 "kind" => "answer",
                 "data" => %{}
               })
    end

    test "a second window WATCHES: it does not take the stream and moves nobody", ctx do
      id = ctx.session_id
      a = viewer!()
      b = viewer!()

      assert {:ok, %{viewer: true, peer_id: pa}} = GameStream.attach_viewer(id, a)

      assert {:ok, %{viewer: false, viewer_token: nil, peer_id: pb, role: :spectator}} =
               GameStream.attach_viewer(id, b)

      refute pa == pb
      refute_receive {:viewer_got, ^a, {:game_stream, ^id, :moved}}, 50

      # The host's offer still goes to the holder only.
      :ok = offer_from_host(ctx.runtime.runtime_id, id)
      assert_receive {:viewer_got, ^a, {:game_stream, ^id, {:signal, "offer", _}}}
      refute_receive {:viewer_got, ^b, {:game_stream, ^id, {:signal, _, _}}}, 50
    end

    test "Play here is a take-over of slot 0: the holder is displaced AND moved", ctx do
      id = ctx.session_id
      a = viewer!()
      b = viewer!()
      {:ok, %{viewer: true}} = GameStream.attach_viewer(id, a)
      {:ok, %{viewer: false}} = GameStream.attach_viewer(id, b)

      assert {:ok, %{viewer: true, slots: %{0 => 0}, viewer_token: token}} =
               GameStream.take_over(id, b, 0)

      assert is_integer(token)
      assert_receive {:viewer_got, ^a, {:game_stream, ^id, {:displaced, 0, nil}}}
      assert_receive {:viewer_got, ^a, {:game_stream, ^id, :moved}}

      # v1 has one slot, and a v1 host cannot drop a connected viewer's input.
      assert {:error, :no_such_slot} = GameStream.take_over(id, a, 1)
      assert {:error, :single_peer_host} = GameStream.leave(id, b)
      refute_received %Broadcast{event: "play_peer_close"}
    end

    test "only the stream holder's current token reaches the host", ctx do
      id = ctx.session_id
      other = viewer!()

      {:ok, %{viewer_token: mine}} = GameStream.attach_viewer(id, self())
      {:ok, %{viewer: false}} = GameStream.attach_viewer(id, other)
      {:ok, %{viewer_token: theirs}} = GameStream.take_over(id, other, 0)
      assert_receive {:game_stream, ^id, :moved}

      # The superseded holder's answer is refused and never broadcast.
      assert {:error, :moved} =
               GameStream.relay_to_host(id, "answer", %{"sdp" => "a"}, {self(), mine})

      refute_receive %Broadcast{event: "play_signal"}, 50

      # A stale token from the right pid (an older twin in the same page) too.
      assert {:error, :moved} = GameStream.relay_to_host(id, "ice", %{}, {other, theirs - 1})
      refute_receive %Broadcast{event: "play_signal"}, 50

      assert :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "b"}, {other, theirs})
      assert_receive %Broadcast{event: "play_signal", payload: %{data: %{"sdp" => "b"}}}
    end

    test "the host's offer goes to the holder only, not to every subscriber", ctx do
      id = ctx.session_id
      holder = viewer!()
      {:ok, _} = GameStream.attach_viewer(id, holder)

      :ok = offer_from_host(ctx.runtime.runtime_id, id)

      assert_receive {:viewer_got, ^holder,
                      {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0"}}}}

      # This process only subscribed to the topic: it is not handed the offer.
      refute_received {:game_stream, ^id, {:signal, _, _}}
    end

    test "a holder that dies frees the stream for the next window, reload included", ctx do
      id = ctx.session_id
      holder = viewer!()
      {:ok, %{viewer: true}} = GameStream.attach_viewer(id, holder)
      :ok = offer_from_host(ctx.runtime.runtime_id, id, %{"data" => %{"sdp" => "pending"}})

      # The reload: the old window's pid is gone. The next window is granted
      # the stream and handed the offer nobody answered.
      kill!(holder)

      assert {:ok, %{viewer: true, pending_offer: %{"sdp" => "pending"}}} =
               GameStream.attach_viewer(id, self())
    end

    test "attaching to an ended session moves nobody", ctx do
      id = ctx.session_id
      {:ok, %{viewer: true}} = GameStream.attach_viewer(id, self())
      {:ok, _} = GameStream.stop_session(id, "done")
      other = viewer!()

      assert {:ok, %{state: "ended", viewer: false, viewer_token: nil, peer_id: nil}} =
               GameStream.attach_viewer(id, other)

      refute_receive {:game_stream, ^id, :moved}, 50
    end

    test "Start again's window holds the new session from the start as P1", ctx do
      GameStream.stop_session(ctx.session_id)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})

      {:ok, %{session_id: id}} =
        start!(task, viewer: self(), viewer_info: %{user_id: ctx.user.id, name: "GS User"})

      other = viewer!()
      assert {:ok, %{viewer: false}} = GameStream.attach_viewer(id, other, :follow)

      assert {:ok, %{viewer: true, viewer_token: token, slots: %{0 => 0}}} =
               GameStream.attach_viewer(id, self())

      assert {:ok, %{slots: %{0 => %{name: "GS User"}}, spectators: 1, multi: false}} =
               GameStream.roster(id)

      assert :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "a"}, {self(), token})
    end

    test "a viewer going away leaves the session live", ctx do
      id = ctx.session_id
      :ok = GameStream.handle_host_status(ctx.runtime.runtime_id, frame(id, "live"))
      pid = spawn(fn -> :ok end)
      {:ok, _} = GameStream.attach_viewer(id, pid)
      Process.sleep(20)
      assert {:ok, %{state: "live"}} = GameStream.status(id)
    end
  end

  describe "peers, slots and spectators on a game_stream_multi host (01a0dbd6)" do
    setup ctx do
      runtime = host!(ctx.user, ["game_stream_host", "game_stream_multi"])
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      %{runtime: runtime, task: task}
    end

    test "watch never moves anyone: every peer gets its own peer_open and video", ctx do
      id = multi!(ctx)
      rid = ctx.runtime.runtime_id
      a = viewer!()
      b = viewer!()

      assert {:ok, %{viewer: true, role: :spectator, slots: slots, peer_id: pa}} =
               GameStream.attach_viewer(id, a)

      assert slots == %{}

      assert_receive %Broadcast{
        event: "play_peer_open",
        payload: %{session_id: ^id, peer_id: ^pa}
      }

      assert {:ok, %{viewer: true, role: :spectator, peer_id: pb}} =
               GameStream.attach_viewer(id, b)

      assert_receive %Broadcast{event: "play_peer_open", payload: %{peer_id: ^pb}}
      refute_receive {:viewer_got, ^a, {:game_stream, ^id, :moved}}, 50
      refute_received %Broadcast{event: "play_peer_close"}

      # Each peer's offer goes to that peer only.
      :ok = offer_from_host(rid, id, %{"peer_id" => pa, "data" => %{"sdp" => "for a"}})
      :ok = offer_from_host(rid, id, %{"peer_id" => pb, "data" => %{"sdp" => "for b"}})

      assert_receive {:viewer_got, ^a,
                      {:game_stream, ^id, {:signal, "offer", %{"sdp" => "for a"}}}}

      assert_receive {:viewer_got, ^b,
                      {:game_stream, ^id, {:signal, "offer", %{"sdp" => "for b"}}}}

      refute_receive {:viewer_got, ^a, {:game_stream, ^id, {:signal, _, %{"sdp" => "for b"}}}}, 50

      # An offer for no attached peer, or untagged, is refused.
      assert {:error, :unknown_peer} = offer_from_host(rid, id, %{"peer_id" => "nobody"})
      assert {:error, :unknown_peer} = offer_from_host(rid, id)

      assert_receive {:game_stream, ^id, {:roster, %{slots: %{}, spectators: 2}}}
    end

    test "a resume re-sends what the host missed while its socket was down", ctx do
      id = multi!(ctx)
      rid = ctx.runtime.runtime_id
      a = viewer!()
      b = viewer!()
      {:ok, %{peer_id: pa}} = GameStream.attach_viewer(id, a)
      {:ok, %{peer_id: pb}} = GameStream.attach_viewer(id, b)
      :ok = GameStream.handle_host_status(rid, frame(id, "live"))
      assert :ok = GameStream.host_disconnected(rid)

      # A joiner while the host is away: its play_peer_open goes nowhere.
      c = viewer!()
      {:ok, %{peer_id: pc}} = GameStream.attach_viewer(id, c)
      flush_host_frames()

      # The host still holds a, and a peer core already dropped.
      resume = %{"resume" => true, "peers" => [pa, "gone-peer"]}
      assert :ok = GameStream.handle_host_status(rid, frame(id, "live", resume))

      opened = collect_host("play_peer_open")
      assert Enum.sort(opened) == Enum.sort([pb, pc])
      assert_received %Broadcast{event: "play_peer_close", payload: %{peer_id: "gone-peer"}}
      refute_received %Broadcast{event: "play_peer_close", payload: %{peer_id: ^pa}}
      peers = last_slots(nil)
      assert Map.keys(peers) |> Enum.sort() == Enum.sort([pa, pb, pc])

      refute_receive {:game_stream, ^id, {:status, %{state: "failed"}}}, @grace_ms * 3
      assert {:ok, %{state: "live"}} = GameStream.status(id)
    end

    test "join takes the next free slot, idempotently per src, and snapshots play_slots", ctx do
      id = multi!(ctx)
      a = viewer!()
      b = viewer!()
      {:ok, %{peer_id: pa}} = GameStream.attach_viewer(id, a, :watch, %{name: "Ana"})
      {:ok, %{peer_id: pb}} = GameStream.attach_viewer(id, b, :watch, %{name: "Ben"})

      assert {:ok, %{role: :player, slots: %{0 => 0}}} = GameStream.join(id, a, 0)
      assert {:ok, %{slots: %{0 => 1}}} = GameStream.join(id, b, 0)
      # A second pad in b's browser is b's peer holding a second slot.
      assert {:ok, %{slots: %{0 => 1, 1 => 2}}} = GameStream.join(id, b, 1)
      assert {:ok, %{slots: %{0 => 1, 1 => 2}}} = GameStream.join(id, b, 1)

      assert_receive %Broadcast{
        event: "play_slots",
        payload: %{session_id: ^id, max_players: 4, peers: peers}
      }

      # The last snapshot is the whole table.
      peers = last_slots(peers)
      assert peers == %{pa => %{0 => 0}, pb => %{0 => 1, 1 => 2}}

      assert_receive {:game_stream, ^id,
                      {:roster,
                       %{
                         slots: %{0 => %{name: "Ana"}, 1 => %{name: "Ben"}, 2 => %{name: "Ben"}},
                         spectators: 0
                       }}}
    end

    test "join prefers a named FREE slot (an open chip) and never displaces for it (stage 4)",
         ctx do
      id = multi!(ctx)
      [a, b, c] = for _ <- 1..3, do: viewer!()
      for v <- [a, b, c], do: {:ok, _} = GameStream.attach_viewer(id, v)

      # a clicks the open P3 chip: it gets P3, not the lowest free P1.
      assert {:ok, %{slots: %{0 => 2}}} = GameStream.join(id, a, 0, 2)
      # b clicks the same chip a moment later: P3 is taken, so b gets the
      # next free slot and a keeps P3. A join never displaces.
      assert {:ok, %{slots: %{0 => 0}}} = GameStream.join(id, b, 0, 2)
      refute_receive {:viewer_got, ^a, {:game_stream, ^id, {:displaced, _, _}}}, 50
      # A preferred slot beyond max_players is ignored, not refused.
      assert {:ok, %{slots: %{0 => 1}}} = GameStream.join(id, c, 0, 9)

      assert {:ok, %{slots: %{0 => %{}, 1 => %{}, 2 => %{}}, multi: true}} =
               GameStream.roster(id)
    end

    test "slots_full when every slot is taken; leave frees a slot and keeps the peer", ctx do
      roster_default!(%{"open_as" => "watch", "max_players" => 2, "max_spectators" => 4})
      id = multi!(ctx)
      [a, b, c] = for _ <- 1..3, do: viewer!()
      for v <- [a, b, c], do: {:ok, _} = GameStream.attach_viewer(id, v)

      {:ok, _} = GameStream.join(id, a)
      {:ok, _} = GameStream.join(id, b)
      assert {:error, :slots_full} = GameStream.join(id, c)

      assert {:ok, %{role: :spectator, slots: slots, viewer: true}} = GameStream.leave(id, a)
      assert slots == %{}
      refute_received %Broadcast{event: "play_peer_close"}
      assert {:ok, %{slots: %{0 => 0}}} = GameStream.join(id, c)
      assert {:error, :not_attached} = GameStream.join(id, viewer!())
    end

    test "spectators_full caps peers without a slot, and a player is not a spectator", ctx do
      roster_default!(%{"open_as" => "watch", "max_players" => 1, "max_spectators" => 1})
      id = multi!(ctx)
      [a, b, c] = for _ <- 1..3, do: viewer!()

      {:ok, _} = GameStream.attach_viewer(id, a)
      flush_host_frames()
      assert {:error, :spectators_full} = GameStream.attach_viewer(id, b)
      refute_received %Broadcast{event: "play_peer_open"}

      # a joining frees a spectator place.
      {:ok, _} = GameStream.join(id, a)
      assert {:ok, %{role: :spectator}} = GameStream.attach_viewer(id, b)
      assert {:error, :spectators_full} = GameStream.attach_viewer(id, c)
      # A re-attach of an existing peer is never refused by the cap.
      assert {:ok, _} = GameStream.attach_viewer(id, b)
    end

    test "take_over moves the slot; the displaced peer keeps its peer and its video", ctx do
      id = multi!(ctx)
      rid = ctx.runtime.runtime_id
      a = viewer!()
      b = viewer!()

      {:ok, %{peer_id: pa, viewer_token: ta}} =
        GameStream.attach_viewer(id, a, :watch, %{name: "Ana"})

      {:ok, %{peer_id: pb}} = GameStream.attach_viewer(id, b, :watch, %{name: "Ben"})
      {:ok, %{slots: %{0 => 0}}} = GameStream.join(id, a)

      assert {:ok, %{slots: %{0 => 0}, role: :player}} = GameStream.take_over(id, b, 0)
      assert_receive {:viewer_got, ^a, {:game_stream, ^id, {:displaced, 0, "Ben"}}}
      refute_receive {:viewer_got, ^a, {:game_stream, ^id, :moved}}, 50
      refute_received %Broadcast{event: "play_peer_close"}

      # a is a spectator now, and its peer still has video: the host's offer
      # for it reaches it, and its answer still reaches the host.
      assert {:ok, %{slots: %{0 => %{peer_id: ^pb}}, spectators: 1}} = GameStream.roster(id)
      :ok = offer_from_host(rid, id, %{"peer_id" => pa, "data" => %{"sdp" => "still a"}})
      assert_receive {:viewer_got, ^a, {:game_stream, ^id, {:signal, "offer", _}}}
      assert :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "a"}, {a, ta, pa})
      assert_receive %Broadcast{event: "play_signal", payload: %{peer_id: ^pa}}

      assert {:error, :no_such_slot} = GameStream.take_over(id, b, 4)
    end

    test "a peer whose LiveView goes away frees its slots and is closed on the host", ctx do
      id = multi!(ctx)
      a = viewer!()
      {:ok, %{peer_id: pa}} = GameStream.attach_viewer(id, a)
      {:ok, _} = GameStream.join(id, a, 0)
      {:ok, _} = GameStream.join(id, a, 1)

      kill!(a)

      assert_receive %Broadcast{
        event: "play_peer_close",
        payload: %{session_id: ^id, peer_id: ^pa}
      }

      # The close is sent from the DOWN handler, so the roster is settled.
      assert {:ok, %{slots: slots, spectators: 0}} = GameStream.roster(id)
      assert slots == %{}
      assert_receive {:game_stream, ^id, {:roster, %{spectators: 0}}}
      {:ok, _} = GameStream.attach_viewer(id, self())
      assert {:ok, %{slots: %{0 => 0}}} = GameStream.join(id, self())
    end

    test "a same-pid re-attach sends play_peer_open for the SAME peer at once (stage 1's H3)",
         ctx do
      id = multi!(ctx)
      rid = ctx.runtime.runtime_id
      a = viewer!()
      {:ok, %{peer_id: pa, viewer_token: t1}} = GameStream.attach_viewer(id, a)
      assert_receive %Broadcast{event: "play_peer_open", payload: %{peer_id: ^pa}}
      :ok = offer_from_host(rid, id, %{"peer_id" => pa, "data" => %{"sdp" => "old pc"}})

      # A twin copy in the same page takes the stream back.
      assert {:ok, %{peer_id: ^pa, viewer_token: t2, pending_offer: nil}} =
               GameStream.attach_viewer(id, a)

      refute t2 == t1
      # Immediately, not after the host's peer timeout: the frame is already
      # on the host topic when attach returns.
      assert_received %Broadcast{
        event: "play_peer_open",
        payload: %{session_id: ^id, peer_id: ^pa}
      }

      # One peer per pid: no second peer was minted.
      assert {:ok, %{spectators: 1}} = GameStream.roster(id)

      # The older copy's token is retired.
      assert {:error, :moved} = GameStream.relay_to_host(id, "answer", %{}, {a, t1, pa})
      refute_receive %Broadcast{event: "play_signal"}, 50
      assert :ok = GameStream.relay_to_host(id, "answer", %{}, {a, t2, pa})
    end

    test "forged signals are refused :moved and NOTHING reaches the host", ctx do
      id = multi!(ctx)
      player = viewer!()
      spectator = viewer!()
      stranger = viewer!()

      {:ok, %{peer_id: pp, viewer_token: tp}} = GameStream.attach_viewer(id, player)
      {:ok, _} = GameStream.join(id, player)
      {:ok, %{peer_id: ps, viewer_token: ts}} = GameStream.attach_viewer(id, spectator)
      flush_host_frames()

      forged = [
        # the spectator's pid and token, naming the player's peer
        {spectator, ts, pp},
        # the player's peer and token, from the spectator's pid
        {spectator, tp, pp},
        # the player's own pid and peer with a stale token
        {player, tp - 1, pp},
        # the player's pid naming the spectator's peer
        {player, tp, ps},
        # a pid that owns no peer at all, with a real peer and token
        {stranger, tp, pp},
        {stranger, tp, nil}
      ]

      for viewer <- forged do
        assert {:error, :moved} =
                 GameStream.relay_to_host(id, "answer", %{"sdp" => "forged"}, viewer),
               "forged #{inspect(viewer)} was not refused"
      end

      refute_receive %Broadcast{event: "play_signal"}, 100

      # The owners themselves get through, each tagged with its own peer.
      assert :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "p"}, {player, tp, pp})

      assert_receive %Broadcast{
        event: "play_signal",
        payload: %{peer_id: ^pp, data: %{"sdp" => "p"}}
      }

      assert :ok = GameStream.relay_to_host(id, "ice", %{}, {spectator, ts, nil})
      assert_receive %Broadcast{event: "play_signal", payload: %{peer_id: ^ps, kind: "ice"}}
    end

    test "start_session(viewer:) joins the clicker as P1 and opens its peer after the start",
         ctx do
      {:ok, %{session_id: id}} =
        start!(ctx.task, viewer: self(), viewer_info: %{user_id: ctx.user.id, name: "GS User"})

      assert_receive %Broadcast{event: "play_session_start"}
      assert_receive %Broadcast{event: "play_peer_open", payload: %{peer_id: peer_id}}
      assert_receive %Broadcast{event: "play_slots", payload: %{peers: peers}}
      assert peers == %{peer_id => %{0 => 0}}

      assert {:ok, %{slots: %{0 => %{peer_id: ^peer_id, name: "GS User"}}}} =
               GameStream.roster(id)
    end

    test "open_as join (the data variant) joins a free slot on open; follow never does", ctx do
      roster_default!(%{"open_as" => "join", "max_players" => 1, "max_spectators" => 2})
      id = multi!(ctx)
      a = viewer!()
      b = viewer!()
      c = viewer!()

      assert {:ok, %{role: :spectator}} = GameStream.attach_viewer(id, c, :follow)
      assert {:ok, %{role: :player, slots: %{0 => 0}}} = GameStream.attach_viewer(id, a)
      # Slots full: the next open watches.
      assert {:ok, %{role: :spectator}} = GameStream.attach_viewer(id, b)
    end

    test "play_slot_activity from the host reaches every viewer's topic", ctx do
      id = multi!(ctx)
      rid = ctx.runtime.runtime_id

      assert :ok =
               GameStream.handle_slot_activity(rid, %{"session_id" => id, "slots" => [2, 0, 2]})

      assert_receive {:game_stream, ^id, {:slot_activity, [0, 2]}}

      other = host!(ctx.user)

      assert {:error, :not_host} =
               GameStream.handle_slot_activity(other.runtime_id, %{
                 "session_id" => id,
                 "slots" => [0]
               })

      assert {:error, :bad_slots} =
               GameStream.handle_slot_activity(rid, %{"session_id" => id, "slots" => ["x"]})
    end

    test "stats are kept per slot; the row carries slot_stats, the worst slot and the peaks",
         ctx do
      id = multi!(ctx)
      a = viewer!()
      b = viewer!()
      s = viewer!()
      for v <- [a, b, s], do: {:ok, _} = GameStream.attach_viewer(id, v)
      {:ok, _} = GameStream.join(id, a)
      {:ok, _} = GameStream.join(id, b)

      :ok =
        GameStream.report_stats(
          id,
          %{"rtt_p50_ms" => 30, "rtt_p95_ms" => 40, "fps_avg" => 60, "connection_path" => "lan"},
          a
        )

      :ok =
        GameStream.report_stats(
          id,
          %{"rtt_p50_ms" => 35, "rtt_p95_ms" => 70, "fps_avg" => 58, "connection_path" => "turn"},
          b
        )

      # A spectator has no input-to-photon: dropped. A slot hint the peer does
      # not hold is ignored.
      :ok = GameStream.report_stats(id, %{"rtt_p95_ms" => 999}, s)
      :ok = GameStream.report_stats(id, %{"rtt_p95_ms" => 45}, a, 1)

      {:ok, _} = GameStream.stop_session(id, "done")
      row = Repo.get!(SessionRecord, id)

      assert row.slot_stats == %{
               "0" => %{
                 "rtt_p50_ms" => 30.0,
                 "rtt_p95_ms" => 45.0,
                 "fps_avg" => 60.0,
                 "connection_path" => "lan"
               },
               "1" => %{
                 "rtt_p50_ms" => 35.0,
                 "rtt_p95_ms" => 70.0,
                 "fps_avg" => 58.0,
                 "connection_path" => "turn"
               }
             }

      assert {row.rtt_p50_ms, row.rtt_p95_ms, row.fps_avg, row.connection_path} ==
               {35.0, 70.0, 58.0, "turn"}

      assert row.peak_players == 2
      assert row.peak_spectators == 3
    end
  end

  defp multi!(ctx, opts \\ []) do
    {:ok, status} = start!(ctx.task, opts)
    assert status.multi
    assert_receive %Broadcast{event: "play_session_start"}
    :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(status.session_id))
    status.session_id
  end

  # The plan's control, typed as a literal (task 01a0fe45 stage 1), not read
  # back from the surface under test.
  @touch_control %{slop_px: 8, move_hz: 60, variant: nil}

  describe "the game_stream_touch capability gate (01a0fe45)" do
    setup ctx do
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      %{task: task}
    end

    # The touch map as each surface the browser reads carries it: the start
    # status, a later status, the attach reply's status and roster, and the
    # roster call. They must all agree.
    defp touch_maps(status) do
      id = status.session_id
      {:ok, later} = GameStream.status(id)
      {:ok, attached} = GameStream.attach_viewer(id, viewer!())
      {:ok, roster} = GameStream.roster(id)
      [status.touch, later.touch, attached.touch, attached.roster.touch, roster.touch]
    end

    test "a host declaring game_stream_touch gets touch enabled with the control tuning",
         ctx do
      host!(ctx.user, ["game_stream_host", "game_stream_touch"])
      {:ok, status} = start!(ctx.task)

      for touch <- touch_maps(status),
          do: assert(touch == Map.put(@touch_control, :enabled, true))
    end

    test "a touch host that is also multi is enabled too", ctx do
      host!(ctx.user, ["game_stream_host", "game_stream_multi", "game_stream_touch"])
      {:ok, status} = start!(ctx.task)
      assert status.multi
      for touch <- touch_maps(status), do: assert(touch.enabled == true)
    end

    test "a host with only game_stream_host, or with game_stream_multi, is NOT enabled",
         ctx do
      for features <- [["game_stream_host"], ["game_stream_host", "game_stream_multi"]] do
        task = task!(ctx.project, "in_review")
        heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
        runtime = host!(ctx.user, features)
        {:ok, status} = start!(task)
        assert status.host_runtime_id == runtime.runtime_id

        # Disabled, and the tuning is still reported so the arm stays visible.
        for touch <- touch_maps(status),
            do: assert(touch == Map.put(@touch_control, :enabled, false))

        # Gone before the next pass, so discovery cannot pick this host again.
        stop_all_sessions()
        RuntimePresence.untrack(runtime.runtime_id)
      end
    end

    test "nothing about touch is sent to the host: play_session_start is unchanged", ctx do
      host!(ctx.user, ["game_stream_host", "game_stream_touch"])
      {:ok, _status} = start!(ctx.task)
      assert_receive %Broadcast{event: "play_session_start", payload: payload}

      assert Map.keys(payload) |> Enum.sort() ==
               ~w(branch encoder ice_servers idle_timeout_s repo_url session_id sha task_id)a
    end

    test "a promoted game_stream.touch default replaces the control", ctx do
      Repo.insert!(
        Platform.Experiments.SurfaceDefault.changeset(%Platform.Experiments.SurfaceDefault{}, %{
          surface_key: "game_stream.touch",
          surface_target: "play_session.start",
          seq: 1,
          kind: "promote",
          payload: %{"slop_px" => 0, "move_hz" => 30}
        })
      )

      host!(ctx.user, ["game_stream_host", "game_stream_touch"])
      {:ok, status} = start!(ctx.task)

      for touch <- touch_maps(status),
          do: assert(touch == %{enabled: true, slop_px: 0, move_hz: 30, variant: nil})
    end
  end

  describe "touch_host?/1 (01a0fe45)" do
    test "true only when the declared features list game_stream_touch" do
      features = fn list -> %{metadata: %{"client_info" => %{"features" => list}}} end

      assert GameStream.touch_host?(features.(["game_stream_host", "game_stream_touch"]))
      refute GameStream.touch_host?(features.(["game_stream_host"]))
      refute GameStream.touch_host?(features.(["game_stream_host", "game_stream_multi"]))
      refute GameStream.touch_host?(features.([]))
    end

    # Host discovery refuses an undeclared host before start_session/2 asks,
    # so only a direct call reaches this arm.
    test "undeclared features fail closed" do
      refute GameStream.touch_host?(%{metadata: %{}})
      refute GameStream.touch_host?(%{metadata: %{"client_info" => %{}}})
      refute GameStream.touch_host?(%{metadata: %{"client_info" => %{"features" => "touch"}}})
      refute GameStream.touch_host?(%{metadata: nil})
    end
  end

  describe "summarize_stats/1" do
    test "one slot's figures are the row's figures exactly (identical to v1)" do
      one = %{0 => %{rtt_p50_ms: 31.0, rtt_p95_ms: 48.5, fps_avg: 59.9, connection_path: "lan"}}

      assert %{rtt_p50_ms: 31.0, rtt_p95_ms: 48.5, fps_avg: 59.9, connection_path: "lan"} =
               Platform.GameStream.Session.summarize_stats(one)
    end

    test "no stats is all nil and an empty map" do
      assert %{slot_stats: %{}, rtt_p50_ms: nil, rtt_p95_ms: nil} =
               Platform.GameStream.Session.summarize_stats(%{})
    end
  end

  # Drains the host-topic frames a setup produced, so a case can refute on
  # what follows.
  defp flush_host_frames do
    receive do
      %Broadcast{} -> flush_host_frames()
    after
      0 -> :ok
    end
  end

  # The peer_ids of every host-topic frame named `event` in the mailbox,
  # oldest first. Other frames stay in the mailbox.
  defp collect_host(event, acc \\ []) do
    receive do
      %Broadcast{event: ^event, payload: %{peer_id: peer_id}} ->
        collect_host(event, [peer_id | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  # The last play_slots snapshot in the mailbox (or `first` if there is none).
  defp last_slots(first) do
    receive do
      %Broadcast{event: "play_slots", payload: %{peers: peers}} -> last_slots(peers)
    after
      20 -> first
    end
  end
end
