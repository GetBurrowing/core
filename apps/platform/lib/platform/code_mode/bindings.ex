defmodule Platform.CodeMode.Bindings do
  @moduledoc """
  What a `burrow_run` script can call, and how each call is carried out
  (task 01a114a8 stage 2).

  ## The surface is the runtime's own

  `tool_names/1` is `ToolAuthorization.effective_tools/1` minus `burrow_run`
  itself: a script sees exactly the tools its runtime may call over `/mcp`
  (an external principal's chat allowlist included), bound on `burrow` by
  name (`burrow.canvas_create`, `burrow.task_get`), plus the generic
  `burrow.call(name, args)`. The global `suite` is the same object (task
  01a14b9e-50a4 stage 1), so `suite === burrow` and a script written against
  `suite.task_get` keeps working. The legacy name of a held tool is bound
  too and a dotted one nests (`burrow.canvas.create`, task 01a14a7f stage 3);
  it is never listed by `burrow_run_describe`.

  ## Every call is a federated tool call

  `host/1` builds the function `Platform.CodeMode.Runtime` calls for each
  `burrow.host_call`. A tool call:

    1. counts against `max_calls`; past it the call is refused with kind
       `call_limit` and the whole run ends `call_limit` even if the script
       catches the error;
    2. RELOADS the runtime row (`Federation.get_runtime/1`), the posture of
       `RuntimeChannel`'s tool path, so a grant revoked mid-run takes effect
       on the next call;
    3. runs `Platform.Federation.ToolCall.invoke/4` with
       `parent_run_id: run_id`: `ToolAuthorization.authorize/2`, the argument
       gate, the handler and a ledger row. There is no second authorization
       path here to drift from the transports.

  A nested run is refused before `invoke/4` (and ledgered as denied), under
  EITHER name: `burrow_run` or its legacy alias `suite_run`.
  `$store.get / set / delete` go to `Platform.CodeMode.Store`, are not tool
  calls and are not ledgered.

  Results reach the script as the handler's data made JSON-safe
  (`Platform.Federation.Jsonable`), each capped at `inner_result_bytes`.
  Nothing here logs a name's arguments or a result.
  """

  alias Platform.CodeMode.Store
  alias Platform.Federation
  alias Platform.Federation.Jsonable
  alias Platform.Federation.McpContent
  alias Platform.Federation.ToolAliases
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolCall
  alias Platform.Federation.ToolCallLedger

  @self_tools ~w(burrow_run suite_run)

  @doc """
  Names a script may call: the runtime's effective tools minus burrow_run,
  then the legacy name of every one of them that has one (task 01a14a7f
  stage 3), so `burrow.canvas.create(...)` keeps resolving. The
  prelude nests a dotted name; a call through it reaches `ToolCall.invoke/4`
  under that name, which resolves the alias and authorizes the canonical.
  """
  @spec tool_names(struct()) :: [String.t()]
  def tool_names(runtime) do
    names =
      runtime
      |> ToolAuthorization.tool_names()
      |> Enum.reject(&(&1 in @self_tools))

    held = MapSet.new(names)

    legacy =
      for {legacy, canonical} <- Enum.sort(ToolAliases.aliases()),
          MapSet.member?(held, canonical),
          do: legacy

    names ++ legacy
  end

  @doc """
  The host function for one run. `run` carries `:runtime_pk` (the runtime
  row's id), `:run_id`, `:agent_id`, `:store_scope`, `:limits`,
  `:counter` (an `:atomics` ref of 3: tool calls, store ops, call-limit
  tripped) and optionally `:attribution_hints` (the `task_id` / `stage_id` /
  `plan_id` from the run's `inputs`, used for an inner call that names none
  of its own).
  """
  @spec host(map()) :: (String.t(), String.t() -> String.t())
  def host(run), do: fn name, args_json -> handle(name, args_json, run) end

  @doc "A fresh counter for `host/1`."
  def new_counter, do: :atomics.new(3, signed: false)

  @doc """
  Inner tool calls a run made: one per ledger row carrying its
  `parent_run_id` (ok, error and denied). Calls refused at the call limit
  never reach the ledger and are not counted.
  """
  def calls(counter), do: :atomics.get(counter, 1)

  @doc "Did the run hit its call limit?"
  def call_limit_tripped?(counter), do: :atomics.get(counter, 3) == 1

  defp handle("$store." <> op, args_json, run) do
    if :atomics.add_get(run.counter, 2, 1) > run.limits.max_store_ops do
      fail("call_limit", "the run made more than #{run.limits.max_store_ops} store operations")
    else
      with {:ok, args} <- decode(args_json) do
        store(op, args, run)
      end
    end
  end

  defp handle(name, _args_json, run) when name in @self_tools do
    :atomics.add(run.counter, 1, 1)
    record_denied(name, run)
    fail("forbidden", "#{name} cannot be called from inside burrow_run")
  end

  defp handle(name, args_json, run) do
    if :atomics.add_get(run.counter, 1, 1) > run.limits.max_calls do
      :atomics.put(run.counter, 3, 1)
      :atomics.sub(run.counter, 1, 1)
      fail("call_limit", "the run made more than #{run.limits.max_calls} tool calls")
    else
      with {:ok, args} <- decode(args_json) do
        invoke(name, args, run)
      end
    end
  end

  defp invoke(name, args, run) do
    case Federation.get_runtime(run.runtime_pk) do
      %{status: "active"} = runtime ->
        name
        |> ToolCall.invoke(args, runtime,
          parent_run_id: run.run_id,
          attribution_hints: Map.get(run, :attribution_hints, %{})
        )
        |> respond(name, run)

      _gone ->
        fail("forbidden", "this runtime is no longer active")
    end
  rescue
    error -> fail("tool_error", "#{name} raised #{inspect(error.__struct__)}")
  end

  defp respond({:ok, data}, name, run) do
    case Jason.encode(%{ok: true, data: data |> McpContent.strip() |> Jsonable.encodable()}) do
      {:ok, json} when byte_size(json) <= run.limits.inner_result_bytes ->
        json

      {:ok, _json} ->
        fail(
          "result_too_large",
          "#{name}'s result exceeds #{run.limits.inner_result_bytes} bytes; narrow the call"
        )

      {:error, _} ->
        fail("tool_error", "#{name}'s result could not be encoded as JSON")
    end
  end

  defp respond({:error, :forbidden}, name, _run),
    do: fail("forbidden", ToolAuthorization.deny_message(name))

  defp respond({:error, reason}, _name, _run) do
    envelope = Jsonable.error_envelope(reason)

    Jason.encode!(%{
      ok: false,
      kind: "tool_error",
      message: Map.get(envelope, :error),
      code: Map.get(envelope, :code),
      details: Map.drop(envelope, [:error, :code])
    })
  end

  defp store("get", %{"key" => key}, run) when is_binary(key) do
    {:ok, json} = Store.get(run.agent_id, run.store_scope, key)
    ~s({"ok":true,"data":) <> (json || "null") <> "}"
  end

  defp store("set", %{"key" => key} = args, run) when is_binary(key) do
    ttl_ms =
      case Map.get(args, "ttl") do
        seconds when is_integer(seconds) and seconds > 0 -> seconds * 1000
        _ -> nil
      end

    with {:ok, json} <- Jason.encode(Map.get(args, "value")),
         :ok <- Store.set(run.agent_id, run.store_scope, key, json, ttl_ms) do
      ~s({"ok":true,"data":true})
    else
      {:error, code, message} -> fail("store_error", message, code)
      {:error, _} -> fail("store_error", "the value is not JSON-encodable")
    end
  end

  defp store("delete", %{"key" => key}, run) when is_binary(key) do
    :ok = Store.delete(run.agent_id, run.store_scope, key)
    ~s({"ok":true,"data":true})
  end

  defp store(_op, _args, _run), do: fail("invalid_args", "store keys are strings")

  defp decode(args_json) do
    case Jason.decode(args_json) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _ -> fail("invalid_args", "arguments must be a JSON object")
    end
  end

  defp fail(kind, message, code \\ nil),
    do: Jason.encode!(%{ok: false, kind: kind, message: message, code: code})

  defp record_denied(name, run) do
    ToolCallLedger.record(%{
      tool: name,
      status: "denied",
      duration_ms: 0,
      result_bytes: nil,
      runtime_id: run.runtime_id,
      agent_id: run.agent_id,
      parent_run_id: run.run_id,
      hints: %{}
    })
  end
end
