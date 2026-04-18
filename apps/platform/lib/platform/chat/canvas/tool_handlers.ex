defmodule Platform.Chat.Canvas.ToolHandlers do
  @moduledoc """
  Implementations of the `canvas.create` / `canvas.patch` / `canvas.describe`
  agent tools (ADR 0036, Phase 4).

  Each handler returns `{:ok, payload}` or `{:error, payload}` so callers in
  `tool_runner.ex` / `tool_surface.ex` can uniformly format responses.
  Rejections from `Canvas.Server.apply_patches/3` surface as structured
  `{:error, %{recoverable: true, ...}}` payloads the model can self-correct on.
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.PubSub, as: ChatPubSub

  @doc "canvas.create — validates the document, inserts a canvas."
  @spec create(map(), map()) :: {:ok, map()} | {:error, map()}
  def create(args, context) do
    space_id = Map.get(args, "space_id") || Map.get(context, :space_id)
    participant_id = Map.get(context, :agent_participant_id) || Map.get(context, :participant_id)
    document = Map.get(args, "document")
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
           error: "canvas.create requires an authenticated participant context",
           recoverable: false
         }}

      not is_map(document) ->
        {:error,
         %{
           error: "canvas.create requires a canonical document object",
           recoverable: true,
           suggestion: "See canvas.describe on an existing canvas for a valid document shape."
         }}

      true ->
        with {:ok, valid_doc} <- validate_document(document) do
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

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp validate_document(document) do
    case CanvasDocument.validate(document) do
      {:ok, doc} ->
        {:ok, doc}

      {:error, reasons} ->
        {:error,
         %{
           error: "document invalid: #{Enum.join(reasons, "; ")}",
           recoverable: true
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

  defp parse_op(["set_props", id, props]) when is_binary(id) and is_map(props),
    do: {:ok, {:set_props, id, props}}

  defp parse_op(["replace_children", id, children])
       when is_binary(id) and is_list(children),
       do: {:ok, {:replace_children, id, children}}

  defp parse_op(["append_child", id, child]) when is_binary(id) and is_map(child),
    do: {:ok, {:append_child, id, child}}

  defp parse_op(["delete_node", id]) when is_binary(id), do: {:ok, {:delete_node, id}}

  defp parse_op(["replace_document", doc]) when is_map(doc),
    do: {:ok, {:replace_document, doc}}

  defp parse_op(other), do: {:error, "unrecognized operation: #{inspect(other)}"}

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
