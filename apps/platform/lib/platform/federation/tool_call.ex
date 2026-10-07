defmodule Platform.Federation.ToolCall do
  @moduledoc """
  THE path a federated tool call takes from an authenticated runtime to a
  handler (task 01a114a8 stage 1).

      invoke(name, args, runtime, opts)
        = ToolAuthorization.authorize/2
          -> build_context/2
          -> ToolArguments.dispatch/3
          -> ToolCallLedger.record/1

  Both federation transports call it: `PlatformWeb.MCPController`
  (`tools/call`) and `PlatformWeb.RuntimeChannel` (`tool_call`). Stage 2's
  `suite_run` inner calls call it too, with `parent_run_id:` set. One path
  means authorization is structural for every caller, not a copy each
  caller has to remember.

  ## What this module does NOT do

  It does not frame a refusal. `{:error, :forbidden}` is returned as a value
  and each transport keeps its own wire shape for it: JSON-RPC `-32001` on
  `/mcp`, a `tool_result` frame with `status: "error"` on the socket. The
  `ToolArguments` moduledoc calls those shapes load-bearing.
  `{:error, :forbidden}` comes ONLY from the authorization step. A handler
  that itself returns the bare atom `:forbidden` gets it wrapped as a
  `%{error, code: "forbidden"}` map, so a transport cannot mistake it for a
  capability denial.

  It does not log. The transports keep their existing log lines.

  ## The ledger

  Every call, whether ok, error or denied, writes one `dispatch_tool_calls`
  row through `Platform.Federation.ToolCallLedger.record/1`. The row holds the
  tool NAME, status, duration, a size figure and the attribution. It never
  holds argument values, result values or secrets. The write never raises
  into the call and never changes its result (ADR-0048 posture). See
  `ToolCallLedger`.
  """

  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolCallLedger

  @type result :: {:ok, term()} | {:error, :forbidden} | {:error, term()}

  @doc """
  Authorize, execute and record one tool call.

  Options:

    * `:parent_run_id` — the `suite_run` run this call is an inner call of
      (stage 2). Absent for a model-issued call.
    * `:attribution_hints` — ids to attribute the call by when its own args
      carry no `task_id`, `stage_id` or `plan_id` (task 01a114a8 stage 4).
      `suite_run` passes the ids from its `inputs` for every inner call. A
      `suite_run` call itself is attributed by its `inputs` the same way.

  Every call gets a fresh UUIDv7 that is both its ledger row's id and
  `context.tool_call_id` for the handler. `suite_run` uses it as its
  `run_id`, so the run's own row and its inner calls' `parent_run_id` are
  the same value.
  """
  @spec invoke(String.t(), map(), AgentRuntime.t(), keyword()) :: result()
  def invoke(name, args, %AgentRuntime{} = runtime, opts \\ [])
      when is_binary(name) and is_map(args) do
    started = System.monotonic_time(:millisecond)
    call_id = Platform.Types.UUIDv7.generate()

    case ToolAuthorization.authorize(name, runtime) do
      :ok ->
        context = args |> build_context(runtime) |> Map.put(:tool_call_id, call_id)
        result = name |> ToolArguments.dispatch(args, context) |> normalize()
        record(call_id, name, args, runtime, opts, started, result)
        result

      {:error, :forbidden} ->
        record(call_id, name, args, runtime, opts, started, :denied)
        {:error, :forbidden}
    end
  end

  @doc """
  The handler context for `args` from `runtime`. Moved here from
  `MCPController` so both transports build it the same way.
  """
  @spec build_context(map(), AgentRuntime.t()) :: map()
  def build_context(args, %AgentRuntime{} = runtime) do
    space_id = Map.get(args, "space_id")

    %{
      space_id: space_id,
      agent_id: runtime.agent_id,
      agent_participant_id: lookup_participant(space_id, runtime.agent_id),
      runtime_id: runtime.runtime_id
    }
  end

  defp lookup_participant(nil, _agent_id), do: nil
  defp lookup_participant(_space_id, nil), do: nil

  defp lookup_participant(space_id, agent_id) do
    case Chat.get_agent_participant(space_id, agent_id) do
      %Chat.Participant{id: id} -> id
      _ -> nil
    end
  end

  defp normalize({:ok, _data} = ok), do: ok

  defp normalize({:error, :forbidden}),
    do: {:error, %{error: "forbidden", code: "forbidden", recoverable: false}}

  defp normalize({:error, _reason} = error), do: error
  defp normalize(other), do: {:error, other}

  defp record(call_id, name, args, runtime, opts, started, outcome) do
    {status, result_bytes} =
      case outcome do
        :denied -> {"denied", nil}
        {:ok, data} -> {"ok", term_size(data)}
        {:error, reason} -> {"error", term_size(reason)}
      end

    entry = %{
      id: call_id,
      tool: name,
      status: status,
      duration_ms: System.monotonic_time(:millisecond) - started,
      result_bytes: result_bytes,
      runtime_id: runtime.runtime_id,
      agent_id: runtime.agent_id,
      parent_run_id: Keyword.get(opts, :parent_run_id),
      # Only the attribution keys travel to the ledger; the rest of `args`
      # never leaves this function.
      hints: hints(name, args, opts)
    }

    entry |> Map.merge(script_fingerprint(name, args)) |> ToolCallLedger.record()
  end

  # The call's own ids win. Only when it names no task, stage or plan do the
  # fallback ids apply: for `suite_run`, the ids in its `inputs`; for an
  # inner call, the ids its run passed as `:attribution_hints`. A call that
  # names its own task is never re-attributed to the run's.
  @task_keys ~w(task_id stage_id plan_id)

  defp hints(name, args, opts) do
    own = ToolCallLedger.attribution_hints(args)

    if Enum.any?(@task_keys, &Map.has_key?(own, &1)) do
      own
    else
      fallback =
        case {name, Map.get(args, "inputs")} do
          {"suite_run", %{} = inputs} -> ToolCallLedger.attribution_hints(inputs)
          _ -> Keyword.get(opts, :attribution_hints, %{})
        end

      Map.merge(own, Map.take(fallback || %{}, @task_keys))
    end
  end

  # `suite_run` (stage 2): the sha256 and byte length of the script, never
  # the script itself. Every other tool records neither.
  defp script_fingerprint("suite_run", %{"script" => script}) when is_binary(script) do
    %{
      script_sha256: :crypto.hash(:sha256, script) |> Base.encode16(case: :lower),
      script_bytes: byte_size(script)
    }
  end

  defp script_fingerprint(_name, _args), do: %{}

  # BEAM external term size: a cheap, allocation-free proxy for the result's
  # size. It is NOT the JSON byte count on the wire.
  defp term_size(term) do
    :erlang.external_size(term)
  rescue
    _ -> nil
  end
end
