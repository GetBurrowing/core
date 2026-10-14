defmodule Platform.CodeMode.Run do
  @moduledoc """
  `suite_run`: run an agent-written JavaScript program against the agent's
  own tool surface (task 01a114a8 stage 2, `code_mode` bundle).

      suite_run {script, inputs?, session?, timeout_ms?}
        -> {ok: true, result, logs, logs_truncated, calls, run_id, elapsed_ms}
         | {ok: false, error: {kind, message}, logs, calls, run_id, elapsed_ms}

  `kind` is one of `timeout`, `memory`, `fuel`, `call_limit`,
  `output_limit`, `script_error`, `forbidden`.

  The script is QuickJS-ng global code with top-level `await`; its last
  expression is the result (a script that uses `return` is run as an async
  function body instead). Tool calls are synchronous: `suite.task_get({...})`
  returns the data or throws a `SuiteError` with `kind`, `code` and
  `message`. There are no timers, no `fetch`, no modules and no filesystem.

  Pieces: `Platform.CodeMode.Runtime` (the wasm sandbox), `Bindings` (what a
  script may call, each call through `ToolCall.invoke/4`), `Limits`,
  `Slots` (concurrency) and `Store` (`store.get/set/delete`).

  ## What is recorded

  The run's own ledger row (written by `ToolCall.invoke/4` for the outer
  `suite_run` call) has the run's id, the script's sha256 and its byte
  length; every inner call's row carries `parent_run_id = run_id`. The
  script, its inputs and its result are never persisted or logged. The one
  log line per run names the run id, runtime, outcome kind, call count and
  elapsed time.
  """

  require Logger

  alias Platform.CodeMode.Bindings
  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Runtime
  alias Platform.CodeMode.Slots
  alias Platform.Federation

  @max_script_bytes 262_144
  @max_session_bytes 128

  @error_kinds ~w(timeout memory fuel call_limit output_limit script_error forbidden)

  @doc """
  Every `kind` a failed run reports in `{ok: false, error: {kind, message}}`
  (task 01a115b5 stage 1). The ledger's `error_kind` column admits exactly
  these values, so it holds an enumerated kind and never an error message.
  """
  @spec error_kinds() :: [String.t()]
  def error_kinds, do: @error_kinds

  @doc "The `suite_run` tool handler (`ToolSurface.execute/3`)."
  @spec run_tool(map(), map()) :: {:ok, map()} | {:error, map()}
  def run_tool(args, context) do
    with {:ok, script} <- script_arg(args),
         {:ok, session} <- session_arg(args),
         {:ok, runtime} <- runtime_for(context) do
      execute(runtime, script,
        inputs: Map.get(args, "inputs"),
        session: session,
        timeout_ms: Map.get(args, "timeout_ms"),
        run_id: Map.get(context, :tool_call_id)
      )
    end
  end

  @doc """
  Run `script` as `runtime` (an `%AgentRuntime{}`). Options: `:inputs`,
  `:session`, `:timeout_ms`, `:run_id` (default a fresh UUIDv7),
  `:limits`.
  """
  @spec execute(struct(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def execute(runtime, script, opts \\ []) do
    limits = Keyword.get_lazy(opts, :limits, &Limits.get/0)
    run_id = Keyword.get(opts, :run_id) || Platform.Types.UUIDv7.generate()

    case Slots.acquire(runtime.runtime_id, limits) do
      {:ok, slot} ->
        run_in_slot(runtime, script, slot, run_id, limits, opts)

      {:error, which} ->
        {:error,
         %{
           error: busy_message(which, limits),
           code: "concurrency_limit",
           recoverable: true,
           suggestion: "wait for a running suite_run to finish, then retry"
         }}
    end
  end

  defp run_in_slot(runtime, script, slot, run_id, limits, opts) do
    started = System.monotonic_time(:millisecond)
    counter = Bindings.new_counter()

    host =
      Bindings.host(%{
        runtime_pk: runtime.id,
        runtime_id: runtime.runtime_id,
        agent_id: runtime.agent_id,
        run_id: run_id,
        store_scope: store_scope(runtime, Keyword.get(opts, :session)),
        limits: limits,
        counter: counter,
        attribution_hints: input_hints(Keyword.get(opts, :inputs))
      })

    outcome =
      try do
        Runtime.run(script, Keyword.get(opts, :inputs),
          host: host,
          tools: Bindings.tool_names(runtime),
          limits: limits,
          wall_ms: Limits.wall_ms(limits, Keyword.get(opts, :timeout_ms)),
          on_store: &Slots.attach_store(slot, &1)
        )
      rescue
        error ->
          Logger.error("[CodeMode] run=#{run_id} sandbox failed: #{inspect(error.__struct__)}")
          {:error, "script_error", "the sandbox failed to run the script"}
      end

    # A timed-out run's Store may still be finishing an interrupted call.
    case outcome do
      {:error, "timeout", _} -> Slots.release_when_idle(slot)
      _ -> Slots.release(slot)
    end

    outcome =
      if Bindings.call_limit_tripped?(counter), do: call_limit(outcome, limits), else: outcome

    elapsed = System.monotonic_time(:millisecond) - started
    calls = Bindings.calls(counter)

    Logger.info(
      "[CodeMode] suite_run run=#{run_id} runtime=#{runtime.runtime_id} " <>
        "outcome=#{kind(outcome)} calls=#{calls} elapsed=#{elapsed}ms"
    )

    {:ok, body(outcome) |> Map.merge(%{calls: calls, run_id: run_id, elapsed_ms: elapsed})}
  end

  @doc """
  Evaluate `script` with no tools bound and no slot taken: the smoke check
  that the NIF loads and the artifact runs (`Platform.CodeMode.Run.eval("1+1")`
  in ci.yml's image smoke step, where no application is started). Returns
  `{:ok, result}` or `{:error, kind, message}`.
  """
  @spec eval(String.t(), keyword()) :: {:ok, term()} | {:error, String.t(), String.t()}
  def eval(script, opts \\ []) do
    case Runtime.run(script, Keyword.get(opts, :inputs), Keyword.delete(opts, :inputs)) do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, kind, message} -> {:error, kind, message}
    end
  end

  defp body({:ok, %{result: result, logs: logs, logs_truncated: truncated}}),
    do: %{ok: true, result: result, logs: logs, logs_truncated: truncated}

  defp body({:error, kind, message}),
    do: %{ok: false, error: %{kind: kind, message: message}}

  defp kind({:ok, _}), do: "ok"
  defp kind({:error, kind, _}), do: kind

  # The script hit the call limit: the run ends call_limit whatever the
  # script did with the error.
  defp call_limit(_outcome, limits),
    do: {:error, "call_limit", "the run made more than #{limits.max_calls} tool calls"}

  defp script_arg(%{"script" => script}) when is_binary(script) and script != "" do
    if byte_size(script) <= @max_script_bytes,
      do: {:ok, script},
      else: invalid("script_too_large", "a script may be #{@max_script_bytes} bytes")
  end

  defp script_arg(_args), do: invalid("missing_script", "suite_run needs a non-empty `script`")

  defp session_arg(%{"session" => session}) when is_binary(session) do
    if session != "" and byte_size(session) <= @max_session_bytes,
      do: {:ok, session},
      else: invalid("invalid_session", "a session is 1..#{@max_session_bytes} bytes")
  end

  defp session_arg(%{"session" => nil}), do: {:ok, nil}
  defp session_arg(%{"session" => _}), do: invalid("invalid_session", "a session is a string")
  defp session_arg(_args), do: {:ok, nil}

  defp runtime_for(%{runtime_id: runtime_id}) when is_binary(runtime_id) do
    case Federation.get_runtime_by_runtime_id(runtime_id) do
      nil -> invalid("unknown_runtime", "the calling runtime was not found")
      runtime -> {:ok, runtime}
    end
  end

  defp runtime_for(_context), do: invalid("unknown_runtime", "suite_run needs a calling runtime")

  # Task 01a114a8 stage 4: the ids in `inputs` attribute every inner call
  # that names no task of its own. Only the id keys are read.
  defp input_hints(%{} = inputs),
    do: Platform.Federation.ToolCallLedger.attribution_hints(inputs)

  defp input_hints(_inputs), do: %{}

  defp store_scope(_runtime, session) when is_binary(session), do: "session:" <> session
  defp store_scope(runtime, nil), do: "runtime:" <> runtime.runtime_id

  defp busy_message(:runtime_busy, limits),
    do: "this runtime already has #{limits.per_runtime_concurrency} suite_run calls running"

  defp busy_message(:node_busy, limits),
    do: "the node already has #{limits.global_concurrency} suite_run calls running"

  defp invalid(code, message),
    do: {:error, %{error: message, code: code, recoverable: true}}
end
