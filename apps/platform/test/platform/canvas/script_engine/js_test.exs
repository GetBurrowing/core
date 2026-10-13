defmodule Platform.Canvas.ScriptEngine.JSTest do
  @moduledoc """
  Task 01a1316b-aab0 stage 1: the `"js"` canvas handler engine. A handler
  emits room ops and timer effects through a frozen `ctx`, runs inside the
  canvas budget, and takes its slot from the canvas pool, never the agent
  pool.
  """

  use Platform.DataCase, async: false

  import Platform.CodeModeFixtures

  alias Platform.Canvas.ScriptEngine
  alias Platform.Canvas.ScriptEngine.JS
  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Run
  alias Platform.CodeMode.Slots

  @pool Platform.Canvas.ScriptEngine.Slots
  @now 1_760_000_000_000

  defp handler(source), do: %{"name" => "h", "engine" => "js", "source" => source}

  defp bindings(overrides \\ %{}) do
    Map.merge(
      %{
        canvas_id: Ecto.UUID.generate(),
        actor: %{type: "user", id: Ecto.UUID.generate(), display_name: "Viewer"},
        now: @now
      },
      overrides
    )
  end

  defp event(args \\ %{}), do: %{"type" => "call", "args" => args}

  defp run(source, opts \\ []) do
    ScriptEngine.run(
      handler(source),
      Keyword.get(opts, :event, event()),
      Keyword.get(opts, :state, %{"keys" => %{}, "collections" => %{}}),
      Keyword.get(opts, :bindings, bindings()),
      Keyword.get(opts, :limits, ScriptEngine.limits())
    )
  end

  describe "engine_for/1" do
    test "js is the only engine" do
      assert {:ok, JS} = ScriptEngine.engine_for("js")
      assert {:error, "unknown_engine", _} = ScriptEngine.engine_for("lua")
      assert {:error, "unknown_engine", _} = ScriptEngine.engine_for(nil)

      assert {:error, "unknown_engine", _} =
               ScriptEngine.run(%{handler("1") | "engine" => "lua"}, event(), %{}, bindings())
    end
  end

  describe "limits/0" do
    test "the canvas budget is read at call time over code mode's defaults" do
      limits = ScriptEngine.limits()
      assert limits.wall_ms == 1_000
      assert limits.max_wall_ms == 5_000
      assert limits.memory_bytes == 16 * 1024 * 1024
      assert limits.max_calls == 10
      assert limits.per_runtime_concurrency == 1
      assert limits.global_concurrency == 8
      assert limits.fuel_per_ms == Limits.defaults().fuel_per_ms

      previous = Application.get_env(:platform, ScriptEngine)
      Application.put_env(:platform, ScriptEngine, wall_ms: 250, per_canvas_concurrency: 3)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, ScriptEngine, previous),
          else: Application.delete_env(:platform, ScriptEngine)
      end)

      assert %{wall_ms: 250, per_runtime_concurrency: 3, max_calls: 10} = ScriptEngine.limits()
    end
  end

  describe "ops and effects" do
    test "increment, set and add come back as Ops maps, in order" do
      source = """
      (event, ctx) => {
        ctx.increment('votes.' + event.args.option);
        ctx.set('last', event.args.option);
        ctx.add('log', {by: ctx.actor.display_name});
        ctx.increment('n', 5);
        ctx.update('log', 'x', {seen: true});
        ctx.remove('log', 'y');
        ctx.set('gone');
      }
      """

      assert {:ok, ops, []} = run(source, event: event(%{"option" => "a"}))

      assert ops == [
               %{"type" => "state.increment", "key" => "votes.a", "by" => 1},
               %{"type" => "state.set", "key" => "last", "value" => "a"},
               %{"type" => "collection.add", "name" => "log", "item" => %{"by" => "Viewer"}},
               %{"type" => "state.increment", "key" => "n", "by" => 5},
               %{
                 "type" => "collection.update",
                 "name" => "log",
                 "id" => "x",
                 "patch" => %{"seen" => true}
               },
               %{"type" => "collection.remove", "name" => "log", "id" => "y"},
               %{"type" => "state.set", "key" => "gone", "value" => nil}
             ]

      # The ops apply as is through the room's own pure op set.
      state =
        Enum.reduce(Enum.take(ops, 4), Platform.Chat.CanvasRoom.Ops.empty(), fn op, state ->
          {:ok, state, _diff} = Platform.Chat.CanvasRoom.Ops.apply(state, op, nil)
          state
        end)

      assert state["keys"]["votes.a"] == 1
      assert state["keys"]["n"] == 5
    end

    test "timer effects come back as effects" do
      source =
        "(e, ctx) => { ctx.after(200, 'tick', {a: 1}); ctx.every(1000, 'beat'); ctx.cancel('old') }"

      assert {:ok, [], effects} = run(source)

      assert effects == [
               %{"type" => "after", "ms" => 200, "handler" => "tick", "args" => %{"a" => 1}},
               %{"type" => "every", "ms" => 1000, "handler" => "beat", "args" => %{}},
               %{"type" => "cancel", "name" => "old"}
             ]
    end

    test "an async handler is awaited" do
      source = "async (e, ctx) => { await Promise.resolve(); ctx.increment('k') }"
      assert {:ok, [%{"type" => "state.increment", "key" => "k"}], []} = run(source)
    end

    test "ctx.now and Date.now() are the injected room time" do
      source = "(e, ctx) => { ctx.set('now', ctx.now); ctx.set('date', Date.now()) }"

      assert {:ok, [%{"value" => @now}, %{"value" => @now}], []} = run(source)
    end

    test "ctx.state is the snapshot, deep-frozen" do
      state = %{"keys" => %{"votes" => %{"a" => 3}}, "collections" => %{}}

      assert {:ok, [%{"value" => 3}], []} =
               run("(e, ctx) => { ctx.set('seen', ctx.state.keys.votes.a) }", state: state)

      assert {:error, "script_error", message} =
               run("(e, ctx) => { ctx.state.keys.votes.a = 99 }", state: state)

      assert message =~ "TypeError"

      assert {:error, "script_error", _} =
               run("(e, ctx) => { ctx.state.keys.extra = 1 }", state: state)

      assert {:error, "script_error", _} = run("(e, ctx) => { ctx.set = null }", state: state)
    end

    test "the wrapper's own ops list is not reachable from the handler" do
      assert {:ok, [], []} = run("(e, ctx) => { if (typeof ops !== 'undefined') ops.push(1) }")
    end
  end

  describe "malformed handlers and results" do
    test "a source that is not a function expression is script_error" do
      assert {:error, "script_error", _} = run("42")
      assert {:error, "script_error", _} = run("(e, ctx) => {")
    end

    test "a missing or oversized source is script_error" do
      assert {:error, "script_error", _} = run("")

      big = "(e, ctx) => {}" <> String.duplicate(" ", 65_536)
      assert {:error, "script_error", message} = run(big)
      assert message =~ "65536"
    end

    test "51 ops is script_error; 50 is fine" do
      assert {:ok, ops, []} =
               run("(e, ctx) => { for (let i = 0; i < 50; i++) ctx.increment('k') }")

      assert length(ops) == 50

      assert {:error, "script_error", message} =
               run("(e, ctx) => { for (let i = 0; i < 51; i++) ctx.increment('k') }")

      assert message =~ "50 ops"
    end

    test "17 effects is script_error" do
      assert {:error, "script_error", message} =
               run("(e, ctx) => { for (let i = 0; i < 17; i++) ctx.cancel('t' + i) }")

      assert message =~ "16 effects"
    end

    test "a handler that throws is script_error" do
      assert {:error, "script_error", message} = run("(e, ctx) => { throw new Error('nope') }")
      assert message =~ "nope"
    end

    test "monkey-patching a builtin cannot forge the result shape" do
      # Replacing Array.prototype.push still leaves the wrapper's lists
      # lists; what the engine checks is the shape that comes back.
      source = "(e, ctx) => { Array.prototype.push = function () { this.length = 0; return 0 } }"
      assert {:ok, [], []} = run(source)
    end
  end

  describe "limits" do
    test "while(true){} is fuel or timeout within the canvas wall limit plus grace" do
      started = System.monotonic_time(:millisecond)
      assert {:error, kind, _} = run("(e, ctx) => { while (true) {} }")
      elapsed = System.monotonic_time(:millisecond) - started

      assert kind in ["fuel", "timeout"]
      # wall_ms 1_000 plus the 500 ms native grace, plus slack for setup.
      assert elapsed < 1_000 + 500 + 1_000
      # A timed-out slot frees once its Store is idle, not at once.
      wait_until(fn -> Slots.held(@pool).total == 0 end, 5_000)
    end

    test "a 24 MB allocation is stopped at the canvas 16 MB memory limit" do
      source =
        "(e, ctx) => { const a = []; for (let i = 0; i < 3; i++) a.push(new Float64Array(1e6)); ctx.set('n', a.length) }"

      assert {:error, "memory", _} = run(source)

      # The same allocation fits the agent budget, so the cap is the canvas one.
      assert {:ok, [%{"value" => 3}], []} =
               run(source, limits: %{ScriptEngine.limits() | memory_bytes: 64 * 1024 * 1024})
    end
  end

  describe "the canvas slot pool" do
    test "a run holds a canvas slot while it runs and frees it after" do
      canvas_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          run("(e, ctx) => { while (true) {} }", bindings: bindings(%{canvas_id: canvas_id}))
        end)

      # The check can fire: the pool reads 1 for this canvas mid-run, and the
      # agent pool reads nothing for it.
      wait_until(fn -> Slots.held(@pool).by_runtime[canvas_id] == 1 end, 5_000)
      assert Slots.held().by_runtime[canvas_id] == nil
      assert {:error, kind, _} = Task.await(task, 10_000)
      assert kind in ["fuel", "timeout"]
      wait_until(fn -> Slots.held(@pool).by_runtime[canvas_id] == nil end, 5_000)
    end

    test "a second concurrent handler on one canvas is busy" do
      canvas_id = Ecto.UUID.generate()
      b = bindings(%{canvas_id: canvas_id})

      task = Task.async(fn -> run("(e, ctx) => { while (true) {} }", bindings: b) end)
      wait_until(fn -> Slots.held(@pool).by_runtime[canvas_id] == 1 end, 5_000)

      assert {:error, "busy", message} = run("(e, ctx) => {}", bindings: b)
      assert message =~ "canvas"

      # Another canvas is not affected.
      assert {:ok, [], []} = run("(e, ctx) => {}")
      Task.await(task, 10_000)
    end

    test "with every agent slot held, a canvas run still runs" do
      limits = Limits.get()

      held =
        for i <- 1..limits.global_concurrency do
          {:ok, slot} = Slots.acquire("agent-hold-#{i}-#{u()}", limits)
          slot
        end

      on_exit(fn -> Enum.each(held, &Slots.release/1) end)

      assert %{total: total} = Slots.held()
      assert total == limits.global_concurrency
      assert {:error, :node_busy} = Slots.acquire("one-more-#{u()}", limits)

      assert {:ok, [%{"type" => "state.increment"}], []} = run("(e, ctx) => ctx.increment('k')")
      assert Slots.held().total == limits.global_concurrency
      assert Slots.held(@pool).total == 0
    end

    test "with every canvas slot held, an agent suite_run still runs" do
      limits = ScriptEngine.limits()

      held =
        for _ <- 1..limits.global_concurrency do
          {:ok, slot} = Slots.acquire(@pool, Ecto.UUID.generate(), limits)
          slot
        end

      on_exit(fn -> Enum.each(held, &Slots.release(@pool, &1)) end)

      assert Slots.held(@pool).total == limits.global_concurrency
      assert {:error, "busy", _} = run("(e, ctx) => {}")

      {runtime, _token} = insert_runtime!(insert_agent!(), bundles(["code_mode"]))
      assert {:ok, %{ok: true, result: 2}} = Run.execute(runtime, "1 + 1")
      assert Slots.held().total == 0
    end
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
        true -> Process.sleep(25) && nil
      end
    end)
    |> Enum.find(& &1)
  end
end
