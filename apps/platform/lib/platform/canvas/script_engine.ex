defmodule Platform.Canvas.ScriptEngine do
  @moduledoc """
  The pluggable engine behind canvas room handlers (task 01a1316b-aab0
  stage 1): a handler is a small program stored on a canvas that runs when a
  viewer calls it, and an engine is what runs it.

  `engine_for/1` maps a binding's `"engine"` tag to a module. v1 has exactly
  one, `"js"` (`Platform.Canvas.ScriptEngine.JS`, on code mode's QuickJS
  sandbox). Anything else is `{:error, "unknown_engine", _}`; there is no
  stub for a second engine.

  ## The contract

      run(handler, event, state, bindings, limits)
        :: {:ok, [room_op], [effect]} | {:error, kind, message}

    * `handler` — `%{"name" => name, "source" => source, "engine" => tag}`,
      the binding as stored on the canvas.
    * `event` — the string-keyed event the handler receives
      (`%{"type" => "call", "args" => map}`).
    * `state` — a snapshot of the room's state (`Platform.Chat.CanvasRoom.Ops`
      shape). The handler reads it; it cannot write it.
    * `bindings` — the invocation the host bindings are bound to, fixed
      host-side: `:canvas_id` (the OWNING canvas), `:actor` (the room's
      `%{type, id, display_name}`, from the caller's session), `:now` (room
      time in ms) and, for an agent actor, `:runtime` (its `%AgentRuntime{}`).
      See `Platform.Canvas.ScriptEngine.Bindings`.
    * `limits` — `limits/0` unless the caller narrows it.

  ## Why a list of ops, not a new state

  A handler returns ROOM OPS, in the exact string-keyed shape
  `Platform.Chat.CanvasRoom.Ops.apply/3` takes, and the room applies them to
  its CURRENT state. Three reasons: a handler runs off the room process, so
  other viewers' plain ops can land while it runs and a returned whole state
  would silently clobber them; ops go through the same caps and the same
  append-only event log as a frame op, so a handler can never write anything
  a viewer could not; and any future engine returns the same list. This
  deviates from the task text's `{:ok, new_state, effects}`.

  An `effect` is `%{"type" => "after" | "every" | "cancel", ...}`: a timer
  request the room applies (stage 2), never something the engine does.

  `kind` is code mode's (`timeout`, `memory`, `fuel`, `output_limit`,
  `script_error`, `forbidden`, `call_limit`), passed through unchanged, plus
  `busy` (the canvas pool refused a slot) and `unknown_engine`.

  ## Experiment surface

  The per-handler budget is read at CALL time, never as a module attribute:

      config :platform, Platform.Canvas.ScriptEngine,
        wall_ms: 1_000,
        max_wall_ms: 5_000,
        memory_bytes: 16 * 1024 * 1024,
        max_calls: 10,
        per_canvas_concurrency: 1,
        global_concurrency: 8

  `limits/0` merges that over the defaults above, and those over
  `Platform.CodeMode.Limits.defaults/0` (fuel per ms, log and result caps).
  The measured outcome is handler p95 duration and the share of runs ending
  `fuel` / `timeout` / `memory`, against how long a room's handler queue
  waits.
  """

  alias Platform.CodeMode.Limits

  @type room_op :: %{required(String.t()) => term()}
  @type effect :: %{required(String.t()) => term()}
  @type outcome :: {:ok, [room_op()], [effect()]} | {:error, String.t(), String.t()}

  @callback run(
              handler :: map(),
              event :: map(),
              state :: map(),
              bindings :: map(),
              limits :: map()
            ) :: outcome()

  @canvas_keys [
    :wall_ms,
    :max_wall_ms,
    :memory_bytes,
    :max_calls,
    :per_canvas_concurrency,
    :global_concurrency
  ]

  @doc "The engine module for a binding's `\"engine\"` tag."
  @spec engine_for(term()) :: {:ok, module()} | {:error, String.t(), String.t()}
  def engine_for("js"), do: {:ok, Platform.Canvas.ScriptEngine.JS}

  def engine_for(tag),
    do: {:error, "unknown_engine", "no script engine is registered for #{inspect(tag)}"}

  @doc """
  Run `handler` on the engine its `"engine"` tag names (default `"js"`).
  """
  @spec run(map(), map(), map(), map(), map()) :: outcome()
  def run(handler, event, state, bindings, limits \\ limits()) do
    with {:ok, engine} <- engine_for(Map.get(handler, "engine", "js")) do
      engine.run(handler, event, state, bindings, limits)
    end
  end

  @doc "The canvas defaults, before app env."
  @spec defaults() :: map()
  def defaults do
    %{
      wall_ms: 1_000,
      max_wall_ms: 5_000,
      memory_bytes: 16 * 1024 * 1024,
      max_calls: 10,
      per_canvas_concurrency: 1,
      global_concurrency: 8
    }
  end

  @doc """
  The effective handler limits: app env (`config :platform,
  Platform.Canvas.ScriptEngine`) over `defaults/0` over
  `Platform.CodeMode.Limits.defaults/0`. Read at call time.

  The result is a code mode limits map, so `Platform.CodeMode.Runtime` and
  `Platform.CodeMode.Slots` take it as is: `per_canvas_concurrency` is also
  written as `per_runtime_concurrency`, the key the pool's per-key cap reads.
  """
  @spec limits() :: Limits.t()
  def limits do
    overrides =
      :platform
      |> Application.get_env(__MODULE__, [])
      |> Map.new()
      |> Map.take(@canvas_keys)

    canvas = Map.merge(defaults(), overrides)

    Limits.defaults()
    |> Map.merge(canvas)
    |> Map.put(:per_runtime_concurrency, canvas.per_canvas_concurrency)
  end
end
