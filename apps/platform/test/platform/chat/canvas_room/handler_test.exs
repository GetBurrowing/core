defmodule Platform.Chat.CanvasRoom.HandlerTest do
  @moduledoc """
  Task 01a1316b-aab0 stage 2: canvas handlers wired into the room. A
  `call` runs the handler off the room process and applies its returned
  OPS, all or nothing, to the room's then-current state; timers come from
  the handler's effects; every run is audited.

  Anti-vacuity targets:

    * "a plain op landing during a 900 ms handler is not clobbered" must
      fail if the handler's result is applied as a whole-state replace (the
      ops applied to the dispatch-time snapshot) instead of as ops on the
      current state.
    * "one script_run event per run" attaches its own telemetry handler, so
      an emit that never fires cannot pass it.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.CodeModeFixtures, only: [insert_agent!: 0, insert_runtime!: 2, bundles: 1]
  import Platform.ExternalUserFixtures

  alias Platform.Audit.TelemetryHandler
  alias Platform.Canvas.ScriptEngine
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasRoom
  alias Platform.Chat.CanvasRoom.{Event, Record}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Tenancy

  @node "proto"
  @vote "(event, ctx) => { ctx.increment('votes.' + event.args.option) }"

  setup do
    org = Tenancy.get_org_by_slug!("globex")
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Handlers #{n}",
        slug: "handlers-#{n}",
        kind: "channel",
        org_id: org.id
      })

    alice = create_user!(%{name: "Alice"})
    bob = create_user!(%{name: "Bob"})
    author = add_user!(space.id, alice.id)
    add_user!(space.id, bob.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Handlers",
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

    previous = Application.get_env(:platform, ScriptEngine)

    on_exit(fn ->
      CanvasRoom.stop(canvas.id, @node)
      CanvasServer.stop(canvas.id)

      if previous,
        do: Application.put_env(:platform, ScriptEngine, previous),
        else: Application.delete_env(:platform, ScriptEngine)
    end)

    %{
      org: org,
      space: space,
      canvas: canvas,
      alice: alice,
      bob: bob,
      a: actor(alice),
      b: actor(bob)
    }
  end

  defp actor(user), do: %{type: "user", id: user.id, display_name: user.name}

  defp bind!(ctx, name, source) do
    assert {:ok, _} =
             Chat.patch_canvas({:user, ctx.alice.id}, ctx.canvas, [
               {:set_binding, name, %{"kind" => "handler", "engine" => "js", "source" => source}}
             ])
  end

  defp call_async(ctx, actor, name, args \\ %{}) do
    ref = make_ref()
    :ok = CanvasRoom.call_handler(ctx.canvas.id, @node, actor, name, args, {self(), ref})
    ref
  end

  defp await_result(ref, timeout \\ 5_000) do
    assert_receive {:canvas_room_call_result, ^ref, result}, timeout
    result
  end

  # Bounded poll on the canvas pool: returns once `canvas_id` holds `n`
  # slots, flunks at `deadline_ms`.
  defp await_slots_held(canvas_id, n, deadline_ms) do
    until = System.monotonic_time(:millisecond) + deadline_ms
    poll_slots_held(canvas_id, n, until)
  end

  defp poll_slots_held(canvas_id, n, until) do
    held = Platform.CodeMode.Slots.held(Platform.Canvas.ScriptEngine.Slots)

    cond do
      Map.get(held.by_runtime, canvas_id, 0) == n ->
        :ok

      System.monotonic_time(:millisecond) >= until ->
        flunk("canvas #{canvas_id} never held #{n} slot(s); pool: #{inspect(held)}")

      true ->
        Process.sleep(5)
        poll_slots_held(canvas_id, n, until)
    end
  end

  defp call(ctx, actor, name, args \\ %{}),
    do: ctx |> call_async(actor, name, args) |> await_result()

  defp keys(ctx) do
    {:ok, %{state: state}} = CanvasRoom.snapshot(ctx.canvas.id, @node)
    state["keys"]
  end

  defp flushed_events(ctx) do
    :ok = CanvasRoom.stop(ctx.canvas.id, @node)

    case Repo.one(from(r in Record, where: r.canvas_id == ^ctx.canvas.id and r.node_id == ^@node)) do
      nil -> []
      rec -> Repo.all(from(e in Event, where: e.room_id == ^rec.id, order_by: e.seq))
    end
  end

  defp attach_script_run do
    test_pid = self()
    id = "script-run-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:platform, :canvas, :script_run],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:script_run, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "a call" do
    test "a vote handler raises the key and the diff is broadcast to other viewers", ctx do
      bind!(ctx, "vote", @vote)
      ChatPubSub.subscribe_canvas_room(ctx.canvas.id, @node)

      assert {:ok, %{seq: 1, applied: 1}} = call(ctx, ctx.a, "vote", %{"option" => "a"})
      assert {:ok, %{seq: 2, applied: 1}} = call(ctx, ctx.b, "vote", %{"option" => "a"})
      assert {:ok, %{seq: 3}} = call(ctx, ctx.b, "vote", %{"option" => "b"})

      assert_receive {:canvas_room_diff, _, @node, 1, %{"key" => "votes.a", "value" => 1}, aid}
      assert aid == ctx.alice.id
      assert_receive {:canvas_room_diff, _, @node, 3, %{"key" => "votes.b", "value" => 1}, bid}
      assert bid == ctx.bob.id

      assert keys(ctx) == %{"votes.a" => 2, "votes.b" => 1}

      events = flushed_events(ctx)
      assert Enum.map(events, & &1.op["via"]) == List.duplicate("handler:vote", 3)
      assert Enum.map(events, & &1.actor_id) == [ctx.alice.id, ctx.bob.id, ctx.bob.id]
    end

    test "an unknown handler is refused and nothing changes", ctx do
      assert {:error, %{kind: "unknown_handler"}} = call(ctx, ctx.a, "nope")
      assert keys(ctx) == %{}
    end

    test "a plain op landing during a 900 ms handler is not clobbered", ctx do
      Application.put_env(:platform, ScriptEngine, wall_ms: 4_000, max_wall_ms: 5_000)

      bind!(ctx, "slow", """
      (event, ctx) => {
        const end = new Date().getTime() + 900;
        while (new Date().getTime() < end) {}
        ctx.increment('votes');
      }
      """)

      ref = call_async(ctx, ctx.a, "slow")
      Process.sleep(150)

      # The room serves a plain op while the handler is still running.
      assert {:ok, %{seq: 1}} =
               CanvasRoom.apply_op(ctx.canvas.id, @node, ctx.b, %{
                 "type" => "state.set",
                 "key" => "label",
                 "value" => "bob"
               })

      refute_received {:canvas_room_call_result, ^ref, _}

      assert {:ok, %{seq: 2, applied: 1}} = await_result(ref)
      assert keys(ctx) == %{"label" => "bob", "votes" => 1}

      events = flushed_events(ctx)
      assert Enum.map(events, &{&1.seq, &1.op["key"]}) == [{1, "label"}, {2, "votes"}]
      assert [nil, "handler:slow"] = Enum.map(events, & &1.op["via"])
    end

    test "all or nothing: a valid op and an over-cap op change nothing", ctx do
      bind!(ctx, "half", "(e, ctx) => { ctx.set('a', 1); ctx.set('b', 'x'.repeat(20000)) }")
      ChatPubSub.subscribe_canvas_room(ctx.canvas.id, @node)

      assert {:error, %{kind: "too_large", code: "too_large"}} = call(ctx, ctx.a, "half")
      assert keys(ctx) == %{}
      {:ok, %{seq: 0}} = CanvasRoom.snapshot(ctx.canvas.id, @node)
      refute_received {:canvas_room_diff, _, _, _, _, _}
    end

    test "the room runs 4 handlers at once, queues 16 more, then busy", ctx do
      Application.put_env(:platform, ScriptEngine, wall_ms: 4_000, max_wall_ms: 5_000)
      assert ScriptEngine.limits().per_canvas_concurrency == 4

      bind!(ctx, "slow", """
      (e, ctx) => { const end = new Date().getTime() + 600; while (new Date().getTime() < end) {} }
      """)

      bind!(ctx, "noop", "(e, ctx) => { ctx.increment('n') }")

      slow = for _ <- 1..4, do: call_async(ctx, ctx.a, "slow")
      queued = for _ <- 1..16, do: call_async(ctx, ctx.a, "noop")
      over = call_async(ctx, ctx.a, "noop")

      assert {:error, %{kind: "busy"}} = await_result(over, 500)
      for ref <- slow, do: assert({:ok, _} = await_result(ref))
      for ref <- queued, do: assert({:ok, %{applied: 1}} = await_result(ref))
      assert keys(ctx) == %{"n" => 16}
    end

    test "a second handler starts and lands while a 900 ms handler is still running", ctx do
      Application.put_env(:platform, ScriptEngine, wall_ms: 4_000, max_wall_ms: 5_000)

      bind!(ctx, "spin", """
      (e, ctx) => {
        const end = new Date().getTime() + 900;
        while (new Date().getTime() < end) {}
        ctx.increment('spins');
      }
      """)

      bind!(ctx, "vote", @vote)

      # The wasm module is compiled once per node, lazily, into a
      # persistent_term. When this test is the VM's first code-mode run (a
      # shard, or a retry of this test alone), spin and vote each find the
      # cache empty and each run a full cranelift compile; on a 2-vCPU hosted
      # runner with spin's busy loop on one core, vote's compile alone ate the
      # 600 ms below (hosted run 40431360559, first pass and retry). The claim
      # here is concurrency, not cold start, so compile before the clock.
      assert {:ok, _} = Platform.CodeMode.Runtime.compiled()

      spin = call_async(ctx, ctx.a, "spin")
      # Spin is in flight once it holds its canvas slot (held until its run
      # returns), rather than after a guessed sleep.
      await_slots_held(ctx.canvas.id, 1, 600)
      started = System.monotonic_time(:millisecond)
      vote = call_async(ctx, ctx.b, "vote", %{"option" => "a"})

      # The vote returns while spin is still in flight, well inside spin's
      # remaining ~800 ms, and its op takes the first seq.
      assert {:ok, %{seq: 1, applied: 1}} = await_result(vote, 600)
      assert System.monotonic_time(:millisecond) - started < 600
      refute_received {:canvas_room_call_result, ^spin, _}
      assert keys(ctx) == %{"votes.a" => 1}

      assert {:ok, %{seq: 2, applied: 1}} = await_result(spin)
      assert keys(ctx) == %{"votes.a" => 1, "spins" => 1}

      events = flushed_events(ctx)

      assert Enum.map(events, &{&1.seq, &1.op["via"]}) == [
               {1, "handler:vote"},
               {2, "handler:spin"}
             ]
    end

    test "an agent caller's runtime reaches its canvas_patch binding", ctx do
      agent = insert_agent!()
      add_agent!(ctx.space.id, agent.id)
      {runtime, _token} = insert_runtime!(agent, bundles(["canvas"]))

      bind!(
        ctx,
        "rename",
        ~s|(e, ctx) => { ctx.patch([["set_props", "h", {"value": "Renamed"}]]) }|
      )

      agent_actor = %{type: "agent", id: agent.id, display_name: agent.name}

      # Without its runtime the agent is refused, and the code survives.
      assert {:error, %{kind: "forbidden", code: "no_active_runtime"}} =
               call(ctx, agent_actor, "rename")

      assert {:ok, _} = call(ctx, Map.put(agent_actor, :runtime, runtime), "rename")
      {:ok, %{document: doc}} = CanvasServer.describe(ctx.canvas.id)
      assert get_in(doc, ["root", "children", Access.at(1), "props", "value"]) == "Renamed"
    end
  end

  describe "timers" do
    test "after(200, 'tick') fires exactly once", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.after(200, 'tick', {}) }")
      bind!(ctx, "tick", "(e, ctx) => { ctx.increment('ticks') }")

      assert {:ok, %{applied: 0}} = call(ctx, ctx.a, "arm")
      Process.sleep(700)
      assert keys(ctx) == %{"ticks" => 1}
      Process.sleep(500)
      assert keys(ctx) == %{"ticks" => 1}

      events = flushed_events(ctx)
      assert [%{op: %{"via" => "handler:tick"}} = row] = events
      # A fire runs as the actor who scheduled it.
      assert row.actor_id == ctx.alice.id
    end

    test "a timer scheduled and then stopped before it fires produces no row", ctx do
      bind!(ctx, "arm", "(e, ctx) => { ctx.after(400, 'tick', {}) }")
      bind!(ctx, "tick", "(e, ctx) => { ctx.increment('ticks') }")
      attach_script_run()

      assert {:ok, _} = call(ctx, ctx.a, "arm")
      assert_receive {:script_run, _, %{handler: "arm"}}
      :ok = CanvasRoom.stop(ctx.canvas.id, @node)
      Process.sleep(700)

      refute_received {:script_run, _, %{handler: "tick"}}
      assert CanvasRoom.whereis(ctx.canvas.id, @node) == nil
      assert flushed_events(ctx) == []
    end

    test "16 named timers are allowed, the 17th is refused, and every < 1 s is refused", ctx do
      sixteen = Enum.map_join(1..16, "; ", &"ctx.every(60000, 'h#{&1}', {})")
      bind!(ctx, "sixteen", "(e, ctx) => { #{sixteen} }")
      bind!(ctx, "more", "(e, ctx) => { ctx.set('x', 1); ctx.every(60000, 'h17', {}) }")
      bind!(ctx, "again", "(e, ctx) => { ctx.every(60000, 'h1', {}) }")
      bind!(ctx, "fast", "(e, ctx) => { ctx.every(10, 'h1', {}) }")
      bind!(ctx, "drop", "(e, ctx) => { ctx.cancel('h1'); ctx.every(60000, 'h17', {}) }")

      assert {:ok, _} = call(ctx, ctx.a, "sixteen")

      # The 17th refuses the whole run: its op is not applied either.
      assert {:error, %{kind: "too_many_timers"}} = call(ctx, ctx.a, "more")
      assert keys(ctx) == %{}

      # Re-scheduling an existing name replaces it, so it is not a 17th.
      assert {:ok, _} = call(ctx, ctx.a, "again")
      assert {:error, %{kind: "invalid_effect"}} = call(ctx, ctx.a, "fast")

      # A cancel frees a slot in the same run.
      assert {:ok, _} = call(ctx, ctx.a, "drop")
    end
  end

  describe "set_binding is a canvas write" do
    test "a reader-only actor is refused", ctx do
      reader = create_user!()
      plain_member!(reader, ctx.org)

      assert {:ok, _canvas, :org_reader} =
               Platform.Chat.CanvasAccess.fetch_for_viewer(ctx.canvas.id, {:user, reader.id},
                 audit: false
               )

      assert {:error, :forbidden} =
               Chat.patch_canvas({:user, reader.id}, ctx.canvas, [
                 {:set_binding, "vote", %{"kind" => "handler", "source" => @vote}}
               ])

      {:ok, %{document: doc}} = CanvasServer.describe(ctx.canvas.id)
      assert Map.get(doc, "bindings", %{}) == %{}
    end

    test "a 65 KB source and a replace_document with a bad binding are refused", ctx do
      big = "(e, ctx) => {}" <> String.duplicate(" ", 65 * 1024)

      refute match?(
               {:ok, _},
               Chat.patch_canvas({:user, ctx.alice.id}, ctx.canvas, [
                 {:set_binding, "big", %{"kind" => "handler", "source" => big}}
               ])
             )

      {:ok, %{document: doc}} = CanvasServer.describe(ctx.canvas.id)
      bad = Map.put(doc, "bindings", %{"Bad Name" => %{"kind" => "handler", "source" => @vote}})

      refute match?(
               {:ok, _},
               Chat.patch_canvas({:user, ctx.alice.id}, ctx.canvas, [{:replace_document, bad}])
             )

      {:ok, %{document: after_doc}} = CanvasServer.describe(ctx.canvas.id)
      assert Map.get(after_doc, "bindings", %{}) == %{}
    end
  end

  describe "audit" do
    test "the event is registered with the audit handler" do
      assert [:platform, :canvas, :script_run] in TelemetryHandler.events()
    end

    test "one script_run event per run, with the listed metadata and no source or args", ctx do
      bind!(ctx, "vote", @vote)
      attach_script_run()

      assert {:ok, _} = call(ctx, ctx.a, "vote", %{"option" => "secret-arg"})
      assert_receive {:script_run, %{duration_ms: d}, meta}
      refute_received {:script_run, _, _}

      # An ok run has no code: absent, never nil (which the audit handler
      # would persist as the string "nil").
      refute Map.has_key?(meta, :code)

      assert is_integer(d) and d >= 0

      assert %{
               canvas_id: canvas_id,
               node_id: @node,
               handler: "vote",
               script_sha256: sha,
               caller_type: "user",
               caller_id: caller_id,
               engine: "js",
               trigger: "call",
               duration_ms: ^d,
               result: "ok"
             } = meta

      assert canvas_id == ctx.canvas.id
      assert caller_id == ctx.alice.id
      assert sha == :crypto.hash(:sha256, @vote) |> Base.encode16(case: :lower)

      dump = inspect(meta, limit: :infinity, printable_limit: :infinity)
      refute dump =~ "secret-arg"
      refute dump =~ "ctx.increment"

      refute Map.has_key?(meta, :source) or Map.has_key?(meta, :args) or
               Map.has_key?(meta, :state)

      # The handler persisted it too.
      assert [row] =
               Platform.Audit.list(
                 event_type: "platform.canvas.script_run",
                 resource_id: ctx.canvas.id
               )

      assert row.actor_id == ctx.alice.id
      refute Map.has_key?(row.metadata, "code")
      assert row.metadata["result"] == "ok"
    end

    test "a refused binding carries its code into the result and the audit row", ctx do
      bind!(ctx, "mk", "(e, ctx) => suite.call('tasks.create', {title: 'x'})")
      attach_script_run()

      assert {:error, %{kind: "forbidden", code: "binding_not_registered"}} =
               call(ctx, ctx.b, "mk")

      assert_receive {:script_run, _,
                      %{result: "forbidden", code: "binding_not_registered"} = meta}

      assert meta.caller_id == ctx.bob.id
    end

    test "the refusal message reaching the caller carries no sandbox stack trace", ctx do
      bind!(ctx, "mk", "(e, ctx) => suite.call('tasks.create', {title: 'x'})")

      assert {:error, %{kind: "forbidden", code: "binding_not_registered", message: message}} =
               call(ctx, ctx.b, "mk")

      # The check can fire: code mode does append the stack for this error.
      assert {:error, "forbidden", raw} =
               ScriptEngine.run(
                 %{
                   "name" => "mk",
                   "engine" => "js",
                   "source" => "(e, ctx) => suite.call('x', {})"
                 },
                 %{"type" => "call", "args" => %{}},
                 %{"keys" => %{}, "collections" => %{}},
                 %{canvas_id: ctx.canvas.id, actor: ctx.b, now: 0}
               )

      assert raw =~ "\n"
      assert raw =~ "<prelude>"

      assert message != ""
      refute message =~ "\n"
      refute message =~ "<prelude>"
      refute message =~ " at "
      assert byte_size(message) <= 300
    end

    test "refusals before the engine runs are audited too", ctx do
      attach_script_run()
      assert {:error, %{kind: "unknown_handler"}} = call(ctx, ctx.a, "missing")

      assert_receive {:script_run, _,
                      %{result: "unknown_handler", code: "unknown_handler"} = meta}

      refute Map.has_key?(meta, :script_sha256)
    end
  end
end
