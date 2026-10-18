defmodule Platform.Canvas.ScriptEngine.JS do
  @moduledoc """
  The `"js"` canvas handler engine (task 01a1316b-aab0 stage 1), on
  `Platform.CodeMode.Runtime.run/3` directly. Not `Platform.CodeMode.Run`:
  that is `burrow_run`, bound to an `%AgentRuntime{}` and its tool surface. A
  handler runs as whoever clicked, through `Platform.Canvas.ScriptEngine.Bindings`.

  ## A wrapper script, not a new wasm

  The pinned wasm artifact is unchanged. The engine runs a fixed wrapper
  script whose `inputs` are `%{event, state, now, actor, handler}`. The
  wrapper evaluates the handler's source as a strict-mode function
  expression (global `eval`, so the source is data and never spliced into
  the wrapper's text), calls it with `(event, ctx)`, awaits it if it returns
  a Promise, and returns `{ops, effects}`. A handler's own return value is
  ignored.

  `ctx`, frozen:

    * `state` — a deep-frozen copy of the room's state snapshot. Assigning to
      it throws (the handler runs in strict mode).
    * `now` — room time in ms. `Date.now()` is also overridden to return it.
      That is replay hygiene so two runs of one event agree, NOT a security
      boundary: `new Date()` still reads the sandbox clock.
    * `actor` — `{type, id, display_name}`, a copy for display. The principal
      the host acts as is bound host-side and cannot be changed from here.
    * `set(key, value)`, `increment(key, by = 1)`, `add(name, item)`,
      `update(name, id, patch)`, `remove(name, id)` — each pushes one room op
      in `Platform.Chat.CanvasRoom.Ops`'s wire shape.
    * `after(ms, handler, args)`, `every(ms, handler, args)`, `cancel(name)`
      — each pushes one timer effect for the room to apply.
    * `patch(operations)` — `burrow.call('canvas_patch', {operations})`,
      synchronous, on the owning canvas.

  ## What the engine checks

  The handler source is at most 64 KB. The result must be `{ops, effects}`
  with each a list of maps, at most 50 ops and 16 effects, each effect of a
  known type; anything else is `script_error`. Runtime's error kinds pass
  through unchanged, and a run that tripped the binding call limit ends
  `call_limit` even if the handler caught the error.

  ## Slots

  Each run takes a slot in the canvas pool (`Platform.Canvas.ScriptEngine.Slots`,
  a second `Platform.CodeMode.Slots`), keyed by canvas id at
  `per_canvas_concurrency` per canvas and `global_concurrency` per node, and
  never in the agent pool. A refused slot is `{:error, "busy", _}`; nothing
  queues here (the room queues, stage 2).
  """

  @behaviour Platform.Canvas.ScriptEngine

  require Logger

  alias Platform.Canvas.ScriptEngine.Bindings
  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Runtime
  alias Platform.CodeMode.Slots

  @pool Platform.Canvas.ScriptEngine.Slots

  @max_source_bytes 65_536
  @max_ops 50
  @max_effects 16
  @effect_types ~w(after every cancel)

  # The script uses a top-level `return`, so code mode runs it as an async
  # function body (cm.c `compile/4`): its locals are invisible to the
  # handler, which is evaluated in global scope.
  @wrapper """
  'use strict';
  const I = inputs;
  const freeze = (o) => {
    if (o !== null && typeof o === 'object' && !Object.isFrozen(o)) {
      Object.freeze(o);
      for (const k of Object.keys(o)) freeze(o[k]);
    }
    return o;
  };
  const copy = (v) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
  const NOW = I.now;
  Date.now = () => NOW;
  const ops = [];
  const effects = [];
  const op = (o) => { ops.push(o); };
  const effect = (e) => { effects.push(e); };
  const args = (a) => (a === undefined ? {} : a);
  const ctx = Object.freeze({
    state: freeze(copy(I.state)),
    now: NOW,
    actor: freeze(copy(I.actor)),
    set: (key, value) => op({ type: 'state.set', key, value: value === undefined ? null : value }),
    increment: (key, by) => op({ type: 'state.increment', key, by: by === undefined ? 1 : by }),
    add: (name, item) => op({ type: 'collection.add', name, item }),
    update: (name, id, patch) => op({ type: 'collection.update', name, id, patch }),
    remove: (name, id) => op({ type: 'collection.remove', name, id }),
    after: (ms, handler, a) => effect({ type: 'after', ms, handler, args: args(a) }),
    every: (ms, handler, a) => effect({ type: 'every', ms, handler, args: args(a) }),
    cancel: (name) => effect({ type: 'cancel', name }),
    patch: (operations) => burrow.call('canvas_patch', { operations }),
  });
  const fn = (0, eval)('"use strict";\\n(' + I.handler.source + '\\n)');
  if (typeof fn !== 'function') throw new TypeError('a handler must be a function expression');
  await fn(freeze(copy(I.event)), ctx);
  return { ops, effects };
  """

  @doc "The wrapper script every handler runs inside (for tests and docs)."
  def wrapper, do: @wrapper

  @doc "The caps this engine checks."
  def caps,
    do: %{max_source_bytes: @max_source_bytes, max_ops: @max_ops, max_effects: @max_effects}

  @impl true
  def run(handler, event, state, bindings, limits) do
    with {:ok, source} <- source(handler),
         {:ok, canvas_id} <- canvas_id(bindings) do
      case Slots.acquire(@pool, canvas_id, limits) do
        {:ok, slot} -> run_in_slot(slot, source, handler, event, state, bindings, limits)
        {:error, which} -> {:error, "busy", busy_message(which, limits)}
      end
    end
  end

  defp run_in_slot(slot, source, handler, event, state, bindings, limits) do
    counter = Bindings.new_counter()
    host = Bindings.host(Map.merge(bindings, %{limits: limits, counter: counter}))

    inputs = %{
      event: event,
      state: state,
      now: Map.get(bindings, :now) || System.system_time(:millisecond),
      actor: actor_input(Map.get(bindings, :actor)),
      handler: %{name: Map.get(handler, "name"), source: source}
    }

    outcome =
      try do
        Runtime.run(@wrapper, inputs,
          host: host,
          limits: limits,
          wall_ms: Limits.wall_ms(limits, nil),
          on_store: &Slots.attach_store(@pool, slot, &1)
        )
      rescue
        error ->
          Logger.error("[ScriptEngine.JS] sandbox failed: #{inspect(error.__struct__)}")
          {:error, "script_error", "the sandbox failed to run the handler"}
      end

    case outcome do
      {:error, "timeout", _} -> Slots.release_when_idle(@pool, slot)
      _ -> Slots.release(@pool, slot)
    end

    if Bindings.call_limit_tripped?(counter) do
      {:error, "call_limit", "the handler made more than #{limits.max_calls} binding calls"}
    else
      shape(outcome)
    end
  end

  defp shape({:ok, %{result: %{"ops" => ops, "effects" => effects}}})
       when is_list(ops) and is_list(effects) do
    cond do
      length(ops) > @max_ops ->
        script_error("a handler may emit at most #{@max_ops} ops per run")

      length(effects) > @max_effects ->
        script_error("a handler may emit at most #{@max_effects} effects per run")

      not Enum.all?(ops, &op?/1) ->
        script_error("every op must be an object with a string type")

      not Enum.all?(effects, &effect?/1) ->
        script_error("every effect must be an object with type after, every or cancel")

      true ->
        {:ok, ops, effects}
    end
  end

  defp shape({:ok, _other}), do: script_error("a handler run must produce {ops, effects} lists")
  defp shape({:error, kind, message}), do: {:error, kind, message}

  defp op?(%{"type" => type}) when is_binary(type), do: true
  defp op?(_op), do: false

  defp effect?(%{"type" => type}) when type in @effect_types, do: true
  defp effect?(_effect), do: false

  defp source(%{"source" => source}) when is_binary(source) and source != "" do
    if byte_size(source) <= @max_source_bytes,
      do: {:ok, source},
      else: script_error("a handler's source may be at most #{@max_source_bytes} bytes")
  end

  defp source(_handler), do: script_error("a handler needs a non-empty source")

  defp canvas_id(%{canvas_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp canvas_id(_bindings), do: script_error("a handler run needs its owning canvas")

  defp actor_input(%{} = actor) do
    %{
      type: field(actor, :type),
      id: field(actor, :id),
      display_name: field(actor, :display_name)
    }
  end

  defp actor_input(_actor), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp script_error(message), do: {:error, "script_error", message}

  defp busy_message(:runtime_busy, limits),
    do: "this canvas already has #{limits.per_runtime_concurrency} handler runs in flight"

  defp busy_message(:node_busy, limits),
    do: "the node already has #{limits.global_concurrency} canvas handler runs in flight"
end
