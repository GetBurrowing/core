defmodule PlatformWeb.GameStreamHooksTest do
  @moduledoc """
  `PlatformWeb.GameStreamHooks` (task 01a0db5f stage 4), driven through the
  real `/canvases/:id` LiveView the way the `GameStream` JS hook drives it:
  `render_hook/3` pushes the event, `assert_reply/2` reads the answer, and
  what reaches the play host is observed on its `runtime:<id>` topic.

  NOT async: cases toggle `:platform, :game_stream_enabled` and
  `:branch_provisioner` (global app env) and track runtimes in the global
  `RuntimePresence` map.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 2]
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Phoenix.Socket.Broadcast
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.GameStream
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule StubRunner do
    @moduledoc false
    # Called from the LiveView process (restart), so it cannot read the test
    # process's dictionary: every branch has the same tip.
    def branch_head_sha(_args), do: {:ok, "0123456789abcdef0123456789abcdef01234567"}
  end

  setup do
    previous = Application.get_env(:platform, :game_stream_enabled)
    previous_bp = Application.get_env(:platform, :branch_provisioner)
    Application.put_env(:platform, :game_stream_enabled, true)
    Application.put_env(:platform, :branch_provisioner, runner: StubRunner)

    on_exit(fn ->
      sup = Platform.GameStream.Supervisor.sessions()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end

      restore(:game_stream_enabled, previous)
      restore(:branch_provisioner, previous_bp)
    end)

    org = Tenancy.get_org_by_slug!("sxi")
    space = channel!(%{org_id: org.id, name: "Review builds"})
    user = create_user!(%{name: "Rowan"})
    add_user!(space.id, user.id)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Voltron #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/rowanellis/voltron"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Dash tuning"})
    task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()

    %{org: org, space: space, user: user, task: task}
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp host!(user, features \\ ["game_stream_host"]) do
    runtime_id = "play-host-#{System.unique_integer([:positive])}"

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

  defp session!(task) do
    {:ok, status} = GameStream.start_session(task.id, linger_ms: 50)
    status
  end

  defp canvas!(space, session_id, task_id) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Review build",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "game-stream",
                "type" => "game_stream",
                "props" => %{
                  "session_id" => session_id,
                  "task_id" => task_id,
                  "review_sha" => @sha,
                  "branch" => "task/" <> task_id,
                  "title" => "Review build"
                }
              }
            ]
          },
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  defp ids(canvas, session_id),
    do: %{"session_id" => session_id, "canvas_id" => canvas.id, "node_id" => "game-stream"}

  defp signal(view, session_id, sdp, token) do
    render_hook(view, "game_stream_signal", %{
      "session_id" => session_id,
      "kind" => "answer",
      "data" => %{"type" => "answer", "sdp" => sdp},
      "viewer_token" => token
    })
  end

  defp open(conn, user, canvas) do
    {:ok, view, html} = live(login(conn, user.id), ~p"/canvases/#{canvas.id}")
    {view, html}
  end

  defp session_pid(session_id) do
    [{pid, _}] =
      Registry.lookup(Platform.GameStream.Supervisor.registry(), {:session, session_id})

    pid
  end

  describe "the canvas page renders the hook" do
    test "a game_stream node mounts the GameStream hook with its ids", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {_view, html} = open(ctx.conn, ctx.user, canvas)

      assert html =~ ~s(phx-hook="GameStream")
      assert html =~ ~s(data-session-id="#{s.session_id}")
      assert html =~ ~s(data-canvas-id="#{canvas.id}")
      assert html =~ "on the play host…"
    end
  end

  describe "attach, signal, end" do
    test "attach answers with status and ice servers, and relays the host's offer", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)

      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))

      assert_reply(view, %{
        ok: true,
        status: %{state: "building", review_sha: @sha},
        ice_servers: [],
        pending_offer: nil,
        viewer: true,
        viewer_token: token
      })

      assert :ok =
               GameStream.relay_to_viewer(s.host_runtime_id, %{
                 "session_id" => s.session_id,
                 "kind" => "offer",
                 "data" => %{"type" => "offer", "sdp" => "v=0 offer"}
               })

      assert_push_event(view, "game_stream", %{
        type: "signal",
        kind: "offer",
        data: %{"sdp" => "v=0 offer"}
      })

      render_hook(view, "game_stream_signal", %{
        "session_id" => s.session_id,
        "kind" => "answer",
        "data" => %{"type" => "answer", "sdp" => "v=0 answer"},
        "viewer_token" => token
      })

      assert_reply(view, %{ok: true})
      id = s.session_id

      assert_receive %Broadcast{
        event: "play_signal",
        payload: %{session_id: ^id, kind: "answer", data: %{"sdp" => "v=0 answer"}}
      }
    end

    test "force_relay reaches the attach reply as ice_transport_policy relay (stage 5)", ctx do
      previous = Application.get_env(:platform, :game_stream_turn)
      on_exit(fn -> restore(:game_stream_turn, previous) end)
      turn = %{urls: ["turn:turn.example:3479"], username: "game_stream", credential: "c"}
      Application.put_env(:platform, :game_stream_turn, Map.to_list(turn))

      host!(ctx.user)
      {:ok, relay} = GameStream.start_session(ctx.task.id, linger_ms: 50, force_relay: true)
      canvas = canvas!(ctx.space, relay.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)

      render_hook(view, "game_stream_attach", ids(canvas, relay.session_id))
      assert_reply(view, %{ok: true, ice_servers: [^turn], ice_transport_policy: "relay"})

      # The same window on a session started without it is "all".
      GameStream.stop_session(relay.session_id)
      {:ok, plain} = GameStream.start_session(ctx.task.id, linger_ms: 50)
      canvas = canvas!(ctx.space, plain.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)

      render_hook(view, "game_stream_attach", ids(canvas, plain.session_id))
      assert_reply(view, %{ok: true, ice_transport_policy: "all"})
    end

    test "a window that attaches after the offer went out gets it as pending_offer", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      offer = %{"type" => "offer", "sdp" => "v=0 early"}

      :ok =
        GameStream.relay_to_viewer(s.host_runtime_id, %{
          "session_id" => s.session_id,
          "kind" => "offer",
          "data" => offer
        })

      {view, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(view, %{ok: true, pending_offer: ^offer, viewer_token: token})

      # Answered, the offer belongs to that window's peer: a later window
      # must not be handed it again.
      render_hook(view, "game_stream_signal", %{
        "session_id" => s.session_id,
        "kind" => "answer",
        "data" => %{"type" => "answer", "sdp" => "a"},
        "viewer_token" => token
      })

      assert_reply(view, %{ok: true})
      {view2, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(view2, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(view2, %{ok: true, pending_offer: nil, viewer: false, peer_id: peer2})
      assert is_binary(peer2)

      # Opening a second window WATCHES (task 01a0dbd6): the first window is
      # not moved.
      refute_push_event(view, "game_stream", %{type: "moved"}, 100)

      # "Play here" in the second window is a take-over of P1; the first
      # window is told who took it, and (a v1 host has one peer) moved.
      render_hook(view2, "game_stream_take_over", Map.put(ids(canvas, s.session_id), "slot", 0))
      assert_reply(view2, %{ok: true, viewer: true, slots: %{0 => 0}, peer_id: ^peer2})
      assert_push_event(view, "game_stream", %{type: "displaced", slot: 0, by: "Rowan"})
      assert_push_event(view, "game_stream", %{type: "moved"})
      render_hook(view2, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(view2, %{ok: true, viewer: true})

      # From then on only the window that took over hears the host: two
      # answers to one offer would leave the host's peer half-connected.
      :ok =
        GameStream.relay_to_viewer(s.host_runtime_id, %{
          "session_id" => s.session_id,
          "kind" => "offer",
          "data" => %{"type" => "offer", "sdp" => "v=0 second"}
        })

      assert_push_event(view2, "game_stream", %{type: "signal", data: %{"sdp" => "v=0 second"}})
      refute_push_event(view, "game_stream", %{type: "signal"}, 100)

      # "Play here" in the first window takes it back and re-attaches, which
      # subscribes it again and hands it the offer nobody answered.
      render_hook(view, "game_stream_take_over", Map.put(ids(canvas, s.session_id), "slot", 0))
      assert_reply(view, %{ok: true, viewer: true})
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(view, %{ok: true, pending_offer: %{"sdp" => "v=0 second"}})
      assert_push_event(view2, "game_stream", %{type: "moved"})
    end

    test "status changes reach the window as pushes", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))

      :ok =
        GameStream.handle_host_status(s.host_runtime_id, %{
          "session_id" => s.session_id,
          "state" => "live",
          "elapsed_ms" => 100
        })

      assert_push_event(view, "game_stream", %{type: "status", status: %{state: "live"}})
    end

    test "End stops the session and names who ended it; stats are recorded", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))

      render_hook(view, "game_stream_stats", %{
        "session_id" => s.session_id,
        "stats" => %{"rtt_p50_ms" => 39.0, "fps_avg" => 60, "connection_path" => "lan"}
      })

      assert_reply(view, %{ok: true})

      render_hook(view, "game_stream_end", %{"session_id" => s.session_id})
      assert_reply(view, %{ok: true, status: %{state: "ended", ended_reason: "Ended by Rowan"}})
      assert_receive %Broadcast{event: "play_session_stop", payload: %{reason: "Ended by Rowan"}}

      row = Repo.get!(Platform.GameStream.SessionRecord, s.session_id)
      assert row.rtt_p50_ms == 39.0
      assert row.connection_path == "lan"
    end

    test "Start again starts a new session and patches the node to name it", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))
      {:ok, _} = GameStream.stop_session(s.session_id, "Stopped")

      render_hook(view, "game_stream_restart", ids(canvas, s.session_id))
      assert_reply(view, %{ok: true, session_id: new_id, status: %{state: "building"}})
      refute new_id == s.session_id

      {:ok, %{document: doc}} = Platform.Chat.Canvas.Server.describe(canvas.id)
      [node] = doc["root"]["children"]
      assert node["props"]["session_id"] == new_id
      assert node["props"]["review_sha"] == @sha

      # The new session is granted on this socket.
      render_hook(view, "game_stream_stats", %{"session_id" => new_id, "stats" => %{}})
      assert_reply(view, %{ok: true})
    end
  end

  describe "which window plays (stage 6)" do
    test "a superseded window's answer is refused and never reaches the host", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      id = s.session_id
      canvas = canvas!(ctx.space, id, ctx.task.id)
      {x, _} = open(ctx.conn, ctx.user, canvas)
      {y, _} = open(ctx.conn, ctx.user, canvas)

      # The replies are bound whole, not matched on the stage 6 keys, so this
      # test fails on the stage 5 code (6f8b32ff) at the ANSWER below, which
      # is the defect, rather than at a missing reply key.
      render_hook(x, "game_stream_attach", ids(canvas, id))
      assert_reply(x, %{ok: true} = x_reply)
      render_hook(y, "game_stream_attach", ids(canvas, id))
      assert_reply(y, %{ok: true, viewer: false})
      render_hook(y, "game_stream_take_over", ids(canvas, id))
      assert_reply(y, %{ok: true} = y_reply)
      assert_push_event(x, "game_stream", %{type: "moved"})
      x_token = x_reply[:viewer_token]
      y_token = y_reply[:viewer_token]

      # X answers anyway (its answer was already in flight): refused, and
      # nothing reaches the host, so the host never sees two answers.
      signal(x, id, "from x", x_token)
      assert_reply(x, %{ok: false, error: "moved"})
      refute_receive %Broadcast{event: "play_signal"}, 100

      signal(y, id, "from y", y_token)
      assert_reply(y, %{ok: true})

      assert_receive %Broadcast{
        event: "play_signal",
        payload: %{session_id: ^id, kind: "answer", data: %{"sdp" => "from y"}}
      }
    end

    test "Start again: the clicking window keeps the stream when another window re-renders onto it",
         ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {y, _} = open(ctx.conn, ctx.user, canvas)
      {x, _} = open(ctx.conn, ctx.user, canvas)
      old_id = s.session_id
      render_hook(y, "game_stream_attach", ids(canvas, old_id))
      assert_reply(y, %{ok: true, status: %{session_id: ^old_id}})
      render_hook(x, "game_stream_attach", ids(canvas, old_id))
      assert_reply(x, %{ok: true, status: %{session_id: ^old_id}})
      # X pressed Play here, so it held the old session.
      render_hook(x, "game_stream_take_over", ids(canvas, old_id))
      assert_reply(x, %{ok: true, viewer: true})
      assert_push_event(y, "game_stream", %{type: "moved", session_id: ^old_id})
      {:ok, _} = GameStream.stop_session(old_id, "Stopped")

      # Y clicks Start again, then attaches to the new session.
      render_hook(y, "game_stream_restart", ids(canvas, s.session_id))
      assert_reply(y, %{ok: true, session_id: new_id})

      # X's node was re-rendered onto the new session and attaches first, as
      # a follower (the order the review observed): it does not take it.
      render_hook(x, "game_stream_attach", Map.put(ids(canvas, new_id), "mode", "follow"))
      assert_reply(x, %{ok: true, viewer: false, viewer_token: nil, pending_offer: nil})

      render_hook(y, "game_stream_attach", ids(canvas, new_id))
      assert_reply(y, %{ok: true, viewer: true, viewer_token: y_token})
      refute_push_event(y, "game_stream", %{type: "moved", session_id: ^new_id}, 50)

      # The host's offer goes to Y only.
      :ok =
        GameStream.relay_to_viewer(s.host_runtime_id, %{
          "session_id" => new_id,
          "kind" => "offer",
          "data" => %{"type" => "offer", "sdp" => "v=0 new"}
        })

      assert_push_event(y, "game_stream", %{type: "signal", data: %{"sdp" => "v=0 new"}})
      refute_push_event(x, "game_stream", %{type: "signal"}, 100)

      # Were X to answer anyway, only Y's answer would reach the host.
      signal(x, new_id, "from x", nil)
      assert_reply(x, %{ok: false, error: "moved"})
      signal(y, new_id, "from y", y_token)
      assert_reply(y, %{ok: true})
      assert_receive %Broadcast{event: "play_signal", payload: %{data: %{"sdp" => "from y"}}}
      refute_receive %Broadcast{event: "play_signal"}, 100

      # An open in X does not take it (watch), "Play here" does.
      render_hook(x, "game_stream_attach", ids(canvas, new_id))
      assert_reply(x, %{ok: true, viewer: false})
      render_hook(x, "game_stream_take_over", ids(canvas, new_id))
      assert_reply(x, %{ok: true, viewer: true})
      assert_push_event(y, "game_stream", %{type: "moved"})
    end

    test "an attach right after Start again is granted while the canvas row still names the old session",
         ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {y, _} = open(ctx.conn, ctx.user, canvas)
      {x, _} = open(ctx.conn, ctx.user, canvas)
      render_hook(y, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(y, %{ok: true})
      {:ok, _} = GameStream.stop_session(s.session_id, "Stopped")

      stale_document = Repo.get!(Platform.Chat.Canvas, canvas.id).document
      render_hook(y, "game_stream_restart", ids(canvas, s.session_id))
      assert_reply(y, %{ok: true, session_id: new_id})

      # The restart's patch is persisted asynchronously in production; put
      # the row back to what it held before, as a window attaching in that
      # gap reads it. The live Canvas.Server document already names new_id.
      Platform.Chat.Canvas
      |> where(id: ^canvas.id)
      |> Repo.update_all(set: [document: stale_document])

      render_hook(x, "game_stream_attach", Map.put(ids(canvas, new_id), "mode", "follow"))
      assert_reply(x, %{ok: true, viewer: false})

      # A session the node never named is still refused.
      render_hook(x, "game_stream_attach", ids(canvas, Ecto.UUID.generate()))
      assert_reply(x, %{ok: false, error: "forbidden"})
    end
  end

  describe "peers and slots on a game_stream_multi host (01a0dbd6)" do
    setup ctx do
      host!(ctx.user, ["game_stream_host", "game_stream_multi"])
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      %{s: s, canvas: canvas}
    end

    test "two windows both watch with video; join, take over and leave are explicit", ctx do
      id = ctx.s.session_id
      ids = ids(ctx.canvas, id)
      other = create_user!(%{name: "Saru"})
      add_user!(ctx.space.id, other.id)
      {a, _} = open(ctx.conn, ctx.user, ctx.canvas)
      {b, _} = open(build_conn(), other, ctx.canvas)

      render_hook(a, "game_stream_attach", ids)
      assert_reply(a, %{ok: true, viewer: true, role: :spectator, peer_id: pa, viewer_token: ta})
      render_hook(b, "game_stream_attach", ids)
      assert_reply(b, %{ok: true, viewer: true, role: :spectator, peer_id: pb})
      refute pa == pb
      assert_receive %Broadcast{event: "play_peer_open", payload: %{peer_id: ^pa}}
      assert_receive %Broadcast{event: "play_peer_open", payload: %{peer_id: ^pb}}
      refute_push_event(a, "game_stream", %{type: "moved"}, 50)

      render_hook(a, "game_stream_join", Map.put(ids, "src", 0))
      assert_reply(a, %{ok: true, role: :player, slots: %{0 => 0}})

      assert_push_event(b, "game_stream", %{
        type: "roster",
        roster: %{slots: %{0 => %{name: "Rowan"}}}
      })

      render_hook(b, "game_stream_take_over", Map.merge(ids, %{"slot" => 0, "src" => 0}))
      assert_reply(b, %{ok: true, slots: %{0 => 0}})
      assert_push_event(a, "game_stream", %{type: "displaced", slot: 0, by: "Saru"})
      # The displaced window keeps its video: it is never moved.
      refute_push_event(a, "game_stream", %{type: "moved"}, 50)

      # A's signal for its own peer still reaches the host, tagged.
      render_hook(a, "game_stream_signal", %{
        "session_id" => id,
        "kind" => "answer",
        "data" => %{"sdp" => "from a"},
        "viewer_token" => ta,
        "peer_id" => pa
      })

      assert_reply(a, %{ok: true})
      assert_receive %Broadcast{event: "play_signal", payload: %{peer_id: ^pa}}

      # A's LiveView naming B's peer is refused, and nothing is broadcast.
      render_hook(a, "game_stream_signal", %{
        "session_id" => id,
        "kind" => "answer",
        "data" => %{"sdp" => "forged"},
        "viewer_token" => ta,
        "peer_id" => pb
      })

      assert_reply(a, %{ok: false, error: "moved"})
      refute_receive %Broadcast{event: "play_signal"}, 100

      render_hook(b, "game_stream_leave", ids)
      assert_reply(b, %{ok: true, role: :spectator})
      render_hook(b, "game_stream_join", Map.put(ids, "src", "not a number"))
      assert_reply(b, %{ok: false, error: "malformed"})

      # An open chip names the slot it asks for (stage 4); a junk slot is malformed.
      render_hook(b, "game_stream_join", Map.merge(ids, %{"src" => 0, "slot" => 3}))
      assert_reply(b, %{ok: true, role: :player, slots: %{0 => 3}})

      assert_push_event(a, "game_stream", %{
        type: "roster",
        roster: %{slots: %{3 => %{name: "Saru"}}, multi: true}
      })

      render_hook(a, "game_stream_join", Map.merge(ids, %{"src" => 0, "slot" => "P2"}))
      assert_reply(a, %{ok: false, error: "malformed"})
    end

    test "slot activity from the host is pushed to every window", ctx do
      id = ctx.s.session_id
      {a, _} = open(ctx.conn, ctx.user, ctx.canvas)
      render_hook(a, "game_stream_attach", ids(ctx.canvas, id))
      assert_reply(a, %{ok: true})

      :ok =
        GameStream.handle_slot_activity(ctx.s.host_runtime_id, %{
          "session_id" => id,
          "slots" => [1]
        })

      assert_push_event(a, "game_stream", %{type: "slot_activity", slots: [1]})
    end
  end

  describe "refusals" do
    test "an event carrying a foreign session_id is refused and reaches no host", ctx do
      host!(ctx.user)
      mine = session!(ctx.task)
      canvas = canvas!(ctx.space, mine.session_id, ctx.task.id)

      # A second host with a session this viewer's canvas does not carry.
      other_host = host!(ctx.user)
      {:ok, other_task} = Tasks.create_task(%{project_id: ctx.task.project_id, title: "Other"})
      other_task = other_task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()
      foreign = session!(other_task)
      assert foreign.host_runtime_id == other_host.runtime_id

      {view, _} = open(ctx.conn, ctx.user, canvas)

      render_hook(view, "game_stream_attach", ids(canvas, foreign.session_id))
      assert_reply(view, %{ok: false, error: "forbidden"})

      for event <- ~w(game_stream_signal game_stream_stats game_stream_end) do
        render_hook(view, event, %{
          "session_id" => foreign.session_id,
          "kind" => "answer",
          "data" => %{"sdp" => "x"},
          "stats" => %{}
        })

        assert_reply(view, %{ok: false, error: "forbidden"})
      end

      render_hook(view, "game_stream_restart", ids(canvas, foreign.session_id))
      assert_reply(view, %{ok: false, error: "forbidden"})

      # The slot events run the full canvas grant check too (01a0dbd6).
      for event <- ~w(game_stream_join game_stream_leave game_stream_take_over) do
        render_hook(view, event, ids(canvas, foreign.session_id))
        assert_reply(view, %{ok: false, error: "forbidden"})
      end

      refute_receive %Broadcast{event: "play_signal"}, 100
      refute_receive %Broadcast{event: "play_session_stop"}
      assert {:ok, %{state: "building"}} = GameStream.status(foreign.session_id)
      assert :sys.get_state(session_pid(foreign.session_id)).peers == %{}
    end

    test "the right session_id on a canvas the viewer cannot read is refused", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)

      # The outsider can read a canvas elsewhere (to get a live page) but not
      # the one that carries the session.
      outsider = create_user!()
      other_space = channel!(%{org_id: ctx.org.id, name: "Elsewhere"})
      add_user!(other_space.id, outsider.id)
      readable = canvas!(other_space, Ecto.UUID.generate(), ctx.task.id)

      assert {:error, :forbidden} =
               Platform.Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:user, outsider.id})

      {view, _} = open(ctx.conn, outsider, readable)
      render_hook(view, "game_stream_attach", ids(canvas, s.session_id))
      assert_reply(view, %{ok: false, error: "forbidden"})
      assert :sys.get_state(session_pid(s.session_id)).peers == %{}
    end

    test "the session_id must be on the NAMED node of the canvas", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)

      render_hook(
        view,
        "game_stream_attach",
        Map.put(ids(canvas, s.session_id), "node_id", "root")
      )

      assert_reply(view, %{ok: false, error: "forbidden"})
    end
  end

  describe "inert with the flag off" do
    test "every event is refused as disabled and nothing is subscribed or relayed", ctx do
      host!(ctx.user)
      s = session!(ctx.task)
      canvas = canvas!(ctx.space, s.session_id, ctx.task.id)
      {view, _} = open(ctx.conn, ctx.user, canvas)

      Application.delete_env(:platform, :game_stream_enabled)

      for event <- PlatformWeb.GameStreamHooks.events() do
        render_hook(view, event, Map.merge(ids(canvas, s.session_id), %{"kind" => "answer"}))
        assert_reply(view, %{ok: false, error: "disabled"})
      end

      # The session was never attached and the window never subscribed: a
      # status published on the topic produces no push.
      assert :sys.get_state(session_pid(s.session_id)).peers == %{}

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        GameStream.topic(s.session_id),
        {:game_stream, s.session_id, {:status, %{state: "live"}}}
      )

      refute_push_event(view, "game_stream", %{}, 100)
      refute_receive %Broadcast{event: "play_signal"}
      refute_receive %Broadcast{event: "play_session_stop"}
      assert Platform.Chat.get_canvas(canvas.id).document == canvas.document
    end

    test "other events and messages pass through", _ctx do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert {:cont, ^socket} =
               PlatformWeb.GameStreamHooks.handle_event("canvas_open", %{}, socket)

      assert {:cont, ^socket} = PlatformWeb.GameStreamHooks.handle_info(:tick, socket)
    end
  end
end
