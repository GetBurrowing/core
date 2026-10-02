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
  alias Platform.Federation.McpContent
  alias Platform.Federation.ResultBound
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolDoc

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
        :telemetry.execute(
          [:platform, :federation, :tool_call_denied],
          %{system_time: System.system_time()},
          %{runtime_id: runtime.runtime_id, tool: name, reason: deny_reason_tag(name)}
        )

        {:error, -32001, ToolAuthorization.deny_message(name)}
    end
  end

  defp dispatch("tools/call", _params, _runtime) do
    {:error, -32602, "tools/call requires string name and map arguments"}
  end

  defp dispatch(method, _params, _runtime) do
    {:error, -32601, "method not found: #{method}"}
  end

  # Telemetry-only projection of `ToolAuthorization.deny_reason/1` down to
  # the bare atom the `[:platform, :federation, :tool_call_denied]` metadata
  # carries — the suggestion (if any) is in the message text, not here.
  defp deny_reason_tag(name) do
    case ToolAuthorization.deny_reason(name) do
      :forbidden -> :forbidden
      {:unknown_tool, _suggestion} -> :unknown_tool
    end
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

  # `_meta` carries `anthropic/maxResultSizeChars` (task 01a049de).
  #
  # READ THE DIRECTION OF THIS FIELD BEFORE CHANGING IT. It is an escape hatch
  # that RAISES a client's result ceiling, not a cap that lowers it: Claude
  # Code truncates an MCP result at `MAX_MCP_OUTPUT_TOKENS` (default 25_000
  # tokens) and persists the remainder to disk, and a tool declaring this field
  # gets that number instead, up to 500_000 characters. The ticket for this
  # work called declaring the 500K ceiling "the direct lever"; declaring 500K
  # would have RAISED our ceiling roughly five-fold and made the problem worse.
  #
  # So we declare `ResultBound.max_result_bytes/0` — a number BELOW the client
  # default — which states the server's own guarantee and lowers the ceiling
  # for any client that honours the field. The real enforcement is
  # `ResultBound.fit/2` on the way out, because this field is advisory, is
  # Claude-Code-specific, and does nothing at all for the other transport.
  #
  # `description` is rendered by `ToolDoc.render_description/1`, which folds the
  # tool's `returns` / `limitations` / `when_to_use` prose into the string —
  # original description first and unmodified. Those three fields are NOT added
  # as sibling keys here on purpose: the MCP tool object is a closed schema, so
  # a client is entitled to drop keys it does not know and the change would be
  # a silent no-op. See `Platform.Federation.ToolDoc`.
  defp to_mcp_tool(tool) do
    %{
      name: tool.name,
      description: ToolDoc.render_description(tool),
      inputSchema: to_input_schema(tool.parameters),
      _meta: %{"anthropic/maxResultSizeChars" => ResultBound.max_result_bytes()}
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

  # The transport backstop (task 01a049de). Every tool passes through here, so
  # this is the one place that can promise "no MCP result floods a context
  # window" without auditing ~98 handlers. The per-tool bounds on `task_list`,
  # `stage_list` and `review_item_list` shape a GOOD answer; this catches the
  # ones nobody has shaped yet.
  #
  # When it has to drop records, the notice goes in a SECOND content block
  # rather than into the JSON. That keeps the first block's shape byte-identical
  # to what the tool declared it returns — a bare array stays a bare array, and
  # no caller has to learn a new envelope to survive a truncation it may never
  # hit. `ResultBound.fit/2` shrinks the term and re-encodes, so block one
  # always parses.
  #
  # Image blocks (task 01a0fcfa). A handler that opted in via
  # `McpContent.offer_image/3` carries a bytes-free marker naming the field
  # that holds the base64. `McpContent.split/1` lifts that field out: the text
  # block keeps the metadata plus `image_content_block: true` and NO base64,
  # and the bytes go in an MCP `image` block appended LAST (text, then any
  # truncation note, then the image). The image block deliberately sits
  # OUTSIDE `ResultBound.fit/2`: that backstop bounds TEXT spent from a context
  # window, while vision providers bill an image by pixels, not by base64
  # length. Its own size bound is `McpContent.image_block_max_bytes/0`,
  # enforced when the handler offers the image. Results with no marker (or a
  # malformed one, which `split/1` logs and drops) take the text path, with
  # the marker removed so it never reaches the wire.
  defp success_content(data) when is_map(data) and not is_struct(data) do
    case McpContent.split(data) do
      {:image, rest, base64, mime_type} ->
        rest
        |> Map.put(:image_content_block, true)
        |> text_content()
        |> Map.update!(:content, &(&1 ++ [%{type: "image", data: base64, mimeType: mime_type}]))

      {:none, data} ->
        text_content(data)
    end
  end

  defp success_content(data), do: text_content(data)

  defp text_content(data) do
    case ResultBound.fit(data) do
      {:ok, json} ->
        %{content: [%{type: "text", text: json}], isError: false}

      {:truncated, json, note} ->
        %{
          content: [%{type: "text", text: json}, %{type: "text", text: note}],
          isError: false
        }
    end
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
  #
  # Every key the handler set is carried, not an enumerated four. The comment
  # above describes flattening a refusal down to what one layer happened to
  # know about, and a whitelist is that same bug at a different width: it kept
  # `code`/`recoverable`/`suggestion` and dropped everything else a handler
  # attached. What it dropped was the diagnostic half of the contract —
  # `stack_complete`'s `pending: [%{id, title, status}]` names the member
  # blocking the close, and `stack_eject`'s `dependents: [%{id, title}]` names
  # the tasks its own `suggestion` tells you to eject first. Both are promised
  # in the tools' documented `limitations` prose. Neither reached an HTTP
  # caller, so `stack_complete` refused with "some member is not done" and no
  # way to learn which — the failure that stranded stack
  # `019fd80f-531e-7dab-ab61-c26c2e4748ba`.
  #
  # `RuntimeChannel.execute_tool_call/4` already pushes the handler map intact.
  # Carrying every key is what makes the two federation transports agree, which
  # is what the fix above set out to do.
  defp error_envelope(%Ecto.Changeset{} = changeset),
    do: %{error: inspect(changeset.errors)}

  defp error_envelope(reason) when is_map(reason) and not is_struct(reason) do
    reason
    |> Map.drop([:error])
    |> Map.new(fn {key, value} -> {key, jsonable(value)} end)
    |> Map.put(:error, error_message(reason))
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
  #
  # Lists and plain maps recurse instead of collapsing to `inspect/1`, because
  # the payloads worth carrying are shaped like `[%{id: _, title: _}]` and a
  # client branching on them needs structure, not a debug string. Structs are
  # kept only when they already implement `Jason.Encoder` (`DateTime` and
  # friends do); anything else still falls through to `inspect/1`, so the 500
  # this clause exists to prevent stays prevented.
  defp jsonable(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  # `Jason.Encoder` sets `@fallback_to_any true`, so `impl_for/1` never
  # returns nil for a struct: one with no encoder of its own resolves to
  # `Jason.Encoder.Any`, whose `encode/2` raises. That module is the
  # "not encodable" answer, not nil (the Elixir 1.20 type checker flagged
  # the old `if impl_for(value)` test as always true).
  defp jsonable(%_{} = value) do
    case Jason.Encoder.impl_for(value) do
      Jason.Encoder.Any -> inspect(value)
      _encoder -> value
    end
  end

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {jsonable_key(key), jsonable(val)} end)

  defp jsonable(value), do: inspect(value)

  # Jason encodes atom, binary and numeric keys; anything else (a tuple key,
  # a pid) would raise mid-encode, which is the 500 again.
  defp jsonable_key(key) when is_atom(key) or is_binary(key) or is_number(key), do: key
  defp jsonable_key(key), do: inspect(key)
end
