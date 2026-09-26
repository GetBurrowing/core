defmodule Platform.GameStreamTest do
  @moduledoc """
  `Platform.GameStream` — review-build resolution, host discovery, one
  session per host, status transitions, host disconnect and viewer takeover
  (task 01a0db5f stage 2).

  NOT async: cases toggle `:platform, :game_stream_enabled` (global app env)
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

  setup do
    previous = Application.get_env(:platform, :game_stream_enabled)
    Application.put_env(:platform, :game_stream_enabled, true)

    on_exit(fn ->
      stop_all_sessions()

      if is_nil(previous),
        do: Application.delete_env(:platform, :game_stream_enabled),
        else: Application.put_env(:platform, :game_stream_enabled, previous)
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
      Application.delete_env(:platform, :game_stream_enabled)
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
      Application.put_env(:platform, :game_stream_enabled, "true")
      refute GameStream.enabled?()
      Application.put_env(:platform, :game_stream_enabled, true)
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

    test "a host disconnect fails the session with 'The play host disconnected'", ctx do
      id = ctx.session_id
      assert :ok = GameStream.host_disconnected(ctx.runtime.runtime_id)

      assert_receive {:game_stream, ^id,
                      {:status, %{state: "failed", detail: "The play host disconnected"}}}

      assert %SessionRecord{ended_state: "failed"} = Repo.get!(SessionRecord, id)
    end

    test "an ended session lingers, then is not_found", ctx do
      id = ctx.session_id
      {:ok, _} = GameStream.stop_session(id)
      assert {:ok, _} = GameStream.status(id)
      Process.sleep(150)
      assert {:error, :not_found} = GameStream.status(id)
    end
  end

  describe "signalling and viewers" do
    setup ctx do
      runtime = host!(ctx.user)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      {:ok, status} = start!(task)
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, GameStream.topic(status.session_id))
      %{runtime: runtime, session_id: status.session_id}
    end

    test "the host's offer reaches the viewer; the viewer's answer reaches the host", ctx do
      id = ctx.session_id
      rid = ctx.runtime.runtime_id
      {:ok, %{viewer: true, viewer_token: token}} = GameStream.attach_viewer(id, self())

      assert :ok =
               GameStream.relay_to_viewer(rid, %{
                 "session_id" => id,
                 "kind" => "offer",
                 "data" => %{"sdp" => "v=0"}
               })

      assert_receive {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0"}}}

      assert :ok =
               GameStream.relay_to_host(id, "answer", %{"sdp" => "v=0 answer"}, {self(), token})

      assert_receive %Broadcast{
        event: "play_signal",
        payload: %{session_id: ^id, kind: "answer", data: %{"sdp" => "v=0 answer"}}
      }
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

    test "the latest viewer takes over; the previous one is told :moved", ctx do
      id = ctx.session_id
      parent = self()

      viewer = fn ->
        spawn(fn ->
          receive do
            msg -> send(parent, {:viewer_got, self(), msg})
          end
        end)
      end

      a = viewer.()
      b = viewer.()

      assert {:ok, %{state: "building"}} = GameStream.attach_viewer(id, a)
      assert {:ok, _} = GameStream.attach_viewer(id, b)

      assert_receive {:viewer_got, ^a, {:game_stream, ^id, :moved}}
      refute_received {:viewer_got, ^b, _}
    end

    test "only the CURRENT viewer's signals reach the host (stage 6)", ctx do
      id = ctx.session_id
      parent = self()

      other =
        spawn(fn ->
          receive do
            msg -> send(parent, {:other_got, msg})
          end
        end)

      {:ok, %{viewer_token: mine}} = GameStream.attach_viewer(id, self())
      {:ok, %{viewer_token: theirs}} = GameStream.attach_viewer(id, other)
      assert_receive {:game_stream, ^id, :moved}

      # The superseded viewer's answer is refused and never broadcast.
      assert {:error, :moved} =
               GameStream.relay_to_host(id, "answer", %{"sdp" => "a"}, {self(), mine})

      refute_receive %Broadcast{event: "play_signal"}, 50

      # A stale token from the right pid (an older twin in the same page) too.
      assert {:error, :moved} = GameStream.relay_to_host(id, "ice", %{}, {other, theirs - 1})
      refute_receive %Broadcast{event: "play_signal"}, 50

      assert :ok = GameStream.relay_to_host(id, "answer", %{"sdp" => "b"}, {other, theirs})
      assert_receive %Broadcast{event: "play_signal", payload: %{data: %{"sdp" => "b"}}}
    end

    test "the host's offer goes to the viewer only, not to every subscriber", ctx do
      id = ctx.session_id
      parent = self()

      viewer =
        spawn(fn ->
          receive do
            msg -> send(parent, {:viewer_got, msg})
          end
        end)

      {:ok, _} = GameStream.attach_viewer(id, viewer)

      :ok =
        GameStream.relay_to_viewer(ctx.runtime.runtime_id, %{
          "session_id" => id,
          "kind" => "offer",
          "data" => %{"sdp" => "v=0"}
        })

      assert_receive {:viewer_got, {:game_stream, ^id, {:signal, "offer", %{"sdp" => "v=0"}}}}
      # This process only subscribed to the topic: it is not handed the offer.
      refute_received {:game_stream, ^id, {:signal, _, _}}
    end

    test "a follower does not take a session someone holds; it takes a free one", ctx do
      id = ctx.session_id
      holder = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, %{viewer: true}} = GameStream.attach_viewer(id, holder)

      assert {:ok, %{viewer: false, viewer_token: nil, pending_offer: nil}} =
               GameStream.attach_viewer(id, self(), :follow)

      refute_received {:game_stream, ^id, :moved}

      # Once the holder is gone, a follower is granted the session.
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert {:ok, %{viewer: true, viewer_token: token}} =
               GameStream.attach_viewer(id, self(), :follow)

      assert is_integer(token)

      # A take from another window then moves this one.
      taker = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(taker, :kill) end)
      assert {:ok, %{viewer: true}} = GameStream.attach_viewer(id, taker, :take)
      assert_receive {:game_stream, ^id, :moved}
    end

    test "attaching to an ended session moves nobody", ctx do
      id = ctx.session_id
      {:ok, %{viewer: true}} = GameStream.attach_viewer(id, self())
      {:ok, _} = GameStream.stop_session(id, "done")
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      assert {:ok, %{state: "ended", viewer: false, viewer_token: nil}} =
               GameStream.attach_viewer(id, other, :take)

      refute_receive {:game_stream, ^id, :moved}, 50
    end

    test "Start again's window holds the new session from the start", ctx do
      GameStream.stop_session(ctx.session_id)
      task = task!(ctx.project, "in_review")
      heads!(%{{"rowanellis/voltron", branch(task)} => @sha})
      {:ok, %{session_id: id}} = start!(task, viewer: self())

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)
      assert {:ok, %{viewer: false}} = GameStream.attach_viewer(id, other, :follow)
      assert {:ok, %{viewer: true, viewer_token: token}} = GameStream.attach_viewer(id, self())
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
end
