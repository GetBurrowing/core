defmodule Platform.Canvas.ScriptEngine.AdversarialTest do
  @moduledoc """
  Task 01a1316b-aab0 stage 3: hostile canvas handlers are contained by the
  limits stages 1 and 2 built. One describe per attack, mirroring
  `test/platform/code_mode/sandbox_adversarial_test.exs`.

  Every containment test here was SHOWN TO FIRE: the stage ran, on a local
  throwaway branch, the mutation that removes or loosens the limit the test
  names, and recorded that the test then failed. The per-attack table (limit,
  test, mutation, observed failure) is in the stage 3 commit message. A test
  that still passed with its limit removed is recorded there as a FINDING,
  not patched around.

  Tests named `FINDING:` pin a behaviour the stage MEASURED and reports
  rather than changes. Each one asserts what the code does today, so the fix
  that closes the finding must invert it.

  Every looping handler is bounded by the canvas wall budget, every Task this
  file starts is awaited or shut down, and every room is stopped on exit.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import Platform.CodeModeFixtures, only: [insert_agent!: 0, insert_runtime!: 2, bundles: 1]

  import Platform.ExternalUserFixtures,
    only: [create_user!: 1, add_user!: 2, plain_member!: 2, login: 2, message_count: 1]

  alias Platform.Canvas.ScriptEngine
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasRoom
  alias Platform.Chat.CanvasRoom.{Event, Record}
  alias Platform.CodeMode.Run
  alias Platform.CodeMode.Slots
  alias Platform.Federation.ToolCallRecord
  alias Platform.Repo
  alias Platform.Tenancy

  @pool Platform.Canvas.ScriptEngine.Slots
  @node "proto"

  setup do
    org = Tenancy.get_org_by_slug!("sxi")
    space = space!(org, "Hostile")

    alice = create_user!(%{name: "Alice"})
    bob = create_user!(%{name: "Bob"})
    author = add_user!(space.id, alice.id)
    add_user!(space.id, bob.id)
    plain_member!(alice, org)
    plain_member!(bob, org)

    canvas = canvas!(space, author, "Hostile")
    other = canvas!(space, author, "Bystander")

    previous = Application.get_env(:platform, ScriptEngine)

    on_exit(fn ->
      for c <- [canvas, other] do
        CanvasRoom.stop(c.id, @node)
        CanvasServer.stop(c.id)
      end

      if previous,
        do: Application.put_env(:platform, ScriptEngine, previous),
        else: Application.delete_env(:platform, ScriptEngine)
    end)

    %{
      org: org,
      space: space,
      canvas: canvas,
      other: other,
      alice: alice,
      bob: bob,
      a: actor(alice),
      b: actor(bob)
    }
  end

  # ── Builders and helpers ────────────────────────────────────────────────

  defp space!(org, name) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "#{name} #{n}",
        slug: "#{String.downcase(name)}-#{n}",
        kind: "channel",
        org_id: org && org.id
      })

    space
  end

  defp canvas!(space, author, title) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => title,
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
              %{"id" => "h", "type" => "heading", "props" => %{"value" => "Original"}}
            ]
          }
        }
      })

    canvas
  end

  defp actor(user), do: %{type: "user", id: user.id, display_name: user.name}

  defp bind!(writer, canvas, name, source) do
    assert {:ok, _} =
             Chat.patch_canvas({:user, writer.id}, canvas, [
               {:set_binding, name, %{"kind" => "handler", "engine" => "js", "source" => source}}
             ])
  end

  defp bind!(ctx, name, source), do: bind!(ctx.alice, ctx.canvas, name, source)

  defp call_async(canvas, actor, name, args) do
    ref = make_ref()
    :ok = CanvasRoom.call_handler(canvas.id, @node, actor, name, args, {self(), ref})
    ref
  end

  defp await_result(ref, timeout \\ 8_000) do
    assert_receive {:canvas_room_call_result, ^ref, result}, timeout
    result
  end

  defp call(ctx, actor, name, args \\ %{}),
    do: ctx.canvas |> call_async(actor, name, args) |> await_result()

  defp keys(canvas) do
    {:ok, %{state: state}} = CanvasRoom.snapshot(canvas.id, @node)
    state["keys"]
  end

  defp flushed_events(canvas) do
    :ok = CanvasRoom.stop(canvas.id, @node)

    case Repo.one(from(r in Record, where: r.canvas_id == ^canvas.id and r.node_id == ^@node)) do
      nil -> []
      rec -> Repo.all(from(e in Event, where: e.room_id == ^rec.id, order_by: e.seq))
    end
  end

  defp heading(canvas_id) do
    {:ok, %{document: doc, revision: revision}} = CanvasServer.describe(canvas_id)
    {get_in(doc, ["root", "children", Access.at(1), "props", "value"]), revision}
  end

  defp attach_script_run do
    test_pid = self()
    id = "adversarial-script-run-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:platform, :canvas, :script_run],
      fn _event, _measurements, metadata, _ -> send(test_pid, {:script_run, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp open(space, user) do
    conn = login(build_conn(), user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}", on_error: :warn)
    view
  end

  defp ids(canvas, node \\ @node),
    do: %{"canvas_id" => canvas.id, "node_id" => node, "hook_id" => "h1"}

  defp join(view, canvas) do
    render_hook(view, "canvas_room_join", ids(canvas))
    assert_reply(view, reply)
    reply
  end

  defp lv_call(view, ids, name, args, extra \\ %{}) do
    render_hook(
      view,
      "canvas_room_call",
      ids |> Map.merge(%{"req" => "c1", "name" => name, "args" => args}) |> Map.merge(extra)
    )
  end

  defp result_event(canvas, node \\ @node), do: "canvas_room:#{canvas.id}:#{node}:call_result"

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
        true -> Process.sleep(10) && nil
      end
    end)
    |> Enum.find(& &1)
  end

  defp canvas_held(canvas_id), do: Slots.held(@pool).by_runtime[canvas_id]

  # ── 1. Infinite loop ────────────────────────────────────────────────────

  describe "attack 1: an infinite loop" do
    test "ends fuel or timeout within the canvas wall budget plus the 500 ms grace", ctx do
      bind!(ctx, "spin", "(e, ctx) => { while (true) {} }")

      started = System.monotonic_time(:millisecond)
      ref = call_async(ctx.canvas, ctx.a, "spin", %{})
      assert {:error, %{kind: kind}} = await_result(ref, 8_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert kind in ["fuel", "timeout"]
      # Canvas wall_ms 1_000 + runtime.ex's 500 ms grace + 1 s setup slack.
      assert elapsed < 1_000 + 500 + 1_000, "the loop ran #{elapsed} ms"

      # The room survives its handler.
      assert {:ok, _} = CanvasRoom.snapshot(ctx.canvas.id, @node)
    end

    test "while it loops, the same room, an agent suite_run and another LiveView all serve",
         ctx do
      # A longer wall so the liveness checks below run inside the loop.
      Application.put_env(:platform, ScriptEngine, wall_ms: 3_000, max_wall_ms: 5_000)
      bind!(ctx, "spin", "(e, ctx) => { while (true) {} }")

      {runtime, _token} = insert_runtime!(insert_agent!(), bundles(["code_mode"]))
      bob_view = open(ctx.space, ctx.bob)
      before = message_count(ctx.space.id)

      ref = call_async(ctx.canvas, ctx.a, "spin", %{})

      # The canvas-pool check can produce a hit: 1 while the loop runs.
      wait_until(fn -> canvas_held(ctx.canvas.id) == 1 end, 2_000)

      # A plain op on the SAME room is served at once, not after the loop.
      {us, reply} =
        :timer.tc(fn ->
          CanvasRoom.apply_op(ctx.canvas.id, @node, ctx.b, %{
            "type" => "state.set",
            "key" => "label",
            "value" => "bob"
          })
        end)

      assert {:ok, %{seq: 1}} = reply
      assert us < 500_000, "the plain op waited #{div(us, 1000)} ms behind the handler"
      refute_received {:canvas_room_call_result, ^ref, _}

      # Another LiveView posts a chat message.
      bob_view |> form("#compose-form", compose: %{text: "still here"}) |> render_submit()
      assert message_count(ctx.space.id) == before + 1
      refute_received {:canvas_room_call_result, ^ref, _}

      # An agent's suite_run runs in the agent pool.
      assert {:ok, %{ok: true, result: 2}} = Run.execute(runtime, "1 + 1")
      refute_received {:canvas_room_call_result, ^ref, _}
      assert canvas_held(ctx.canvas.id) == 1

      assert {:error, %{kind: kind}} = await_result(ref, 8_000)
      assert kind in ["fuel", "timeout"]
      assert keys(ctx.canvas) == %{"label" => "bob"}
    end
  end

  # ── 2. Huge allocation ──────────────────────────────────────────────────

  describe "attack 2: a huge allocation" do
    test "an unbounded allocation loop ends memory at the canvas cap", ctx do
      bind!(ctx, "hog", "(e, ctx) => { let a = []; for (;;) a.push(new Array(1e6)) }")
      assert {:error, %{kind: "memory"}} = call(ctx, ctx.a, "hog")
    end

    test "a finite 24 MB allocation fails: the cap is the canvas 16 MB, not the agent 64 MB",
         ctx do
      bind!(ctx, "big", """
      (e, ctx) => {
        const a = [];
        for (let i = 0; i < 3; i++) a.push(new Float64Array(1e6));
        ctx.set('n', a.length);
      }
      """)

      assert {:error, %{kind: "memory"}} = call(ctx, ctx.a, "big")
      assert keys(ctx.canvas) == %{}
    end
  end

  # ── 3. Deep recursion ───────────────────────────────────────────────────

  describe "attack 3: deep recursion" do
    test "is script_error and the room keeps its pid", ctx do
      bind!(ctx, "deep", "(e, ctx) => { const f = n => f(n + 1); f(0) }")
      bind!(ctx, "ok", "(e, ctx) => { ctx.increment('after') }")

      {:ok, pid} = CanvasRoom.start_room(ctx.canvas.id, @node)
      assert {:error, %{kind: "script_error", message: message}} = call(ctx, ctx.a, "deep")
      assert message =~ ~r/stack/i

      assert CanvasRoom.whereis(ctx.canvas.id, @node) == pid
      assert {:ok, %{applied: 1}} = call(ctx, ctx.a, "ok")
      assert keys(ctx.canvas) == %{"after" => 1}
    end
  end

  # ── 4. Binding misuse ───────────────────────────────────────────────────

  describe "attack 4: binding misuse" do
    test "11 ctx.patch calls end call_limit at max_calls 10, even when each is caught", ctx do
      bind!(ctx, "flood", """
      (e, ctx) => {
        for (let i = 0; i < 11; i++) {
          try { ctx.patch([["set_props", "h", {"value": "p" + i}]]) } catch (_) {}
        }
        ctx.set('done', true);
      }
      """)

      {_, revision} = heading(ctx.canvas.id)
      assert {:error, %{kind: "call_limit"}} = call(ctx, ctx.a, "flood")

      # The room ops are refused with the run. The ten document patches that
      # landed before the limit are NOT rolled back (they are canvas writes
      # the caller already holds): recorded as a measurement.
      assert keys(ctx.canvas) == %{}
      assert {"p9", after_revision} = heading(ctx.canvas.id)
      assert after_revision == revision + 10
    end

    test "tasks.create, suite_run and $store.* are forbidden / binding_not_registered, with no side effect",
         ctx do
      count = fn ->
        {Repo.aggregate(Platform.Tasks.Task, :count), Repo.aggregate(ToolCallRecord, :count),
         :ets.info(:code_mode_store, :size)}
      end

      before = count.()

      for {name, source} <- [
            {"mk", "(e, ctx) => suite.call('tasks.create', {title: 'x'})"},
            {"nest", "(e, ctx) => suite.call('suite_run', {code: '1 + 1'})"},
            {"put", "(e, ctx) => suite.call('$store.set', {key: 'k', value: 1})"},
            {"store", "(e, ctx) => store.set('k', 1)"},
            {"post", "(e, ctx) => suite.call('chat.post_message', {content: 'x'})"}
          ] do
        bind!(ctx, name, source)

        assert {:error, %{kind: "forbidden", code: "binding_not_registered"}} =
                 call(ctx, ctx.a, name),
               "#{name} was not refused as binding_not_registered"
      end

      assert count.() == before
      assert keys(ctx.canvas) == %{}
    end

    test "a canvas.patch naming another canvas_id patches only the owning canvas", ctx do
      bind!(ctx, "aim", """
      (e, ctx) => suite.call('canvas.patch', {
        canvas_id: e.args.target,
        operations: [["set_props", "h", {"value": "Hijacked"}]]
      })
      """)

      {_, other_revision} = heading(ctx.other.id)
      assert {:ok, _} = call(ctx, ctx.a, "aim", %{"target" => ctx.other.id})

      assert {"Hijacked", _} = heading(ctx.canvas.id)
      assert {"Original", ^other_revision} = heading(ctx.other.id)
    end

    test "a returned op list with one op over the Ops caps applies nothing", ctx do
      bind!(ctx, "half", "(e, ctx) => { ctx.set('a', 1); ctx.set('b', 'x'.repeat(20000)) }")
      assert {:error, %{kind: "too_large"}} = call(ctx, ctx.a, "half")
      assert keys(ctx.canvas) == %{}
      assert {:ok, %{seq: 0}} = CanvasRoom.snapshot(ctx.canvas.id, @node)
    end
  end

  # ── 5. Forged caller ────────────────────────────────────────────────────

  describe "attack 5: a forged caller" do
    setup ctx do
      bind!(ctx, "vote", "(event, ctx) => { ctx.increment('votes') }")
      :ok
    end

    test "params carrying actor run as the session user", ctx do
      view = open(ctx.space, ctx.alice)
      assert %{ok: true, writable: true} = join(view, ctx.canvas)

      lv_call(view, ids(ctx.canvas), "vote", %{}, %{
        "actor" => %{"type" => "user", "id" => ctx.bob.id, "display_name" => "Forged"},
        "principal" => %{"type" => "user", "id" => ctx.bob.id}
      })

      result_event = result_event(ctx.canvas)
      assert_push_event(view, ^result_event, %{ok: true, seq: 1}, 8_000)

      assert [event] = flushed_events(ctx.canvas)
      assert event.actor_id == ctx.alice.id
    end

    test "a canvas_id or node_id the session has not joined is refused, and nothing runs there",
         ctx do
      # A canvas in a space (and org) the session user has no part in.
      stranger_space = space!(nil, "Elsewhere")
      owner = create_user!(%{name: "Owner"})
      owner_p = add_user!(stranger_space.id, owner.id)
      stranger = canvas!(stranger_space, owner_p, "Elsewhere")
      bind!(owner, stranger, "vote", "(event, ctx) => { ctx.increment('votes') }")
      on_exit(fn -> CanvasRoom.stop(stranger.id, @node) end)

      attach_script_run()
      view = open(ctx.space, ctx.alice)
      assert %{ok: true} = join(view, ctx.canvas)

      lv_call(view, ids(stranger), "vote", %{})
      stranger_event = result_event(stranger)
      assert_push_event(view, ^stranger_event, %{ok: false, code: "not_joined"}, 2_000)

      lv_call(view, ids(ctx.canvas, "other-node"), "vote", %{})
      node_event = result_event(ctx.canvas, "other-node")
      assert_push_event(view, ^node_event, %{ok: false, code: "not_joined"}, 2_000)

      stranger_id = stranger.id
      refute_receive {:script_run, %{canvas_id: ^stranger_id}}, 300
      assert CanvasRoom.whereis(stranger.id, @node) == nil
    end

    test "a handler cannot reach the host as someone else: the principal is bound host-side",
         ctx do
      reader = create_user!(%{name: "Reader"})
      plain_member!(reader, ctx.org)

      bind!(ctx, "forge", """
      (e, ctx) => {
        try { ctx.actor.id = e.args.victim } catch (_) {}
        try { Object.defineProperty(ctx, 'actor', {value: {type: 'user', id: e.args.victim}}) } catch (_) {}
        return suite.call('canvas.patch', {
          actor: {type: 'user', id: e.args.victim},
          principal: {type: 'user', id: e.args.victim},
          operations: [["set_props", "h", {"value": "Forged"}]]
        });
      }
      """)

      {_, revision} = heading(ctx.canvas.id)

      assert {:error, %{kind: "forbidden", code: "forbidden"}} =
               call(ctx, actor(reader), "forge", %{"victim" => ctx.alice.id})

      assert {"Original", ^revision} = heading(ctx.canvas.id)

      # The same handler, clicked by a writer, writes: the authority is the
      # CLICKER's (the confused-deputy note in CanvasRoom's moduledoc).
      assert {:ok, _} = call(ctx, ctx.b, "forge", %{"victim" => ctx.alice.id})
      assert {"Forged", _} = heading(ctx.canvas.id)
    end

    test "a read-only viewer's handler call is refused as not_writable, like its plain op",
         ctx do
      reader = create_user!(%{name: "Reader"})
      plain_member!(reader, ctx.org)
      own = space!(ctx.org, "ReaderOwn")
      add_user!(own.id, reader.id)

      bind!(ctx, "claim", "(e, ctx) => { ctx.set('owner', 'reader') }")

      view = open(own, reader)
      assert %{ok: true, writable: false} = join(view, ctx.canvas)

      # A plain op from the reader is refused...
      render_hook(
        view,
        "canvas_room_op",
        ids(ctx.canvas)
        |> Map.put("op", %{"type" => "state.set", "key" => "owner", "value" => "x"})
      )

      assert_reply(view, %{ok: false, error: "forbidden"})
      assert keys(ctx.canvas) == %{}

      # ...and so is the same write through a writer-authored handler (stage
      # 3 finding F1, fixed in stage 4). The refusal is audited as the reader.
      attach_script_run()
      lv_call(view, ids(ctx.canvas), "claim", %{})
      result_event = result_event(ctx.canvas)

      assert_push_event(
        view,
        ^result_event,
        %{ok: false, kind: "forbidden", code: "not_writable"},
        8_000
      )

      reader_id = reader.id

      assert_receive {:script_run,
                      %{caller_id: ^reader_id, result: "forbidden", code: "not_writable"}},
                     2_000

      assert keys(ctx.canvas) == %{}
      assert flushed_events(ctx.canvas) == []

      # Positive control: a writer's call through the same LiveView path lands.
      writer_view = open(ctx.space, ctx.bob)
      assert %{ok: true, writable: true} = join(writer_view, ctx.canvas)
      lv_call(writer_view, ids(ctx.canvas), "claim", %{})
      assert_push_event(writer_view, ^result_event, %{ok: true, seq: 1}, 8_000)
      assert keys(ctx.canvas) == %{"owner" => "reader"}
    end
  end

  # ── 6. Timer flood ──────────────────────────────────────────────────────

  describe "attack 6: a timer flood" do
    test "every(1000) x 17 trips too_many_timers", ctx do
      sixteen = Enum.map_join(1..16, "; ", &"ctx.every(1000, 'h#{&1}', {})")
      bind!(ctx, "sixteen", "(e, ctx) => { #{sixteen} }")
      bind!(ctx, "seventeenth", "(e, ctx) => { ctx.set('x', 1); ctx.every(1000, 'h17', {}) }")

      assert {:ok, _} = call(ctx, ctx.a, "sixteen")
      assert {:error, %{kind: "too_many_timers"}} = call(ctx, ctx.a, "seventeenth")
      assert keys(ctx.canvas) == %{}
    end

    test "every(10) is refused as below 1 s", ctx do
      bind!(ctx, "fast", "(e, ctx) => { ctx.set('x', 1); ctx.every(10, 'tick', {}) }")
      assert {:error, %{kind: "invalid_effect"}} = call(ctx, ctx.a, "fast")
      assert keys(ctx.canvas) == %{}
    end

    test "a handler that re-schedules itself from every fire runs at most once a second", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.every(1000, 'tick', {}) }")
      bind!(ctx, "tick", "(e, ctx) => { ctx.increment('ticks'); ctx.every(1000, 'tick', {}) }")

      assert {:ok, _} = call(ctx, ctx.a, "arm")
      Process.sleep(3_400)
      ticks = keys(ctx.canvas)["ticks"] || 0
      assert ticks in 2..4, "tick ran #{ticks} times in 3.4 s"
    end

    # Stage 3 finding F4, fixed in stage 4: an `after` scheduled from a timer
    # fire is raised to 1 s. Measured at stage 3 without it: 10 runs in 1.05 s.
    test "an after(100) self-chain runs at most once a second over 3 s", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.after(100, 'tock', {}) }")
      bind!(ctx, "tock", "(e, ctx) => { ctx.increment('tocks'); ctx.after(100, 'tock', {}) }")

      assert {:ok, _} = call(ctx, ctx.a, "arm")
      Process.sleep(3_000)
      tocks = keys(ctx.canvas)["tocks"] || 0
      # First fire at ~0.1 s (set by a call, not floored), then ~1.1, ~2.1.
      assert tocks in 2..4, "tock ran #{tocks} times in 3 s"
    end

    test "a two-handler after(100) ping-pong is held to the same floor", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.after(100, 'ping', {}) }")
      bind!(ctx, "ping", "(e, ctx) => { ctx.increment('n'); ctx.after(100, 'pong', {}) }")
      bind!(ctx, "pong", "(e, ctx) => { ctx.increment('n'); ctx.after(100, 'ping', {}) }")

      assert {:ok, _} = call(ctx, ctx.a, "arm")
      Process.sleep(3_000)
      n = keys(ctx.canvas)["n"] || 0
      assert n in 2..4, "ping/pong ran #{n} times in 3 s"
    end

    test "calls run 4 at once, queue 16 more, then busy", ctx do
      Application.put_env(:platform, ScriptEngine, wall_ms: 4_000, max_wall_ms: 5_000)

      bind!(ctx, "slow", """
      (e, ctx) => { const end = new Date().getTime() + 600; while (new Date().getTime() < end) {} }
      """)

      bind!(ctx, "noop", "(e, ctx) => { ctx.increment('n') }")

      slow = for _ <- 1..4, do: call_async(ctx.canvas, ctx.a, "slow", %{})
      # The check can fire: the canvas pool holds 4 for this canvas.
      wait_until(fn -> Slots.held(@pool).by_runtime[ctx.canvas.id] == 4 end, 3_000)
      queued = for _ <- 1..16, do: call_async(ctx.canvas, ctx.a, "noop", %{})
      over = call_async(ctx.canvas, ctx.a, "noop", %{})

      assert {:error, %{kind: "busy"}} = await_result(over, 500)
      for ref <- slow, do: assert({:ok, _} = await_result(ref))
      for ref <- queued, do: assert({:ok, %{applied: 1}} = await_result(ref))
      assert keys(ctx.canvas) == %{"n" => 16}
    end

    test "after CanvasRoom.stop/2, no further script_run arrives in 2 s", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.every(1000, 'tick', {}) }")
      bind!(ctx, "tick", "(e, ctx) => { ctx.increment('ticks') }")
      attach_script_run()

      assert {:ok, _} = call(ctx, ctx.a, "arm")
      assert_receive {:script_run, %{handler: "arm"}}
      # The check can fire: the timer's own run is audited.
      assert_receive {:script_run, %{handler: "tick", trigger: "timer"}}, 2_500

      :ok = CanvasRoom.stop(ctx.canvas.id, @node)
      assert CanvasRoom.whereis(ctx.canvas.id, @node) == nil
      refute_receive {:script_run, _}, 2_000
    end
  end

  # ── 7. Pool exhaustion ──────────────────────────────────────────────────

  describe "attack 7: pool exhaustion" do
    test "9 canvases looping: the 9th is busy and the agent pool stays at 0 throughout" do
      Application.put_env(:platform, ScriptEngine, wall_ms: 3_000, max_wall_ms: 5_000)
      limits = ScriptEngine.limits()

      run = fn canvas_id, source ->
        ScriptEngine.run(
          %{"name" => "spin", "engine" => "js", "source" => source},
          %{"type" => "call", "args" => %{}},
          %{"keys" => %{}, "collections" => %{}},
          %{
            canvas_id: canvas_id,
            actor: %{type: "user", id: Ecto.UUID.generate(), display_name: "V"},
            now: 0
          },
          limits
        )
      end

      tasks =
        for _ <- 1..8 do
          id = Ecto.UUID.generate()
          Task.async(fn -> run.(id, "(e, ctx) => { while (true) {} }") end)
        end

      # The canvas-pool check can produce a hit: all 8 slots are held.
      samples = :ets.new(:samples, [:duplicate_bag, :public])

      sampler =
        Task.async(fn ->
          Enum.each(1..400, fn _ ->
            :ets.insert(samples, {:agent, Slots.held().total})
            Process.sleep(10)
          end)
        end)

      wait_until(fn -> Slots.held(@pool).total == 8 end, 3_000)

      assert {:error, "busy", message} = run.(Ecto.UUID.generate(), "(e, ctx) => {}")
      assert message =~ "node"

      for task <- tasks do
        assert {:error, kind, _} = Task.await(task, 10_000)
        assert kind in ["fuel", "timeout"]
      end

      Task.await(sampler, 10_000)
      agent = for {:agent, total} <- :ets.tab2list(samples), do: total
      assert length(agent) == 400
      assert Enum.all?(agent, &(&1 == 0)), "the agent pool held #{Enum.max(agent)}"
      assert Slots.held().total == 0
    end
  end
end
