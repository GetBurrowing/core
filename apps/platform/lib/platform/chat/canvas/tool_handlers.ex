defmodule Platform.Chat.Canvas.ToolHandlers do
  @moduledoc """
  Implementations of the `canvas.create` / `canvas.patch` / `canvas.describe` /
  `canvas.list_kinds` / `canvas.template` agent tools (ADR 0036, Phase 4).

  Each handler returns `{:ok, payload}` or `{:error, payload}` so callers in
  `tool_runner.ex` / `tool_surface.ex` can uniformly format responses.
  Rejections from `Canvas.Server.apply_patches/3` surface as structured
  `{:error, %{recoverable: true, ...}}` payloads the model can self-correct on.

  ## Authorization: `Platform.Chat.Canvas.ToolAccess`, for both doors

  Neither gated handler decides access itself. `describe/2` resolves its canvas
  through `ToolAccess.fetch_for_read/2` and `patch/2` through
  `ToolAccess.fetch_for_write/3` — the same two calls `canvas.versions` and
  `canvas.restore` make in `Platform.Chat.Canvas.VersionHandlers`, so the four
  canvas-id-keyed tools on this surface cannot answer one question four ways.
  Handlers keep argument parsing and payload building; they do not keep their
  own authorization.

  `describe/2` was the exception until task 019fb01b stage 3. It ignored its
  `context` entirely and read through `Chat.get_canvas/1`, the deliberately
  unauthorized primitive, so any caller holding the `canvas` tool bundle could
  hand it any canvas id in any org and receive the whole document. That was zero
  authorization rather than weak authorization. It is gated now, and
  `test/platform/federation/canvas_read_enumeration_test.exs` is what stops the
  next tool from arriving the same way: every tool on the federation surface
  that reaches canvas code must be classified there in writing, and any
  classification claiming a gate is driven against a real outsider rather than
  taken at its word.

  `canvas.create` is the one tool here with no canvas to gate. It writes a NEW
  canvas and requires the context's `agent_participant_id` to be a participant
  row of the target space; a participant id from any other space is refused
  (task 01a0cbe0 stage 2 — before it, a space_id in args was never compared
  with the participant's space). `canvas.list_kinds` and
  `canvas.template` return the static kind registry and the starter templates
  and touch no canvas row at all.

  A forbidden READ additionally emits `[:platform, :chat, :canvas_read_denied]`
  from `ToolAccess` (stage 5). `:not_found` and `:forbidden` stay distinct here,
  which leaves a per-id existence oracle in place on purpose; that event is the
  control that makes someone using it visible.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.Links
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Templates
  alias Platform.Chat.Canvas.ToolAccess
  alias Platform.Chat.Canvas.Versions
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.PubSub, as: ChatPubSub

  @patch_denial "Access denied: canvas.patch requires participation in the canvas's space. " <>
                  "Being able to read a canvas (via a task it is attached to, or via your org) " <>
                  "does not confer write access."

  @patch_suggestion "Ask a human to add you to the space that owns this canvas, " <>
                      "or create your own canvas with canvas.create."

  @doc "canvas.create — validates the document, inserts a canvas."
  @spec create(map(), map()) :: {:ok, map()} | {:error, map()}
  def create(args, context) do
    space_id = Map.get(args, "space_id") || Map.get(context, :space_id)
    agent_id = Map.get(context, :agent_id)

    # A context participant id is honoured only when that participant row
    # belongs to the space being written (task 01a0cbe0 stage 2). Resolving
    # space_id from args while trusting a participant id from ANOTHER space let
    # a caller write a canvas and its message into a space it is not in. A
    # mismatch resolves to nil, so the `not is_binary(participant_id)` branch
    # below refuses it with the existing not-a-participant contract.
    participant_id =
      space_participant_id(
        space_id,
        Map.get(context, :agent_participant_id) || Map.get(context, :participant_id)
      )

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
                 revision: CanvasDocument.revision(canvas.document),
                 view_url: Links.view_url(canvas.id)
               }}

            {:error, %Ecto.Changeset{} = cs} ->
              {:error,
               %{
                 error: "canvas.create: #{inspect(cs.errors)}",
                 recoverable: true
               }}

            # A refused scripted embed (`prototypes_disabled`,
            # `scripted_embed_requires_org`, ...; task 01a1316b-677a).
            {:error, %{code: code, message: message}} ->
              {:error, %{error: "canvas.create: #{message}", code: code, recoverable: true}}

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

  @doc """
  canvas.patch — authorize the caller, then route through
  `Canvas.Server.apply_patches/3`.

  The authorization gate is task 019e2c4b stage 2. Before it, this handler
  ignored its `context` entirely and patched any `canvas_id` in any space in
  any org for any caller. `Canvas.VersionHandlers`' moduledoc already described
  `canvas.restore` as using "the same gate as `canvas.patch`" — this makes that
  true rather than aspirational.

  Argument shape is validated BEFORE authorization so a malformed call hears
  about its shape rather than about permissions, and so the denial message
  cannot be used to probe canvas ids with junk operations.
  """
  @spec patch(map(), map()) :: {:ok, map()} | {:error, map()}
  def patch(args, context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, base_revision} <- require_integer(args, "base_revision"),
         {:ok, ops_list} <- require_list(args, "operations"),
         {:ok, parsed_ops} <- parse_operations(ops_list),
         {:ok, canvas} <- authorize_write(canvas_id, context) do
      # The space comes from the canvas the authorization gate already
      # fetched, not from an argument: `canvas.patch` args carry no space_id,
      # and adding one would let a caller name a space the canvas isn't in.
      attribution = Versions.attribution_from_context(context, canvas.space_id)

      case CanvasServer.apply_patches(canvas_id, parsed_ops, base_revision, attribution) do
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

        {:error, %{code: code, message: message}} ->
          {:error, %{error: "canvas.patch: #{message}", code: code, recoverable: true}}

        {:error, reason} ->
          {:error, %{error: "canvas.patch failed: #{inspect(reason)}", recoverable: true}}
      end
    end
  end

  @doc """
  canvas.describe — current document, revision, and presence, for a caller
  authorized to read the canvas.

  The read gate is task 019fb01b stage 3. Before it, this handler ignored its
  `context` and resolved through `Chat.get_canvas/1`, the deliberately
  unauthorized primitive: any caller holding the `canvas` tool bundle could
  hand it any canvas id, in any space, in any org, and receive the whole
  document. That was zero authorization, not weak authorization —
  `ExternalScope.visible_space_id?/2` returns true for a nil scope, so even the
  scoped reader would have waved it through.

  Resolution lives in `ToolAccess.fetch_for_read/2`, which is also what
  `canvas.versions` calls, so the two reads on this surface cannot drift into
  two different answers to one question. `:not_found` and `:forbidden` stay
  distinct; see that module for why collapsing them relocates the oracle rather
  than removing it.
  """
  @spec describe(map(), map()) :: {:ok, map()} | {:error, map()}
  def describe(args, context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, canvas} <- ToolAccess.fetch_for_read(canvas_id, context) do
      case CanvasServer.describe(canvas.id) do
        {:ok, %{document: doc, revision: rev}} ->
          maybe_subscribe(canvas.id)

          {:ok,
           %{
             canvas_id: canvas_id,
             title: canvas.title,
             space_id: canvas.space_id,
             kind: CanvasDocument.root_kind(doc),
             revision: rev,
             document: doc,
             # From `canvas.id`, not from the argument: `Platform.UUID`
             # accepts an uppercase id and the query downcases it, so
             # building from the raw argument would emit two different
             # strings for one canvas.
             view_url: Links.view_url(canvas.id),
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

  @doc """
  canvas.list_kinds — return ergonomic summaries of every registered node
  kind. Agents call this once to discover what they can emit, without
  having to parse the recursive discriminated-union JSON Schema.
  """
  @spec list_kinds(map(), map()) :: {:ok, map()}
  def list_kinds(_args, _context) do
    # Task 01a04a7a stage 4: the kind registry is static and returned whole.
    {:ok, Platform.Federation.ResultBound.whole(:kinds, Kinds.summaries())}
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

  # ── Authorization ───────────────────────────────────────────────────────

  # Write gate for `canvas.patch` (task 019e2c4b, stage 2).
  #
  # The canvas is resolved from `canvas_id`, NOT from `context.space_id`:
  # `canvas.patch` args carry only a `canvas_id`, so `context` never has an
  # `agent_participant_id` for this call (the MCP controller derives that from
  # `args["space_id"]`). The membership question can only be asked once the
  # canvas has told us which space it lives in.
  #
  # An unidentifiable caller DENIES. It deliberately does not fall back to
  # `:system` the way `VersionHandlers.assert_member/2` falls through on a nil
  # `agent_id` — that shape fails open, and this is the tool an untrusted
  # remote runtime calls.
  #
  # Resolution lives in `ToolAccess` (task 019fb01b stage 1); only the denial
  # sentence is this handler's, because only the sentence differs between the
  # canvas write tools.
  # Returns the fetched canvas rather than `:ok` — the caller needs its
  # space_id to resolve the writer's attribution, and re-fetching it would be
  # a second read of a row the gate already has.
  defp authorize_write(canvas_id, context) do
    ToolAccess.fetch_for_write(canvas_id, context,
      denial: @patch_denial,
      suggestion: @patch_suggestion
    )
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

  defp normalize_node(node, fallback_id) do
    case decode_if_string(node) do
      map when is_map(map) -> normalize_map_node(map, fallback_id)
      other -> other
    end
  end

  defp normalize_map_node(node, fallback_id) do
    id =
      case Map.get(node, "id") do
        v when is_binary(v) and v != "" -> v
        _ -> fallback_id
      end

    props =
      case decode_if_string(Map.get(node, "props", %{})) do
        p when is_map(p) -> p
        _ -> %{}
      end

    children =
      case decode_if_string(Map.get(node, "children")) do
        list when is_list(list) ->
          Enum.map(list, &normalize_node(&1, Ecto.UUID.generate()))

        _ ->
          nil
      end

    node
    |> Map.put("id", id)
    |> Map.put("props", props)
    |> then(fn n ->
      if children, do: Map.put(n, "children", children), else: n
    end)
  end

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

  @doc """
  Parse `canvas.patch`'s wire operations (`[["set_props", id, props], ...]`)
  into `Platform.Chat.CanvasPatch` operations. Returns `{:ok, ops}` or
  `{:error, %{error: reason, recoverable: true}}` naming the first bad one.

  Public so the canvas handler binding (`Platform.Canvas.ScriptEngine.Bindings`,
  task 01a1316b-aab0 stage 1) parses exactly what this tool parses; there is
  one parser, not two.
  """
  @spec parse_operations(list()) :: {:ok, list()} | {:error, map()}
  def parse_operations(list) when is_list(list) do
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

  defp parse_op(["set_binding", name, nil]) when is_binary(name),
    do: {:ok, {:set_binding, name, nil}}

  defp parse_op(["set_binding", name, binding]) when is_binary(name) do
    case decode_if_string(binding) do
      b when is_map(b) -> {:ok, {:set_binding, name, b}}
      _ -> {:error, "set_binding: binding must be an object or null (got #{describe(binding)})"}
    end
  end

  defp parse_op(other), do: {:error, "unrecognized operation: #{inspect(other)}"}

  # Some MCP clients (and some LLM providers) serialize nested object
  # arguments as JSON strings. Accept either shape transparently so callers
  # don't have to know the wire encoding their gateway chose.
  defp space_participant_id(space_id, participant_id) do
    case Chat.get_space_participant(space_id, participant_id) do
      %Platform.Chat.Participant{id: id} -> id
      nil -> nil
    end
  end

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
