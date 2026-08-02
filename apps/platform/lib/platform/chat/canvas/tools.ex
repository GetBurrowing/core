defmodule Platform.Chat.Canvas.Tools do
  @moduledoc """
  JSON-Schema tool definitions compiled from the kind registry (ADR 0036).

  Three tools:

    * `canvas.create(space_id, title?, document)` — create a new canvas with
      a validated canonical document.
    * `canvas.patch(canvas_id, base_revision, operations)` — apply operations
      with rebase-or-reject concurrency. Returns the new revision or a
      structured rejection the agent can use to self-correct.
    * `canvas.describe(canvas_id)` — return `{document, revision, view_url,
      presence, recent_events}`. Idempotent, cheap; agents should call freely.

  The `document` parameter of `canvas.create` and `replace_document` patches
  is a recursive discriminated union over every registered kind. Schemas are
  compiled at runtime from `Platform.Chat.Canvas.Kinds.tool_schemas/0` — the
  next call to `definitions/0` reflects any new kind immediately.

  ## Sharing boundary

  `sharing_boundary/0` is the one sentence every canvas tool that hands out a
  URL repeats verbatim, and `Platform.Federation.ToolSurface` quotes the same
  function rather than paraphrasing it. It states what the code enforces and
  nothing wider: an agent that reads "shareable" and pastes a link into a
  space its reader cannot reach has been misled by the description, not by the
  authorization model.
  """

  alias Platform.Chat.Canvas.Kinds

  @tool_names [
    "canvas.create",
    "canvas.patch",
    "canvas.describe",
    "canvas.versions",
    "canvas.restore"
  ]

  # The sharing boundary, stated as the code enforces it (task 019e2c4b).
  #
  # Every clause here is a grant path in `Platform.Chat.CanvasAccess`:
  # `:member` (space participation), `:task_reader` (org membership on a task
  # the canvas is attached to) and `:org_reader` (org membership where the
  # parent space is a non-archived CHANNEL that carries an org). Execution
  # spaces are excluded from `:org_reader` by `Chat.space_accessible?/1`, which
  # is why the task-attachment nudge is here rather than in a wiki page nobody
  # reads mid-call.
  #
  # The external-user clause is not redundant with the grant list: an external
  # user CAN hold `:member`, and would still be halted before mount by
  # `PlatformWeb.Plugs.ExternalUserScope`, which allowlists `/chat` only. Without
  # that clause the sentence promises a page some grant-holders cannot open.
  #
  # LIVE and NON-ARCHIVED are load-bearing, not hedging. `:task_reader` drops
  # soft-deleted tasks (`list_canvas_tasks/1` resolves them to `task: nil`), and
  # `:org_reader` runs through `Chat.space_accessible?/1`, which excludes
  # archived spaces. An archived channel is still `kind == "channel"`, so
  # without that word the sentence promises org members a canvas they would be
  # denied.
  #
  # There is deliberately no mention of a share token. None exists: a token
  # form needs a signing key, a guest host scope and a revocation model, none
  # of which shipped. Naming a mechanism that does not exist would be the one
  # failure mode worse than the missing feature.
  # The agent clause (task 019fb01b stage 2) is stated separately from the
  # human ones because it is keyed on a different column. The three human
  # grants read `org_memberships.user_id`, which is meaningless for an agent
  # id; an agent reaches a canvas outside its own spaces only through a task's
  # `phase_assignees` map. It says "an agent assigned to" rather than naming the
  # column, because the reader of this sentence is a model deciding whether to
  # paste a link, not a maintainer.
  @sharing_boundary "Returned URLs are canonical Suite links, never share tokens. A link opens only " <>
                      "for a viewer who already holds a grant on the canvas: a participant of its " <>
                      "space, an AGENT assigned to a LIVE task the canvas is attached to, a member " <>
                      "of the org that owns such a task, or a member of the org that owns the space " <>
                      "when the canvas lives in a NON-ARCHIVED channel. External users never reach " <>
                      "the page whatever their grant. No share-token mechanism exists, so a link " <>
                      "cannot be widened past that. A canvas created in an execution space is " <>
                      "reachable only through the task path, so attach it to a task in your " <>
                      "reader's org with task_attach_canvas before pasting the link or they get a " <>
                      "403."

  # The read gate, quoted by the two canvas READS (task 019fb01b stage 3).
  # Separate from `@sharing_boundary`: that one is about who can open a URL you
  # hand a human, this one is about whether the tool call you are making now
  # will resolve. They were one sentence-set until describe and versions were
  # gated, at which point conflating them would have left a model unable to
  # tell "I cannot read this" from "my reader cannot open this".
  @read_gate "You can read a canvas if you participate in its space, or if you are assigned to a " <>
               "live task it is attached to. Otherwise the call is denied. A denial for a canvas " <>
               "that does not exist reads differently from one you may not read: not-found means " <>
               "the id or the attachment is stale, denied means ask a human to add you to the " <>
               "space or to attach the canvas to your task."

  @doc "Tool names handled by this module."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @doc """
  The sharing boundary for canvas URLs, in one sentence-set, quoted verbatim by
  every canvas tool description that returns a URL.

  Exposed rather than inlined so `Platform.Federation.ToolSurface` states the
  same boundary as this module, and so a test can assert both surfaces carry
  it.
  """
  @spec sharing_boundary() :: String.t()
  def sharing_boundary, do: @sharing_boundary

  @doc """
  The read gate for the canvas-id-keyed READS, quoted verbatim by every
  description of one.

  Exposed for the same reason `sharing_boundary/0` is, plus one specific to
  this stage: `PlatformWeb.MCPController.to_mcp_tool/1` forwards only `name`,
  `description` and `inputSchema`, so a gate stated only in a `limitations`
  field is read by maintainers and by nobody who calls the tool. An agent that
  is denied needs to know from the description whether to ask for roster or to
  drop a stale attachment.
  """
  @spec read_gate() :: String.t()
  def read_gate, do: @read_gate

  @doc "Return the list of agent tool definitions."
  @spec definitions() :: [map()]
  def definitions do
    [
      create_tool(),
      patch_tool(),
      describe_tool(),
      versions_tool(),
      restore_tool()
    ]
  end

  # ── canvas.create ────────────────────────────────────────────────────────

  defp create_tool do
    %{
      "name" => "canvas.create",
      "description" =>
        "Create a new live canvas in a space. The document must be a canonical node tree with a root node whose type is one of the registered kinds: #{Enum.join(Kinds.names(), ", ")}. Returns the canvas id, title, kind, revision, and view_url — the canonical page for the canvas, which you can cite back to a human. #{@sharing_boundary}",
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
        "Return the current document, revision, view_url, presence, and recent events for a canvas you hold a grant on. Cheap and idempotent; call this before emitting patches to ensure the caller's base_revision is fresh, or to recover the view_url of a canvas you did not create. #{@read_gate} #{@sharing_boundary}",
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

  # ── canvas.versions ──────────────────────────────────────────────────────

  defp versions_tool do
    %{
      "name" => "canvas.versions",
      "description" =>
        "List a canvas's revision history newest-first. Each entry has revision, written_at, written_by, and a 1-sentence op_summary. Use limit + before_revision to paginate. Same auth gate as canvas.describe, literally: both resolve through Platform.Chat.Canvas.ToolAccess.fetch_for_read/2. #{@read_gate} #{@sharing_boundary}",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["canvas_id"],
        "properties" => %{
          "canvas_id" => %{"type" => "string"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "before_revision" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Cursor — return only revisions strictly less than this"
          }
        }
      }
    }
  end

  # ── canvas.restore ───────────────────────────────────────────────────────

  defp restore_tool do
    %{
      "name" => "canvas.restore",
      "description" =>
        "Replace the live canvas with the document from a historical revision. The restore is itself a write — it produces a new revision row at current+1. Same auth gate as canvas.patch.",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["canvas_id", "revision"],
        "properties" => %{
          "canvas_id" => %{"type" => "string"},
          "revision" => %{"type" => "integer", "minimum" => 1}
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
