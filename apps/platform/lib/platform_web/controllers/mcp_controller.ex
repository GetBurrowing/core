defmodule PlatformWeb.MCPController do
  @moduledoc """
  Streamable HTTP MCP endpoint for federated agents.

  One URL serves JSON-RPC 2.0 over `POST`. `GET` is reserved for server-
  initiated SSE notifications and is currently unused (returns 405).

  Auth is handled upstream by `PlatformWeb.Plugs.RuntimeBearerAuth`; the
  authenticated runtime lives at `conn.assigns.runtime` and its
  `allowed_bundles` field scopes both `tools/list` and `tools/call`.

  Capability scoping itself is NOT implemented here. Both `tools/list` and
  `tools/call` delegate to `Platform.Federation.ToolAuthorization`, the single
  enforcement point shared with the WebSocket transport
  (`PlatformWeb.RuntimeChannel`), so the two transports cannot answer
  differently.
  """

  use PlatformWeb, :controller

  alias Platform.Chat
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolAuthorization

  @protocol_version "2025-06-18"
  @server_name "startup-suite"
  @server_version "0.1.0"

  def handle(conn, %{"jsonrpc" => "2.0", "method" => method} = body) do
    params = Map.get(body, "params", %{}) || %{}
    runtime = conn.assigns.runtime

    case Map.get(body, "id") do
      nil ->
        _ = dispatch(method, params, runtime)
        send_resp(conn, 204, "")

      id ->
        respond(conn, id, dispatch(method, params, runtime))
    end
  end

  def handle(conn, _body) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      jsonrpc: "2.0",
      error: %{code: -32600, message: "invalid JSON-RPC envelope"}
    })
  end

  defp respond(conn, id, {:ok, result}) do
    json(conn, %{jsonrpc: "2.0", id: id, result: result})
  end

  defp respond(conn, id, {:error, code, message}) do
    json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  def stream(conn, _params), do: send_resp(conn, 405, "")

  # ── JSON-RPC method dispatch ────────────────────────────────────────

  defp dispatch("initialize", _params, _runtime) do
    {:ok,
     %{
       protocolVersion: @protocol_version,
       serverInfo: %{name: @server_name, version: @server_version},
       capabilities: %{tools: %{listChanged: false}}
     }}
  end

  defp dispatch("notifications/initialized", _params, _runtime), do: {:ok, nil}

  defp dispatch("tools/list", _params, runtime) do
    tools =
      runtime
      |> ToolAuthorization.effective_tools()
      |> Enum.map(&to_mcp_tool/1)

    {:ok, %{tools: tools}}
  end

  defp dispatch("tools/call", %{"name" => name, "arguments" => args}, runtime)
       when is_binary(name) and is_map(args) do
    case ToolAuthorization.authorize(name, runtime) do
      :ok ->
        context = build_context(args, runtime)

        # `ToolArguments.dispatch/3`, not `ToolSurface.execute/3`: the argument
        # gate runs first and refuses a call that names no required argument,
        # so a malformed call gets a `missing_<param>` code instead of whatever
        # 500 the handler happened to raise. Authorization stays above it —
        # capability is decided before arguments are looked at.
        case ToolArguments.dispatch(name, args, context) do
          {:ok, data} -> {:ok, success_content(data)}
          {:error, reason} -> {:ok, error_content(reason)}
          other -> {:ok, error_content(other)}
        end

      {:error, :forbidden} ->
        {:error, -32001, "tool '#{name}' not in allowed bundles"}
    end
  end

  defp dispatch("tools/call", _params, _runtime) do
    {:error, -32602, "tools/call requires string name and map arguments"}
  end

  defp dispatch(method, _params, _runtime) do
    {:error, -32601, "method not found: #{method}"}
  end

  # ── Execution context ───────────────────────────────────────────────

  defp build_context(args, runtime) do
    space_id = Map.get(args, "space_id")
    agent_participant_id = lookup_participant(space_id, runtime.agent_id)

    %{
      space_id: space_id,
      agent_id: runtime.agent_id,
      agent_participant_id: agent_participant_id,
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

  # ── MCP schema translation ──────────────────────────────────────────

  defp to_mcp_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      inputSchema: to_input_schema(tool.parameters)
    }
  end

  defp to_input_schema(params) when is_map(params) and map_size(params) > 0 do
    properties =
      for {key, meta} <- params, into: %{} do
        {to_string(key), property_schema(meta)}
      end

    required =
      for {key, meta} <- params, is_map(meta), meta[:required] == true, do: to_string(key)

    %{type: "object", properties: properties, required: required}
  end

  defp to_input_schema(_) do
    %{type: "object", properties: %{}, required: []}
  end

  defp property_schema(meta) when is_map(meta) do
    # If the tool declares a full JSON Schema for this parameter (under
    # `:schema`), prefer it verbatim — this is how complex nested types
    # (document trees, patch operations) surface proper structure to MCP
    # clients instead of leaving them to guess from a bare `{type: "object"}`.
    case meta[:schema] do
      nil ->
        %{
          type: meta[:type] || "string",
          description: meta[:description] || ""
        }

      schema when is_map(schema) ->
        schema
        |> Map.put_new(:description, meta[:description] || "")
    end
  end

  defp property_schema(_), do: %{type: "string"}

  defp success_content(data) do
    %{content: [%{type: "text", text: Jason.encode!(data)}], isError: false}
  end

  # Symmetric with `success_content/1` directly above, and the symmetry is the
  # whole point. `ToolSurface.execute/3` refuses with
  # `%{error:, code:, recoverable:, suggestion:}`; the previous first clause
  # here — `format_error(%{error: msg}) when is_binary(msg)` — matched EVERY
  # one of those maps and returned the sentence alone, so `code`,
  # `recoverable` and `suggestion` never reached an HTTP caller.
  #
  # That is not a cosmetic loss. `task_design_decline` and
  # `plan_architecture_verdict` each document a CLOSED `code` taxonomy in
  # their `limitations` prose and instruct remote runtimes to branch on it.
  # Both are guarded by tests, but those tests assert at the `execute/3`
  # layer — one level above where this flattened. Guard green, docs accurate,
  # `/mcp` client still handed a bare sentence.
  #
  # `RuntimeChannel.execute_tool_call/4` pushes the same map intact, so the
  # two federation transports answered the same refusal differently. They now
  # agree, and `runtime_channel_test.exs` pins that at the wire.
  #
  # BREAKING SHAPE, stated plainly: `content[0].text` of every `/mcp` tool
  # error changes from a bare sentence to a JSON object. The success path was
  # already `Jason.encode!`, so any client reading MCP output is already
  # JSON-aware — the asymmetry IS the bug, not a compatibility guarantee.
  defp error_content(reason) do
    %{content: [%{type: "text", text: Jason.encode!(error_envelope(reason))}], isError: true}
  end

  # Atom codes serialize as JSON strings: `:missing_reason` reaches the wire
  # as `"missing_reason"`. Nil-valued keys are dropped rather than emitted as
  # `null`, so "this refusal declares no code" reads differently from "this
  # refusal is not recoverable" — `recoverable: false` survives.
  defp error_envelope(%Ecto.Changeset{} = changeset),
    do: %{error: inspect(changeset.errors)}

  defp error_envelope(reason) when is_map(reason) and not is_struct(reason) do
    %{
      error: error_message(reason),
      code: jsonable(Map.get(reason, :code)),
      recoverable: jsonable(Map.get(reason, :recoverable)),
      suggestion: jsonable(Map.get(reason, :suggestion))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_envelope(reason) when is_binary(reason), do: %{error: reason}
  defp error_envelope(reason), do: %{error: inspect(reason)}

  # `error` is always a string, whatever the handler put there — a client
  # branching on `code` still needs something human-readable to log.
  defp error_message(%{error: message}) when is_binary(message), do: message
  defp error_message(%{error: %Ecto.Changeset{} = changeset}), do: inspect(changeset.errors)
  defp error_message(%{error: nil} = reason), do: inspect(reason)
  defp error_message(%{error: other}), do: inspect(other)
  defp error_message(reason), do: inspect(reason)

  # Guarantees the envelope encodes. Every `code:` in the tool surface today
  # is an atom or a binary, but an unencodable value here would turn a
  # handled refusal into a 500 — strictly worse than the bug being fixed.
  defp jsonable(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp jsonable(value), do: inspect(value)
end
