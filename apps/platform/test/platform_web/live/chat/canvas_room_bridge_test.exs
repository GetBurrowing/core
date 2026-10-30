defmodule PlatformWeb.ChatLive.CanvasRoomBridgeTest do
  @moduledoc """
  The LiveView side of the canvas-room bridge (task 01a1316b-84fa stage 2):
  `CanvasHooks`' `canvas_room_*` events and the room's PubSub messages, driven
  through two real `ChatLive` sessions on one prototype canvas.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.CanvasRoom
  alias Platform.Chat.CanvasRoom.{Event, Record}
  alias Platform.Repo

  @node "proto"

  setup do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Rooms #{n}", slug: "rooms-#{n}", kind: "channel"})

    alice = insert_user!("Alice")
    bob = insert_user!("Bob")
    alice_p = participant!(space, alice)
    _bob_p = participant!(space, bob)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => alice_p.id,
        "title" => "Counter",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => @node,
                "type" => "prototype",
                "props" => %{"prototype_id" => Ecto.UUID.generate()}
              },
              %{"id" => "words", "type" => "text", "props" => %{"value" => "hi"}}
            ]
          }
        }
      })

    on_exit(fn -> CanvasRoom.stop(canvas.id, @node) end)

    %{space: space, canvas: canvas, alice: alice, bob: bob}
  end

  defp insert_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "room-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-room-#{n}"
    })
  end

  defp participant!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp open(ctx, user) do
    conn = init_test_session(build_conn(), current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{ctx.space.slug}", on_error: :warn)
    view
  end

  defp ids(ctx, node \\ @node),
    do: %{"canvas_id" => ctx.canvas.id, "node_id" => node, "hook_id" => "h1"}

  defp join!(view, ctx) do
    render_hook(view, "canvas_room_join", ids(ctx))
    assert_reply(view, %{ok: true} = reply)
    reply
  end

  defp op(view, ctx, op, extra \\ %{}) do
    render_hook(view, "canvas_room_op", ids(ctx) |> Map.put("op", op) |> Map.merge(extra))
  end

  defp flushed_events(ctx) do
    :ok = CanvasRoom.stop(ctx.canvas.id, @node)

    rec =
      Repo.one(from(r in Record, where: r.canvas_id == ^ctx.canvas.id and r.node_id == ^@node))

    Repo.all(from(e in Event, where: e.room_id == ^rec.id, order_by: e.seq))
  end

  test "ChatLive renders the marker that lets the bridge hook talk to it", ctx do
    view = open(ctx, ctx.alice)
    assert render(view) =~ "data-canvas-rooms"
  end

  test "join replies with the snapshot and the session's own identity", ctx do
    view = open(ctx, ctx.alice)
    reply = join!(view, ctx)

    assert reply.seq == 0
    assert reply.state == %{"keys" => %{}, "collections" => %{}}
    assert reply.me == %{id: ctx.alice.id, display_name: "Alice"}
    assert reply.writable == true
    assert [%{id: id, viewers: 1}] = reply.presence
    assert id == ctx.alice.id
  end

  test "an op from one LiveView reaches the other as a push_event", ctx do
    a = open(ctx, ctx.alice)
    b = open(ctx, ctx.bob)
    join!(a, ctx)
    join!(b, ctx)

    op(a, ctx, %{"type" => "state.increment", "key" => "count"})
    assert_reply(a, %{ok: true, seq: 1, result: 1})

    diff_event = "canvas_room:#{ctx.canvas.id}:#{@node}:diff"
    assert_push_event(b, ^diff_event, %{seq: 1, diff: diff, actor: actor})
    assert diff["key"] == "count" and diff["value"] == 1
    assert actor == ctx.alice.id
  end

  test "a join for a node that is not a prototype is refused", ctx do
    view = open(ctx, ctx.alice)
    render_hook(view, "canvas_room_join", ids(ctx, "words"))
    assert_reply(view, %{ok: false, error: "not_a_room_node"})

    render_hook(view, "canvas_room_join", ids(ctx, "no-such-node"))
    assert_reply(view, %{ok: false, error: "not_a_room_node"})

    assert CanvasRoom.whereis(ctx.canvas.id, "words") == nil
  end

  test "a scripts: true embed is a room node; a plain embed is still refused", ctx do
    Platform.PrototypeFixtures.scratch_storage!("canvas_room_bridge_test")
    Platform.PrototypeFixtures.set_settings!(%{enabled: true})
    n = System.unique_integer([:positive])
    org_id = Platform.TenancyFixtures.tenant_org_id("rooms-embed-#{n}")

    {:ok, space} =
      Chat.create_space(%{
        name: "Embeds #{n}",
        slug: "embeds-#{n}",
        kind: "channel",
        org_id: org_id
      })

    author = participant!(space, ctx.alice)
    html = "<!doctype html><html><body><script>1</script></body></html>"

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Embeds",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => "live",
                "type" => "embed",
                "props" => %{"srcdoc" => html, "scripts" => true}
              },
              %{"id" => "flat", "type" => "embed", "props" => %{"srcdoc" => "<p>x</p>"}}
            ]
          }
        }
      })

    on_exit(fn -> CanvasRoom.stop(canvas.id, "live") end)
    ectx = %{space: space, canvas: canvas}
    view = open(ectx, ctx.alice)

    render_hook(view, "canvas_room_join", ids(ectx, "live"))
    assert_reply(view, %{ok: true, writable: true})

    render_hook(view, "canvas_room_join", ids(ectx, "flat"))
    assert_reply(view, %{ok: false, error: "not_a_room_node"})
    assert CanvasRoom.whereis(canvas.id, "flat") == nil
  end

  test "a non-participant cannot write: refused, or at most a read-only join", ctx do
    outsider = insert_user!("Outsider")
    n = System.unique_integer([:positive])
    {:ok, own} = Chat.create_space(%{name: "Own #{n}", slug: "own-#{n}", kind: "channel"})
    participant!(own, outsider)

    view = open(%{space: own}, outsider)
    render_hook(view, "canvas_room_join", ids(ctx))
    assert_reply(view, reply)
    assert reply.ok == false or reply.writable == false

    op(view, ctx, %{"type" => "state.set", "key" => "label", "value" => "x"})
    assert_reply(view, %{ok: false})
  end

  test "an op before a join is refused", ctx do
    view = open(ctx, ctx.alice)
    op(view, ctx, %{"type" => "state.set", "key" => "label", "value" => "x"})
    assert_reply(view, %{ok: false, error: "not_joined"})
  end

  test "the actor comes from the session even when params carry one", ctx do
    view = open(ctx, ctx.alice)
    join!(view, ctx)
    forged = Ecto.UUID.generate()

    op(view, ctx, %{"type" => "state.set", "key" => "label", "value" => "hi"}, %{
      "actor" => %{"type" => "user", "id" => forged, "display_name" => "Forged"}
    })

    assert_reply(view, %{ok: true, seq: 1})

    # An actor smuggled inside the op is dropped too.
    op(view, ctx, %{"type" => "state.set", "key" => "x", "value" => 1, "actor" => forged})
    assert_reply(view, %{ok: true, seq: 2})

    events = flushed_events(ctx)
    assert Enum.map(events, & &1.actor_id) == [ctx.alice.id, ctx.alice.id]
    refute Enum.any?(events, &Map.has_key?(&1.op, "actor"))
  end

  test "the viewer's own ephemeral echo is dropped; the other viewer gets it", ctx do
    a = open(ctx, ctx.alice)
    b = open(ctx, ctx.bob)
    join!(a, ctx)
    join!(b, ctx)

    render_hook(
      a,
      "canvas_room_ephemeral",
      Map.merge(ids(ctx), %{"channel" => "cursor", "payload" => %{"x" => 1, "y" => 2}})
    )

    event = "canvas_room:#{ctx.canvas.id}:#{@node}:ephemeral"
    assert_push_event(b, ^event, %{channel: "cursor", payload: %{"x" => 1, "y" => 2}})
    _ = render(a)
    refute_push_event(a, own_echo, %{channel: "cursor"})
  end

  test "the room going down makes the LiveView rejoin and push a fresh snapshot", ctx do
    view = open(ctx, ctx.alice)
    join!(view, ctx)
    op(view, ctx, %{"type" => "state.increment", "key" => "count", "by" => 5})
    assert_reply(view, %{ok: true, seq: 1})

    old = CanvasRoom.whereis(ctx.canvas.id, @node)
    :ok = CanvasRoom.stop(ctx.canvas.id, @node)

    snapshot = "canvas_room:#{ctx.canvas.id}:#{@node}:snapshot"
    assert_push_event(view, ^snapshot, %{seq: 1, state: %{"keys" => %{"count" => 5}}}, 1_000)

    new = CanvasRoom.whereis(ctx.canvas.id, @node)
    assert is_pid(new) and new != old

    # The rejoined room still takes ops from this LiveView.
    op(view, ctx, %{"type" => "state.increment", "key" => "count"})
    assert_reply(view, %{ok: true, seq: 2, result: 6})
  end

  test "leave from the last hook leaves the room", ctx do
    view = open(ctx, ctx.alice)
    join!(view, ctx)
    {:ok, %{presence: [_]}} = CanvasRoom.snapshot(ctx.canvas.id, @node)

    render_hook(view, "canvas_room_leave", ids(ctx))
    {:ok, %{presence: []}} = CanvasRoom.snapshot(ctx.canvas.id, @node)
  end

  defp call(view, ctx, name, args, extra \\ %{}) do
    render_hook(
      view,
      "canvas_room_call",
      ids(ctx) |> Map.merge(%{"req" => "c1", "name" => name, "args" => args}) |> Map.merge(extra)
    )
  end

  describe "canvas_room_call (task 01a1316b-aab0 stage 2)" do
    @vote "(event, ctx) => { ctx.increment('votes.' + event.args.option) }"

    setup ctx do
      assert {:ok, _} =
               Chat.patch_canvas({:user, ctx.alice.id}, ctx.canvas, [
                 {:set_binding, "vote", %{"kind" => "handler", "source" => @vote}}
               ])

      on_exit(fn -> Platform.Chat.Canvas.Server.stop(ctx.canvas.id) end)
      :ok
    end

    test "a call reaches the other LiveView as a diff and the caller as a call_result", ctx do
      a = open(ctx, ctx.alice)
      b = open(ctx, ctx.bob)
      join!(a, ctx)
      join!(b, ctx)

      call(a, ctx, "vote", %{"option" => "a"})

      result_event = "canvas_room:#{ctx.canvas.id}:#{@node}:call_result"
      assert_push_event(a, ^result_event, %{ok: true, req: "c1", hook_id: "h1", seq: 1}, 5_000)

      diff_event = "canvas_room:#{ctx.canvas.id}:#{@node}:diff"
      assert_push_event(b, ^diff_event, %{seq: 1, diff: diff, actor: actor})
      assert diff["key"] == "votes.a" and diff["value"] == 1
      assert actor == ctx.alice.id
    end

    test "a refused call pushes its kind and code", ctx do
      view = open(ctx, ctx.alice)
      join!(view, ctx)
      call(view, ctx, "missing", %{})

      result_event = "canvas_room:#{ctx.canvas.id}:#{@node}:call_result"

      assert_push_event(
        view,
        ^result_event,
        %{ok: false, kind: "unknown_handler", code: "unknown_handler", req: "c1"},
        5_000
      )
    end

    test "a call before a join is refused with not_joined", ctx do
      view = open(ctx, ctx.alice)
      call(view, ctx, "vote", %{"option" => "a"})
      result_event = "canvas_room:#{ctx.canvas.id}:#{@node}:call_result"
      assert_push_event(view, ^result_event, %{ok: false, code: "not_joined"})
    end

    test "the recorded actor is the session user even when params carry another", ctx do
      view = open(ctx, ctx.alice)
      join!(view, ctx)
      forged = ctx.bob.id

      call(view, ctx, "vote", %{"option" => "a"}, %{
        "actor" => %{"type" => "user", "id" => forged, "display_name" => "Forged"}
      })

      result_event = "canvas_room:#{ctx.canvas.id}:#{@node}:call_result"
      assert_push_event(view, ^result_event, %{ok: true, seq: 1}, 5_000)

      assert [event] = flushed_events(ctx)
      assert event.actor_id == ctx.alice.id
      assert event.op["via"] == "handler:vote"
    end
  end

  # Task 01a18d38 stage 1, gap 4: the room join resolves through
  # `CanvasAccess.fetch_for_viewer/3` WITH the viewer's Access scope, so a
  # `canvas.read` deny refuses it like a missing canvas. Each deny test sits
  # next to a participant on the SAME canvas who still joins and writes.
  describe "canvas_room_join honours canvas.read denies (task 01a18d38 stage 1)" do
    alias Platform.Access.Grants
    alias PlatformWeb.ChatLive.CanvasHooks

    defp deny!(user, resource) do
      {:ok, _} =
        Grants.deny(%{principal: user, permission: "canvas.read", resource: resource})

      :ok
    end

    defp refused_join!(view, ctx) do
      render_hook(view, "canvas_room_join", ids(ctx))
      assert_reply(view, %{ok: false, error: "not_found"})
    end

    test "a participant denied on the CANVAS is refused; an allowed participant joins and writes",
         ctx do
      deny!(ctx.bob, {:canvas, ctx.canvas.id})

      denied = open(ctx, ctx.bob)
      refused_join!(denied, ctx)
      # No join reached the room: none was started for this node.
      assert CanvasRoom.whereis(ctx.canvas.id, @node) == nil

      # A refused join holds no writable grant, so an op is still not_joined.
      op(denied, ctx, %{"type" => "state.set", "key" => "label", "value" => "x"})
      assert_reply(denied, %{ok: false, error: "not_joined"})

      # Positive control on the same canvas: alice joins writable and writes.
      allowed = open(ctx, ctx.alice)
      assert %{writable: true} = join!(allowed, ctx)
      op(allowed, ctx, %{"type" => "state.increment", "key" => "count"})
      assert_reply(allowed, %{ok: true, seq: 1, result: 1})
    end

    test "a participant denied on the canvas's SPACE is refused; an allowed participant joins",
         ctx do
      carol = insert_user!("Carol")
      participant!(ctx.space, carol)
      deny!(carol, {:space, ctx.space.id})

      refused_join!(open(ctx, carol), ctx)
      assert %{writable: true} = join!(open(ctx, ctx.bob), ctx)
    end

    test "with NO :access_scope assign the socket's own user record still carries the deny",
         ctx do
      deny!(ctx.bob, {:canvas, ctx.canvas.id})

      denied = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user_record: ctx.bob}
      }

      allowed = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_user_record: ctx.alice}
      }

      assert CanvasHooks.room_canvas(denied, ctx.canvas.id) == {:error, :not_found}
      assert {:ok, %{id: id}, :member} = CanvasHooks.room_canvas(allowed, ctx.canvas.id)
      assert id == ctx.canvas.id
    end

    test "a socket with no resolvable user is refused, never read as an unscoped viewer", ctx do
      bare = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assert CanvasHooks.room_canvas(bare, ctx.canvas.id) == {:error, :not_found}
    end
  end
end
