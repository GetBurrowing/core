defmodule Platform.Chat.Canvas.ToolHandlers do
  @moduledoc """
  Implementations of the `canvas.create` / `canvas.patch` / `canvas.describe`
  agent tools (ADR 0036, Phase 4).

  Each handler returns `{:ok, payload}` or `{:error, payload}` so callers in
  `tool_runner.ex` / `tool_surface.ex` can uniformly format responses.
  Rejections from `Canvas.Server.apply_patches/3` surface as structured
  `{:error, %{recoverable: true, ...}}` payloads the model can self-correct on.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Templates
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.PubSub, as: ChatPubSub

  @doc "canvas.create — validates the document, inserts a canvas."
  @spec create(map(), map()) :: {:ok, map()} | {:error, map()}
  def create(args, context) do
    space_id = Map.get(args, "space_id") || Map.get(context, :space_id)
    participant_id = Map.get(context, :agent_participant_id) || Map.get(context, :participant_id)
    agent_id = Map.get(context, :agent_id)
    raw_document = Map.get(args, "document") || Map.get(args, "initial_state")
    document = decode_if_string(raw_document)
    title = Map.get(args, "title")

    cond do
      not is_binary(space_id) ->
        {:error,
         %{
           error: "canvas.create requires space_id (string)",
           recoverable: true
         }}

      not is_binary(participant_id) ->
        {:error,
         %{
           error:
             "canvas.create: agent #{inspect(agent_id)} is not a participant in space #{inspect(space_id)} — join the space first (ask a human to @mention you there, or be added to the roster) before creating canvases in it.",
           recoverable: false,
           agent_id: agent_id,
           space_id: space_id
         }}

      not is_map(document) ->
        Logger.warning(
          "[Canvas.ToolHandlers] canvas.create rejected: document unusable. " <>
            "agent=#{inspect(agent_id)} space=#{inspect(space_id)} " <>
            "arg_keys=#{inspect(Map.keys(args))} " <>
            "raw_type=#{describe(raw_document)} decoded_type=#{describe(document)} " <>
            "raw_preview=#{raw_document |> inspect() |> String.slice(0, 300)}"
        )

        {:error,
         %{
           error:
             "canvas.create requires a canonical document object (got #{describe(document)}). Pass `document` as a nested JSON object, not a string; see canvas.describe on an existing canvas for a valid shape.",
           recoverable: true,
           got_type: describe(document),
           accepted_keys: ["document", "initial_state"],
           received_keys: Map.keys(args)
         }}

      true ->
        with {:ok, valid_doc} <- validate_document(normalize_document(document)) do
          attrs = %{
            "title" => title,
            "document" => valid_doc
          }

          case Chat.create_canvas_with_message(space_id, participant_id, attrs) do
            {:ok, canvas, _message} ->
              maybe_subscribe(canvas.id)

              {:ok,
               %{
                 canvas_id: canvas.id,
                 title: canvas.title,
                 kind: CanvasDocument.root_kind(canvas.document),
                 revision: CanvasDocument.revision(canvas.document)
               }}

            {:error, %Ecto.Changeset{} = cs} ->
              {:error,
               %{
                 error: "canvas.create: #{inspect(cs.errors)}",
                 recoverable: true
               }}

            {:error, reason} ->
              {:error,
               %{
                 error: "canvas.create failed: #{inspect(reason)}",
                 recoverable: true
               }}
          end
        end
    end
  end

  @doc "canvas.patch — route through Canvas.Server.apply_patches/3."
  @spec patch(map(), map()) :: {:ok, map()} | {:error, map()}
  def patch(args, _context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, base_revision} <- require_integer(args, "base_revision"),
         {:ok, ops_list} <- require_list(args, "operations"),
         {:ok, parsed_ops} <- parse_operations(ops_list) do
      case CanvasServer.apply_patches(canvas_id, parsed_ops, base_revision) do
        {:ok, new_revision} ->
          maybe_subscribe(canvas_id)
          {:ok, %{canvas_id: canvas_id, revision: new_revision}}

        {:conflict, payload} ->
          {:error,
           %{
             error: "canvas.patch rejected: #{inspect(payload.reason)}",
             recoverable: true,
             conflict: payload,
             suggestion:
               "Use canvas.describe to fetch the current revision and tree, then retry with a corrected patch."
           }}

        {:error, reason} ->
          {:error, %{error: "canvas.patch failed: #{inspect(reason)}", recoverable: true}}
      end
    end
  end

  @doc "canvas.describe — current document, revision, and presence."
  @spec describe(map(), map()) :: {:ok, map()} | {:error, map()}
  def describe(args, _context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id") do
      case Chat.get_canvas(canvas_id) do
        nil ->
          {:error, %{error: "canvas #{canvas_id} not found", recoverable: false}}

        canvas ->
          case CanvasServer.describe(canvas_id) do
            {:ok, %{document: doc, revision: rev}} ->
              maybe_subscribe(canvas_id)

              {:ok,
               %{
                 canvas_id: canvas_id,
                 title: canvas.title,
                 space_id: canvas.space_id,
                 kind: CanvasDocument.root_kind(doc),
                 revision: rev,
                 document: doc,
                 presence: presence_for_canvas(canvas),
                 recent_events: []
               }}

            {:error, reason} ->
              {:error,
               %{
                 error: "canvas.describe failed: #{inspect(reason)}",
                 recoverable: true
               }}
          end
      end
    end
  end

  @doc """
  canvas.list_kinds — return ergonomic summaries of every registered node
  kind. Agents call this once to discover what they can emit, without
  having to parse the recursive discriminated-union JSON Schema.
  """
  @spec list_kinds(map(), map()) :: {:ok, map()}
  def list_kinds(_args, _context) do
    {:ok, %{kinds: Kinds.summaries()}}
  end

  @doc """
  canvas.template — return a named canonical document. Agents that can't
  reason about the schema from scratch can pick a template by name and
  pass the returned `document` straight to `canvas.create`, adjusting as
  needed. When called with no name, returns the list of available
  templates.
  """
  @spec template(map(), map()) :: {:ok, map()} | {:error, map()}
  def template(args, _context) do
    case Map.get(args, "name") do
      name when is_binary(name) and name != "" ->
        case Templates.get(name) do
          nil ->
            {:error,
             %{
               error: "canvas.template: unknown template #{inspect(name)}",
               recoverable: true,
               available: Enum.map(Templates.list(), & &1.name)
             }}

          template ->
            {:ok, template}
        end

      _ ->
        {:ok, %{templates: Templates.list()}}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Auto-fill trivial scaffolding fields so minimal agent-emitted docs work:
  # `version`, `revision`, `theme`, `bindings`, `meta` default to sane values,
  # and every node with a missing/empty `id` gets one (root → "root",
  # everyone else → a fresh UUID). Validation still runs after, so truly
  # malformed shapes (unknown kinds, illegal children) still surface as
  # errors — we're only filling in what has one obvious value.
  defp normalize_document(doc) when is_map(doc) do
    doc
    |> Map.put_new("version", 1)
    |> Map.put_new("revision", 1)
    |> Map.put_new("theme", %{})
    |> Map.put_new("bindings", %{})
    |> Map.put_new("meta", %{})
    |> Map.update("root", nil, &normalize_node(&1, "root"))
  end

  defp normalize_document(other), do: other

  defp normalize_node(node, fallback_id) when is_map(node) do
    id =
      case Map.get(node, "id") do
        v when is_binary(v) and v != "" -> v
        _ -> fallback_id
      end

    children =
      case Map.get(node, "children") do
        list when is_list(list) ->
          Enum.map(list, &normalize_node(&1, Ecto.UUID.generate()))

        _ ->
          nil
      end

    node
    |> Map.put("id", id)
    |> Map.put_new("props", %{})
    |> then(fn n ->
      if children, do: Map.put(n, "children", children), else: n
    end)
  end

  defp normalize_node(other, _fallback), do: other

  defp validate_document(document) do
    case CanvasDocument.validate(document) do
      {:ok, doc} ->
        {:ok, doc}

      {:error, reasons} ->
        {:error,
         %{
           error: "document invalid: #{Enum.join(reasons, "; ")}",
           recoverable: true,
           reasons: reasons,
           suggestion:
             "Discover shape via `canvas.list_kinds` (node catalog) or `canvas.template` (named starter docs). The example below is known-good — adjust and retry.",
           minimal_valid_example: Templates.minimal_example(),
           available_templates: Enum.map(Templates.list(), & &1.name)
         }}
    end
  end

  defp require_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, %{error: "missing or invalid \"#{key}\" (string)", recoverable: true}}
    end
  end

  defp require_integer(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, %{error: "missing or invalid \"#{key}\" (integer)", recoverable: true}}
    end
  end

  defp require_list(map, key) do
    case Map.get(map, key) do
      v when is_list(v) and v != [] -> {:ok, v}
      _ -> {:error, %{error: "missing or empty \"#{key}\" (array)", recoverable: true}}
    end
  end

  defp parse_operations(list) do
    Enum.reduce_while(list, {:ok, []}, fn op, {:ok, acc} ->
      case parse_op(op) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, reason} -> {:halt, {:error, %{error: reason, recoverable: true}}}
      end
    end)
  end

  defp parse_op(["set_props", id, props]) when is_binary(id) do
    case decode_if_string(props) do
      p when is_map(p) -> {:ok, {:set_props, id, p}}
      _ -> {:error, "set_props: props must be an object (got #{describe(props)})"}
    end
  end

  defp parse_op(["replace_children", id, children]) when is_binary(id) do
    case decode_if_string(children) do
      c when is_list(c) -> {:ok, {:replace_children, id, c}}
      _ -> {:error, "replace_children: children must be an array (got #{describe(children)})"}
    end
  end

  defp parse_op(["append_child", id, child]) when is_binary(id) do
    case decode_if_string(child) do
      c when is_map(c) -> {:ok, {:append_child, id, c}}
      _ -> {:error, "append_child: child must be an object (got #{describe(child)})"}
    end
  end

  defp parse_op(["delete_node", id]) when is_binary(id), do: {:ok, {:delete_node, id}}

  defp parse_op(["replace_document", doc]) do
    case decode_if_string(doc) do
      d when is_map(d) -> {:ok, {:replace_document, d}}
      _ -> {:error, "replace_document: doc must be an object (got #{describe(doc)})"}
    end
  end

  defp parse_op(other), do: {:error, "unrecognized operation: #{inspect(other)}"}

  # Some MCP clients (and some LLM providers) serialize nested object
  # arguments as JSON strings. Accept either shape transparently so callers
  # don't have to know the wire encoding their gateway chose.
  defp decode_if_string(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> s
    end
  end

  defp decode_if_string(other), do: other

  defp describe(v) when is_binary(v), do: "string"
  defp describe(v) when is_list(v), do: "array"
  defp describe(v) when is_map(v), do: "object"
  defp describe(v) when is_integer(v), do: "integer"
  defp describe(v) when is_boolean(v), do: "boolean"
  defp describe(nil), do: "null"
  defp describe(_), do: "other"

  defp presence_for_canvas(_canvas) do
    # Phase 5 wires this to the per-space presence engagement bag. For now
    # return an empty map so the field is stable in the payload shape.
    %{viewing: [], editing: []}
  end

  # Subscribe the calling process to the canvas PubSub topic so subsequent
  # patches and events are delivered as observations. Best-effort — ignore
  # duplicate subscriptions (Phoenix.PubSub returns :ok either way).
  defp maybe_subscribe(canvas_id) do
    ChatPubSub.subscribe_canvas(canvas_id)
  rescue
    _ -> :ok
  end
end
