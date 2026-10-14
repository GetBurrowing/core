defmodule Platform.Canvas.ScriptEngine.Bindings do
  @moduledoc """
  What a canvas handler can call, and as whom (task 01a1316b-aab0 stage 1).

  ## Principal mode

  Code mode's own bindings (`Platform.CodeMode.Bindings`) act as an agent
  runtime. A canvas handler instead acts as its PRINCIPAL: the person (or
  agent) who triggered it, `{:user, id}` or `{:agent, id}`, derived host-side
  from the invocation's `:actor`. Nothing the script passes can change it.
  The canvas is likewise the OWNING canvas fixed at invocation: a
  `canvas_id` in a call's arguments is ignored.

  ## The registry

  `registry/0` maps a binding name to its handler. v1 registers exactly one,
  `canvas.patch`. Every other name (`tasks.create`, `chat.post_message`,
  `suite_run`, `$store.*`, anything) is refused with kind `forbidden` and
  code `binding_not_registered`, before any argument is read.

  `canvas.patch` parses its `operations` with the canvas.patch MCP tool's
  own parser (`Platform.Chat.Canvas.ToolHandlers.parse_operations/1`) and
  writes through `Platform.Chat.patch_canvas/3` as the principal, whose gate
  is `CanvasAccess.fetch_for_writer/2`: the same gate as the MCP tool, so a
  viewer holding only a READ grant is refused. There is no second
  authorization path here and no Repo call.

  An `{:agent, id}` principal must additionally carry its `%AgentRuntime{}`
  as the invocation's `:runtime`. Each call reloads that row
  (`Federation.get_runtime/1`, as `Platform.CodeMode.Bindings` does) and
  requires it to be active, to belong to the agent, and to be granted
  `canvas.patch` by `ToolAuthorization.authorize/2`. No runtime is a refusal.

  ## Call limit

  Every host call, registered or not, counts against `max_calls` on an
  `:atomics` counter. Past it the call is refused with kind `call_limit` and
  the run ends `call_limit` even if the handler catches the error, mirroring
  `Platform.CodeMode.Bindings`.

  ## Write bindings are a follow-up

  A handler is authored by any canvas writer and runs with the CALLER's
  authority. v1 is safe because its only binding writes the owning canvas,
  which every writer already holds. Any write binding beyond that must first
  bound the handler author's authority too (stage 3's confused-deputy note).
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolHandlers, as: CanvasToolHandlers
  alias Platform.Federation
  alias Platform.Federation.Jsonable
  alias Platform.Federation.ToolAuthorization

  @doc "The registered bindings: name to `fn args, invocation -> response_json`."
  @spec registry() :: %{String.t() => (map(), map() -> String.t())}
  def registry, do: %{"canvas.patch" => &canvas_patch/2}

  @doc "The registered binding names."
  @spec names() :: [String.t()]
  def names, do: Map.keys(registry())

  @doc """
  The host function for one handler run. `invocation` carries `:canvas_id`,
  `:actor` (`%{type, id, display_name}`), `:limits`, `:counter`
  (`new_counter/0`) and, for an agent actor, `:runtime`.
  """
  @spec host(map()) :: (String.t(), String.t() -> String.t())
  def host(invocation), do: fn name, args_json -> handle(name, args_json, invocation) end

  @doc "A fresh counter for `host/1`: binding calls, call-limit tripped."
  def new_counter, do: :atomics.new(2, signed: false)

  @doc "Binding calls a run made (refusals at the call limit excluded)."
  def calls(counter), do: :atomics.get(counter, 1)

  @doc "Did the run hit its call limit?"
  def call_limit_tripped?(counter), do: :atomics.get(counter, 2) == 1

  @doc """
  The principal an invocation acts as: `{:user, id}`, `{:agent, id}`, or nil
  (which every gate refuses).
  """
  @spec principal(map()) :: {:user, String.t()} | {:agent, String.t()} | nil
  def principal(%{actor: actor}) when is_map(actor) do
    case {field(actor, :type), field(actor, :id)} do
      {"user", id} when is_binary(id) and id != "" -> {:user, id}
      {"agent", id} when is_binary(id) and id != "" -> {:agent, id}
      _ -> nil
    end
  end

  def principal(_invocation), do: nil

  defp handle(name, args_json, invocation) do
    if :atomics.add_get(invocation.counter, 1, 1) > invocation.limits.max_calls do
      :atomics.put(invocation.counter, 2, 1)
      :atomics.sub(invocation.counter, 1, 1)

      fail(
        "call_limit",
        "the handler made more than #{invocation.limits.max_calls} binding calls"
      )
    else
      case Map.fetch(registry(), name) do
        {:ok, binding} ->
          with {:ok, args} <- decode(args_json), do: binding.(args, invocation)

        :error ->
          fail(
            "forbidden",
            "binding_not_registered: #{name} is not a canvas handler binding",
            "binding_not_registered"
          )
      end
    end
  rescue
    error -> fail("tool_error", "#{name} raised #{inspect(error.__struct__)}")
  end

  defp canvas_patch(args, invocation) do
    principal = principal(invocation)

    with {:ok, operations} <- operations(args),
         :ok <- agent_runtime(principal, invocation),
         {:ok, canvas} <- owning_canvas(invocation) do
      principal |> Chat.patch_canvas(canvas, operations) |> patched(canvas.id)
    end
  end

  defp operations(%{"operations" => list}) when is_list(list) and list != [] do
    case CanvasToolHandlers.parse_operations(list) do
      {:ok, operations} -> {:ok, operations}
      {:error, %{error: reason}} -> fail("invalid_args", reason, "invalid_operations")
    end
  end

  defp operations(_args),
    do: fail("invalid_args", "canvas.patch needs a non-empty operations array", "invalid_args")

  defp agent_runtime({:agent, agent_id}, invocation) do
    with %{id: pk} <- Map.get(invocation, :runtime),
         %{status: "active", agent_id: ^agent_id} = runtime <- Federation.get_runtime(pk) do
      case ToolAuthorization.authorize("canvas.patch", runtime) do
        :ok ->
          :ok

        {:error, :forbidden} ->
          fail("forbidden", "this agent's runtime is not granted canvas.patch", "forbidden")
      end
    else
      _ -> fail("forbidden", "an agent principal needs its active runtime", "no_active_runtime")
    end
  end

  defp agent_runtime(_principal, _invocation), do: :ok

  defp owning_canvas(%{canvas_id: canvas_id}) when is_binary(canvas_id) do
    case Chat.get_canvas(canvas_id) do
      nil -> fail("tool_error", "the owning canvas no longer exists", "not_found")
      canvas -> {:ok, canvas}
    end
  end

  defp owning_canvas(_invocation),
    do: fail("tool_error", "the handler has no owning canvas", "not_found")

  defp patched({:ok, _canvas}, canvas_id) do
    revision =
      case CanvasServer.describe(canvas_id) do
        {:ok, %{revision: revision}} -> revision
        _ -> nil
      end

    Jason.encode!(%{ok: true, data: %{canvas_id: canvas_id, revision: revision}})
  end

  defp patched({:error, :forbidden}, _canvas_id),
    do:
      fail(
        "forbidden",
        "canvas.patch requires participation in the canvas's space; a read grant does not confer write",
        "forbidden"
      )

  defp patched({:conflict, payload}, _canvas_id),
    do:
      fail(
        "tool_error",
        "canvas.patch rejected: #{inspect(Map.get(payload, :reason))}",
        "conflict"
      )

  defp patched({:error, %{code: code, message: message}}, _canvas_id),
    do: fail("tool_error", "canvas.patch: #{message}", to_string(code))

  defp patched({:error, reason}, _canvas_id) do
    envelope = Jsonable.error_envelope(reason)
    fail("tool_error", "canvas.patch failed: #{Map.get(envelope, :error)}", code(reason))
  end

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "patch_failed"

  defp decode(args_json) do
    case Jason.decode(args_json) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _ -> fail("invalid_args", "arguments must be a JSON object", "invalid_args")
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @refusal_key {__MODULE__, :refusal_code}

  @doc """
  Pop the code of the last refusal a binding returned in THIS process, or nil
  (task 01a1316b-aab0 stage 2). The engine's `{:error, kind, message}` has no
  code slot, so an uncaught `binding_not_registered` would otherwise survive
  only as text in the message. Code mode calls the host in the calling
  process (`Platform.CodeMode.Runtime.run/3`, `:host`), so the process that
  ran the engine can read the code back once the run returns.
  """
  @spec take_refusal_code() :: String.t() | nil
  def take_refusal_code, do: Process.delete(@refusal_key)

  # Every refusal is returned as the JSON response the script sees: a `with`
  # that hits one returns it as is.
  defp fail(kind, message, code \\ nil) do
    Process.put(@refusal_key, code || kind)
    Jason.encode!(%{ok: false, kind: kind, message: message, code: code})
  end
end
