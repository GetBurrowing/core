defmodule Platform.Chat.Canvas.Tools do
  @moduledoc """
  JSON-Schema tool definitions compiled from the kind registry (ADR 0036).

  Three tools:

    * `canvas.create(space_id, title?, document)` — create a new canvas with
      a validated canonical document.
    * `canvas.patch(canvas_id, base_revision, operations)` — apply operations
      with rebase-or-reject concurrency. Returns the new revision or a
      structured rejection the agent can use to self-correct.
    * `canvas.describe(canvas_id)` — return `{document, revision, presence,
      recent_events}`. Idempotent, cheap; agents should call freely.

  The `document` parameter of `canvas.create` and `replace_document` patches
  is a recursive discriminated union over every registered kind. Schemas are
  compiled at runtime from `Platform.Chat.Canvas.Kinds.tool_schemas/0` — the
  next call to `definitions/0` reflects any new kind immediately.
  """

  alias Platform.Chat.Canvas.Kinds

  @tool_names ["canvas.create", "canvas.patch", "canvas.describe"]

  @doc "Tool names handled by this module."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @doc "Return the list of agent tool definitions."
  @spec definitions() :: [map()]
  def definitions do
    [
      create_tool(),
      patch_tool(),
      describe_tool()
    ]
  end

  # ── canvas.create ────────────────────────────────────────────────────────

  defp create_tool do
    %{
      "name" => "canvas.create",
      "description" =>
        "Create a new live canvas in a space. The document must be a canonical node tree with a root node whose type is one of the registered kinds: #{Enum.join(Kinds.names(), ", ")}.",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["space_id", "document"],
        "properties" => %{
          "space_id" => %{"type" => "string", "description" => "Target space UUID"},
          "title" => %{"type" => "string", "description" => "Human-readable title (optional)"},
          "document" => document_schema()
        }
      }
    }
  end

  # ── canvas.patch ─────────────────────────────────────────────────────────

  defp patch_tool do
    %{
      "name" => "canvas.patch",
      "description" =>
        "Apply patch operations to a canvas. Requires the current base_revision so the server can rebase-or-reject. On rejection the response includes a structured reason, the offending op index, the current revision, and (when relevant) the current tree so the agent can retry.",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["canvas_id", "base_revision", "operations"],
        "properties" => %{
          "canvas_id" => %{"type" => "string"},
          "base_revision" => %{"type" => "integer", "minimum" => 1},
          "operations" => %{
            "type" => "array",
            "items" => operation_schema(),
            "minItems" => 1
          }
        }
      }
    }
  end

  # ── canvas.describe ──────────────────────────────────────────────────────

  defp describe_tool do
    %{
      "name" => "canvas.describe",
      "description" =>
        "Return the current document, revision, presence, and recent events for a canvas. Cheap and idempotent; call this before emitting patches to ensure the caller's base_revision is fresh.",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["canvas_id"],
        "properties" => %{
          "canvas_id" => %{"type" => "string"}
        }
      }
    }
  end

  # ── Shared schemas ───────────────────────────────────────────────────────

  @doc "Compile the document JSON schema (recursive discriminated union over kinds)."
  @spec document_schema() :: map()
  def document_schema do
    %{
      "type" => "object",
      "description" =>
        "Canonical canvas document. `root` is a node whose `type` is one of the registered kinds.",
      "additionalProperties" => false,
      "required" => ["version", "revision", "root"],
      "properties" => %{
        "version" => %{"type" => "integer", "const" => 1},
        "revision" => %{"type" => "integer", "minimum" => 1},
        "root" => node_schema(),
        "theme" => %{"type" => "object"},
        "bindings" => %{"type" => "object"},
        "meta" => %{"type" => "object"}
      }
    }
  end

  @doc "Compile the node schema as a discriminated union over kinds."
  @spec node_schema() :: map()
  def node_schema do
    %{
      "oneOf" =>
        Enum.map(Kinds.all(), fn mod ->
          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["id", "type"],
            "properties" => node_properties(mod)
          }
        end)
    }
  end

  defp node_properties(mod) do
    name = mod.name()

    base = %{
      "id" => %{"type" => "string", "minLength" => 1},
      "type" => %{"type" => "string", "const" => name},
      "props" => merged_props(mod)
    }

    case mod.children() do
      :none ->
        base

      :any ->
        Map.put(base, "children", %{"type" => "array", "items" => %{"type" => "object"}})

      whitelist when is_list(whitelist) ->
        Map.put(base, "children", %{
          "type" => "array",
          "description" => "Allowed child kinds: #{Enum.join(whitelist, ", ")}",
          "items" => %{"type" => "object"}
        })
    end
  end

  defp merged_props(mod) do
    struct_props = mod.schema()
    styling_props = mod.styling()

    Map.merge(struct_props, styling_props, fn
      "properties", a, b when is_map(a) and is_map(b) -> Map.merge(a, b)
      "required", a, b when is_list(a) and is_list(b) -> Enum.uniq(a ++ b)
      _k, _a, b -> b
    end)
  end

  defp operation_schema do
    %{
      "description" =>
        "One of: [\"set_props\", node_id, props] | [\"replace_children\", node_id, children] | [\"append_child\", parent_id, child] | [\"delete_node\", node_id] | [\"replace_document\", document].",
      "type" => "array",
      "minItems" => 2,
      "maxItems" => 3
    }
  end
end
