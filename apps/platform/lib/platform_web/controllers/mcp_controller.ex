defmodule PlatformWeb.MCPController do
  @moduledoc """
  Streamable HTTP MCP endpoint for federated agents.

  One URL serves JSON-RPC 2.0 over `POST`. `GET` is reserved for server-
  initiated SSE notifications and is currently unused (returns 405).

  Auth is handled upstream by `PlatformWeb.Plugs.RuntimeBearerAuth`; the
  authenticated runtime lives at `conn.assigns.runtime` and its
  `allowed_bundles` field scopes both `tools/list` and `tools/call`.
  """

  use PlatformWeb, :controller

  alias Platform.Chat
  alias Platform.Federation.ToolSurface

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

  defp respond(conn, id, {:ok, result}) do
    json(conn, %{jsonrpc: "2.0", id: id, result: result})
  end

  defp respond(conn, id, {:error, code, message}) do
    json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  def handle(conn, _body) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      jsonrpc: "2.0",
      error: %{code: -32600, message: "invalid JSON-RPC envelope"}
    })
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
      runtime.allowed_bundles
      |> ToolSurface.list_tools()
      |> Enum.map(&to_mcp_tool/1)

    {:ok, %{tools: tools}}
  end

  defp dispatch("tools/call", %{"name" => name, "arguments" => args}, runtime)
       when is_binary(name) and is_map(args) do
    case authorize_tool(name, runtime) do
      :ok ->
        context = build_context(args, runtime)

        case ToolSurface.execute(name, args, context) do
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

  # ── Authorization ───────────────────────────────────────────────────

  defp authorize_tool(name, runtime) do
    scoped = ToolSurface.list_tools(runtime.allowed_bundles)

    if Enum.any?(scoped, &(&1.name == name)),
      do: :ok,
      else: {:error, :forbidden}
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

  defp error_content(reason) do
    %{content: [%{type: "text", text: format_error(reason)}], isError: true}
  end

  defp format_error(%{error: msg}) when is_binary(msg), do: msg
  defp format_error(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp format_error(other) when is_binary(other), do: other
  defp format_error(other), do: inspect(other)
end
