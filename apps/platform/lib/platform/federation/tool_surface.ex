defmodule Platform.Federation.ToolSurface do
  @moduledoc """
  Tool surface for federated agents.
  Same tools available to built-in and external runtimes.
  Includes both write tools and bounded read tools for space context.

  ## `canvas_get` is WIDER than it was (task 019fb01b, stage 4)

  `canvas_get` used to ask `assert_agent_in_space/2` one question: is this agent
  a participant of the canvas's space. It now asks
  `Platform.Chat.Canvas.ToolAccess.fetch_for_read/2`, the same seam
  `canvas.describe` and `canvas.versions` use, so every canvas-id-keyed read on
  this surface has one rule.

  That move ADDS callers. It denied a non-rostered agent before and it still
  denies one with no other claim, but an agent holding the `:task_agent` grant —
  bound by a task's `phase_assignees` map to a live task the canvas is attached
  to — now resolves a canvas in a space it was never added to. It also keeps
  failing closed on a nil `agent_id`, which is the boundary of the widening: the
  new reach is "agents bound to the task", never "callers we cannot identify".

  The widening is the point of the stage, not a side effect of code reuse.
  `Platform.Orchestration.PromptTemplates` has been instructing the planner
  "if a design direction canvas is attached to this task, read it with
  `canvas_get`" while that call denied the planner in the exact shape the
  instruction describes: ADR-0046's native path has the designer create the
  canvas in its OWN space, which the planner is not rostered in. The instruction
  was false. This makes it true.

  What it does not widen: `canvas_get` still returns nothing about a canvas the
  caller may not read, `canvas_list` still enumerates only spaces the agent
  participates in (see the comment on its clause), and read grants still confer
  no write. The residual risk this inherits — `task_attach_canvas` does not
  authorize the attacher against the task, so an attachment can be pushed onto a
  task by anyone who can already read the canvas — is knowingly accepted and
  filed as task 019fb581, not discovered here.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Architecture.StageAudit
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, ContextPlane, Participant}
  alias Platform.Design.Brand
  alias Platform.Design.PreplanStep
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Memory.JournalSweep
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Journal, Routing, Search}
  alias Platform.Orchestration.Diagnostics
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Tasks

  alias Platform.Tasks.{
    CanvasAttachments,
    DeliveryReference,
    PhaseTransitions,
    Plan,
    PlanEngine,
    Stack,
    StackDeployer,
    Stacks,
    Stage,
    Task,
    Validation
  }

  alias Platform.Tasks.Stacks.CommencementGate
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Repo

  alias Platform.Federation.ResultBound
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.TaskAttrs

  import Ecto.Query, only: [from: 2]

  @bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files meetings)

  # Per-message content cap (graphemes) for space_get_messages /
  # space_search_messages. Anything longer is sliced and flagged via the
  # `content_truncated` boolean on the returned map.
  @message_content_cap 64_000

  # ── External-principal chat allowlist (M11, rbac-external-users) ───────
  #
  # These are exactly the tools an EXTERNAL principal (a runtime whose
  # owner holds an `org_memberships` row with `external: true`) needs to
  # hold a scoped chat conversation:
  #
  #   * send_media            — post a message/attachment into a space
  #   * react                 — react to a message
  #   * space_list            — see the spaces they participate in
  #   * space_get_context     — read a space's context
  #   * space_get_messages    — read a space's messages
  #   * space_search_messages — search within a space
  #
  # Everything else — all of task/plan/review/canvas/memory/skill/
  # attachment/federation/files, plus the mutating `space_leave` — is
  # blocked for external principals per the RBAC v1 design (canvas
  # 019f4d7f §4 "Federation MCP" row + §11 mcp item: "block all non-chat
  # tools entirely"). A name-level allowlist (rather than a bundle
  # allowlist) expresses "chat tools" precisely: the `space` bundle mixes
  # `space_list` with the mutating `space_leave`, and `context_read` mixes
  # message reads with `canvas_get`/`principal_search`.
  @external_chat_tools MapSet.new(
                         ~w(send_media react space_list space_get_context space_get_messages space_search_messages)
                       )

  @doc "Known capability bundle names."
  def all_bundles, do: @bundles

  @doc """
  Returns the full tool surface.

  Each tool follows the 6-component rubric:
  name, description, parameters, returns, limitations, when_to_use, plus a
  `:bundle` key identifying which capability bundle owns the tool.
  """
  def tool_definitions, do: list_tools(@bundles)

  @doc """
  Returns tools scoped to the given capability bundles.

  Unknown bundle names are skipped silently. Duplicate names are deduped.
  """
  def list_tools(bundles) when is_list(bundles) do
    bundles
    |> Enum.uniq()
    |> Enum.flat_map(&tools_for_bundle/1)
  end

  @doc "The set of tool names an external principal may see/call (chat only)."
  def external_chat_tools, do: @external_chat_tools

  @doc "Is `name` a chat tool an external principal is allowed to use?"
  def external_chat_tool?(name) when is_binary(name),
    do: MapSet.member?(@external_chat_tools, name)

  @doc """
  Reduce a tool list to the external-chat allowlist when `external?` is true.

  When `external?` is `false` this is the identity function — internal
  principals are unaffected.

  CRITICAL PROPERTY: this is an INTERSECTION applied AFTER `list_tools/1`,
  so it can only ever REMOVE tools, never add one. An external runtime
  whose `allowed_bundles` do not include a chat bundle still gets zero
  chat tools (fail-closed) — the filter never grants a capability the
  runtime's bundles did not already include. The existing bundle scope
  remains the outer bound; external-restriction is layered inside it
  (defense-in-depth).
  """
  def scope_for_external(tools, true),
    do: Enum.filter(tools, &MapSet.member?(@external_chat_tools, &1.name))

  def scope_for_external(tools, false), do: tools

  defp tools_for_bundle("canvas"), do: tag(canvas_tools(), "canvas")
  defp tools_for_bundle("messaging"), do: tag(messaging_tools(), "messaging")
  defp tools_for_bundle("task"), do: tag(task_tools(), "task")
  defp tools_for_bundle("plan"), do: tag(plan_tools(), "plan")
  defp tools_for_bundle("review"), do: tag(review_tools(), "review")
  defp tools_for_bundle("space"), do: tag(space_tools(), "space")
  defp tools_for_bundle("context_read"), do: tag(context_read_tools(), "context_read")
  defp tools_for_bundle("federation"), do: tag(federation_tools(), "federation")
  defp tools_for_bundle("memory"), do: tag(memory_tools(), "memory")
  defp tools_for_bundle("skill"), do: tag(skill_tools(), "skill")
  defp tools_for_bundle("attachment"), do: tag(attachment_tools(), "attachment")
  defp tools_for_bundle("files"), do: tag(files_tools(), "files")
  defp tools_for_bundle("meetings"), do: tag(meetings_tools(), "meetings")
  defp tools_for_bundle(_), do: []

  defp tag(tools, bundle), do: Enum.map(tools, &Map.put(&1, :bundle, bundle))

  defp federation_tools do
    [
      %{
        name: "federation_status",
        description:
          "Check the status of all registered agent runtimes. Reports three groups of facts that routinely disagree: connection (is a socket up), build (which code the process is running), and proven (which capabilities core has actually OBSERVED this runtime exercise).",
        parameters: %{},
        returns:
          "Array of runtime status objects with runtime_id, agent_name, agent_slug; connection: online, connected_at, last_seen_at, last_connected_at; build: client_build (\"unknown\" if the client never told us), process_started_at; proven: {capability => ISO8601 timestamp or \"never\"}; declared_features",
        limitations:
          "Only shows active runtimes. `online` means the socket is live and nothing more — it says nothing about which build is loaded or what that build can do. Presence and `proven` are in-memory and reset on restart, so `never` after a core restart means \"not since restart\". `declared_features` is the runtime's own claim and cannot discriminate builds that ship a capability from builds that do not; read `client_build` and `proven` instead.",
        when_to_use:
          "When you need to diagnose connectivity issues or verify which agent runtimes are currently reachable"
      }
    ]
  end

  defp attachment_tools do
    [
      %{
        name: "attachment.upload_inline",
        description:
          "Upload bytes as a base64 string in a single call (ADR 0039). Use for payloads up to the configured inline limit (default 25 MB). Returns a /chat/attachments/<id> URL suitable for referencing as a canvas image src or embedding in a message.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "Target space UUID"},
          filename: %{type: "string", required: true, description: "Client-reported filename"},
          content_type: %{
            type: "string",
            required: true,
            description: "MIME type (e.g. image/png)"
          },
          data_base64: %{
            type: "string",
            required: true,
            description: "Base64-encoded file bytes"
          },
          canvas_id: %{
            type: "string",
            required: false,
            description: "Attach to a specific canvas (space_id is still required)"
          }
        },
        returns: "%{id, url, byte_size, content_hash, content_type, deduplicated}",
        limitations:
          "Capped at :inline_upload_max_bytes (default 25 MB). Use attachment.upload_start for larger files. Dedup is per-space — identical content in the same space returns the canonical id.",
        when_to_use:
          "When you have bytes in hand and they fit under the inline cap. Ideal for screenshots, diagrams, small documents."
      },
      %{
        name: "attachment.get_inline",
        description:
          "Read an attachment back as base64 inline bytes (ADR 0039 phase 7). Loads the row, fetches the stored bytes, base64-encodes them, and returns the decoded payload along with content_type, byte_size, and filename. Cap is 25 MB; for larger files use a presigned download URL (follow-up).",
        parameters: %{
          attachment_id: %{
            type: "string",
            required: true,
            description:
              "Attachment UUID (from message.attachments[].url or another tool's payload)"
          }
        },
        returns: "%{content_type, byte_size, data_base64, filename}",
        limitations:
          "Capped at 25 MB. Caller agent must be a participant in the space the attachment belongs to. Attachments without a parent message space (legacy rows) are not retrievable here.",
        when_to_use:
          "When you need to read attachment bytes — e.g. to OCR an image, summarize a document, or hand bytes to a tool that does not accept URLs."
      },
      %{
        name: "attachment.upload_start",
        description:
          "Reserve a pending attachment row and get back a presigned POST URL to stream raw bytes to (ADR 0039). Use for files larger than the inline cap, or when the agent wants to hand off bytes via a plain HTTP POST.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "Target space UUID"},
          filename: %{type: "string", required: true, description: "Client-reported filename"},
          content_type: %{
            type: "string",
            required: true,
            description: "MIME type — the POST's Content-Type header must match"
          },
          byte_size: %{
            type: "integer",
            required: true,
            description: "Declared size in bytes; enforced at POST time"
          },
          canvas_id: %{
            type: "string",
            required: false,
            description: "Attach to a specific canvas"
          }
        },
        returns: "%{id, upload_url, expires_at, max_bytes, url}",
        limitations:
          "Capped at :upload_max_bytes (default 500 MB). The reservation TTL is :pending_ttl_seconds (default 15 min); expired pending rows are reaped.",
        when_to_use:
          "Files over the inline cap, or any case where streaming bytes directly is preferable to base64-in-JSON."
      }
    ]
  end

  # ── Files (ADR 0042) ────────────────────────────────────────────────────
  # Surfaces the project-scoped document store. Authorization mirrors
  # `memory_search` at the dispatch layer — tenant-pinned agents may
  # only read files in their own org; root-pinned agents see every
  # tenant. The error envelope matches the `recoverable: false`
  # `unauthorized: …` shape that memory_search returns so federated
  # clients have one consistent handling path.
  defp files_tools do
    [
      %{
        name: "file_list",
        description:
          "List the most recent files for a project (ADR 0042 document store). Filterable by content_type. Authorization mirrors memory_search — tenant-pinned agents may only list files in projects under their own org.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "UUID of the project whose files you want to list."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant pin. Optional — when omitted the org is derived from the project. When provided, must match the project's owning org or the call is rejected."
          },
          content_type: %{
            type: "string",
            required: false,
            description:
              "Exact MIME-type filter (e.g. `\"application/pdf\"`, `\"image/png\"`). Omit for all types."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max rows to return (default 50, max 200)."
          }
        },
        returns:
          "%{files: [%{id, name, original_filename, content_type, byte_size, inserted_at, ingest_status, ingest_intent, agent_content_available, agent_content_note}], project_id, count}",
        limitations:
          "Tenant-pinned agents calling with a sibling-org project return an `unauthorized: …` envelope (NOT an empty list, so existence can't be probed). Unknown project_id returns `:not_found`. Files still ingesting carry `ingest_status: \"pending\"` — call file_get_text only on \"ingested\" rows. Files marked human-only (`ingest_intent: \"human_only\"`) ARE listed here, deliberately: their content is never retrievable by an agent (`agent_content_available: false`, and `file_get_text` returns `:human_only`), but the file exists and a person can read it. Surface such a file to the human by name and quote `agent_content_note` — do NOT tell them no such file exists.",
        when_to_use:
          "When you need to enumerate the documents in a project — e.g. before calling file_get_text to read one, or to surface the right file to the user."
      },
      %{
        name: "file_get_text",
        description:
          "Fetch the extracted text body for a single file (ADR 0042). Returns the full body or — when `page` is supplied and the file has a per-page split (PDF, gdoc) — that page only. Reads from the `platform_file_texts` cache populated at ingest time; no re-extraction. Set `binary: true` to skip the text cache and return the raw bytes base64-encoded — agents almost always want text, so reach for `binary: true` only when handing the file off to another tool that needs the actual bytes (zip, image, raw blob the extractor can't read). Files marked human-only (`ingest_intent: \"human_only\"`) ARE listed by file_list and file_get_metadata, but are never readable here — neither as text nor as bytes; both branches return `:human_only`.",
        parameters: %{
          file_id: %{
            type: "string",
            required: true,
            description: "UUID of the file row to read."
          },
          page: %{
            type: "integer",
            required: false,
            description:
              "1-based page index. Only honored for paginated formats (PDF, gdoc); flow formats (CSV, text, OCR'd image) return the full body regardless. Ignored when `binary: true`."
          },
          binary: %{
            type: "boolean",
            required: false,
            description:
              "Default `false`. When `true`, skip the extracted-text lookup and return the raw bytes as base64 in `data_base64`. Capped at 25 MB — larger files return `:too_large`. Use sparingly: agents nearly always want text. Does NOT bypass the human-only audience gate — a `human_only` file returns `:human_only` here too."
          }
        },
        returns:
          "Default: %{file_id, content_type, text, page?, total_pages?, original_filename}. With `binary: true`: %{file_id, content_type, byte_size, data_base64, original_filename}.",
        limitations:
          "Authorization mirrors file_list. Unknown `file_id` → `:not_found`. File not yet ingested / extraction failed → `:no_text_available` (consider retrying with `binary: true` if you just need the raw bytes). A file marked human-only → `:human_only` from BOTH branches: its contents are deliberately withheld from agents, and it is also absent from file_search hits. That is a decision, not a fault, and `binary: true` is not a way around it — the file is still listed by file_list, so tell the human it exists and ask them to describe it. `page` out of range → `:page_out_of_range`. Tenant-pinned agents reading a sibling-org file → `unauthorized: …`. `binary: true` over 25 MB → `:too_large` (a presigned-download path is planned but not yet shipped).",
        when_to_use:
          "When you have a file_id (e.g. from file_list or a memory_search hit with `memory_type=document`) and want to read its extracted text — either the whole body or one specific page. Pass `binary: true` for the rare case of needing the raw bytes (e.g. handing a zip off to another tool) — agents nearly always want text."
      },
      %{
        name: "file_get_metadata",
        description:
          "Fetch the metadata for a single file (ADR 0042) — richer than the `file_list` row: includes uploader, project/org pin, content hash, and timestamps. Does NOT include `storage_key` (internal) or the extracted text body (use `file_get_text` for that).",
        parameters: %{
          file_id: %{
            type: "string",
            required: true,
            description: "UUID of the file row to inspect."
          }
        },
        returns:
          "%{file_id, project_id, org_id, name, original_filename, content_type, byte_size, content_hash, ingest_status, ingest_intent, agent_content_available, agent_content_note, uploaded_by_user_id, inserted_at, updated_at}",
        limitations:
          "Authorization mirrors file_list / file_get_text. Unknown `file_id` → `:not_found`. Tenant-pinned agents reading a sibling-org file → `unauthorized: …`. `storage_key` is intentionally omitted — it's an internal handle into the object store, not a stable public identifier. Metadata is returned for human-only files too (`ingest_intent: \"human_only\"`, `agent_content_available: false`): the row is never hidden, only its content is withheld, so tell the human about the file and quote `agent_content_note` rather than denying it exists.",
        when_to_use:
          "When you have a file_id and want to know the row's properties (uploader, size, MIME-type, ingest status) without pulling the extracted text body."
      },
      %{
        name: "file_search",
        description:
          "Semantic search across the extracted text of a project's files (ADR 0042). Delegates to the same embedded corpus the ingester populates (`Platform.Memory.ingest/1`) so results match the chunks indexed at upload time — a parallel SQL ILIKE would diverge. Scoped to a single project and the `document` memory_type so hits never bleed in from journal or page entries.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the project to search within. Files outside this project are never returned."
          },
          query: %{
            type: "string",
            required: true,
            description:
              "Natural-language search query — embedded server-side and matched against the file chunks."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max hits to return (default 20, max 100 — mirrors `memory_search`)."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant pin. Optional — when omitted the org is derived from the project. When provided, must match the project's owning org or the call is rejected."
          }
        },
        returns:
          "%{project_id, count, hits: [%{file_id, name, original_filename, content_type, snippet, score}]}",
        limitations:
          "Authorization mirrors file_list / file_get_text. Tenant-pinned agents calling with a sibling-org project return an `unauthorized: …` envelope. Unknown `project_id` returns `:not_found`. Hits whose underlying file row has been deleted are silently dropped (no `:not_found` per-hit). Files not yet ingested are not in the index and therefore not searchable — call `file_list` to enumerate ingest_status. No matches returns an empty `hits` list (NOT `:not_found`).",
        when_to_use:
          "When you need to find files in a project by what they contain (semantic match), not by filename — e.g. \"which file mentions the rate-limit cap\". For metadata-only lookups use `file_list` (with `content_type` filter) instead."
      },
      %{
        name: "file_add",
        description:
          "Upload a file into a project's document store (ADR 0042). One tool, two branches — pass `data_base64` for the inline path (small bytes, capped at 25 MB) or pass `byte_size` alone for the presigned-upload path (large files up to 500 MB). Inline branch persists bytes, dedups against prior `(project_id, content_hash)` siblings, fires extract + Memory ingest async, and returns the file id with `state: \"ready\"`. Presigned branch reserves a `platform_files` row in `ingest_status: \"pending\"`, returns a host-relative `upload_url` (a `/chat/attachments/upload/<token>` path on this Suite host — prefix your base URL), and surfaces `state: \"pending\"`. POST the raw bytes (`Content-Type` matching `content_type`, e.g. `curl --data-binary @file -H 'Content-Type: application/pdf' <base_url><upload_url>`) before `expires_at`; the response is the same `state: \"ready\"` envelope as the inline branch (`id`, `byte_size`, `content_hash`, `deduplicated`), extract + Memory ingest run async, and the file becomes searchable once `file_list` shows `ingest_status: \"ingested\"`. Expired token 410, body over `max_bytes` 413, wrong content-type 400, second POST 409.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the project to add the file under. Authorization mirrors file_list — tenant-pinned agents may only write to projects in their own org."
          },
          filename: %{
            type: "string",
            required: true,
            description: "Client-reported filename. Used for display + storage-key derivation."
          },
          content_type: %{
            type: "string",
            required: true,
            description:
              "MIME type (e.g. `\"text/plain\"`, `\"application/pdf\"`). Determines which extractor runs at ingest."
          },
          data_base64: %{
            type: "string",
            required: false,
            description:
              "Base64-encoded bytes for the INLINE branch. Capped at 25 MB. Mutually exclusive with `byte_size` — pass one or the other."
          },
          byte_size: %{
            type: "integer",
            required: false,
            description:
              "Declared upload size in bytes for the PRESIGNED branch. Capped at 500 MB. Required when `data_base64` is absent; ignored when `data_base64` is provided (the actual byte length wins)."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant pin. Optional — when omitted the org is derived from the project. When provided, must match the project's owning org or the call is rejected."
          }
        },
        returns:
          "INLINE: %{id, project_id, state: \"ready\", deduplicated: boolean, byte_size, content_hash, content_type}. PRESIGNED: %{id, project_id, upload_url, expires_at, max_bytes, state: \"pending\"}.",
        limitations:
          "Caller MUST pass exactly one of `data_base64` (inline) or `byte_size` (presigned) — passing neither returns a recoverable arg error; passing both takes the inline branch and ignores `byte_size`. Inline cap is 25 MB; payloads over that should use the presigned branch. Presigned-branch rows are not searchable / readable via file_get_text until bytes finalize (status flips from `pending` → `ingested`). Agent uploads have no `uploaded_by_user_id` — historic uploader tracking only applies to user-driven LiveView uploads. Tenant-pinned agents writing to a sibling-org project → `unauthorized: …` envelope. Unknown `project_id` → `:not_found`.",
        when_to_use:
          "When you need to add a document to a project — either by handing bytes directly (small file, e.g. a generated report) or by reserving a slot for the caller to POST a large file separately. Prefer the inline branch unless the file is genuinely large."
      },
      %{
        name: "file_delete",
        description:
          "Delete a file (ADR 0042). REVERSIBLE for 30 days: the file is soft-deleted — hidden from every list/read/search surface and scrubbed from the AI search index, but restorable by a human (Undo in the Files UI) until the 30-day retention window lapses, after which it is permanently purged. The delete is audit-logged with you (the calling agent) attributed. Idempotent — re-deleting a non-existent or already-deleted file returns the standard `:not_found` envelope rather than crashing. Broadcasts `{:file_deleted, file_id}` on the project topic so live UIs (FilesLive) drop the row without a manual refresh.",
        parameters: %{
          file_id: %{
            type: "string",
            required: true,
            description: "UUID of the file row to delete."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant pin. Optional — when omitted the org is derived from the file's project. When provided, must match the project's owning org or the call is rejected."
          }
        },
        returns: "%{file_id, deleted: true}",
        limitations:
          "Authorization mirrors file_list / file_get_text. Unknown `file_id` → `:not_found` (idempotent — a second delete looks the same as a never-existed id). Tenant-pinned agents deleting a sibling-org file → `unauthorized: …` envelope. Deleting does NOT free storage immediately — bytes are retained for the 30-day undo window and reclaimed by the retention sweeper. Deleting a file in an archived project → `:project_archived`. There is no agent-facing restore tool — undo is human-driven from the Files UI.",
        when_to_use:
          "When a file should be removed from a project — retracting stale or superseded content. Deletes are reversible for 30 days, so prefer deleting a wrong upload over leaving it searchable; but don't use delete to free storage (bytes persist until the retention window lapses)."
      }
    ]
  end

  defp skill_tools do
    [
      %{
        name: "skill.list",
        description:
          "List registered skills (centrally-distributed markdown playbooks). Returns summaries without the content body. Use `query` to filter by case-insensitive substring against name, description, or slug.",
        parameters: %{
          query: %{
            type: "string",
            required: false,
            description: "Case-insensitive substring to filter by. Omit to list everything."
          }
        },
        returns:
          "%{count, skills: [%{id, slug, name, description, content_size, inserted_at, updated_at}]}",
        limitations:
          "Returns every matching skill in one call — no pagination. Content body is omitted; fetch with skill.get.",
        when_to_use:
          "Before picking a playbook for a task, or when you need to check whether a skill already exists."
      },
      %{
        name: "skill.get",
        description: "Fetch a full skill (including markdown content) by slug or id.",
        parameters: %{
          slug: %{
            type: "string",
            required: false,
            description: "Skill slug (preferred lookup key)."
          },
          id: %{
            type: "string",
            required: false,
            description: "Skill UUID (alternative lookup key)."
          }
        },
        returns: "%{id, slug, name, description, content, inserted_at, updated_at}",
        limitations: "Exactly one of `slug` or `id` is required.",
        when_to_use:
          "After skill.list has told you the skill exists and you want to read it; before skill.upsert to fetch current content for editing."
      },
      %{
        name: "skill.upsert",
        description:
          "Create or update a skill by name. Slug is derived from the name. Existing skills with the same slug are replaced (content + description).",
        parameters: %{
          name: %{
            type: "string",
            required: true,
            description: "Human-readable name. Slug is derived from this."
          },
          description: %{
            type: "string",
            required: false,
            description: "One-line summary shown in skill.list."
          },
          content: %{
            type: "string",
            required: true,
            description: "Full markdown body of the skill playbook."
          }
        },
        returns:
          "%{id, slug, name, description, content, inserted_at, updated_at, action: :created | :updated}",
        limitations:
          "Partial updates are not supported — pass the full content on every update. Two skills with the same slug-able name would collide; use a more specific name to disambiguate.",
        when_to_use:
          "When you want to publish a new playbook or iterate on an existing one without touching the DB directly."
      }
    ]
  end

  # ── Memory tools (ADR-0041 T5) ───────────────────────────────────────────
  # Anthropic memory-tool-trained naming. Path determines routing through
  # `Platform.Org.Wiki.Routing`; the per-tool descriptions document the
  # path-policy table so agents can read the rules from the catalog.
  defp memory_tools do
    [
      %{
        name: "memory_view",
        description:
          "Read a memory page or a day's journal entries. Returns the full body for pages/private notes, or a virtual concatenation of all entries for a journal day. Path determines routing: `org/page/...` / `project/<uuid>/page/...` / `space/<uuid>/page/...` (curated wiki), `*/journal/<YYYY-MM-DD>.md` (append-only journal), `space/<uuid>/private/<agent_id>/...` (owner-only scratch).",
        parameters: %{
          path: %{
            type: "string",
            required: true,
            description:
              "File-key path (e.g. `org/page/identity.md`, `org/journal/2026-05-20.md`, `space/<uuid>/private/<agent_id>/notes.md`)."
          },
          view_range: %{
            type: "array",
            required: false,
            description:
              "Two-element [start, end] (1-based, inclusive) line slice. Omit to return the full body."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns:
          "%{path, content, kind, version?, lines_returned, ...} — page/private hits include `version`/`frontmatter`/`updated_by`; journal hits include `date`/`entry_ids`/`namespace`.",
        limitations:
          "Private paths are gated to the owning agent. Unknown namespaces return `:rejected_namespace`. Missing rows return `:not_found`.",
        when_to_use:
          "When you need to read curated org/project/space pages, today's or a past day's journal, or your own private scratch notes."
      },
      %{
        name: "memory_create",
        description:
          "Create a memory page or append a journal entry. Path determines routing: `org/page/...` / `project/<uuid>/page/...` / `space/<uuid>/page/...` (Historian-only writes), `*/journal/<YYYY-MM-DD>.md` (any agent appends), `space/<uuid>/private/<agent_id>/...` (owner only). Non-Historian writes to a page path return a `propose via journal` error with the suggested journal path.",
        parameters: %{
          path: %{
            type: "string",
            required: true,
            description: "File-key path. See description for the path-policy table."
          },
          file_text: %{
            type: "string",
            required: true,
            description:
              "Content body. For journal entries this is the entry text appended for the path's date."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns:
          "%{path, kind, ...} — page/private hits include `version`/`frontmatter`/`updated_at`; journal hits include `entry_id`/`date`/`namespace`.",
        limitations:
          "Page writes require Historian role (pin the agent to `role_key: \"historian\"` via the Roles picker). Private writes require ownership. Unknown namespaces are rejected.",
        when_to_use:
          "When you need to create a new page (Historian only), append a journal entry (any agent), or write to your own private scratch path."
      },
      %{
        name: "memory_str_replace",
        description:
          "Replace exactly one occurrence of `old_str` with `new_str` in a memory page. Page paths only — journal paths return `:journal_immutable` (the Wiki.Journal contract is append-only; propose a change via `memory_create` against the day's journal path instead).",
        parameters: %{
          path: %{type: "string", required: true, description: "Page or private path."},
          old_str: %{
            type: "string",
            required: true,
            description: "Substring to replace. Must appear exactly once in the page body."
          },
          new_str: %{
            type: "string",
            required: true,
            description: "Replacement substring."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns: "%{path, version, kind, updated_at, frontmatter}",
        limitations:
          "Zero matches → `:no_match`. Multiple matches → `:ambiguous_match` (provide more surrounding context). Journal paths → `:journal_immutable`. Optimistic-lock conflict → `:version_conflict`.",
        when_to_use:
          "When you (Historian) are editing a curated page and want a targeted substitution rather than a full body rewrite."
      },
      %{
        name: "memory_insert",
        description:
          "Insert `insert_text` before line `insert_line` (1-based) of a memory page. `insert_line = 1` prepends; `insert_line = line_count + 1` appends. Page paths only — journal paths return `:journal_immutable`.",
        parameters: %{
          path: %{type: "string", required: true, description: "Page or private path."},
          insert_line: %{
            type: "integer",
            required: true,
            description: "1-based line number to insert BEFORE. Range: `1..length(lines)+1`."
          },
          insert_text: %{
            type: "string",
            required: true,
            description: "Text block to insert. Newlines preserved."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns: "%{path, version, kind, updated_at, frontmatter}",
        limitations:
          "Out-of-range line numbers → `:out_of_range`. Journal paths → `:journal_immutable`. Optimistic-lock conflict → `:version_conflict`.",
        when_to_use:
          "When you (Historian) want to splice a block into a curated page at a known line."
      },
      %{
        name: "memory_delete",
        description:
          "Delete a memory page. Page paths only — journal paths return `:journal_immutable`. The T3 indexer picks up the delete event and removes the embedding automatically.",
        parameters: %{
          path: %{type: "string", required: true, description: "Page or private path."},
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns: "%{path, kind, deleted: true}",
        limitations:
          "Page writes require Historian role; private writes require ownership. Missing rows → `:not_found`. Journal paths → `:journal_immutable`.",
        when_to_use:
          "When you (Historian) need to retire a page, or you (owner) want to clear your private scratch path."
      },
      %{
        name: "memory_rename",
        description:
          "Atomically rename a memory page from `old_path` to `new_path`. Same-kind only (page ↔ page, private ↔ private — no cross-kind moves). Page paths only — journal paths return `:journal_immutable`. Gated against BOTH paths: the calling agent must be allowed to write to both `old_path` and `new_path`.",
        parameters: %{
          old_path: %{type: "string", required: true, description: "Current path."},
          new_path: %{type: "string", required: true, description: "Target path."},
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (default: org-level)."
          }
        },
        returns: "%{path: new_path, version, kind, updated_at, frontmatter}",
        limitations:
          "Cross-kind moves (page ↔ private) → `:ambiguous_kind`. Either-side gate failure surfaces that gate's error. Missing source → `:not_found`.",
        when_to_use:
          "When you (Historian) want to move a curated page to a new path while preserving its content + embeddings."
      },
      %{
        name: "memory_search",
        description:
          "Hybrid (semantic + lexical) search across memory pages, journal entries, chat messages, and tasks. Results are source-tagged and ranked via Reciprocal Rank Fusion (k=60) across corpora. Message hits are filtered to spaces the calling agent participates in. Each hit carries a BOUNDED SNIPPET (first 500 characters of the body) in `content`, not the full body — call `memory_view` with the hit's `path` to read the whole thing.",
        parameters: %{
          query: %{
            type: "string",
            required: true,
            description: "Natural-language search query."
          },
          source: %{
            type: "string",
            required: false,
            description:
              "Restrict to one corpus: `\"page\"`, `\"journal\"`, `\"message\"`, or `\"task\"`. Omit for all four."
          },
          namespace: %{
            type: "string",
            required: false,
            description:
              "Restrict to a namespace prefix: `\"org\"`, `\"project/<uuid>\"`, or `\"space/<uuid>\"`."
          },
          since: %{
            type: "string",
            required: false,
            description: "ISO date (YYYY-MM-DD). Only return hits at or after this date."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max results (default 20, max 100)."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description: "UUID of the workspace (legacy, default: org-level)."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant filter — restrict page/journal hits to a single org. Subject to caller authorization (tenant agents cannot query a sibling-org id)."
          },
          project_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 project filter — restrict page/journal hits to a single project."
          },
          memory_type: %{
            type: "string",
            required: false,
            description:
              "Restrict semantic hits to a single memory_type tag (e.g. `\"document\"` for files, `\"daily\"` for journal entries, `\"page\"` for curated pages). Omit to span all types."
          }
        },
        returns:
          "HEALTHY (`retrieval_status: \"ok\"`, every channel answered): %{results: [%{source, id, path, space_id, content, content_truncated, content_length, score, semantic_rank, lexical_rank, authored_by, date_or_inserted_at}], retrieval_status: \"ok\", fusion_constant_k: 60, truncated: boolean, dead_channels: [], dropped: %{page, journal, message, task}, payload_truncated: boolean} — and no `degraded` key. DEGRADED WITH SURVIVING HITS: `retrieval_status: \"degraded\"`, the hits under `partial_results` and NO `results` KEY AT ALL, plus `degraded: %{dead_channels, channels_down: [\"semantic\" | \"lexical:<corpus>\"], implication}`. The rename is deliberate: a search with a dead channel is a FAILED MEASUREMENT, not a negative result, so the hits are reachable only through a key whose name says they are partial. DEGRADED WITH ZERO SURVIVING HITS: an ERROR, `code: :search_degraded`, carrying `dead_channels` and no `results` key — an empty `results` there would read as an established absence, which it is not. `dead_channels` lists every search channel that timed out or crashed as a `[channel, corpus]` pair (e.g. `[\"semantic\", \"all\"]` or `[\"lexical\", \"task\"]`) — empty when every channel answered; `dropped` counts, per corpus, the fused hits that hydration refused (row deleted or not readable by the caller) and always carries all four keys. `content` is a 500-character snippet; `content_truncated` says whether the body was longer and `content_length` is its full byte size — fetch the body with `memory_view` on `path`. Task hits (source: \"task\") carry additional advisory fields: `status`, `priority`, `updated_at`, `merged_pr_url` (or nil), `follow_up_task_ids` (list of open tasks that reference this one), and `cancellation_note` (rework directive for cancelled tasks).",
        limitations:
          "Message hits are filtered to spaces the calling agent participates in (anonymous callers get no message hits). Deleted or orphaned rows are dropped and counted in `dropped`. `truncated: true` means the result set is incomplete for ANY reason: a channel hit its `2*limit` cap (a higher `limit` may surface more hits) OR a channel died (see `dead_channels` — a non-empty list always forces `truncated: true`; retry later rather than raising `limit`). `payload_truncated: true` is a different thing: the whole response is capped at 20_000 bytes, and lowest-ranked hits were dropped from the tail to fit. Degraded-vs-healthy is decided BEFORE that byte bound is applied, so a payload bound that empties the kept list never reports itself as `:search_degraded`. A caller written against `results` will see that key MISSING on a degraded search — that is the intended fail-loud: read `partial_results` and the `degraded` map, or treat the `:search_degraded` error as an unestablished absence.",
        when_to_use:
          "When you need to recall information beyond the org preamble — past decisions, journal entries, relevant chat threads, prior tasks (shipped or in-flight), or any cross-corpus lookup."
      },
      %{
        name: "org_memory_recently_edited",
        description:
          "List the K most recent org-memory edit events. Useful for understanding what shape of content Rowan / a human editor prefers to keep. Read-only wrapper over `Platform.MemoryFeedback.list_recent/1` scoped to `feedback_kind: \"edit\"` rows.",
        parameters: %{
          path_prefix: %{
            type: "string",
            required: false,
            description:
              "Restrict to rows whose `path` starts with this literal prefix (case-insensitive, `_`/`%`/`\\` escaped). Omit to return edits across all paths."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description:
              "UUID scoping the read to a single workspace. Omit to span every workspace (org-level view)."
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Max rows to return (default 20, capped at 100). Values above 100 are clamped."
          }
        },
        returns:
          "Array of %{path, original_content, edited_content, editor_id, original_author_id, inserted_at}, newest first.",
        limitations:
          "Read-only — no way to edit or delete a feedback row through MCP. Filters compose via strict-eq (workspace) and prefix-ilike (path). Empty corpus returns `[]`, never an error.",
        when_to_use:
          "Before proposing a curated-page edit, to inspect the last-K human-preferred content shapes for that path/prefix. Also useful as a few-shot exemplar source when the historian is deciding phrasing."
      },
      %{
        name: "org_memory_recently_deleted",
        description:
          "List the K most recent org-memory delete events. Useful for avoiding recreating content that was intentionally removed. Read-only wrapper over `Platform.MemoryFeedback.list_recent/1` scoped to `feedback_kind: \"delete\"` rows.",
        parameters: %{
          path_prefix: %{
            type: "string",
            required: false,
            description:
              "Restrict to rows whose `path` starts with this literal prefix (case-insensitive, `_`/`%`/`\\` escaped). Omit to return deletes across all paths."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description:
              "UUID scoping the read to a single workspace. Omit to span every workspace (org-level view)."
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Max rows to return (default 20, capped at 100). Values above 100 are clamped."
          }
        },
        returns:
          "Array of %{path, original_content, editor_id, original_author_id, reason_text, inserted_at}, newest first.",
        limitations:
          "Read-only. Rows are append-only — a path being present here does NOT mean it is currently deleted (a later `memory_create` may have restored it). Cross-reference with `org_memory_feedback_at_path` when you need a full history for one path.",
        when_to_use:
          "Before creating or restoring a page/journal entry, to check whether a similarly-named path was intentionally retired. Historian consults this when resolving broken backlinks — a deleted target means clean up the referrer, not re-create the target."
      },
      %{
        name: "org_memory_feedback_at_path",
        description:
          "Full feedback history for one path. Used by the historian to answer 'was this backlink-target intentionally deleted?' when resolving broken references. Returns both edit and delete rows in one call, split into two arrays.",
        parameters: %{
          path: %{
            type: "string",
            required: true,
            description:
              "Exact `path` (file_key) to look up. Prefix / fuzzy matching is not supported — pass the same string that appears in an `org_memory_*` row's `path` field."
          },
          workspace_id: %{
            type: "string",
            required: false,
            description:
              "UUID scoping the read to a single workspace. Omit to span every workspace (org-level view)."
          }
        },
        returns:
          "%{path, edits: [...edit rows...], deletes: [...delete rows...]} — arrays are newest-first, both empty (never nil) when the path has no feedback history.",
        limitations:
          "Read-only. Exact-path match — no prefix/fuzzy lookup (use `org_memory_recently_edited` / `org_memory_recently_deleted` with `path_prefix` for that). Capped at the same 100-row ceiling per side.",
        when_to_use:
          "When you have a specific broken backlink or a suspicious re-create candidate and you need the full audit trail for that one path — both what got edited and what got deleted, in one round-trip."
      }
    ]
  end

  defp messaging_tools do
    [
      %{
        name: "send_media",
        description: "Send a message with one or more file attachments to a Suite space.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          file_paths: %{
            type: "array",
            required: false,
            description: "Absolute local file paths to attach"
          },
          file_path: %{
            type: "string",
            required: false,
            description: "Back-compat single absolute local path to the file"
          },
          content: %{
            type: "string",
            required: false,
            description: "Optional message text"
          },
          filename: %{
            type: "string",
            required: false,
            description: "Optional display filename for single-file uploads"
          }
        },
        returns: "The message ID, space ID, and attachment count",
        limitations:
          "Files must exist on the local filesystem. Agent must be a participant in the space.",
        when_to_use: "When you need to share files (images, documents, etc.) in a space"
      },
      %{
        name: "react",
        description:
          "React to a specific message in a Suite space with an emoji. Prefer this over a text reply for quick acknowledgements (👍 got it, ✅ done, 🎉 shipped). Idempotent — re-reacting with the same emoji returns success without duplicating.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          message_id: %{
            type: "string",
            required: true,
            description: "UUID of the message to react to. Must belong to space_id."
          },
          emoji: %{
            type: "string",
            required: true,
            description: "Single emoji grapheme, e.g. 👍, 🎉, ✅"
          }
        },
        returns:
          "A map with message_id, emoji, space_id, and status: 'added' for a new reaction or 'already_reacted' if the agent had already reacted with that emoji.",
        limitations:
          "Agent must be a participant in the space. message_id must belong to the provided space_id.",
        when_to_use:
          "When a short emoji ack is more appropriate than a text reply, especially for mobile readers"
      }
    ]
  end

  defp review_tools do
    [
      %{
        name: "review_request_create",
        description:
          "Submit evidence for a manual_approval validation gate. Creates a review request with labelled items for human review. Each item is independently approvable. Use this instead of validation_evaluate for manual_approval validations.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The manual_approval validation ID to submit evidence for"
          },
          items: %{
            type: "array",
            required: true,
            description:
              "Array of review items: {label: string, canvas_id?: string, content?: string}. Each item is independently reviewed by a human."
          }
        },
        returns: "The created review request object with id, status, and items list",
        limitations: "Only for manual_approval validations. Items cannot be empty.",
        when_to_use:
          "When you reach a manual_approval validation gate and need to submit evidence (screenshots, canvases, text) for human review"
      },
      %{
        name: "review_request_get",
        description:
          "Read back one review request plus every item on it — including each item's status, the human's feedback text, who reviewed it and when. PRECEDENCE RULE: the review_items row is authoritative for WHAT A HUMAN SAID; the validations row is GATE STATE and can legitimately read `pending` again after a gate is reopened for another attempt. If you see item=needs_revision and validation=pending, the item is the ruling and the validation is the current gate — act on the item's feedback, do not read the pending validation as 'no verdict yet'.",
        parameters: %{
          review_request_id: %{
            type: "string",
            required: true,
            description: "UUID of the review request to read."
          }
        },
        returns:
          "The review request (id, validation_id, task_id, status, submitted_by, timestamps) with an `items` list; each item carries id, label, status, feedback, reviewed_by, reviewed_at, canvas_id, content.",
        limitations:
          "Reads only. Scoped to the org that owns the request's task — a tenant-pinned agent reading a sibling org's request is denied before any label or feedback is serialized. Unknown or malformed ids return a non-recoverable not-found envelope.",
        when_to_use:
          "After a manual_approval gate comes back and you need the human's actual words — the rejection feedback that tells you what to change — rather than just the gate's pass/fail bit."
      },
      %{
        name: "review_item_list",
        description:
          "List every review item across every review request on a task, newest ruling first. Superseded requests are INCLUDED and labelled via `request_status`, never filtered — a ruling that was made must always be findable. PRECEDENCE RULE: the review_items row is authoritative for WHAT A HUMAN SAID; the validations row is GATE STATE and can legitimately read `pending` again after a gate is reopened for another attempt. If you see item=needs_revision and validation=pending, the item is the ruling and the validation is the current gate.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "UUID of the task whose review items you want."
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Maximum items to return. Defaults to #{ResultBound.default_limit()}, capped at #{ResultBound.max_limit()}."
          },
          offset: %{
            type: "integer",
            required: false,
            description: "How many items to skip before the page. Defaults to 0."
          },
          detail: %{
            type: "string",
            required: false,
            description:
              "\"summary\" (default) truncates `content` and `feedback` to #{ResultBound.snippet_chars()} characters each; \"full\" returns them whole."
          }
        },
        returns:
          "A map with task_id, count, and `items` — each item carries id, label, status, feedback, reviewed_by, reviewed_at, canvas_id, content, plus review_request_id, request_status and validation_id so you can tell a live ruling from one whose evidence was replaced. " <>
            "`count` is the TOTAL number of items on the task, not the number returned; `returned_count`, `offset` and `next_offset` (null on the last page) describe the page you got. " <>
            "In the default summary detail `content` and `feedback` are previews, each with `_truncated` and `_length` siblings.",
        limitations:
          "Reads only. Scoped to the org that owns the task — a tenant-pinned agent reading a sibling org's task is denied before any label or feedback is serialized. A malformed or unknown task_id returns an empty list, not an error.",
        when_to_use:
          "When you are picking up a task that has already been through review and need every ruling a human has made on it, across attempts."
      },
      %{
        name: "design_critique_request",
        description:
          "Obtain the Designer role's design critique (`design.critique`, held by Saru) of one evidence canvas, synchronously. Returns the verdict to you so you can inline it into your own review request; when `review_request_id` is supplied the verdict is ALSO appended to that pending request as an item the human reads.",
        parameters: %{
          canvas_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the evidence canvas to critique — normally the canvas holding your captured screenshots."
          },
          note: %{
            type: "string",
            required: false,
            description:
              "Free-text grounding for the critique: what changed, what to look at, what you are unsure about."
          },
          task_id: %{
            type: "string",
            required: false,
            description:
              "UUID of the task under review. Adds the task title/description as grounding and logs the critique to the task's execution space as an audit trail."
          },
          review_request_id: %{
            type: "string",
            required: false,
            description:
              "UUID of a PENDING review request. When supplied the verdict is appended to it as an item labelled 'Design review (Saru)'."
          }
        },
        returns:
          "A map with issues (a list of {severity, location, issue, suggestion} maps, possibly empty), raw (the critique text as returned), unparseable? (true when the reply carried no parseable JSON — the prose is still in raw and still lands), and review_item_id (the id of the appended review item, or null when none was appended).",
        limitations:
          "Requires `design.critique` to be assigned to an external agent — an unassigned Designer role returns a non-recoverable error rather than a critique. Critiques exactly one canvas per call. Advisory only: the verdict never disposes of a manual_approval gate, and appending an item does not resolve the request.",
        when_to_use:
          "Before creating the human review request on a UI change: it returns the verdict SYNCHRONOUSLY, so you can include Saru's issue list as a labelled item in the same review request rather than waiting on a channel post."
      }
    ]
  end

  defp space_tools do
    [
      %{
        name: "space_create",
        description:
          "Create a channel in a Suite org. This is the supported way for an agent to create a channel — the alternative (a raw `Platform.Chat.create_channel/1` RPC) has repeatedly written participant rows with a NULL `display_name`, which silently drops every `@[Name]` mention of the affected agent. This tool resolves a display name for every participant it adds, so it cannot reproduce that. The calling agent is added as a participant (attention_mode `mention`) so it can hear the channel it just made; the role-pinned Historian auto-joins as it does for any channel.",
        parameters: %{
          name: %{
            type: "string",
            required: true,
            description: "Human-readable channel name, e.g. \"Webhook Intake\""
          },
          slug: %{
            type: "string",
            required: false,
            description:
              "URL slug. Omit to derive it from `name` (lowercased, non-alphanumerics collapsed to hyphens). Must be unique within the org."
          },
          org_id: %{
            type: "string",
            required: false,
            description:
              "UUID of the org to create the channel in. Omit to use the calling agent's home org. A tenant-pinned agent may only pass its own org."
          },
          description: %{
            type: "string",
            required: false,
            description: "Optional one-line description of what the channel is for"
          },
          agent_ids: %{
            type: "array",
            required: false,
            description:
              "Optional UUIDs or slugs of additional agents to add as participants. Each gets its display_name resolved from the `agents` row. Unresolvable entries are reported in `skipped` rather than failing the call."
          }
        },
        returns:
          "`{id, name, slug, org_id, description, kind: \"channel\", participants: [{participant_id, agent_id, display_name}], skipped: [...]}`. `participants` lists every agent row written, each with a non-null display_name.",
        limitations:
          "Creates channels only (never DMs or groups). Slug must be unique within the org — a collision returns a recoverable error rather than reusing the existing channel. Human users are not added; invite them in-app or via `add_participant`. A tenant-pinned agent cannot create channels in another org.",
        when_to_use:
          "Whenever you need a new channel. Prefer this over any RPC or console path: it is the only channel-creation route that guarantees resolved participant display names."
      },
      %{
        name: "space_list",
        description: "List Suite spaces the agent is a member of.",
        parameters: %{
          kind: %{
            type: "string",
            required: false,
            description: "Filter by kind: channel, dm (optional)"
          }
        },
        returns: "Array of space objects with id, name, kind, description",
        limitations: "Only returns spaces the agent is a participant in",
        when_to_use:
          "When you need to discover available spaces or find a space ID for proactive messaging"
      },
      %{
        name: "space_list_agents",
        description:
          "List the agent participants in a space with their IDs, slugs, and display names. Use this to resolve an agent by name before calling tools that require an `agent_id` (e.g. `space_leave`).",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns:
          "Array of `{agent_id, slug, name, display_name, participant_id, joined_at}`. Only active agent participants are returned (humans excluded, left agents excluded).",
        limitations:
          "Only agent participants currently in the space. Name matching is case-sensitive — compare against `slug` for stable lookups or `name` for the human-readable label.",
        when_to_use:
          "Before calling `space_leave` on another agent, or whenever you need to map a human-readable agent name to its UUID."
      },
      %{
        name: "space_leave",
        description:
          "Remove an agent from a Suite space. Defaults to removing the calling agent (self-leave). Pass `agent_id` to remove a different agent — for example if you were asked to evict another agent who shouldn't be present. Hard-delete: the participant row is removed. Message history stays attributed via author-identity snapshots on each message (ADR 0038). To return, a user needs to @-mention the agent in a new message.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          agent_id: %{
            type: "string",
            required: false,
            description:
              "UUID of the agent to remove. Omit to leave the space yourself (the calling agent)."
          }
        },
        returns:
          "`{space_id, agent_id, participant_id, removed: true, removed_at, self_removed}` on success. If the target was the active-agent mutex holder, the mutex is cleared as a side effect.",
        limitations:
          "Only removes agent participants (not humans). Target must currently be a participant in the space. If the target is the principal agent of an execution space with a live task, the space's task will orphan until re-assigned — use deliberately.",
        when_to_use:
          "When you were invited to a space you shouldn't be in (e.g. a private DM you're stuck listening to), or when asked to remove another agent who shouldn't be present."
      },
      %{
        name: "dm_create",
        description:
          "Open a direct message with a HUMAN and say the thing, in one call. Creates the 1:1 DM between you and that person if it does not exist yet, then posts `message` into it. Re-calling it reuses the same thread rather than opening a second one. USE THIS SPARINGLY AND ON PURPOSE: a DM is a tap on the shoulder. It is for a decision only that person can make, a genuine blocker you cannot get around, or something time-sensitive that will rot if it waits. It is NOT for status, progress updates, \"just so you know\", or anything a channel post would serve — a DM channel that fills with those gets muted, and then the one message that genuinely needed them arrives somewhere nobody is reading. Ask yourself whether you ACTUALLY NEED something from this person; if the honest answer is no, post in a channel instead.",
        parameters: %{
          user_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the human to DM. Resolve a name or email to a UUID with `principal_search` (type: \"user\") first."
          },
          message: %{
            type: "string",
            required: true,
            description:
              "The message to post. Lead with what you need from them and why it cannot wait."
          }
        },
        returns:
          "`{space_id, message_id, user_id, agent_participant_id}` — `space_id` is the DM, usable with `space_get_messages` to read their reply.",
        limitations:
          "Humans only — pass a user UUID, not an agent UUID. You are always one of the two parties: this cannot open a DM between two other people, cannot add you to an existing DM, and cannot reach a DM you are not already in. External (guest) users are refused. A tenant-pinned agent may only DM people who hold a membership in its own org; a root agent may DM anyone internal.",
        when_to_use:
          "When you are blocked on a decision only this person can make, or you are holding something time-sensitive that will be worthless by the time a channel post is read. Not for reporting that you finished something."
      }
    ]
  end

  defp context_read_tools do
    [
      %{
        name: "space_get_context",
        description:
          "Get the current context bundle for a space: recent activity summary, active canvases, other agents, and space metadata. Useful for orienting yourself in a space before acting.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns:
          "Context bundle with space metadata, active_canvases, other_agents, and recent_activity_summary",
        limitations:
          "Only works for spaces the agent is an active participant in. Activity data is in-memory and may be incomplete after restarts.",
        when_to_use:
          "When you join a space or need to understand what has been happening before you act"
      },
      %{
        name: "space_search_messages",
        description:
          "Full-text search messages in a space. Returns up to 10 results ranked by relevance with highlighted excerpts.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          query: %{
            type: "string",
            required: true,
            description: "Search query (supports natural language)"
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max results to return (default 10, max 10)"
          }
        },
        returns:
          "Array of message objects with id, participant_id, content, search_headline, inserted_at. " <>
            "If the query parsed to no searchable terms, returns %{results: [], no_searchable_terms: true, note: ...} instead of an array.",
        limitations:
          "Only searches spaces the agent is a participant in. Max 10 results. Uses PostgreSQL full-text search " <>
            "(English stemming via websearch_to_tsquery). A punctuation-only query parses to an empty tsquery and " <>
            "matches nothing by construction — that case comes back as the no_searchable_terms envelope, NOT an " <>
            "empty array, so a zero result is never ambiguous between 'no such message' and 'the query had nothing " <>
            "to search with'. UUIDs and ISO dates DO tokenize and search normally.",
        when_to_use: "When you need to find specific messages or topics discussed in a space"
      },
      %{
        name: "space_get_messages",
        description:
          "Get recent messages from a space, newest first. Supports cursor-based pagination.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          limit: %{
            type: "integer",
            required: false,
            description: "Number of messages to return (default 20, max 20)"
          },
          before_id: %{
            type: "string",
            required: false,
            description: "Cursor: only return messages older than this message ID"
          }
        },
        returns:
          "Array of message objects with id, participant_id, content_type, content, inserted_at, attachments. Each attachments entry is %{url, content_type, byte_size, filename}; the array is empty when the message has no attachments.",
        limitations:
          "Only works for spaces the agent is a participant in. Max 20 messages per call.",
        when_to_use: "When you need to read the recent conversation history in a space"
      },
      %{
        name: "canvas_list",
        # `view_url` is here as well as on `canvas_get` because this is the
        # DISCOVERY call: an agent that lists a space's canvases to cite one
        # would otherwise have to issue a `canvas_get` per row purely to obtain
        # a link that is computable from the id it already holds.
        description:
          "List all canvases in a space with summary information (id, title, type, view_url, timestamps).",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns:
          "Array of canvas summary objects with id, title, type, view_url, inserted_at, updated_at",
        limitations: "Only works for spaces the agent is a participant in.",
        when_to_use:
          "When you need to discover what canvases exist in a space before reading or updating one"
      },
      %{
        name: "canvas_get",
        description:
          "Get a canvas by ID. Returns summary by default, or full document state with mode=full. The summary includes view_url, the canonical page for the canvas. " <>
            Platform.Chat.Canvas.Tools.read_gate() <>
            " " <>
            Platform.Chat.Canvas.Tools.sharing_boundary(),
        parameters: %{
          canvas_id: %{type: "string", required: true, description: "UUID of the canvas"},
          mode: %{
            type: "string",
            required: false,
            description:
              "\"summary\" (default) or \"full\" — full includes the complete state map"
          }
        },
        returns:
          "Canvas object with id, title, type, space_id, view_url, and optionally the full state document",
        # Task 019fb01b stage 4 widened this read to the `:task_agent` grant.
        # The string it replaces named only the space clause, so from that
        # commit on it described a narrower tool than the one that ships — and
        # a `limitations` field is a contract a remote runtime branches on, not
        # a maintainer's note.
        limitations:
          "Reads only canvases you hold a grant on: a participant of the canvas's space, or an agent bound by phase_assignees to a live task the canvas is attached to. Anything else is denied, and a canvas that does not exist is reported separately from one you may not read. Full mode may return large payloads for complex canvases.",
        when_to_use:
          "When you need to inspect a canvas's content before updating it, to present canvas data to a user, to read a design direction canvas attached to your task, or to get its view_url"
      },
      %{
        name: "principal_search",
        description:
          "Search for principals (users OR agents) by display_name / email / slug / partial-match. Returns up to 20 matches with UUIDs suitable for `sponsor_user_id` (users only), `assignee_id` (users + agents), or other principal-ID fields. Use this before calling tools that require a user or agent UUID when you only have a name / email / slug fragment.",
        parameters: %{
          query: %{
            type: "string",
            required: true,
            description:
              "Search term. Minimum 2 characters. Matches on user email (exact, case-insensitive) or name (substring) and agent slug / display_name (substring)."
          },
          type: %{
            type: "string",
            required: false,
            description:
              "Restrict results to principal kind: \"user\", \"agent\", or \"any\" (default)."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max results per kind (default 20, capped at 100)."
          }
        },
        returns:
          "Array of result rows. User rows: `{type: \"user\", id, display_name, email, avatar_url}`. Agent rows: `{type: \"agent\", id, display_name, slug, kind, classification}` where classification is one of `ext_single_responsibility`, `fed_conversational`, `loc_built_in` (see Platform.Agents.Kind).",
        limitations:
          "Substring matches on name/slug/display_name; exact case-insensitive match on user email. Queries under 2 characters return an empty list to avoid catalog-wide scans. Results are not permission-filtered — visibility filters land in a follow-up.",
        when_to_use:
          "Before calling `task_create`, `task_update`, or any tool that expects a `sponsor_user_id` / `assignee_id` when you only have a partial name, an email, or a slug."
      }
    ]
  end

  defp canvas_tools do
    [
      %{
        name: "canvas.create",
        # The boundary lives in `description`, not in `limitations`:
        # `PlatformWeb.MCPController.to_mcp_tool/1` forwards only `name`,
        # `description` and `inputSchema`, so anything stated in the other
        # fields never reaches an agent on the hosted `/mcp` transport. Stated
        # once, here, rather than in both fields — the whole map IS shipped
        # verbatim on the capabilities push, and a duplicate paragraph is
        # payload in every attention broadcast.
        description:
          "Create a live canvas with a canonical document (ADR 0036). The document is a node tree whose root type is one of the registered kinds. Returns view_url, the canonical page for the canvas, which you can paste for a human to read. " <>
            Platform.Chat.Canvas.Tools.sharing_boundary(),
        parameters: %{
          space_id: %{type: "string", required: true, description: "Target space UUID"},
          title: %{type: "string", required: false, description: "Human-readable title"},
          document: %{
            type: "object",
            required: true,
            aliases: ["initial_state"],
            description:
              "Canonical document. See canvas.describe on an existing canvas for a valid shape. Pass as a nested object, not a JSON string.",
            schema: Platform.Chat.Canvas.Tools.document_schema()
          }
        },
        returns: "%{canvas_id, title, kind, revision, view_url}",
        limitations: "Canvas kinds are defined in the kind registry.",
        when_to_use:
          "When you need to present structured, interactive, or visual data to users. Paste the returned view_url when you want a human to read the canvas outside this space."
      },
      %{
        name: "canvas.patch",
        description:
          "Apply patch operations with rebase-or-reject concurrency (ADR 0036). Requires the current base_revision — the server compares it to the live revision and either applies, rebases, or rejects with a structured reason.",
        parameters: %{
          canvas_id: %{type: "string", required: true},
          base_revision: %{
            type: "integer",
            required: true,
            description: "Revision the caller last observed (from canvas.describe)"
          },
          operations: %{
            type: "array",
            required: true,
            description:
              "Each op is [\"set_props\", id, props] | [\"replace_children\", id, children] | [\"append_child\", parent_id, child] | [\"delete_node\", id] | [\"replace_document\", doc]. Pass nested objects (props, children, child, doc) as objects/arrays, not JSON strings.",
            schema: %{
              type: "array",
              minItems: 1,
              items: %{
                type: "array",
                description:
                  "Tuple: first element is the operation name, remaining elements are its arguments."
              }
            }
          }
        },
        returns: "%{canvas_id, revision} on success, structured conflict on rejection",
        limitations:
          "Rejection reasons: target_deleted, schema_violation, illegal_child, too_stale. Refresh with canvas.describe and retry.",
        when_to_use: "When you need to modify the content or state of an existing canvas"
      },
      %{
        name: "canvas.describe",
        description:
          "Read the current document, revision, view_url, presence, and recent events for a canvas you hold a grant on. Cheap, idempotent — call before patching so base_revision is fresh, or to recover the view_url of a canvas you did not create. " <>
            Platform.Chat.Canvas.Tools.read_gate() <>
            " " <>
            Platform.Chat.Canvas.Tools.sharing_boundary(),
        parameters: %{
          canvas_id: %{type: "string", required: true}
        },
        returns:
          "%{canvas_id, title, space_id, kind, revision, document, view_url, presence, recent_events}",
        # Task 019fb01b stage 3 gated this read. The string it replaces
        # ("not gated on space participation today") was accurate when written
        # and is now false; a description that lags the gate is the defect this
        # tool's own history is a case study in, so it moves in the same commit
        # as the gate.
        limitations:
          "Reads only canvases you hold a grant on: a participant of the canvas's space, or an agent bound by phase_assignees to a live task the canvas is attached to. Anything else is denied, and a canvas that does not exist is reported separately from one you may not read. The view_url it returns likewise opens only for a viewer who holds a grant.",
        when_to_use:
          "Before emitting canvas.patch, to present canvas state to a user, or to recover the view_url of a canvas you did not create"
      },
      %{
        name: "canvas.list_kinds",
        description:
          "List every registered canvas node kind with a one-line description, its child rule, a props summary, and an example node. Call this first if you're not sure what to emit in canvas.create.",
        parameters: %{},
        returns: "%{kinds: [%{kind, description, accepts_children, props, example}]}",
        limitations: "Static — same output regardless of caller or space.",
        when_to_use:
          "Before canvas.create when you need to pick a kind or remember props; before canvas.patch when building replacement child nodes."
      },
      %{
        name: "canvas.template",
        description:
          "Fetch a named canonical canvas document you can pass directly to canvas.create. With no `name`, returns the list of available templates.",
        parameters: %{
          name: %{
            type: "string",
            required: false,
            description:
              "One of: empty, text, heading_and_text, checklist, table, form, code, dashboard. Omit to list all available templates."
          }
        },
        returns:
          "%{name, description, document} for a specific template; %{templates: [...]} otherwise",
        limitations:
          "Templates are static starter shapes. Customize the returned document before passing to canvas.create.",
        when_to_use:
          "When you want a known-good canvas shape to adjust rather than hand-building a document from scratch."
      },
      %{
        name: "canvas.versions",
        description:
          "List a canvas's revision history newest-first. Each entry is the revision number, write timestamp, written_by attribution snapshot, and a 1-sentence op_summary derived from the patch ops. Pair with canvas.restore to roll back. Same gate as canvas.describe, literally: both resolve through one seam. " <>
            Platform.Chat.Canvas.Tools.read_gate() <>
            " " <>
            Platform.Chat.Canvas.Tools.sharing_boundary(),
        parameters: %{
          canvas_id: %{type: "string", required: true},
          limit: %{
            type: "integer",
            required: false,
            description: "Max entries (default 20, max 100)"
          },
          before_revision: %{
            type: "integer",
            required: false,
            description: "Cursor — return only versions strictly older than this revision"
          }
        },
        returns:
          "%{canvas_id, versions: [%{revision, written_at, written_by, op_summary}], next_cursor}",
        # Same gate as canvas.describe, stated the same way on purpose (task
        # 019fb01b stage 3). The string it replaces claimed participation only,
        # which was wrong in both directions: it omitted the task grant, and
        # the gate it named fell open entirely for a runtime with no linked
        # agent.
        limitations:
          "Reads only canvases you hold a grant on: a participant of the canvas's space, or an agent bound by phase_assignees to a live task the canvas is attached to. Anything else is denied. Versions older than the table's existence are not back-filled.",
        when_to_use:
          "Before canvas.restore so you can show the user (or the model) what's available; or after a destructive patch to find a known-good revision to roll back to."
      },
      %{
        name: "canvas.restore",
        description:
          "Replace the live canvas with the document from a historical revision. The restore is itself a write — it produces a new revision row at current+1 with ops marked as restore_from_revision.",
        parameters: %{
          canvas_id: %{type: "string", required: true},
          revision: %{
            type: "integer",
            required: true,
            description: "The historical revision to restore"
          }
        },
        returns: "%{canvas_id, revision (the new revision), restored_from}",
        limitations:
          "Restore obeys the same authorization gate as canvas.patch. The previous live document remains in history under its original revision number — restore never deletes prior versions.",
        when_to_use:
          "When a patch clobbered something the user wanted back, or to revert to an approved snapshot."
      }
    ]
  end

  defp task_tools do
    [
      %{
        name: "project_list",
        description:
          "List projects, optionally filtered by org (ADR-0042). Each project carries its parent org's id and slug.",
        parameters: %{
          org_id: %{
            type: "string",
            required: false,
            description:
              "ADR-0042 tenant filter — only return projects belonging to this org. Omit to return every project."
          }
        },
        returns: "Array of project objects with id, name, slug, repo_url, org_id, org_slug",
        limitations:
          "No authorization check on the filter today — any caller can request any org's project list (read-only).",
        when_to_use:
          "When you need to find a project to create tasks or epics in, or to enumerate the projects belonging to a single tenant org."
      },
      %{
        name: "org_list_descendants",
        description:
          "List the direct descendants of an org (ADR-0042 two-tier topology). Returns every tenant org under the root when called with the root id; returns an empty list for a tenant (the topology has no third tier today).",
        parameters: %{
          org_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the parent org to enumerate descendants for. Use the Fabrikam root id to list every tenant."
          }
        },
        returns:
          "Array of %{id, slug, name, role} where `role` is `\"tenant\"` for child orgs (today's only descendant tier) or `\"root\"` for the root org itself when it has no descendants below it.",
        limitations:
          "Unknown `org_id` → `:not_found`. Returns an empty list for any leaf-tier org.",
        when_to_use:
          "When you need to enumerate the tenant orgs under the root, or check whether an org has any descendants below it."
      },
      %{
        name: "project_update",
        description:
          "Update a project's fields including the deploy_config map (which holds the project-wide default_strategy used to resolve task deploy targets).",
        parameters: %{
          project_id: %{type: "string", required: true, description: "The project to update"},
          name: %{type: "string", required: false, description: "New name"},
          repo_url: %{type: "string", required: false, description: "New repo URL"},
          default_branch: %{
            type: "string",
            required: false,
            description: "New default branch"
          },
          deploy_config: %{
            type: "object",
            required: false,
            description:
              "Project-wide deploy config. Set deploy_config.default_strategy to a strategy map (e.g. %{\"type\" => \"pr_merge\"}) to provide a fallback for tasks whose deploy_target is unset. Valid strategy types: none, pr_merge, docker_deploy, fly, skill_driven, manual, project_files."
          },
          brand_decision: %{
            type: "string",
            required: false,
            description:
              "Answer the once-per-project brand escalation (ADR 0046). One of: " <>
                Enum.join(Brand.recordable_modes(), " | ") <>
                ". Recorded at config.brand_decision. Brand sets how strictly design is enforced, never whether work proceeds — a project with no brand is advisory, not blocked."
          },
          dispatch_paused: %{
            type: "boolean",
            required: false,
            description:
              "Pause (true) or resume (false) dispatch for every task in the project. While paused, the TaskRouterWatcher starts no TaskRouter for the project's tasks whatever their status or assignee, and stops any that are running on its next reconcile; tasks can still be created, assigned and moved to planning. The Process project ships paused."
          },
          plan_auto_approve: %{
            type: "object",
            required: false,
            description:
              "Project-wide plan auto-approval policy, recorded at config.plan_auto_approve and merged over the project's other config keys. Shape: {enabled: boolean, max_stages: positive integer, allow_manual_approval?: boolean (default false)}. When enabled, a submitted plan in this project with at most max_stages implementation stages (the auto-injected deploy stage does not count) and — unless allow_manual_approval — no manual_approval validation is auto-approved as if the task carried auto_approve_plan, with plans.approved_by = \"system:project_policy\". The policy only arms the path: the execution/review agent-assignee precondition and the ADR-0046 architecture gate still apply. A malformed policy is refused and nothing is written."
          }
        },
        returns:
          "The updated project object, including dispatch_paused, brand_decision when one is recorded on the project and plan_auto_approve when a policy is set",
        limitations:
          "deploy_config.default_strategy is validated; unknown strategy types are rejected. `config` is NOT writable through this tool — only the named brand_decision enum and the named plan_auto_approve object reach it (each validated by Project.changeset/2 or Brand), because a blanket config write would let a malformed brand_decision land, which is read as no decision at all.",
        when_to_use:
          "When you need to set a project-level default deploy strategy, pause or resume dispatch for a whole project, set or change the project's plan auto-approval policy, answer the brand-direction question posted to a task's execution space, or update other project fields"
      },
      %{
        name: "epic_list",
        description: "List epics, optionally filtered by project.",
        parameters: %{
          project_id: %{
            type: "string",
            required: false,
            description: "Filter epics by project ID. Omit to list all epics."
          }
        },
        returns: "Array of epic objects with id, name, description, project_id, status",
        limitations: "None",
        when_to_use: "When you need to find an epic to assign a task to"
      },
      %{
        name: "epic_update",
        description: "Update an epic's fields including target_branch and deploy_target.",
        parameters: %{
          epic_id: %{type: "string", required: true, description: "The epic to update"},
          name: %{type: "string", required: false, description: "New epic name"},
          description: %{type: "string", required: false, description: "New description"},
          status: %{type: "string", required: false, description: "New status"},
          target_branch: %{
            type: "string",
            required: false,
            description: "Git branch for task worktrees in this epic (e.g. feat/reskin)"
          },
          deploy_target: %{
            type: "string",
            required: false,
            description: "Deploy target for tasks in this epic (e.g. exp, prod)"
          }
        },
        returns: "The updated epic object",
        limitations: "Epic must exist",
        when_to_use: "When you need to configure an epic's target branch or deploy target"
      },
      %{
        name: "epic_create",
        description:
          "Create a new epic in a project. Epics group related tasks under a shared theme, target branch, or deploy target.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "The project to create the epic in"
          },
          name: %{type: "string", required: true, description: "Epic name (1..120 chars)"},
          description: %{type: "string", required: false, description: "Long-form epic body"},
          acceptance_criteria: %{
            type: "string",
            required: false,
            description: "Acceptance criteria for the epic"
          },
          status: %{
            type: "string",
            required: false,
            description: "Initial status: open (default), in_progress, closed"
          },
          target_branch: %{
            type: "string",
            required: false,
            description: "Git branch inherited by member tasks (e.g. feat/reskin)"
          },
          deploy_target: %{
            type: "string",
            required: false,
            description: "Deploy target inherited by member tasks (e.g. exp, prod)"
          }
        },
        returns: "The created epic object with id, name, project_id, status",
        limitations: "Requires a valid project_id and name",
        when_to_use: "When you need to organize related tasks under a new epic in a project"
      },
      %{
        name: "task_create",
        description:
          "Create a new task in a project. Tasks track work items on the kanban board. Optionally set a Sponsor (human shepherd, ADR 0042) distinct from the current-phase technical assignee. Set auto_approve_plan: true to skip human review when the plan is submitted (requires an assigned agent). Canonical shape is documented in ADR 0044 and shared with task_update via `Platform.Federation.TaskAttrs.build_task_attrs/3` — flat assignee_id + assignee_type writes auto-route into `phase_assignees[\"planning\"]` (new tasks start at planning phase), so the write survives future phase transitions. With auto_approve_plan: true and an agent-typed flat assignee, the flat agent instead fans into all three phase slots (planning, execution, review) wherever an entry is absent; explicit phase_assignees entries win over the fan-out. User-typed or missing assignees still need explicit phase_assignees covering execution and review for auto-approve.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "The project to create the task in"
          },
          title: %{type: "string", required: true, description: "Task title"},
          description: %{type: "string", required: false, description: "Task description"},
          epic_id: %{
            type: "string",
            required: false,
            description: "Epic to assign the task to"
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Initial status: backlog (default), planning, in_progress, in_review, deploying, done, blocked"
          },
          priority: %{
            type: "string",
            required: false,
            description: "Priority: low, medium (default), high, critical"
          },
          assignee_type: %{
            type: "string",
            required: false,
            description: "Assignee type: user or agent"
          },
          assignee_id: %{
            type: "string",
            required: false,
            description: "ID of the user or agent to assign"
          },
          sponsor_user_id: %{
            type: "string",
            required: false,
            description:
              "Sponsor — human shepherd who owns the task's outcome (ADR 0042). Nullable user id (UUID) distinct from the current-phase assignee, which is typically an agent. Omit or pass null to leave unsponsored."
          },
          stack_id: %{
            type: "string",
            required: false,
            description:
              "Optional task-stack to attach this task to (ADR 0041). When set, the created task is added to the stack via Stacks.add_task — the in-stack DAG is re-validated, cross-stack dep edges are rejected, and the stack's rollup status is recomputed. Use to create-into-a-stack in one call."
          },
          auto_approve_plan: %{
            type: "boolean",
            required: false,
            description:
              "When true, auto-approve the plan the planner submits and skip the human review step. With an agent-typed flat assignee_id (assignee_type omitted or \"agent\"), the flag fans that agent into all three phase slots (planning, execution, review) wherever an entry is absent; explicit phase_assignees entries win over the fan-out. User-typed or missing assignees still need explicit phase_assignees covering execution and review. Precondition: both the execution-phase and review-phase assignees must resolve to an agent (via assignee_id + assignee_type OR phase_assignees); if either is missing or user-typed, the create is refused with code auto_approve_precondition_missing and nothing is written. Defaults to false."
          },
          deploy_target: %{
            type: "string",
            required: false,
            description:
              "Name of the deploy target this task should ship to (must match an entry in project.deploy_config.deploy_targets, e.g. \"production\" or \"exp\"). Sibling to task_update's deploy_target — setting it at create time avoids a follow-up task_update round-trip once the task auto-advances into the deploying phase."
          },
          phase_assignees: %{
            type: "object",
            required: false,
            description:
              "Granular per-phase assignees keyed by phase (\"planning\" | \"execution\" | \"review\") with values %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\" | \"user\"}. When supplied, wins over flat assignee_id + assignee_type — canonical writer for the assignee family per ADR 0044. Use to assign different agents to different phases in one call (e.g. planner agent for planning, executor agent for execution)."
          }
        },
        returns:
          "The created task object with id, title, status, priority, and sponsor (nil unless sponsor_user_id was supplied, else %{id, name, email}). When stack_id is supplied, the response also includes stack_id and stack_position. Response also includes advisory `similar_tasks: [%{id, title, status, priority, similarity_score, updated_at, merged_pr_url, follow_up_task_ids, cancellation_note}]` (0-5 near-duplicate hits scoped to the same project, each with a similarity_score >= 0.35; the score is the token-overlap coefficient between the new body and the candidate's title+description, NOT a rank) so the caller can detect near-duplicates and decide to fold, reference, or file fresh without a follow-up memory_search. Empty array (not nil) when no matches or when the similarity search fails.",
        limitations:
          "Requires a valid project_id. If stack_id is supplied, the stack must exist and the resulting in-stack DAG must remain acyclic with no cross-stack dependency edges. If sponsor_user_id is supplied it must reference an existing user (FK enforced). When auto_approve_plan is true, the plan won't auto-approve unless every phase assignee resolves to an agent.",
        when_to_use: "When you need to track a work item, feature, bug, or action item"
      },
      %{
        name: "task_get",
        description: "Get a single task by ID with full details.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            aliases: ["id"],
            description: "The task ID"
          }
        },
        returns:
          "Task object with id, title, description, status, priority, project_id, epic_id, and sponsor (nil or %{id, name, email} per ADR 0042).",
        limitations: "Returns nil if task not found",
        when_to_use: "When you need to check the current state of a specific task"
      },
      %{
        name: "task_transition_list",
        description:
          "Read a task's recorded status-transition history — every observed status change, oldest first, with who caused it and when. Pure read over the rows `Platform.Tasks.Task` already writes inside the same transaction as the status change itself; this tool adds no instrumentation and records nothing.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "The task whose transition history you want"
          }
        },
        returns:
          "%{task_id, count, transitions: [%{from_status, to_status, occurred_at, actor_kind, actor_id, actor_label, via}], note} — transitions are OLDEST FIRST. `from_status` is null when no prior status was recorded. `actor_kind` is one of user | agent | system | unknown; `unknown` means the write was unattributed, not that it was automated.",
        limitations:
          "ZERO ROWS IS NOT ZERO DATA. A task with `count: 0` predates this instrumentation — the `note` field says so explicitly. It does NOT mean the task never changed status, and nothing here may be reconstructed from tasks.inserted_at / updated_at (backfill is forbidden). Denied non-recoverably for a tenant-pinned agent whose org does not own the task's project, and for a task_id that cannot be resolved to an org.",
        when_to_use:
          "When you need to know why and when a task reached its current status — who moved it, through which path, and how long ago — without database or SSH access."
      },
      %{
        name: "runtime_event_list",
        description:
          "Read a task's orchestration runtime events — the ack/heartbeat/progress/blocked stream the TaskRouter and its watchdog act on — newest first. Pure read over rows `Platform.Orchestration.RuntimeSupervision` already writes; this tool adds no instrumentation and records nothing. Task-level dispatches that resolve NO stage leave rows here too (task 01a0a5fa): `execution.dispatch_stageless` records that a dispatch frame was SENT for a task with no open stage — its payload carries `stage_id` nil, the addressed runtime id and whether that runtime was connected. `execution.dispatch_unanswered` records that such a dispatch went unanswered past the task-level watchdog window — no state change, no plan, no runtime event came back — and names the elapsed time. Neither mints an `execution_lease` row, so this tool is where a no-stage dispatch is visible at all.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "The task whose runtime events you want"
          },
          event_type: %{
            type: "string",
            required: false,
            description:
              "Exact-match filter, e.g. \"execution.acked\" or \"execution.blocked\". Omit for all types."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max events to return. Defaults to 50, hard-capped at 200."
          }
        },
        returns:
          "%{task_id, count, limit, events: [%{event_type, payload, runtime_id, phase, lease_id, occurred_at}]} — events are NEWEST FIRST. `payload` is returned verbatim, including `payload[\"stage_id\"]`, which is how you attribute an event to a specific stage: there is no top-level stage_id column.",
        limitations:
          "A TASK WITH RUNTIME EVENTS AND ZERO EXECUTION LEASES IS NORMAL, NOT A DEFECT. Leases are created only by the blocker/lifecycle path, never by a plain dispatch-ack: `RuntimeSupervision`'s `@event_statuses` maps `\"execution.acked\" => nil`, and a nil status makes `upsert_lease/2` return the existing lease and insert nothing. Do not read an empty `execution_lease_list` alongside a populated event stream as missing data. `limit` is CLAMPED to 200, not rejected, so a `count` of 200 may mean truncation rather than exhaustion. `event_type` is an open vocabulary and is not validated — an unknown value returns zero events. Denied non-recoverably for a tenant-pinned agent whose org does not own the task's project, and for a task_id that cannot be resolved to an org.",
        when_to_use:
          "When diagnosing whether a runtime actually acked, heartbeat or blocked on a task — especially to confirm or refute a watchdog no-ack alarm — without database or SSH access."
      },
      %{
        name: "execution_lease_list",
        description:
          "Read a task's durable `execution_leases` rows — created only by the blocker/lifecycle path (`RuntimeSupervision.persist_lease/4`), read back for the `needs_human` hold — newest first. These are NOT the records the no-ack/safety-net countdown reasons over: that countdown reads a separate ephemeral ETS store (`Platform.Orchestration.LeaseManager`) this tool does not read, so an empty result here does NOT mean no safety-net timer is armed. Pure read; creates and mutates nothing.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "The task whose execution leases you want"
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Filter to one status: active | blocked | finished | failed | expired | abandoned. An unknown value is REJECTED rather than silently ignored."
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max leases to return. Defaults to 50, hard-capped at 200."
          }
        },
        returns:
          "%{task_id, count, limit, status_filter, leases: [%{id, stage_id, phase, runtime_id, status, started_at, last_heartbeat_at, last_progress_at, expires_at, block_reason, metadata}]} — newest first by started_at.",
        limitations:
          "AN EMPTY LIST IS A LEGITIMATE ANSWER FOR A LIVE, HEALTHY TASK. Leases are created only by the blocker/lifecycle path, never by dispatch: `@event_statuses` maps `\"execution.acked\" => nil`, and `upsert_lease/2` short-circuits on a nil status without inserting. So a task can show a full `runtime_event_list` and zero leases and be working exactly as designed — do NOT report that as missing data. An unknown `status` returns an invalid-argument error rather than every lease, because a silent empty result for a typo is indistinguishable from that genuinely-empty case. `limit` defaults to 50 and is CLAMPED to a maximum of 200 rather than refused, and the response echoes the EFFECTIVE limit it ran with: when `count` equals that echoed `limit`, the list is truncated at the bound and there may be older leases you did not see, so read `count == 50` or `count == 200` as truncation rather than exhaustion. Denied non-recoverably for a tenant-pinned agent whose org does not own the task's project, and for a task_id that cannot be resolved to an org.",
        when_to_use:
          "When you need a task's lease lifecycle — whether one is active, blocked, expired, or was never created at all — to interpret a watchdog escalation without database or SSH access."
      },
      %{
        name: "task_list",
        description: "List tasks with optional filters.",
        parameters: %{
          project_id: %{
            type: "string",
            required: false,
            description: "Filter by project ID"
          },
          epic_id: %{
            type: "string",
            required: false,
            description: "Filter by epic ID"
          },
          status: %{
            type: "string",
            required: false,
            description: "Filter by status (backlog, in_progress, in_review, done, etc.)"
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Maximum tasks to return. Defaults to #{ResultBound.default_limit()}, capped at #{ResultBound.max_limit()}."
          },
          offset: %{
            type: "integer",
            required: false,
            description: "How many tasks to skip before the page. Defaults to 0."
          },
          detail: %{
            type: "string",
            required: false,
            description:
              "\"summary\" (default) truncates each description to #{ResultBound.snippet_chars()} characters; \"full\" returns descriptions whole. Use task_get for one task's full description rather than asking for full detail across a list."
          }
        },
        returns:
          "%{tasks: [...], total, limit, offset, has_more} — an ENVELOPE, not a bare array. `total` is the " <>
            "number of tasks matching the filters, counted in the database, independent of `limit`; `has_more` " <>
            "is true exactly when tasks matching the filters remain beyond this page. Read `has_more` rather " <>
            "than comparing `tasks` against `limit`. Each entry in `tasks` includes sponsor (nil or " <>
            "%{id, name, email}) per ADR 0042. In the default summary detail, `description` is a truncated " <>
            "preview and every entry additionally carries `description_truncated` (boolean) and " <>
            "`description_length` (the original size in bytes).",
        limitations:
          "Paginated: returns at most `limit` tasks (default #{ResultBound.default_limit()}, max " <>
            "#{ResultBound.max_limit()}) from `offset`, and `description` is a preview unless " <>
            "`detail: \"full\"` is passed. To read a whole backlog, page with `offset` until `has_more` is " <>
            "false; do NOT stop because a page came back short of `limit`. `total` and the page are two " <>
            "statements, so a concurrent write can leave `has_more` stale by one call. Rows are ordered " <>
            "`inserted_at` descending, tie-broken by `id`, which is a total order — paging cannot skip or " <>
            "repeat a task. Before task 01a049de this tool returned every matching task with every full " <>
            "description, which measured 3_366_819 bytes on an 807-task project and could not be called " <>
            "safely; before task 01a04a7a it returned a bare array with no way to tell 50 tasks from 50 of " <>
            "807.",
        when_to_use:
          "When you need to see what tasks exist, check the backlog, or find tasks in a specific state"
      },
      %{
        name: "task_complete",
        description:
          "Mark a task as done. Pass `base_updated_at` (the `updated_at` you read the task at) to be REFUSED with a recoverable `stale_base` error instead of completing a task someone else moved out from under you.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID to complete"},
          base_updated_at: %{
            type: "string",
            required: false,
            aliases: ["if_unmodified_since"],
            description:
              "Optional compare-and-set token: the ISO8601 `updated_at` you read the task at (take it verbatim from the task_get / task_update response). When supplied and the row has advanced since, the completion is REFUSED with a recoverable `stale_base` error naming the current updated_at, and the task's status is left untouched. Omit it to keep the pre-existing last-write-wins behaviour."
          }
        },
        returns:
          "%{task_id, status: \"done\", updated_at, previous_updated_at} \u2014 `previous_updated_at` is the `updated_at` the row held BEFORE this call, so a caller that passed no base can still see which revision it completed over. The status transition is RECORDED AGAINST THE CALLING AGENT: the resulting `task_phase_transitions` row carries `via: \"mcp_task_complete\"` and, when the call context carries an `agent_id`, `actor_kind: \"agent\"` with `actor_id` set to that id and `actor_label: \"agent\"`. The via is deliberately distinct from task_update's `\"mcp_task_update\"` so an agent ruling its own gate delivered is distinguishable from the same agent editing status.",
        limitations:
          "`base_updated_at` GUARDS THE STATUS WRITE, WHICH IS THE ONLY WRITE THIS TOOL MAKES \u2014 so when it is supplied and the row has advanced, nothing at all happens: the status stays as it was and no `task_phase_transitions` row is written. (This is a stronger guarantee than task_update's base, which covers that tool's plain-field statement only.) An unparseable base is rejected before any write. Without it this tool is last-write-wins, unchanged. Task must exist and allow transition to done status. Attribution scope: this stamps the status write that this tool makes, and nothing else — it does not resolve, evaluate or hide any validation, so a `done` task can sit beside a still-`pending` gate. When the call context carries NO `agent_id`, the actor falls back to the bare `:agent` atom, which `TransitionActor.normalize/1` does not match and therefore records as `actor_kind: \"unknown\"`, `actor_id: nil`, `actor_label: nil` — `via` is still `\"mcp_task_complete\"`, so the row reads as \"known code path, caller not identifiable\" rather than \"not captured\".",
        when_to_use: "When you need to mark a task as complete/done"
      },
      %{
        name: "task_close_as_delivered",
        description:
          "Record a task as `done` when the work genuinely shipped without a plan cycle \u2014 a `backlog` / `planning` / `blocked` / `stack_pending` task whose fix merged by direct PR. AUTHORIZATION: callable ONLY when the AgentRuntime you are calling through is owned by a user who is a Fabrikam admin; the authority is that admin's, delegated, and the closure records both the admin and this agent. `delivery_reference` is REQUIRED and is VERIFIED against the project's repository before anything is written \u2014 accepted forms are a 7\u201340 character commit sha, `#1018`, a github.com pull URL, or a github.com commit URL, and a URL naming a DIFFERENT repository than the project's is refused. A PR resolves only when it is MERGED. This does NOT widen the transition table: `backlog -> done` remains absent from @valid_task_transitions, and a task already in `in_progress` / `in_review` / `deploying` is refused, because those have a legitimate route to `done` and this must not become a way around the review gate.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to close"},
          delivery_reference: %{
            type: "string",
            required: true,
            description:
              "What says the work shipped: a commit sha (7\u201340 hex chars), `#1018`, https://github.com/<owner>/<repo>/pull/<n>, or https://github.com/<owner>/<repo>/commit/<sha>. Free text is refused. The owner/repo in a URL must be the project's own."
          }
        },
        returns:
          "%{task_id, status: \"done\", delivery_reference, resolution} \u2014 `resolution` is the repo-lookup payload persisted under `metadata.closed_as_delivered.resolution`.",
        limitations:
          "Refuses `not_authorized` (non-admin owner) before reading the task at all, so the refusal cannot be used to probe a task's status or existence. Refuses an unparseable reference, a reference that names another repository, a sha/PR that does not exist (`not_found`), an unmerged PR (`not_merged`), and \u2014 RECOVERABLY, never as not-found \u2014 a lookup that could not run because `gh` is unavailable.",
        when_to_use:
          "When work shipped outside the plan pipeline and the task is stranded in a status from which `done` is unreachable. Not a general completion route: use task_complete for a task that has a legitimate transition."
      },
      %{
        name: "task_update",
        description:
          "Update a task's fields (title, description, status, priority, assignee, sponsor, etc.). Omitted fields are left untouched; sponsor_user_id explicitly accepts null to unset (clears the Sponsor per ADR 0042). Flat assignee_id + assignee_type writes are auto-routed to the task's current-phase slot in phase_assignees (survives phase transitions per ADR 0044); with auto_approve_plan true and an agent-typed flat assignee, task_update also fills the absent phase slots (judged against the task's persisted phase_assignees overlaid with this call's routed slots) from the flat agent, while explicit phase_assignees entries win and present slots are never overwritten. User-typed or missing flat assignees still need explicit agent-typed phase_assignees for auto-approve. Pass phase_assignees directly to set multiple phase slots in one call — when both are supplied, phase_assignees wins. This tool is LAST-WRITE-WINS by default: pass base_updated_at (the `updated_at` you read the task at) to be REFUSED with a recoverable stale_base error instead of silently overwriting a concurrent writer.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            aliases: ["id"],
            description: "The task to update"
          },
          title: %{type: "string", required: false, description: "New title"},
          description: %{type: "string", required: false, description: "New description"},
          status: %{
            type: "string",
            required: false,
            description: "New status (must be a valid transition)"
          },
          priority: %{type: "string", required: false, description: "New priority"},
          epic_id: %{type: "string", required: false, description: "Move to a different epic"},
          assignee_type: %{type: "string", required: false, description: "Assignee type"},
          assignee_id: %{type: "string", required: false, description: "Assignee ID"},
          sponsor_user_id: %{
            type: "string",
            required: false,
            description:
              "Sponsor — human shepherd user id (UUID) per ADR 0042. Unlike the other fields, an explicit null value CLEARS the sponsor rather than being dropped. Omit the key entirely to leave sponsor unchanged."
          },
          deploy_target: %{
            type: "string",
            required: false,
            description:
              "Name of the deploy target this task should ship to (must match an entry in project.deploy_config.deploy_targets, e.g. \"production\" or \"exp\"). Required to be set before the deploying-phase dispatch can pin a target."
          },
          auto_approve_plan: %{
            type: "boolean",
            required: false,
            description:
              "When true, the engine auto-approves the task's submitted plan without waiting for a human approval — the task moves straight from plan_submit to in_progress. With an agent-typed flat assignee_id + assignee_type, task_update fills the absent phase slots (judged against the task's persisted phase_assignees overlaid with this call's routed slots) from the flat agent; explicit phase_assignees entries win and present slots are never overwritten. User-typed or missing flat assignees still need explicit agent-typed phase_assignees. Useful for well-scoped low-risk tasks where plan review is procedural. Defaults to false on new tasks."
          },
          phase_assignees: %{
            type: "object",
            required: false,
            description:
              "Granular per-phase assignees keyed by phase (\"planning\" | \"execution\" | \"review\") with values %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\" | \"user\"}. Canonical writer per ADR 0044 — only the slots supplied are written; other slots stay untouched. Wins over flat assignee_id + assignee_type when both are supplied in the same call."
          },
          base_updated_at: %{
            type: "string",
            required: false,
            aliases: ["if_unmodified_since"],
            description:
              "Optional compare-and-set token: the ISO8601 `updated_at` your edit was composed against (take it from the task_get / task_update response you read). When supplied and the row has advanced since, the write is REFUSED with a recoverable error naming the current updated_at, instead of silently overwriting the other writer. Omit it to keep the pre-existing last-write-wins behaviour."
          }
        },
        returns:
          "The updated task object (includes sponsor: nil | %{id, name, email}), plus `previous_updated_at` — the `updated_at` the row held BEFORE this call, i.e. the revision this write displaced. Compare it against the `updated_at` you last read: if it is newer than yours, you overwrote a concurrent writer's edit. It is disclosure after the fact, not prevention — nothing warns the writer you displaced. Pass `base_updated_at` to be refused instead. This key is on the task_update envelope ONLY; task_get and task_list do not carry it, because a read displaces nothing.",
        limitations:
          "`base_updated_at` GUARDS THE PLAIN-FIELD WRITE AND NOTHING ELSE, and it is LIVE ONLY IF THE CALL CARRIES AT LEAST ONE PLAIN FIELD (title, description, priority, epic_id, sponsor_user_id, deploy_target, auto_approve_plan). `status`, `phase_assignees` and `assignee_id`/`assignee_type` are NOT plain fields: status is applied by a separate statement, and a flat assignee is always routed into `phase_assignees`, which a third statement writes. So a call carrying a base plus ONLY those SUCCEEDS WITHOUT COMPARING ANYTHING — the guard is skipped, no error is raised, and the caller who armed it is the one who believes they are protected. Send the base together with at least one plain field, or it is decoration. On a call that does carry a plain field, the guarded write runs FIRST, so a stale base short-circuits and the later writes never run; the residual exposure is a row that advances BETWEEN statements. WITHOUT `base_updated_at` THIS TOOL IS LAST-WRITE-WINS: a concurrent writer's edit is overwritten silently and nothing tells either party; supplying it (alias `if_unmodified_since`) turns that into a recoverable `stale_base` refusal naming the current updated_at. An unparseable base is rejected before any write. Status transitions are validated; not all transitions are allowed. sponsor_user_id must reference an existing user; passing an unknown UUID returns a recoverable FK error.",
        when_to_use: "When you need to update a task's details or move it between columns"
      },
      %{
        name: "task_start",
        description:
          "Start a task — sets assignee (optional), transitions to in_progress, kicks off TaskRouter. Use instead of task_update when ready to begin work.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to start"},
          assignee_id: %{
            type: "string",
            required: false,
            description: "Agent ID to assign. Defaults to current assignee."
          },
          assignee_type: %{
            type: "string",
            required: false,
            description: "Assignee type: agent or user. Defaults to agent."
          }
        },
        returns: "Updated task object with status in_progress",
        limitations:
          "Task must be in backlog or planning status (per ADR 0029, plan approval transitions to in_progress automatically — manual task_start is for the no-plan-required edge case)",
        when_to_use: "When task is fully specced and ready to begin"
      },
      %{
        name: "task_ack",
        description:
          "Ack that you (the executor/reviewer/deployer) received the dispatch and are actively working on the stage. Call this as your FIRST tool call after spawning for a task (task 019f640d stage 5). Emits an `execution.acked` runtime_event which the TaskRouter consumes to extend the safety-net timer and suppress the 5-minute no-ack alert. Returns `{ack_at, next_safety_net_at}` for reference — `next_safety_net_at` may be nil when no lease is armed (e.g. manual_approval stages, where no safety-net timer runs). Requires a RUNNING stage, on both paths. A SUPPLIED `stage_id` is honoured exactly when all three hold: the stage EXISTS, it BELONGS TO this `task_id`, and its `status` is `\"running\"`; if any one fails the call is refused with a recoverable error naming which of the three it was (not-found / wrong-task / not-running), so a caller with a stale id, a caller holding a sibling task's id, and a caller racing a stage transition each get a different next action. The refusal is not bookkeeping: an honoured ack suppresses that stage's dispatch for the whole safety-net window (~90m; 120m in planning), so a misdirected ack would park a stage nobody is working. With NO `stage_id` the tool derives the current plan's running stage, and when there is none it returns `no running stage — cannot ack without a stage_id`. That is expected during the planning phase, which arms no liveness timers and needs no ack — the planning dispatch says so and does not ask you to call this. Requires a subagent_id — spawn the subagent FIRST, then include its returned handle in the ack.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "UUID of the task you were dispatched to work on."
          },
          stage_id: %{
            type: "string",
            required: false,
            description:
              "Optional — the running stage_id from your dispatch context. When supplied it must exist, belong to this `task_id`, and be `running`; any other stage is refused with a recoverable error naming which of the three failed, because an honoured ack parks that stage for the safety-net window. When omitted the tool resolves it via `current_running_stage(current_plan(task_id))`, so callers who lack a stage_id (e.g. planning-phase agents before the plan exists) can still ack the task-level dispatch."
          },
          subagent_id: %{
            type: "string",
            required: true,
            description:
              "Opaque handle identifying the subagent working this stage — the runtime slug (e.g. `higgins.moon`) for openclaw agents, or the Task-tool `agentId` returned by the Agent spawn call for Claude Code (e.g. `afd767f1e0cc81633`). Must be non-empty and ≤128 chars. Presence forces spawn-before-ack ordering: an operator cannot ack a dispatch they never spawned a subagent for."
          }
        },
        returns:
          "%{task_id, stage_id, event_id, acked_at, next_safety_net_at}. `next_safety_net_at` is nil when the LeaseManager has no active lease for the task (planning-phase dispatch, manual_approval stages, or a boot-race before the router recorded the dispatch).",
        limitations:
          "Idempotent — re-calling on the same stage is a soft ack refresh; each call emits a fresh execution.acked event and extends the safety-net deadline. Unknown `task_id` returns `{:error, :not_found}`. A supplied `stage_id` is accepted only when the stage exists, belongs to this `task_id`, and is `running`; otherwise a recoverable envelope names the failing condition — the stage does not exist, it belongs to another task (the owning task_id is cited), or it is in some other status (the status is cited). When no stage_id is supplied and the task has no running stage, returns `{:error, :no_running_stage}` so the caller can decide whether to task_start first or ignore. Invalid subagent_id returns `{:error, :invalid_subagent_id}` — one of `missing` (key absent or nil), `empty_or_whitespace` (empty string or whitespace-only), or `oversized` (> 128 bytes). No format policing beyond that; any well-formed string identifying the spawn handle is accepted.",
        when_to_use:
          "As your FIRST tool call after being dispatched for a task, before you start reading code or planning steps. Without an ack the router fires an escalation alert in 5 minutes on `coding`/`review`/`deploying` stages (planning: same 5m ack window, longer safety-net)."
      },
      %{
        name: "alarm_silence",
        description:
          "Operator escape hatch: suppress the `execution.no_ack_timeout` alarm for a stage's lease without firing a blocker. Use when your MCP client's tool cache lacks `task_ack` (a known cross-version issue where a session's catalog predates a new tool) and you KNOW a subagent is actively working the stage. Sets `silenced_until` on the lease so the TaskRouter's `:check_no_ack` reschedules instead of firing. Does NOT pause `stage_complete` / validation dispatch, does NOT clear on `record_ack/1`, dies with the stage transition. Audit-logged to the runtime_event stream AND `platform.orchestration.alarm_silence` audit rows. Capped at 24h — re-silence if the condition persists. A SUPPLIED `stage_id` is honoured exactly when all three hold: the stage EXISTS, it BELONGS TO this `task_id`, and its `status` is `\"running\"`; otherwise the call is refused with a recoverable error naming which of the three failed, because silencing a stage you do not own or that is not running suppresses an alarm for work nobody is doing. With no `stage_id` the tool derives the current plan's running stage. Prefer `task_ack` if it's available; this exists to retire the `report_blocker(needs_human: false)` anti-pattern.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "UUID of the task whose lease you want to silence."
          },
          stage_id: %{
            type: "string",
            required: false,
            description:
              "Optional — the running stage_id from your dispatch context. When supplied it must exist, belong to this `task_id`, and be `running`; anything else is refused with a recoverable error naming which of the three failed. When omitted the tool resolves it via `current_running_stage(current_plan(task_id))`, matching the `task_ack` convention."
          },
          until_seconds: %{
            type: "integer",
            required: true,
            description:
              "Silence duration in seconds from now. Must be between 60 (1m minimum — no accidental micro-silences) and 86_400 (24h maximum — no indefinite suppression). Relative window instead of an absolute ISO timestamp avoids clock-skew debates between operator and server."
          },
          reason: %{
            type: "string",
            required: true,
            description:
              "Human-readable justification for the silence, minimum 8 characters. Persisted in the runtime_event payload and audit row so an operator can later explain why the alarm was suppressed."
          }
        },
        returns:
          "%{task_id, stage_id, silenced_until, reason}. `silenced_until` is a %DateTime{} — the router re-arms `:check_no_ack` at `silenced_until + 1s`.",
        limitations:
          "Requires an active LeaseManager row for the task (the router must have already recorded the dispatch). Boot-race calls return `{:error, :not_found}` with a recoverable retry hint. A supplied `stage_id` that does not exist, belongs to another task, or is not `running` returns a recoverable envelope naming the failing condition rather than raising. `until_seconds` outside 60..86_400 returns a validation error. Silence does NOT prevent `stage_complete`, does NOT block dispatch of new stages, and dies when `clear/1` runs on the lease at stage transition. Use `task_ack` in preference when your MCP catalog carries it.",
        when_to_use:
          "As an operator override when your MCP client cache doesn't include `task_ack` and a no-ack alarm would otherwise fire a spurious `needs_human=true` blocker. Not for general liveness — use `task_ack` for that. Not for pausing execution — use `report_blocker(needs_human: true)` when the stage is actually stuck."
      },
      %{
        name: "task_dependencies",
        description:
          "Inspect what a task is waiting on (its declared dependencies + which are still unmet) and what would be unblocked by completing it (its inverse dependents).",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to introspect"}
        },
        returns:
          "%{deps: [%{task_id, title, kind, status}], unmet: [task_id], dependents: [%{task_id, title, status}]}. `deps` preserves authored order; missing/deleted dep ids return entries with nil title/status. `unmet` is the subset of deps whose status is not 'done'. `dependents` lists tasks that declare this one as a dep (sorted by inserted_at).",
        limitations:
          "Read-only. Does not mutate dependency state or trigger unblock sweeps — finishing a dep through task_complete is what cascades the unblock.",
        when_to_use:
          "When deciding whether you can start a task, surfacing what's blocking you in a status update, or estimating the blast radius of completing a task."
      },
      %{
        name: "task_attach_canvas",
        description:
          "Attach a canvas to a task so it rides along in subsequent dispatch payloads. Idempotent on `(task_id, canvas_id)` — re-attaching the same pair updates `note` + attribution and returns the same attachment id rather than duplicating the row.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to attach to"},
          canvas_id: %{
            type: "string",
            required: true,
            description:
              "The canvas to attach. Validated at attach time against `chat_canvases` — soft-deleted or unknown canvas ids are rejected with `canvas_not_found`."
          },
          note: %{
            type: "string",
            required: false,
            description: "Optional human-readable note describing why the canvas is attached."
          }
        },
        returns: "%{attachment_id, task_id, canvas_id, note}",
        limitations:
          "Two independent authorization conjuncts, checked in this order: you must be able to " <>
            "TOUCH THE TASK (assignee or phase assignee, participant in its execution space, " <>
            "sponsor, or member of its project's org) and you must be able to READ THE CANVAS. " <>
            "Neither implies the other, so the four refusals are named separately. " <>
            "`task_forbidden` names `task_design_decline` as the exit for a design dispatch you " <>
            "cannot deliver. `canvas_forbidden` means you cannot read the canvas. " <>
            "`canvas_not_found` means the canvas is unknown or was soft-deleted upstream. " <>
            "`task_not_found` (\"Task not found\") covers a task that is unknown, malformed or " <>
            "soft-deleted, for everyone including grant-holders. Of the four only " <>
            "`task_forbidden` arrives as a machine-readable `code` key; the other three are " <>
            "prose in `error`, so branch on `code` for the task gate and read `error` for the " <>
            "rest. Over the hosted /mcp transport the refusal envelope is exactly `error`, " <>
            "`code`, `recoverable` and `suggestion` — the `task_id` and `canvas_id` keys the " <>
            "handler sets do NOT survive it, so read the id out of `error`. The runtime " <>
            "WebSocket channel keeps them. None of this paragraph is delivered over /mcp at " <>
            "all — it ships only on the capabilities push. " <>
            "Soft-reference contract: the canvas is checked at attach time but not FK-enforced. " <>
            "If the canvas is soft-deleted later, `task_list_canvases` will surface it with " <>
            "`canvas_present: false` so callers can detach. Idempotent re-attach updates the " <>
            "note + attribution but never produces a duplicate row.",
        when_to_use:
          "When you (or an upstream planner) want a canvas to ride along in the next dispatch payload for a task, without copy-pasting it into a chat message."
      },
      # ADR-0046 member 7, task `019fa504` stage 2. Deliberately IN THE `task`
      # BUNDLE, directly beside `task_attach_canvas`, and that placement is the
      # point of the ticket rather than an incidental filing decision.
      #
      # `task_attach_canvas` is the designer's PROVEN delivery path — it is the
      # one instruction `design.task_direction.v1` gives her. Putting the exit
      # in the same bundle makes its reachability CO-EXTENSIVE with a path
      # already known to work on every designer runtime that exists, with zero
      # new `allowed_bundles` grant on any row. A new bundle (or `plan`, which
      # a designer has no reason to hold) would ship an affordance that stays
      # unreachable until somebody hand-edits every designer runtime — which is
      # precisely the failure mode this task exists to fix, re-committed one
      # layer down. `tool_surface_design_decline_test.exs` asserts the
      # co-extensiveness directly, paired with a `["canvas"]` control.
      %{
        name: "task_design_decline",
        description:
          "Decline a design dispatch: close an OPEN pre-plan design step because you, the " <>
            "dispatched designer, judge that this task needs no design direction (ADR-0046). " <>
            "Records the step as `not_applicable` with reason `designer_declined` and returns " <>
            "the planner to work IMMEDIATELY. This is the only exit from a design dispatch " <>
            "other than delivering a canvas with `task_attach_canvas` — going silent instead " <>
            "burns the full design deadline and records the step as `failed`.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description:
              "The task whose design step you are declining. Printed as `task_id:` in the design dispatch prompt."
          },
          reason: %{
            type: "string",
            required: true,
            description:
              "Required, non-blank, at least 8 characters. One sentence saying WHY no direction is needed — the change is not visual, or the surface already has direction that still holds. Persisted verbatim as `decline_note`. This is the only signal that will ever let an analyst separate a genuine UI-classifier misfire from a UI task that legitimately needed no direction, so a placeholder like \"n/a\" is worse than no decline at all."
          }
        },
        returns:
          "%{task_id, outcome, reason, declined_after_timeout} — `outcome` is the PERSISTED planning-step outcome (\"not_applicable\"), `reason` is the persisted `\"designer_declined\"`, and `declined_after_timeout` is true when the decline arrived after the deadline had already recorded a `failed` step and upgraded it. The calling agent (or user) is recorded on the step as `declined_by`, in the same shape `task_attach_canvas` records an attachment's author.",
        # This prose is TESTED, not asserted by hand:
        # `tool_surface_design_decline_test.exs` drives every refusal below
        # through `execute/3` and asserts the observed `code` set is exactly
        # the set named here, via `design_decline_error_codes/0`. The
        # 2026-07-26 e2e journal records `intent_ack` / `task_ack` shipping
        # `limitations` describing an error taxonomy the code never emits,
        # with no test guarding it — remote runtimes branch on these strings.
        limitations:
          "Refusals carry a `code`: `missing_task_id` (task_id absent, blank, or not a string), " <>
            "`missing_reason` (reason absent, blank, or shorter than 8 characters — a decline " <>
            "with no stated reason is unusable as classifier evidence, which is the whole " <>
            "reason this exit records anything), " <>
            "`task_not_found` (no task with that id), " <>
            "`step_not_open` (the design step already settled, was skipped, or never fired; " <>
            "the call changed NOTHING — a decline never overwrites a delivered canvas), " <>
            "`decline_failed` (the write itself failed). " <>
            "The one state that is NOT a refusal is a step the deadline already failed: that " <>
            "succeeds as a late-arrival upgrade and carries `declined_after_timeout: true`, so " <>
            "the timeout stays visible in the record rather than being erased by the upgrade. " <>
            "A runtime WITHOUT the `task` capability bundle simply never declines: the design " <>
            "deadline expires, the step records `failed`, and the planner proceeds exactly as " <>
            "it does today. That degradation is deliberate (ADR-0046 decision 7 — silence " <>
            "falls open) and is why a designer who cannot reach this tool is a missing " <>
            "judgement, not a stuck task.",
        when_to_use:
          "As the dispatched designer, when you have read the task and judge that it needs no design direction — instead of attaching a canvas you do not believe in, and instead of going silent. Not for delivering direction: that is task_attach_canvas."
      },
      %{
        name: "task_detach_canvas",
        description:
          "Detach a canvas from a task. Safe to call on attachments whose canvas was soft-deleted upstream — the attachment row is keyed independently of the live canvas.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to detach from"},
          canvas_id: %{type: "string", required: true, description: "The canvas to detach"}
        },
        returns: "%{detached: true}",
        limitations:
          "Gated on the TASK: you must be able to touch it (assignee or phase assignee, " <>
            "participant in its execution space, sponsor, or member of its project's org), and " <>
            "a denial is `task_forbidden`, delivered as a machine-readable `code` key. There is " <>
            "no canvas-side check — detaching revokes a read grant rather than conferring one, " <>
            "so a canvas you cannot read is still yours to unstaple from a task you own. The " <>
            "other two refusals are prose in `error` with no `code`: `not_found` if no matching " <>
            "`(task_id, canvas_id)` pair exists, and `task_not_found` (\"Task not found\") if " <>
            "the task is unknown, malformed or soft-deleted. Over the hosted /mcp transport " <>
            "none of this paragraph is delivered at all — it ships only on the capabilities " <>
            "push. Does not delete the canvas itself — only the attachment row.",
        when_to_use:
          "When a canvas should no longer ride along with a task's dispatch payload, or to clean up a stale attachment whose underlying canvas was soft-deleted."
      },
      # REACHABILITY CAVEAT for all three canvas-attachment tools, recorded
      # once here (task 019fb581 stage 4). `limitations` ships verbatim on the
      # capabilities push, but `PlatformWeb.MCPController.to_mcp_tool/1`
      # forwards only `name`, `description` and `inputSchema`, so a refusal
      # taxonomy stated only in this field never reaches an agent on the
      # hosted `/mcp` transport. `canvas.create` routes its own boundary
      # through `description` for exactly this reason (see :1097).
      #
      # Deliberately NOT mirrored into `description` here: it would have to be
      # done for attach, detach and list together to be worth anything, and
      # the whole map IS the attention-broadcast payload, so a duplicated
      # paragraph costs bytes on every push. Raised as a decision rather than
      # absorbed as a silent scope expansion.
      %{
        name: "task_list_canvases",
        description:
          "List the canvases attached to a task, in `inserted_at` ASC order. Each row carries the attachment metadata and a hydrated canvas envelope (title, present/soft-deleted state).",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description: "The task to list attachments for"
          }
        },
        returns:
          "%{canvases: [%{attachment_id, canvas_id, title, note, attached_at, canvas_present: bool}]}. `canvas_present: false` means the underlying canvas was soft-deleted upstream — call `task_detach_canvas` to clean up the stale row.",
        limitations:
          "Gated on the TASK, same standing as the two writes: you must be its assignee or " <>
            "phase assignee, a participant in its execution space, its sponsor, or a member of " <>
            "its project's org. A denial is `task_forbidden`, delivered as a machine-readable " <>
            "`code` key, and it is a REFUSAL. It is never disguised as an empty list, so an " <>
            "empty list always means the task has no attachments. `task_not_found` " <>
            "(\"Task not found\", prose in `error` with no `code`) covers a task that is " <>
            "unknown, malformed or soft-deleted, for everyone including grant-holders. Over the " <>
            "hosted /mcp transport none of this paragraph is delivered at all — it ships only " <>
            "on the capabilities push. Metadata only: rows carry the canvas title " <>
            "and your note, never the document. Call `canvas.describe` with the `canvas_id` " <>
            "for that, and it gates separately.",
        when_to_use:
          "When you need to see which canvases will ride along in the next dispatch for a task, or to find stale attachments whose underlying canvas was soft-deleted."
      },
      %{
        name: "stack_create",
        description:
          "Create a new task stack (ADR 0041). Task stacks group co-related tasks that ship together as a single rollup PR. The rollup branch is auto-derived from the slug as `stack/<slug>`. Optionally set a Sponsor (human shepherd, ADR 0042 Decision 8) distinct from any member's technical assignee.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "Project this stack belongs to"
          },
          slug: %{
            type: "string",
            required: true,
            description:
              "Short URL-safe identifier (lowercase alphanumeric + hyphens, max 60 chars). Must be unique per project."
          },
          name: %{type: "string", required: true, description: "Human-friendly stack name"},
          description: %{type: "string", required: false, description: "Optional description"},
          epic_id: %{
            type: "string",
            required: false,
            description: "Optional epic this stack belongs under"
          },
          base_branch: %{
            type: "string",
            required: false,
            description: "Branch the rollup is cut from (defaults to `main`)"
          },
          auto_plan: %{
            type: "boolean",
            required: false,
            description:
              "Stack v2 lifecycle flag. When true, `stack_start_planning` dispatches every member to `planning` in one concurrent pass. When false (default), planning walks in dependency-wave order — only the root wave dispatches; downstream waves advance as upstream plans approve."
          },
          auto_accept_plan: %{
            type: "boolean",
            required: false,
            description:
              "Stack v2 lifecycle flag. When true, submitted member plans auto-approve without human review (resolved via `Tasks.maybe_auto_approve/1` reading the member's stack). When false (default), plans land at `pending_review` and require the normal approval path."
          },
          sponsor_user_id: %{
            type: "string",
            required: false,
            description:
              "Optional Sponsor user id (ADR 0042 Decision 8). The human shepherd accountable for the stack landing, distinct from any member's technical assignee. Nullable — omit for an unsponsored stack."
          }
        },
        returns:
          "%{stack_id, rollup_branch, sponsor} — the new stack id, its derived rollup branch, and the preloaded sponsor envelope (nil when unsponsored, `%{id, name, email}` when set).",
        limitations:
          "Slug must be unique within the project and pass valid_slug?/1. Stack starts in `forming` status with no members. sponsor_user_id must reference an existing user; passing an unknown UUID returns a recoverable FK error envelope.",
        when_to_use:
          "When you need to group multiple co-related tasks into a single ship-unit with one rollup PR."
      },
      %{
        name: "stack_update",
        description:
          "Update a task stack's mutable fields (name, description, sponsor). Omitted keys are left untouched; `sponsor_user_id` explicitly accepts `null` to clear the slot (matches `task_update` nilable semantics per ADR 0042). Mirrors `task_update` for the stack surface. `clear_conflict: true` is the ONLY status exit for a stack halted at `blocked` on a rollup-merge conflict: it deletes `metadata.conflict` and recomputes the stack status from its members in one atomic write (the stack changeset drops any status change on a conflict-held stack that does not clear the conflict in the same write). There is deliberately no free-form `status` arg — a shipped stack may not be walked backwards.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to update"},
          clear_conflict: %{
            type: "boolean",
            required: false,
            description:
              "When true, resolve a conflict-held `blocked` stack: clears `metadata.conflict` and moves the status to the rollup of its members in the same write, then returns `conflict_cleared: true` with the resulting `status`. Use after the rollup-branch conflict has been fixed by hand. Returns a recoverable `not_conflicted` error when the stack carries no conflict."
          },
          name: %{type: "string", required: false, description: "New human-friendly stack name"},
          description: %{type: "string", required: false, description: "New description"},
          sponsor_user_id: %{
            type: "string",
            required: false,
            description:
              "Sponsor — human shepherd user id (UUID) per ADR 0042 Decision 8. Unlike the other fields, an explicit `null` value CLEARS the sponsor rather than being dropped. Omit the key entirely to leave the sponsor unchanged."
          }
        },
        returns:
          "The updated stack object (same shape as `stack_get`'s `stack` field, including `sponsor_user_id` and nested `sponsor: nil | %{id, name, email}`). When `clear_conflict: true` was honoured the envelope also carries `conflict_cleared: true` and `status` is the recomputed rollup status.",
        limitations:
          "Returns `stack_not_found` if the stack does not exist. `sponsor_user_id` must reference an existing user; passing an unknown UUID returns a recoverable `sponsor_fk` error envelope. `clear_conflict: true` on a stack with no `metadata.conflict` returns a recoverable `not_conflicted` error and writes nothing (the other attrs are NOT applied). No `status` arg exists.",
        when_to_use:
          "When you need to rename a stack, edit its description, set/clear its Sponsor after creation, or release a `blocked` stack after resolving its rollup-merge conflict (`clear_conflict: true`)."
      },
      %{
        name: "stack_get",
        description:
          "Get a task stack with its members, in-stack dependency edges, and which members are executable right now (no in-stack predecessors).",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to fetch"}
        },
        returns:
          "%{stack: %{id, slug, name, status, rollup_branch, base_branch, description, auto_plan, auto_accept_plan, rollup_branch_ready, rollup_pr}, members: [%{id, title, status, stack_position, dependencies, paused_reason, landed_at, plan_status, blocked_by}], edges: [%{from_task_id, to_task_id, kind}], executable_now: [task_id], blocked_now: [task_id], members_in_merge_order: [task_id], cross_stack_deps: [%{from_task_id, to_task_id, kind}]}. `stack.auto_plan` and `stack.auto_accept_plan` are Stack v2 lifecycle flags (see `stack_create` for semantics). `stack.rollup_pr` is nil until the deployer starts opening the rollup PR, then a curated `%{status, number, url, merged_at, auto_merge_armed}` where every key is individually nilable (`status: \"opening\"` with no number/url while the open is in flight; `merged_at` set once merged). Per member: `landed_at` is the `%{sha, at}` rollup-merge stamp or nil; `plan_status` is the status of the member's latest plan (`draft` / `pending_review` / `approved` / `completed` / `rejected` / `superseded`) or nil when it has none; `blocked_by` is the list of THIS member's in-stack dependency ids the engine does not yet consider satisfied (`[]` when unblocked). `executable_now` is status-aware: a member is listed iff its status is one the dispatcher treats as live (`planning` / `in_progress` / `in_review` / `deploying`) AND `blocked_by == []`; every other member is in `blocked_now`, so the two lists partition `members` (a `stack_pending` member whose deps all landed but has not been promoted yet sits in `blocked_now` with `blocked_by: []`). `edges` are in-stack dep edges only; cross-stack dep edges (deps to tasks in OTHER stacks) surface separately under `cross_stack_deps`. Deps pointing at non-stack tasks are silently dropped per ADR 0041.",
        limitations:
          "Returns an error envelope if the stack does not exist. `executable_now` is empty (and every member sits in `blocked_now`) when the in-stack DAG fails validation (cycle or cross-stack-dep) — inspect `edges` / `cross_stack_deps` to diagnose. `blocked_by` reflects the rollup-merge stamp and status of each dep, not the git reachability check the promotion sweep additionally runs.",
        when_to_use:
          "When inspecting a stack's current shape, members, in-stack dep graph, or which members are runnable now."
      },
      %{
        name: "stack_list",
        description: "List task stacks, optionally filtered by project and/or status.",
        parameters: %{
          project_id: %{
            type: "string",
            required: false,
            description: "Filter by project"
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Filter by status: forming, in_progress, in_review, deploying, done, abandoned"
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Maximum stacks to return. Defaults to #{ResultBound.default_limit()}, capped at #{ResultBound.max_limit()}."
          },
          offset: %{
            type: "integer",
            required: false,
            description: "How many stacks to skip before the page. Defaults to 0."
          }
        },
        returns:
          "%{stacks: [...], total, limit, offset, has_more} — an ENVELOPE, not a bare array. `total` is the " <>
            "number of stacks matching the filters, counted in the database, independent of `limit`; " <>
            "`has_more` is true exactly when stacks matching the filters remain beyond this page. Read " <>
            "`has_more` rather than comparing `stacks` against `limit`. Each entry in `stacks` is a ROW, " <>
            "not the `stack_get` shape: identity and state only — id, slug, name, status, rollup_branch, " <>
            "base_branch, project_id, epic_id, rollup_branch_ready, rollup_pr (%{status, number, url, " <>
            "merged_at, auto_merge_armed} or nil), inserted_at, updated_at — plus `description` as a " <>
            "preview truncated to #{ResultBound.snippet_chars()} characters with `description_truncated` " <>
            "(boolean) and `description_length` (the original size in bytes) beside it. Rows carry no " <>
            "members, phase_assignees, sponsor, or lifecycle flags; call `stack_get` for those.",
        limitations:
          "Paginated: returns at most `limit` stacks (default #{ResultBound.default_limit()}, max " <>
            "#{ResultBound.max_limit()}) from `offset`. To read every stack, page with `offset` until " <>
            "`has_more` is false; do NOT stop because a page came back short of `limit`. `total` and the " <>
            "page are two statements, so a concurrent write can leave `has_more` stale by one call. Rows " <>
            "are ordered `inserted_at` descending, tie-broken by `id`, which is a total order — paging " <>
            "cannot skip or repeat a stack. `description` is always a preview here; the full text is one " <>
            "`stack_get` away. Before task 01a05394-8300 this tool returned a bare array of every matching " <>
            "stack in the full `stack_get` shape with every full description, and descriptions grow " <>
            "without bound (abandon and complete append to them forever).",
        when_to_use: "When you need an overview of stacks in a project or by lifecycle status."
      },
      %{
        name: "stack_add",
        description:
          "Attach an existing task to a stack as a new member. Validates the resulting in-stack DAG: cycles and cross-stack dep edges are rejected (atomically rolled back).",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to attach to"},
          task_id: %{type: "string", required: true, description: "The task to attach"}
        },
        returns:
          "%{task_id, stack_id, stack_position, status, warning, gate_closed, waiting_on} on success. On a stack that has already commenced (status not `forming`) the task is parked at `stack_pending`, `gate_closed` is true, `waiting_on` lists the members without an approved plan, and `warning` explains that the stack's commencement gate is closed for every member until this task's plan is approved. Error envelopes carry a `code` field: `already_in_stack`, `stack_terminal` (stack is done/abandoned), `cycle` (with `path` of task ids), `cross_stack_dep` (with `from_task_id` and `to_task_id`).",
        limitations:
          "Task must not already be in any stack. A done or abandoned stack refuses new members. The in-stack DAG must remain acyclic and contain no cross-stack dep edges after the add; otherwise the attach is rolled back.",
        when_to_use:
          "When grouping an existing task into a stack. To create-and-attach in one call, pass `stack_id` to `task_create` instead."
      },
      %{
        name: "stack_add_dependency",
        description:
          "Add an in-stack dependency edge from `from_task_id` to `to_task_id` (read: `from` blocks on `to`). Both endpoints must already be members of the same stack; the resulting in-stack DAG is validated atomically (cycles roll back).",
        parameters: %{
          stack_id: %{
            type: "string",
            required: true,
            description: "The stack both endpoints must belong to"
          },
          from_task_id: %{
            type: "string",
            required: true,
            description: "The dependent task (the one that gains a new dep entry)"
          },
          to_task_id: %{
            type: "string",
            required: true,
            description: "The task being depended on"
          },
          kind: %{
            type: "string",
            required: false,
            description:
              "Edge kind; defaults to `\"blocks\"`. Allowed values: #{Enum.join(Platform.Tasks.Task.valid_dependency_kinds(), ", ")}."
          }
        },
        returns:
          "%{from_task_id, to_task_id, kind, executable_now, blocked_now} on success. `executable_now` / `blocked_now` are the SAME status-aware partition `stack_get` reports, recomputed from the post-write state: a member is in `executable_now` iff its status is in planning/in_progress/in_review/deploying AND `blocked_by == []`; every other member is in `blocked_now`; the two lists partition the members.",
        limitations:
          "Both endpoints must be members of the given stack — non-members or cross-stack endpoints return `not_in_stack`. Self-edges (`from == to`) return `self_edge`. A duplicate `(to_task_id, kind)` already on `from_task` returns `duplicate_edge`. Adds that would close a cycle return `cycle` (with `path`); rare cross-stack-DAG slips return `cross_stack_dep`. All errors roll back atomically.",
        when_to_use:
          "When wiring or reshuffling an existing stack's dependency DAG without touching membership. To attach a new task with an initial dep set, prefer `stack_add` after creating the task with `dependencies` populated."
      },
      %{
        name: "stack_remove_dependency",
        description:
          "Remove an in-stack dependency edge from `from_task_id` to `to_task_id`. Mirrors `stack_add_dependency` — same membership/self guards.",
        parameters: %{
          stack_id: %{
            type: "string",
            required: true,
            description: "The stack both endpoints must belong to"
          },
          from_task_id: %{
            type: "string",
            required: true,
            description: "The dependent task (the one whose dep entry is removed)"
          },
          to_task_id: %{
            type: "string",
            required: true,
            description: "The task being un-depended on"
          },
          kind: %{
            type: "string",
            required: false,
            description:
              "Edge kind to remove; defaults to `\"blocks\"`. Allowed values: #{Enum.join(Platform.Tasks.Task.valid_dependency_kinds(), ", ")}."
          }
        },
        returns:
          "%{from_task_id, to_task_id, executable_now, blocked_now, promoted} on success. `executable_now` / `blocked_now` are the SAME status-aware partition `stack_get` reports, recomputed from the post-write state: a member is in `executable_now` iff its status is in planning/in_progress/in_review/deploying AND `blocked_by == []`; every other member is in `blocked_now`; the two lists partition the members. A member this call promoted (`promoted`) appears in `executable_now`.",
        limitations:
          "Both endpoints must be members of the given stack — non-members or cross-stack endpoints return `not_in_stack`. Self-edges return `self_edge`. If no `(to_task_id, kind)` entry exists on `from_task`, returns `not_an_edge` so callers can disambiguate idempotent re-removes from successful ones.",
        when_to_use:
          "When breaking an in-stack dep edge — e.g., to unblock a member after a scope change, or to dissolve a chain before ejecting a task."
      },
      %{
        name: "stack_eject",
        description:
          "Detach a task from its stack. Refuses if other in-stack members declare this task as a dep — they must be ejected or have the dep removed first.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to detach from"},
          task_id: %{type: "string", required: true, description: "The task to detach"}
        },
        returns:
          "%{task_id, stack_id} (the stack the task was removed from). Error envelopes carry a `code` field: `not_in_stack`, `has_dependents` (with `dependents: [%{id, title}]`).",
        limitations:
          "Task's status is intentionally left as-is (per ADR 0041) — the caller decides whether to send it back to backlog. The stack's rollup status is recomputed.",
        when_to_use:
          "When removing a member from a stack — e.g., after a scope change or to break a stuck stack apart."
      },
      %{
        name: "stack_abandon",
        description:
          "Terminal: mark a stack `abandoned` and record the reason. Per-member handling lands in a later T2 stage; today this only flips the stack-level status and stamps the reason into `description`.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to abandon"},
          reason: %{
            type: "string",
            required: false,
            description: "Free-text reason; appended to the stack's description"
          }
        },
        returns: "The updated stack record (status: `abandoned`).",
        limitations:
          "Terminal: abandoned stacks are never auto-recomputed back to another status. Members are NOT yet cleared off the stack — that handling lands with the membership stage's eject_task wiring.",
        when_to_use:
          "When a stack's scope is no longer wanted and you want to record that decision explicitly."
      },
      %{
        name: "stack_complete",
        description:
          "Terminal: mark a stack `done`. Only allowed when every member task is already `done`. Use this when members have shipped through individual PRs (the manual-ship lane) rather than the rollup branch — `recompute_stack_status/1` doesn't recognize per-PR merges as completion, so the stack would otherwise sit at `deploying` forever.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to complete"},
          note: %{
            type: "string",
            required: false,
            description:
              "Free-text note appended to the stack's description (prefixed `Completed:`)"
          }
        },
        returns:
          "The updated stack record (status: `done`). Error envelopes: `members_not_done` (with `pending: [%{id, title, status}]`) when any member task isn't `done`.",
        limitations:
          "Terminal: completed stacks are not auto-recomputed back to another status. The all-members-done precondition is enforced — eject or finish stragglers first.",
        when_to_use:
          "When every member of a stack has merged (typically via individual PRs) and you want to close the stack out cleanly instead of abandoning it."
      },
      %{
        name: "stack_start",
        description:
          "Transition a stack from `forming` to `in_progress` and fan its members out per ADR 0041 §\"Status cascade — entering a stack\". Level-0 roots (members with no in-stack deps) move from `backlog` to `in_progress`; non-root members move from `backlog` to `stack_pending`. Members already past `backlog` are left alone — the cascade is additive.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to start"}
        },
        returns:
          "The updated stack record (status: `in_progress`) plus `started` (the roots moved to `in_progress`) and `parked` (the non-roots moved to `stack_pending`). Per-member transition failures (e.g. a root with no approved plan) surface in a `cascade_errors` array.",
        limitations:
          "Refuses to run when the stack is not currently at `forming`. Members without an approved plan will fail the `in_progress` transition and appear in `cascade_errors`; the stack-level status still advances to `in_progress`.",
        when_to_use:
          "When a stack's membership is finalized and you want the engine to begin dispatching its level-0 roots."
      },
      %{
        name: "stack_retry_member_merge",
        description:
          "Re-run the server-side rollup fast-forward for ONE stack member (task 01a05392). Use it after the member's rollup merge was paused as `rollup_diverged` (visible as `paused_reason` on `task_get` / `stack_get`, and in the `execution.blocked` event that named this tool) and you have rebased the member branch onto `origin/<rollup_branch>` and force-pushed. Runs synchronously and returns the merge outcome directly. Idempotent: a member already merged into the rollup is a successful no-op (`outcome: already_merged`), and a member that is STILL not fast-forwardable is reported (`outcome: still_diverged`) with both SHAs and the exact rebase, never silently retried.\n\nWhy a named tool and not `task_update status: in_review` on an already-in_review member: that overload would attach a real side effect to a call that is a status NO-OP (in_review -> in_review). It appears in no tool list, its documentation would have to describe a side effect that fires on a non-transition (which reads as a bug), and `task_update` returns a task, so the caller could not learn whether the merge succeeded, was already merged, or diverged again. This tool is the one trigger; there is deliberately no second.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            description:
              "The MEMBER task id (the paused task) — NOT the stack id. Find it in the blocker's `member_task_id`, or via `stack_get` members whose `paused_reason` is non-nil."
          }
        },
        returns:
          "On success `{outcome, task_id, stack_id, rollup_branch, task}` where `outcome` is `merged` (plus `merge_sha`, the new rollup HEAD) or `already_merged` (plus the existing `merged_into_rollup_at` stamp). `task` is the reloaded member: after `merged`, `merged_into_rollup_at` is present and `paused_reason` is nil. Error envelopes carry `code` + `outcome`: `rollup_diverged` / `still_diverged` (recoverable; echoes `rollup_branch`, `rollup_sha`, `member_sha`, and the rebase in `suggestion`), `merge_conflict` / `conflict` (NOT recoverable; the stack is now `blocked`; `files` lists the conflicts), `member_not_ready` (recoverable; names the prior step the member still needs), `not_in_stack` / `task_not_found` / `stack_not_found` / `no_repo_url` (NOT recoverable), and `merge_failed` (recoverable; the underlying git reason).",
        limitations:
          "Only merges members the deployer would merge on its own: status `in_review` with every review-stage validation `passed`. It does not rebase for you — a member that is still not a descendant of rollup HEAD returns `still_diverged` again (and files no duplicate blocker while rollup HEAD is unchanged). The task must belong to a stack.",
        when_to_use:
          "When a stack member's rollup merge is paused (`paused_reason.kind == \"rollup_diverged\"`) and you have rebased its branch onto the rollup. Also safe to call when unsure whether a member landed: `already_merged` answers without side effects."
      },
      %{
        name: "stack_start_planning",
        description:
          "Stack-level \"Start Planning\" lifecycle action. Behaviour depends on the stack's `auto_plan` flag (a top-level field settable via `stack_create` or `stack_update`):\n\n• `auto_plan: false` (default, MANUAL mode) — walks the in-stack DAG in wave order (topologically bucketed levels). Only the root wave (members with no in-stack deps) transitions `backlog → planning`; downstream waves stay at `backlog` and advance one wave at a time as each upstream member's plan lands `approved` (post-commit hook in `Tasks.approve_plan/3`).\n\n• `auto_plan: true` (AUTO mode) — every wave fans out to `planning` in a single concurrent pass. Wave discipline still emits one `:wave_dispatched` telemetry event per wave for observability, but no gating occurs.\n\nA sibling flag `auto_accept_plan` controls the plan-approval hop: when true, plans submitted by member planners auto-approve without human review (resolved via `Tasks.maybe_auto_approve/1` reading the parent stack). The two flags compose — auto-plan + auto-accept = fully-headless stack; auto-plan alone = concurrent dispatch but human-gated approvals; neither set = classic wave-gated manual mode.\n\nIdempotent: if ANY member is already past `backlog` (planning/in_progress/…), the tool returns a noop envelope (`noop: true, noop_reason: :already_in_flight`) without re-dispatching. Cyclic DAGs and cross-stack deps also short-circuit — the tool returns an error envelope and no member transitions. Does not write the stack-level status itself: an all-`planning` stack rolls up to `forming` per the ADR 0041 status mapping.",
        parameters: %{
          stack_id: %{
            type: "string",
            required: true,
            description: "The stack to start planning"
          }
        },
        returns:
          "The stack record (including `auto_plan` and `auto_accept_plan`) plus:\n• `planning` — the members moved from `backlog` to `planning`.\n• `unassigned` — the members this call transitioned NOWHERE because no agent-typed planning assignee resolves for them (nil per-phase planning entry, nil top-level assignee, and no stack-level planning default — or a human-typed assignee, which starts no router). They stay at `backlog` and are never listed under `planning`. ALWAYS present (`[]` when every considered member had a planner), so an absent key means an older server, not \"none unassigned\".\n• `mode` — `:manual` or `:auto`, derived from `stack.auto_plan`.\n• `waves_total` — total number of DAG waves (informational; drives progress UI).\n• `edges_authored` — number of dep-inference edges committed on this call (0 when a user override was already present).\n• `edges_skipped_reason` — when inference was skipped or terminally failed (`:user_override_present | :cycle | :parse_failed | :adapter_failed | :empty_response`). Omitted on the happy path.\n\nPer-member transition failures surface in a `cascade_errors` array. An empty stack — or one where a wave 0 dispatch found no `backlog` members — returns an empty `planning` list.\n\nIdempotency short-circuits return `%{stack_id, planning: [], errors: [], noop: true, noop_reason: :already_in_flight}` without the stack record shape. Cyclic DAGs return an error envelope with `cycle_path`; cross-stack deps return an error envelope with `from_task_id`/`to_task_id`.",
        limitations:
          "Wave gating is the default. Callers relying on the pre-Stack-v2 all-at-once cascade must set `auto_plan: true` on the stack. Members that fail the `planning` transition appear in `cascade_errors`; the stack-level status still recomputes from its members.",
        when_to_use:
          "When you want to drive a stack's members into the planning phase — either wave-gated (default) or all-at-once (auto_plan). The MCP mirror of the per-task \"Start Planning\" action, applied stack-wide."
      },
      %{
        name: "stack_assign_agents",
        description:
          "Assign agents at the stack level (ADR 0041). The stack-level assignment is the default that fans out to every member task that is NOT individually overridden. Pass `assignee_id` for the simple all-phases case, OR per-phase `planning`/`execution`/`review` ids for the advanced case. Percolation reuses the per-task phase-assignee pipeline so each member's derived top-level assignee_id is re-derived for its current phase. Members flagged with an individual override are skipped and never clobbered.",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to assign"},
          assignee_id: %{
            type: "string",
            required: false,
            description:
              "Simple mode: one agent id applied to all three phases (planning, execution, review). Pass an empty string to clear all phases. Ignored if any per-phase id is also given."
          },
          planning: %{
            type: "string",
            required: false,
            description: "Advanced mode: agent id for the planning phase (empty string clears it)"
          },
          execution: %{
            type: "string",
            required: false,
            description:
              "Advanced mode: agent id for the execution phase (empty string clears it)"
          },
          review: %{
            type: "string",
            required: false,
            description: "Advanced mode: agent id for the review phase (empty string clears it)"
          }
        },
        returns:
          "%{stack_id, phase_assignees: %{phase => %{assignee_id, assignee_type}}, percolated: [task_id], skipped: [%{task_id, reason: \"individual_override\"}]}. `percolated` are the members that received the stack default; `skipped` are members left untouched because they carry an individual assignee override.",
        limitations:
          "Provide either `assignee_id` (simple) or per-phase ids (advanced) — if any per-phase id is given, `assignee_id` is ignored. Members with `metadata.assignee_override == true` are never overwritten; clear the override first to make them inherit again. Partial per-phase updates are merged phase-by-phase onto the existing stack default.",
        when_to_use:
          "When you want to assign agents once at the stack level instead of drilling into each member task individually."
      }
    ]
  end

  # Task 01a066af stage 4 — the `meetings` bundle. `meeting_create` and
  # `meeting_say` were registered in `task_tools/0`, so `tag/2` stamped them
  # `"task"`, a bundle that is NOT in `AgentRuntime.default_allowed_bundles/0`.
  # A voice-capable runtime sitting on the defaults was therefore refused by
  # `ToolAuthorization.authorize/2` and could not speak at all. Both tool maps
  # moved here VERBATIM — their descriptions carry the `no_ack` contract
  # rewritten in stages 1 and 3 and must not be regenerated.
  #
  # Task 01a083c3 stage 1 moved `meeting_activity_push` here for the same
  # reason, and task 01a08875 stage 1 moved `intent_ack` — the last member of
  # the class. `intent_ack` shipped in `task_tools/0` (019f70b8 stage 3) on the
  # rationale that every dispatch-capable runtime already holds `task`. That
  # was FALSE WHEN WRITTEN, not a claim that went stale: `task` has never
  # appeared in `@default_allowed_bundles` on any commit. A runtime on the
  # defaults was therefore dispatched meeting intents it could not ack, and
  # because `ToolAuthorization.authorize/2` refuses ABOVE `execute/3` the
  # intent queue never heard about the refusal — the intent held the meeting's
  # SERIAL cursor for the whole `:awaiting_delivery` window (the ack timeout
  # doubled, because the shorter `:awaiting_ack` phase only arms on first
  # contact and a refusal is not contact) and then landed plain `:timed_out`,
  # indistinguishable from an offline runtime.
  #
  # `intent_ack`'s descriptor still says "same contract and the same validation
  # as `task_ack`", and that is still true after the move: the pairing is a
  # NAMING symmetry, not a capability one. The two serve different queues with
  # different lifetimes — `task_ack` writes `execution_leases`, `intent_ack`
  # writes meeting-lifetime ETS — so the descriptor moved VERBATIM and the
  # sibling stayed in `task`.
  defp meetings_tools do
    [
      %{
        name: "meeting_create",
        description:
          "Create a durable meeting in a project (ADR 0042). A meeting is a persistent record with its own backing chat space (the future intent panel) and a LiveKit room name — distinct from an ephemeral LiveKit call. Status starts at `scheduled`.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "The project to create the meeting in"
          },
          name: %{type: "string", required: true, description: "Human-readable meeting name"},
          slug: %{
            type: "string",
            required: false,
            description:
              "URL-friendly slug, unique per project. Auto-generated from the name (with a numeric suffix on collision) when omitted."
          },
          host_participant_id: %{
            type: "string",
            required: false,
            description:
              "chat_participants id of the meeting host/owner. When omitted, defaults to the calling agent — it is added to the meeting's backing chat space as the principal participant and set as host."
          },
          scheduled_start_at: %{
            type: "string",
            required: false,
            description:
              "Optional. The meeting's INTENDED start as an ISO8601 UTC timestamp (e.g. \"2026-08-01T15:00:00Z\") — distinct from `started_at`, which is stamped when the meeting actually begins. Omit both scheduled_* parameters for an ad-hoc meeting starting now."
          },
          scheduled_end_at: %{
            type: "string",
            required: false,
            description:
              "Optional. The meeting's INTENDED end as an ISO8601 UTC timestamp, strictly after scheduled_start_at. Required whenever scheduled_start_at is given — there is no default duration to synthesise one from, so pick an explicit end. Omit both scheduled_* parameters for an ad-hoc meeting starting now."
          }
        },
        returns:
          "The created meeting map: id, project_id, name, slug, status, chat_space_id, livekit_room_name, host_participant_id, started_at, ended_at, scheduled_start_at, scheduled_end_at. `livekit_room_name` is the LiveKit room a joiner is minted into — `space-<chat_space_id>`, the same `room_name` a meeting_join payload carries — not a meeting-keyed name. The two scheduled_* keys are always present, and are null for an ad-hoc meeting.",
        limitations:
          "Requires a valid project_id and name. If an explicit slug collides with an existing meeting in the project, a clean changeset error is returned (auto-generated slugs are de-duplicated instead). The intended-time pair is all-or-nothing: supply both scheduled_start_at and scheduled_end_at or neither, with the end strictly after the start; a malformed or half-supplied pair is refused rather than dropped, and creates no meeting.",
        when_to_use:
          "When you need to spin up a persistent meeting surface for a project — a kickoff, sync, design review, or retro."
      },
      %{
        name: "meeting_say",
        description:
          "Speak text aloud into a meeting you have been invited into, in your own configured voice. The text is sent to your voice worker, which synthesises and plays it into the LiveKit room, then reports back. On `spoken` the text is also posted into the meeting's chat space under your name so the transcript shows what you said. Returns `status`: `spoken` (the worker played it; `duration_s` is how long it took), `failed` (the worker could not play it; see `error`), or `no_ack` (nothing answered in time — your voice worker may not be connected, or may still be speaking; core cannot tell which). The wait is not a fixed 15 seconds: it scales with how long your text takes to say, so a long utterance is given time to finish playing before core gives up. `no_ack` describes what CORE KNOWS, not what the room heard. Your words may already have been spoken aloud. Nothing has been posted to chat YET, which is not the same as nothing ever being posted: a late `spoken` ack arriving within the say registry's 5-minute ttl still posts the text under your name, back-dated to when it was dispatched. So do not conclude from `no_ack` that your words were lost, and do not say them again out loud on that basis.",
        parameters: %{
          room_name: %{
            type: "string",
            required: true,
            description:
              "The `room_name` from your meeting_join payload (the LiveKit room name, e.g. `space-<uuid>`). NOT a meeting id."
          },
          text: %{
            type: "string",
            required: true,
            description: "What to say. At most 2000 characters; blank is refused."
          }
        },
        returns:
          "%{utterance_id, status: \"spoken\" | \"failed\" | \"no_ack\", duration_s, error, room_name}. `duration_s` is nil unless the worker reported it. `error` is the worker's own failure string on `failed`, and nil otherwise.",
        limitations:
          "You must be a current participant of the room — invited by a human from the meeting page and not yet dismissed. Being a member of the meeting's chat space is not enough. Text over 2000 characters is refused, not truncated. A reply budget applies: at most 6 says per minute per room (`reply_budget_exhausted`), and no say at all while the last 3 utterances in the room were agents — a human must speak before you may reply again (`agent_chain_too_deep`). `no_ack` is not a failure and not a success: the dispatch went out and nothing came back, and it still spends budget. Do not retry in a loop on `no_ack`; if it repeats, say so in chat instead.",
        when_to_use:
          "When you are in a meeting and want to say something specific out loud — an answer, a summary, a question — rather than waiting for the intent pipeline to prompt you."
      },
      %{
        name: "meeting_activity_push",
        description:
          "Declare what YOU are doing in a meeting right now, so the meeting's agent rail shows it instead of showing you idle. Only two states can be declared — `thinking` (you are working on something) and `composing` (you are drafting a reply you have not started sending) — because those are the only two the meeting cannot already observe for itself; it already sees when you are typing, when an intent is in flight for you, when one failed, and when a transcript segment reached you. The declaration EXPIRES on its own after a ttl the server sets (returned as `ttl_ms`), so call this again on roughly half that interval for as long as the state holds. There is nothing to call to clear it: stop pushing and it lapses. That is deliberate — it means a state you declared still lapses correctly if your runtime crashes, is killed, or loses its socket mid-turn.",
        parameters: %{
          meeting_id: %{
            type: "string",
            required: true,
            description:
              "The meeting to declare the state in. NOT a room name and not a chat space id."
          },
          state: %{
            type: "string",
            required: true,
            description:
              "Exactly `thinking` or `composing`. Any other value — including `idle`, `typing`, `computing`, `failed` or `heard` — is refused, not coerced."
          },
          reason: %{
            type: "string",
            required: false,
            description:
              "Optional short note shown beside the state, e.g. \"reading the last ten minutes of transcript\". Truncated past 200 characters; blank is treated as absent."
          }
        },
        returns:
          "%{meeting_id, agent_id, state, reason, pushed_at, ttl_ms, expires_at}. `pushed_at` and `expires_at` are ISO8601 UTC; `expires_at` is when the declaration lapses if you do not push again.",
        limitations:
          "You must be an active participant of the meeting's live room — seated by a human and not yet departed. Being in the meeting's chat space is not enough, and neither is having been in the room earlier. The state applies to YOU: there is no parameter for declaring another agent's state. It cannot overwrite what the meeting observed directly — a failed intent still reads as failed, and output you are actually emitting still reads as typing — but it does take precedence over a merely in-flight intent, and it holds off the 120-second stall cap for as long as you keep refreshing. It does not make you speak, does not post to chat, and is not persisted: it is in-memory per node and gone after a restart.",
        when_to_use:
          "When you are about to spend more than a few seconds on something in a meeting that the meeting has no other way to see — a long tool chain, a document read, drafting a summary — and the humans in the room would otherwise be watching you sit there looking idle or, past two minutes, looking failed."
      },
      %{
        name: "intent_ack",
        description:
          "Ack a meeting-intent dispatch: report that you spawned a subagent for the intent, and later report how it ended (task 019f70b8 stage 3). The meeting's intent queue is ack-gated and SERIAL — it holds at most one intent per meeting in flight, and the next queued intent does not go out until this one reaches a terminal status. `status: working` says \"I spawned the subagent\" and does NOT advance the queue; `completed`, `rejected` and `cancel_honored` do. Requires a subagent_id — spawn the subagent FIRST, then include its returned handle in the ack. Same contract and the same validation as `task_ack`.",
        parameters: %{
          intent_id: %{
            type: "string",
            required: true,
            description:
              "UUID of the intent from the `meeting_intent_dispatch` attention signal you received. This is the only handle the queue accepts — it resolves the owning meeting for you."
          },
          subagent_id: %{
            type: "string",
            required: true,
            description:
              "Opaque handle identifying the subagent working this intent — the runtime slug (e.g. `higgins.moon`) for openclaw agents, or the Task-tool `agentId` returned by the Agent spawn call for Claude Code (e.g. `afd767f1e0cc81633`). Must be non-empty and ≤128 bytes. Presence forces spawn-before-ack ordering: you cannot ack an intent you never spawned a subagent for. It is also what a later cancellation is addressed to, so it must identify the ACTUAL subagent."
          },
          status: %{
            type: "string",
            required: true,
            description:
              "One of `working` (subagent spawned, work underway — queue does NOT advance), `completed` (work finished — queue advances), `rejected` (this intent was not for you or is not actionable — queue advances and a `wrong_target` correction is recorded as tuning signal), `cancel_honored` (you received an `intent_cancelled` event and stopped the subagent — queue advances)."
          },
          note: %{
            type: "string",
            required: false,
            description:
              "Optional free-text context, most useful with `rejected` — it is carried into the correction record that tunes future classification."
          }
        },
        returns:
          "%{intent_id, meeting_id, status, subagent_id, acked_at}. `status` is the intent's NEW queue status, which is not the same word you sent: `working` → `acked`, `completed` and `rejected` → `completed`, `cancel_honored` → `cancelled` (or `cancelled_late` if the work had already completed).",
        limitations:
          "Invalid subagent_id returns `{:error, :invalid_subagent_id}` — one of `missing` (key absent or nil), `empty_or_whitespace`, or `oversized` (> 128 bytes) — and leaves the queue row COMPLETELY untouched: a schema-rejected ack is never a partial ack. Repeated rejected attempts are counted, and if the intent then times out it is reported as `no_ack_spawn_failed` (the runtime tried and could not spawn) rather than `timed_out` (nothing came back at all). Unknown `intent_id`, or one whose meeting has ended, returns `{:error, :not_found}` — the queue is meeting-lifetime and holds nothing after the meeting. Acking an intent that has not been dispatched, or one already terminal, returns `{:error, :invalid_ack_state}`. If no ack of any kind arrives within the meeting's ack window (default 90s) the intent is timed out and the queue moves on.",
        when_to_use:
          "IMMEDIATELY after spawning a subagent in response to a `meeting_intent_dispatch` attention signal — the meeting's whole queue is waiting behind this one intent. Then again when the work ends, or as soon as you decide the intent isn't yours (`rejected`) — an honest early `rejected` unblocks the meeting AND improves future targeting."
      }
    ]
  end

  # Task 01a05b32 stage 2 — ONE copy of the planner-authored `stages`
  # parameter description, shared verbatim by `plan_create` and
  # `plan_update`. plan_update takes the same shape and contract as
  # plan_create (same pre-persistence passes, same tree-building paths),
  # so the two tool registrations must not be able to drift apart.
  @plan_stages_param_description "Array of IMPLEMENTATION stage objects: {name, description, position, e2e_host?, validations: [{kind, evaluation_payload?}]}. Valid validation kinds for planner-authored stages: lint_pass, type_check, test_pass, manual_approval, e2e_behavior. Do NOT include a deploy stage — the system auto-injects one (with ci_passed / pr_merged / etc. validations) at deploying time from the project's resolved deploy strategy. The e2e_behavior kind requires an evaluation_payload map with keys setup/actions/expected (the planner authors an adversarial test plan the review agent will execute — include 2-5 e2e_behavior validations covering happy path, edges, and regression-prone scenarios; do NOT pre-write failure_feedback, the review agent observes failures at review time). e2e HOST RULE: when the plan carries any e2e_behavior validations, they are all lifted onto ONE host stage. By default the engine synthesizes a task-level review stage at the end. A stage whose name CONTAINS \"review\" or \"validation\" (case-insensitive, anywhere in the name — e.g. \"task_plan_review\") would silently be adopted as that host instead, so such a plan is REFUSED with a recoverable error: rename the stage, or set the optional per-stage boolean \"e2e_host\": true on the stage that should genuinely host them, which is honoured over any name match. Stage names beginning \"deploy:\" are exempt and never adopted. manual_approval RULE: a manual_approval validation means \"here is the UI, does it fit the brief\" — nothing else. It REQUIRES an evaluation_payload map carrying a non-blank \"ui_surface\" string naming the screen or component the human will look at (e.g. \"ui_surface\": \"the task detail page's stage timeline at 375px\"); a manual_approval without it is REFUSED with a recoverable error and nothing is persisted. Test summaries, caveats, and run reports do NOT belong in a review item — those are what lint_pass / test_pass / e2e_behavior are for. If the stage has no rendered surface to show, drop the gate rather than naming one: a manual_approval that shows a human anything but UI is a notification, not a gate."

  defp plan_tools do
    [
      %{
        name: "plan_create",
        description:
          "Create a new execution plan for a task with stages and validations, all in a single transaction. Plan IMPLEMENTATION and validation only — the system auto-injects the deploy stage (PR, CI, merge) when the task transitions to deploying status. Do NOT author a 'Deploy via PR merge' / 'Open PR' / 'Watch CI' / 'Merge' stage; that is the deployer's job.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to create a plan for"},
          stages: %{
            type: "array",
            required: true,
            description: @plan_stages_param_description
          }
        },
        returns: "The created plan with stages and validations preloaded",
        limitations:
          "Requires a valid task_id. Stages must have unique positions. Do not include a deploy stage; the system auto-injects one from the resolved deploy strategy.",
        when_to_use: "When you need to define a multi-stage execution plan for a task"
      },
      %{
        name: "plan_update",
        description:
          "Replace a DRAFT plan's entire stage/validation tree in place (plan_id and version " <>
            "stay stable — this is a correction, not a new plan row), then submit the corrected " <>
            "plan with plan_submit as usual. Stages run through the SAME pre-persistence passes " <>
            "as plan_create (e2e_behavior routing, manual_approval heuristic), so an updated " <>
            "draft cannot carry e2e cases plan_create would have lifted into the task-level " <>
            "review stage. pending_review / approved / completed plans are NOT updatable here.",
        parameters: %{
          plan_id: %{
            type: "string",
            required: true,
            description: "The draft plan ID to fix in place"
          },
          stages: %{
            type: "array",
            required: true,
            description: @plan_stages_param_description
          }
        },
        returns:
          "The updated plan with stages and validations preloaded (same shape plan_create returns)",
        limitations:
          "Only draft-status plans, and `stages` must be a non-empty array — a draft keeps at " <>
            "least one stage. The plan's existing stages and validations are deleted and " <>
            "recreated; the plan row (id + version) is reused.",
        when_to_use:
          "When a plan you created is still draft and wrong (stage descriptions, positions, validations) — fix it without a human round-trip"
      },
      %{
        name: "plan_get",
        description:
          "Get a task's plan with its full stage/validation tree. Defaults to the CURRENT plan " <>
            "(latest approved or completed), exactly as it always has. Pass `status` to read a " <>
            "plan the default resolution hides: the `rejected` plan whose `rejection_reason` and " <>
            "`architecture_verdict` explain why it was turned down, or the `draft` / " <>
            "`pending_review` plan that is blocking a fresh `plan_create`.",
        parameters: %{
          task_id: %{
            type: "string",
            required: true,
            aliases: ["id"],
            description: "The task ID"
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Which plan to resolve. Omit (or \"approved\") for today's behaviour: the highest-version " <>
                "approved-or-completed plan. \"latest\" (alias \"any\") returns the highest-version plan " <>
                "whatever its status. An explicit draft|pending_review|approved|rejected|completed " <>
                "returns the highest-version plan with THAT status. Any other value is refused — it is " <>
                "never silently narrowed back to approved, because a silently-ignored filter would read " <>
                "as \"no such plan exists\"."
          }
        },
        returns:
          "Plan object with stages and validations preloaded, plus `status`, `version`, " <>
            "`rejection_reason`, `architecture_verdict`, and `is_current`. `is_current` is false " <>
            "whenever the returned plan is neither approved nor completed — a rejected or " <>
            "pending_review plan is NOT the plan the task is executing, and must not be read as one.",
        limitations:
          "Returns error if no plan matching the requested status exists for the task. With no " <>
            "`status` that error is the historical \"No approved plan for task\", unchanged.",
        when_to_use:
          "When you need the current execution plan for a task — or, with `status`, the rejected plan's reason or the unapproved plan blocking plan_create."
      },
      %{
        name: "plan_submit",
        description: "Submit a draft plan for review (draft → pending_review).",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID to submit"}
        },
        returns: "The updated plan object",
        limitations: "Plan must be in draft status",
        when_to_use: "When a plan is ready to be reviewed and approved"
      },
      %{
        name: "plan_approve",
        description:
          "Approve a plan that is in pending_review status. Transitions the plan to approved and auto-advances the task to in_progress if it was in planning/ready/backlog.",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID to approve"},
          approved_by: %{
            type: "string",
            required: false,
            description: "Who is approving (agent slug or user ID). Defaults to system."
          }
        },
        returns: "The approved plan object",
        limitations:
          "Plan must be in pending_review status, and the architecture gate must not be open — an agent cannot approve past an architect who is still reviewing (ADR-0046).",
        when_to_use:
          "After plan_submit, when you want to approve a plan and kick off task execution without waiting for human review"
      },
      %{
        name: "plan_reject",
        description:
          "Discard a DRAFT plan so a fresh plan_create can run on the same task immediately " <>
            "(draft → rejected, no human round-trip). This is the planner's self-service exit " <>
            "from the plan_create draft-lock: pass a non-blank rejection_reason saying why the " <>
            "draft died — it is persisted on the plan row and surfaces to future planners. " <>
            "pending_review / approved / completed plans are NOT rejectable here.",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID to discard"},
          rejection_reason: %{
            type: "string",
            required: true,
            description:
              "Non-blank reason the draft is being discarded (persisted on the plan row)"
          },
          rejected_by: %{
            type: "string",
            required: false,
            description: "Who is rejecting (agent slug or user ID). Defaults to system."
          }
        },
        returns:
          "The rejected plan object (status \"rejected\", rejection_reason persisted). The task's status is untouched.",
        limitations:
          "Only draft-status plans. A pending_review plan must wait for the human reviewer; " <>
            "approved / completed plans are immutable to this tool.",
        when_to_use:
          "When your own draft plan is wrong or obsolete and you want to replace it with a fresh plan_create on the same task"
      },
      %{
        name: "plan_architecture_verdict",
        description:
          "Return the architect's verdict on a plan whose architecture gate is open (ADR-0046). " <>
            "The plan is HELD at pending_review until this call lands or the gate deadline expires. " <>
            "Reject ONLY for one of the four closed constraint values — module_boundary, data_model, " <>
            "cross_context_coupling, duplicated_logic. There is no representable value for a taste, " <>
            "naming or style objection: say it in `summary` and pass.",
        parameters: %{
          plan_id: %{
            type: "string",
            required: true,
            description: "The plan under verdict. Printed as `plan_id:` in the review prompt."
          },
          verdict: %{
            type: "string",
            required: true,
            description: "\"pass\" or \"reject\". There is no third value."
          },
          summary: %{
            type: "string",
            required: true,
            description:
              "Non-empty. One paragraph: what you checked and what you found, including anything worth reporting that is NOT grounds for a reject."
          },
          findings: %{
            type: "array",
            required: false,
            description:
              "Required and non-empty when verdict is \"reject\"; omit on a pass. One object per objection: {stage_id, constraint, detail}. `stage_id` is OPTIONAL: supply a stage of THIS plan to object to that stage, or omit it (or send null) when the objection is about the plan AS A WHOLE — a decomposition that is wrong even though each stage is individually sound, or a sequencing defect with no single stage at fault. A plan-level finding reaches the planner labelled `(plan-wide)`. A `stage_id` that is present but is not a stage of this plan is refused as `foreign_stage_id`. `constraint` must be one of #{Enum.join(Plan.architecture_constraints(), " | ")}. `detail` must say WHAT TO CHANGE, not what is wrong — a detail the planner cannot act on produces a differently-worded plan, not a better one."
          }
        },
        returns:
          "%{plan_id, task_id, verdict, state, resolved_at, findings_count} — `state` is the persisted architecture_verdict[\"state\"] (\"passed\" or \"rejected\").",
        # ADR-0046 member 5 stage 4. This prose is TESTED, not asserted by
        # hand: `plan_architecture_verdict_tool_test.exs` drives every
        # refusal below and asserts the observed `code` set is exactly the
        # set named here. The 2026-07-26 e2e journal records `intent_ack` /
        # `task_ack` shipping `limitations` describing an error taxonomy the
        # code never emits, with no test guarding it — remote runtimes branch
        # on these strings.
        limitations:
          "Refusals carry a `code`: `plan_not_found` (unknown plan_id), " <>
            "`invalid_verdict` (verdict is not \"pass\"/\"reject\"), " <>
            "`missing_summary` (summary absent or blank), " <>
            "`missing_findings` (verdict \"reject\" with no findings), " <>
            "`malformed_finding` (a finding is not an object, or its `detail` is blank), " <>
            "`invalid_constraint` (a finding's `constraint` is outside the four allowed values — " <>
            "this is where a style objection is refused), " <>
            "`foreign_stage_id` (a finding's `stage_id` is present but is not a stage of this plan — " <>
            "note an ABSENT or null `stage_id` is not an error, it is a plan-level finding), " <>
            "`gate_not_open` (the gate never opened for this plan version), " <>
            "`gate_already_resolved` (somebody — an earlier call, the deadline, or a human " <>
            "override — already closed it; a duplicate call lands here and changes nothing), " <>
            "`verdict_rejected` (the write itself failed validation). " <>
            "A runtime WITHOUT the `plan` capability bundle simply never resolves the gate: the " <>
            "deadline expires, the verdict records as `expired`, and the plan proceeds unreviewed. " <>
            "That degradation is deliberate (ADR-0046 decision 7 — silence falls open) and is why " <>
            "an architect on a runtime that cannot reach this tool is a missing review, not a stuck task.",
        when_to_use:
          "As the architect, exactly once per plan review, when the architecture gate is holding a plan you have finished reading. This is the only way to release the gate from an agent."
      },
      %{
        name: "stage_architecture_audit",
        description:
          "Land the architect's post-executor drift audit on one stage (task 019fa61c). " <>
            "`architecture.audit_diff` fires when a stage transitions to `passed` and the " <>
            "server records that the fire went out; THIS is the only way to say what came " <>
            "back. The call posts your note to the task's execution space AND records the " <>
            "audit against the stage in one step — a note posted any other way leaves no " <>
            "record that the audit happened. There is deliberately NO pass/reject axis: " <>
            "the stage is already `passed` before you are asked, so an audit is additive " <>
            "commentary and never a gate.",
        parameters: %{
          stage_id: %{
            type: "string",
            required: true,
            description:
              "The stage you audited. Printed as `stage_id:` in the drift-audit prompt."
          },
          summary: %{
            type: "string",
            required: true,
            description:
              "Non-empty. One paragraph: what you checked and what you found — INCLUDING a clean result. \"No drift, no new deps, no memory-pattern reintroduction\" is a valid and useful summary; an empty one is indistinguishable from an architect that never read the stage."
          },
          findings: %{
            type: "array",
            required: false,
            description:
              "Optional. Omit entirely on a clean stage. One object per concern: {constraint, detail}. `constraint` must be one of #{Enum.join(Plan.architecture_constraints(), " | ")}. `detail` must say WHAT TO CHANGE, not what is wrong — a detail nobody can act on produces a differently-worded stage, not a better one. There is no `constraint` value for a taste, naming or style objection: put it in `summary`."
          }
        },
        returns:
          "%{stage_id, task_id, state, source, resolved_at, summary, findings_count, noted_after_deadline} — " <>
            "`state` is the persisted architecture_audit[\"state\"] (\"noted\"), and " <>
            "`noted_after_deadline` is true when the audit deadline had already elapsed.",
        # The prose below is TESTED, not asserted by hand:
        # `stage_architecture_audit_tool_test.exs` drives every refusal and
        # asserts the observed `code` set equals the set named here. The
        # 2026-07-26 e2e journal records `intent_ack` / `task_ack` shipping
        # `limitations` describing an error taxonomy the code never emits,
        # with no test guarding it — remote runtimes branch on these strings.
        limitations:
          "Refusals carry a `code`: `stage_not_found` (unknown stage_id), " <>
            "`missing_summary` (summary absent or blank), " <>
            "`malformed_finding` (a finding is not an object, or its `detail` is blank), " <>
            "`invalid_constraint` (a finding's `constraint` is outside the four allowed " <>
            "values — this is where a style objection is refused), " <>
            "`audit_not_open` (no audit fire was ever recorded for this stage — nothing " <>
            "is waiting on you), " <>
            "`audit_already_recorded` (somebody answered first; a duplicate call lands " <>
            "here and changes nothing — neither the row nor the execution space), " <>
            "`note_rejected` (the note failed validation, or the annotation could not be " <>
            "posted — the task has no execution space — in which case NOTHING was " <>
            "written; the row and the note land together or not at all). " <>
            "A note arriving AFTER the audit deadline is ACCEPTED, not refused, and " <>
            "records `noted_after_deadline: true`: an architect who engaged late still " <>
            "engaged, and the elapsed deadline is kept in the row rather than erased. " <>
            "A runtime WITHOUT the `plan` capability bundle simply never lands an audit: " <>
            "the deadline elapses, the row projects as expired, and nothing is blocked — " <>
            "that degradation is deliberate, because this surface is additive.",
        when_to_use:
          "As the architect, exactly once per stage, when you have finished auditing a stage the drift-audit prompt handed you. This is the only way to land an audit from an agent."
      },
      %{
        name: "stage_start",
        description: "Start a pending stage (pending → running).",
        parameters: %{
          stage_id: %{type: "string", required: true, description: "The stage ID to start"}
        },
        returns: "The updated stage object",
        limitations: "Stage must be in pending status",
        when_to_use: "When you are ready to begin executing a stage"
      },
      %{
        name: "stage_list",
        description:
          "List all stages for a plan, ordered by position, with validations preloaded. " <>
            "Name the plan EITHER directly with `plan_id` OR indirectly with `task_id`, which " <>
            "resolves to that task's CURRENT plan — the highest-version plan whose status is " <>
            "approved or completed. Resolution rule, in full: pass only `plan_id` and it is " <>
            "used as-is; pass only `task_id` and the current plan answers; pass BOTH and they " <>
            "must agree — `plan_id` must name a plan belonging to that task, and then `plan_id` " <>
            "is what answers, because it is the more specific of the two and can name a plan " <>
            "`task_id` would never resolve to. Neither argument is defaulted and no argument is " <>
            "silently preferred over the other; every combination outside that rule is refused " <>
            "with a code (see limitations) rather than answered. `task_id` never falls back to a " <>
            "draft or pending_review plan: if a task's newest plan is awaiting approval, the " <>
            "approved plan below it answers, and if there is no approved plan at all the call " <>
            "is refused instead of returning an empty array that reads as \"this task has no " <>
            "stages\". Every returned row carries `plan_id`, so a caller who passed only " <>
            "`task_id` can always see which plan answered.",
        parameters: %{
          plan_id: %{
            type: "string",
            required: false,
            description:
              "The plan ID. Optional only in the sense that `task_id` can stand in for it — one of the two is always required."
          },
          task_id: %{
            type: "string",
            required: false,
            description:
              "A task ID, resolved to that task's current (approved or completed, highest version) plan. Optional only in the sense that `plan_id` can stand in for it — one of the two is always required."
          },
          limit: %{
            type: "integer",
            required: false,
            description:
              "Maximum stages to return. Defaults to #{ResultBound.default_limit()}, capped at #{ResultBound.max_limit()}."
          },
          offset: %{
            type: "integer",
            required: false,
            description: "How many stages to skip before the page. Defaults to 0."
          },
          detail: %{
            type: "string",
            required: false,
            description:
              "\"summary\" (default) truncates each stage `description` to #{ResultBound.snippet_chars()} characters and replaces each validation's `evidence` and `evaluation_payload` with an empty map plus `_omitted`/`_length` markers; \"full\" returns everything whole."
          }
        },
        returns:
          "Array of stage objects with validations, each carrying its `plan_id`. " <>
            "In the default summary detail, stage `description` is a preview (with `description_truncated` / `description_length`) " <>
            "and each validation's `evidence` and `evaluation_payload` are EMPTY MAPS carrying `evidence_omitted` / `evidence_length` " <>
            "(and the same pair for `evaluation_payload`). They are emptied rather than partially serialized on purpose: a half map " <>
            "would let a caller read a confidently wrong value out of a key that survived the cut. Pass `detail: \"full\"` to read them.",
        # This prose is TESTED, not asserted by hand: `tool_surface_test.exs`
        # drives every refusal below through `ToolArguments.dispatch/3` and
        # asserts the observed `code` set is exactly the set named here, via
        # `stage_list_error_codes/0`. Same convention as
        # `task_design_decline` — a documented taxonomy remote runtimes branch
        # on is worse than none when it drifts from the code.
        limitations:
          "Exactly one of `plan_id` or `task_id` is required; supplying both is allowed only " <>
            "when they agree. Refusals carry a `code`: `missing_plan_reference` (neither " <>
            "argument supplied, or both blank), `plan_task_mismatch` (both supplied, but " <>
            "`plan_id` does not name a plan belonging to `task_id` — including when it names no " <>
            "plan at all), `no_current_plan` (`task_id` supplied but the task has no approved or " <>
            "completed plan; the suggestion names the latest plan's id, version and status when " <>
            "one exists). All three are recoverable. An unknown `plan_id` supplied ALONE is not " <>
            "a refusal — it returns an empty array, unchanged from before `task_id` existed.",
        when_to_use:
          "When you need to see all stages and their validation status. Reach for `task_id` when a task is what you have in hand — it saves a plan_get, and it refuses rather than misleading you when the task's newest plan is still in review."
      },
      %{
        name: "validation_evaluate",
        description:
          "Record a validation result (passed/failed). Auto-advances the stage if all validations are resolved.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The validation ID to evaluate"
          },
          status: %{
            type: "string",
            required: true,
            description: "Result: \"passed\" or \"failed\""
          },
          evidence: %{
            type: "object",
            required: false,
            description: "Optional evidence map (e.g. CI output, test results)"
          },
          evaluated_by: %{
            type: "string",
            required: false,
            description: "Who evaluated this (user ID or \"system\")"
          }
        },
        returns: "The updated validation object",
        limitations: "Status must be \"passed\" or \"failed\"",
        when_to_use: "When a validation check has completed and you need to record the result"
      },
      %{
        name: "validation_pass",
        description:
          "Convenience alias for marking a validation as passed. Mirrors validation_evaluate with status=passed.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The validation ID to mark passed"
          },
          evidence: %{
            type: "object",
            required: false,
            description: "Optional evidence payload"
          },
          evaluated_by: %{
            type: "string",
            required: false,
            description: "Who evaluated this (user ID or \"system\")"
          }
        },
        returns: "The updated validation object",
        limitations: "Equivalent to validation_evaluate with status=passed",
        when_to_use:
          "When prompt contracts refer to validation_pass and you need to mark a validation successful"
      },
      %{
        name: "stage_complete",
        description:
          "Attempt to advance a running stage once its validations are satisfied. Useful for stages with no validations or for prompt contracts that refer to stage_complete.",
        parameters: %{
          stage_id: %{
            type: "string",
            required: true,
            aliases: ["id"],
            description: "The running stage ID"
          }
        },
        returns: "Structured result describing the completed stage and updated plan state",
        limitations: "Fails if the stage is not running or still has pending/failed validations.",
        when_to_use: "When you have completed a running stage and need the plan engine to advance"
      },
      %{
        name: "report_blocker",
        description:
          "Report a blocker for the current task stage. Records a structured execution.blocked " <>
            "event so the router can stop treating silence as liveness. A blocker is EXPENSIVE: " <>
            "it is filed only after three distinct attempts to get past the problem, a read of " <>
            "org memory for prior art, and a named smallest action that would unblock you plus " <>
            "who performs it. All of those are required params and the call is refused (nothing " <>
            "recorded) when any is missing or short. `category` is one of `infra` (moon, " <>
            "containers, deps, ssh, CI runners), `product` (the feature cannot be built as " <>
            "specified) or `decision` (a person must choose between named options). Infra " <>
            "blockers are the infra agent's job: `category: \"infra\"` with `needs_human: true` " <>
            "is refused; post the exact error to @[Dalton] in the execution space instead and " <>
            "keep working on what does not depend on it.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"},
          stage_id: %{type: "string", required: true, description: "The current stage ID"},
          description: %{
            type: "string",
            required: true,
            description: "What is blocked and why"
          },
          needs_human: %{
            type: "boolean",
            required: false,
            description:
              "Whether the blocker requires human intervention. Refused together with category infra."
          },
          attempts: %{
            type: "array",
            items: %{type: "string"},
            required: true,
            description:
              "At least three DISTINCT things you already tried, one per string, each with its outcome " <>
                "(e.g. \"re-ran with --trace: same failure\"). Blank or duplicate entries do not count."
          },
          memory_ref: %{
            type: "string",
            required: true,
            description:
              "Path of the org-memory page or journal you read looking for prior art (memory_search / memory_view), e.g. `org/page/identity.md`."
          },
          unblock_action: %{
            type: "string",
            required: true,
            description:
              "The smallest single action that would unblock you AND who performs it, e.g. \"Rowan picks option A or B\"."
          },
          category: %{
            type: "string",
            required: true,
            enum: ["infra", "product", "decision"],
            description: "One of infra | product | decision (see the tool description)."
          }
        },
        returns: "Structured blocker acknowledgement with event ID and escalation hint",
        limitations:
          "Requires task_id and stage_id from the current execution context. Refused (nothing " <>
            "recorded, error lists every missing or short field) when attempts has fewer than three " <>
            "distinct non-blank entries, memory_ref or unblock_action is blank, or category is not " <>
            "infra | product | decision. Refused when category is infra and needs_human is true.",
        when_to_use:
          "When you cannot proceed after three distinct attempts and an org-memory read, and you " <>
            "can name the smallest unblock action and who performs it. Not for infra problems: " <>
            "those go to @[Dalton] in the execution space while you continue."
      },
      %{
        name: "validation_list",
        description:
          "List all validations for a stage. A gate that reads `pending` may still have been " <>
            "judged before: when a manual_approval gate is reopened for another attempt, the " <>
            "ruling it clears is archived on the same row under `evidence[\"prior_rulings\"]` " <>
            "(oldest first, each entry carrying the earlier status, evidence and evaluator), so " <>
            "read that list for the feedback a human left on a previous attempt.",
        parameters: %{
          stage_id: %{type: "string", required: true, description: "The stage ID"}
        },
        returns: "Array of validation objects",
        limitations: "None",
        when_to_use: "When you need to see the validation status for a specific stage"
      },
      %{
        name: "prompt_template_list",
        description:
          "List all prompt templates (dispatch and heartbeat prompts used by the orchestrator).",
        parameters: %{},
        returns: "Array of prompt template objects with slug, name, description, variables",
        limitations: "None",
        when_to_use:
          "When you need to see or audit the current dispatch/heartbeat prompt templates"
      },
      %{
        name: "prompt_template_update",
        description:
          "Update the content of a prompt template by slug. " <>
            "Use {{variable_name}} placeholders for dynamic values. " <>
            "Sets updated_by to \"agent\".",
        parameters: %{
          slug: %{
            type: "string",
            required: true,
            description:
              "Template slug (e.g. dispatch.planning, dispatch.in_progress, dispatch.in_review, dispatch.fallback, heartbeat)"
          },
          content: %{
            type: "string",
            required: true,
            description:
              "New template content with {{variable_name}} placeholders for interpolation"
          }
        },
        returns: "The updated prompt template object",
        limitations: "Template must exist. Use prompt_template_list to see available slugs.",
        when_to_use: "When you need to improve or customize a dispatch or heartbeat prompt"
      }
    ]
  end

  # ── Execute ──────────────────────────────────────────────────────────────

  # Execute a tool call. NOT the entry point — call
  # `Platform.Federation.ToolArguments.dispatch/3` instead.
  #
  # `@doc false` is deliberate and load-bearing. As of task 019fa609 stage 4
  # the handlers below no longer check that their declared-required arguments
  # were supplied: `ToolArguments.validate/2` owns that, one mechanism instead
  # of twenty-seven hand-written variants that disagreed on wording, on `code`
  # and on `recoverable`. A caller reaching `execute/3` directly therefore
  # bypasses the gate, and several handlers will raise on a `nil` argument
  # rather than refuse it (`space_list_agents` on `space_id`, `intent_ack` on
  # `intent_id`). Both federation transports —
  # `PlatformWeb.MCPController` and `PlatformWeb.RuntimeChannel` — already go
  # through `dispatch/3`; there is no other live caller, and a new one should
  # not become the first.
  #
  # What `execute/3` still owns is everything the gate deliberately does not:
  # conditional requirements (`skill.get`'s "exactly one of slug or id", and
  # `stage_list`'s "exactly one of plan_id or task_id"),
  # value checks (`validation_evaluate`'s status set, `alarm_silence`'s range
  # and reason length), type coercion (`require_string/3`, `require_integer/3`)
  # and present-but-unusable refusals (`task_design_decline`'s <8-character
  # reason). See the `ToolArguments` moduledoc for the presence-only scope.
  #
  # context must include :space_id and :agent_participant_id.
  # Returns {:ok, result} | {:error, %{error: string, recoverable: boolean, suggestion: string}}
  @doc false

  # ── Messaging tools ──────────────────────────────────────────────────────

  def execute("send_media", args, context) do
    space_id = Map.get(args, "space_id")
    content = Map.get(args, "content", "")

    participant_id =
      Map.get(context, :agent_participant_id) ||
        get_agent_participant_id_for_space(space_id, context)

    case normalize_send_media_attachments(args) do
      {:ok, attachment_specs} ->
        with {:ok, attachment_attrs} <- persist_send_media_attachments(attachment_specs),
             {:ok, message, attachments} <-
               Chat.post_message_with_attachments(
                 %{
                   space_id: space_id,
                   participant_id: participant_id,
                   content_type: "text",
                   content: content
                 },
                 attachment_attrs
               ) do
          {:ok,
           %{
             message_id: message.id,
             space_id: space_id,
             attachment_count: length(attachments)
           }}
        else
          {:error, reason} ->
            {:error,
             %{
               error: "Failed to send media: #{inspect(reason)}",
               recoverable: true,
               suggestion:
                 "Check that the files exist and the agent is a participant in the space"
             }}
        end

      {:error, message} ->
        {:error,
         %{
           error: message,
           recoverable: true,
           suggestion:
             "Pass file_paths as a non-empty array, or file_path for a single attachment"
         }}
    end
  end

  def execute("react", args, context) do
    react_after_validation(
      Map.get(args, "space_id"),
      Map.get(args, "message_id"),
      Map.get(args, "emoji"),
      context
    )
  end

  # ── Review tools ────────────────────────────────────────────────────────

  def execute("review_request_create", args, context) do
    validation_id = Map.get(args, "validation_id")
    items = Map.get(args, "items", [])

    with validation when not is_nil(validation) <- get_by_uuid(Validation, validation_id),
         stage when not is_nil(stage) <- Repo.get(Stage, validation.stage_id),
         plan when not is_nil(plan) <- Repo.get(Plan, stage.plan_id) do
      # Find or create the execution space for the task
      execution_space_id =
        case Platform.Orchestration.ExecutionSpace.find_or_create(plan.task_id) do
          {:ok, space} -> space.id
          _ -> nil
        end

      attrs = %{
        validation_id: validation_id,
        task_id: plan.task_id,
        execution_space_id: execution_space_id,
        submitted_by: Map.get(context, :agent_id) || "agent",
        items: items
      }

      case Platform.Tasks.ReviewRequests.create_review_request(attrs) do
        {:ok, request} ->
          {:ok, serialize_review_request(request)}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to create review request: #{inspect_errors_safe(reason)}",
             recoverable: true,
             suggestion: "Check that items have valid labels and validation_id is correct"
           }}
      end
    else
      nil ->
        {:error,
         %{
           error: "Validation, stage, or plan not found for validation_id: #{validation_id}",
           recoverable: false,
           suggestion:
             "Verify the validation_id belongs to an existing manual_approval validation"
         }}
    end
  end

  # Read-back tools for review verdicts. Authorization runs BEFORE any
  # serialization: a review item can carry a human's private assessment, so a
  # denied caller must never see a label, a feedback string, or content.
  def execute("review_request_get", args, context) do
    with {:ok, request_id} <- require_string(args, "review_request_id", "review_request_get"),
         {:ok, request} <- fetch_review_request_for_read(request_id),
         :ok <- authorize_review_access(context, request.task_id) do
      {:ok, serialize_review_request(request)}
    end
  end

  def execute("review_item_list", args, context) do
    with {:ok, task_id} <- require_string(args, "task_id", "review_item_list"),
         :ok <- authorize_review_access(context, task_id) do
      items = Platform.Tasks.ReviewRequests.list_items_for_task(task_id)
      {limit, offset} = ResultBound.page(args)
      page = items |> Enum.drop(offset) |> Enum.take(limit)

      # Task 01a049de. `count` KEEPS meaning "how many items exist on this
      # task" — it is the field the precedence rule in this tool's description
      # is read against, and quietly redefining it as "how many I returned"
      # would corrupt every caller that already branches on it. The new keys
      # are additive: `returned_count`, `offset`, and `next_offset` (nil when
      # this is the last page).
      {:ok,
       %{
         task_id: task_id,
         count: length(items),
         returned_count: length(page),
         offset: offset,
         next_offset: if(offset + length(page) < length(items), do: offset + length(page)),
         items: Enum.map(page, &serialize_review_item_row(&1, full_detail?(args)))
       }}
    end
  end

  def execute("design_critique_request", args, context) do
    request = %{
      canvas_id: Map.get(args, "canvas_id"),
      note: Map.get(args, "note"),
      task_id: Map.get(args, "task_id"),
      review_request_id: Map.get(args, "review_request_id"),
      space_id: Map.get(context, :space_id),
      requested_by: Map.get(context, :agent_id)
    }

    case Platform.Design.Critique.request(request) do
      {:ok, verdict} ->
        {:ok,
         %{
           issues: Map.get(verdict, :issues, []),
           raw: Map.get(verdict, :raw),
           unparseable?: Map.get(verdict, :unparseable?, false),
           review_item_id: Map.get(verdict, :review_item_id)
         }}

      {:error, reason} ->
        {:error, design_critique_error(reason)}
    end
  end

  # ── Space tools ─────────────────────────────────────────────────────────

  def execute("space_create", args, context) do
    with {:ok, name} <- require_string(args, "name", "space_create"),
         {:ok, slug} <- space_create_slug(args, name),
         {:ok, org_id} <- space_create_org(args, context) do
      attrs =
        %{
          name: name,
          slug: slug,
          kind: "channel",
          org_id: org_id,
          description: Map.get(args, "description")
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case Chat.create_channel(attrs) do
        {:ok, space} ->
          # Every agent goes in through `add_agent_participant/3`, which resolves
          # `display_name` from the `agents` row. That is the entire reason this
          # tool exists rather than agents hand-rolling create_channel over RPC:
          # a channel-creation path that can write a NULL name reintroduces the
          # silent mention-drop it was built to prevent.
          #
          # The CALLER is added deliberately. `Chat.create_space/1` auto-joins
          # the Historian and nobody else, so an agent creating a channel over
          # RPC ends up outside it — and since there is no self-join tool, its
          # only way back in is being @-mentioned by a human. Creating a room you
          # cannot enter is never what the caller meant.
          caller_id = Map.get(context, :agent_id)

          requested =
            case Map.get(args, "agent_ids") do
              ids when is_list(ids) -> Enum.filter(ids, &(is_binary(&1) and &1 != ""))
              _ -> []
            end

          {added, skipped} =
            ([caller_id] ++ requested)
            |> Enum.filter(&(is_binary(&1) and &1 != ""))
            |> Enum.uniq()
            |> Enum.reduce({[], []}, fn agent_id, {ok, bad} ->
              case Chat.add_agent_participant(space.id, agent_id, attention_mode: "mention") do
                {:ok, participant} ->
                  {ok ++
                     [
                       %{
                         participant_id: participant.id,
                         agent_id: participant.participant_id,
                         display_name: participant.display_name
                       }
                     ], bad}

                {:error, reason} ->
                  {ok, bad ++ [%{agent_id: agent_id, reason: inspect(reason)}]}
              end
            end)

          {:ok,
           %{
             id: space.id,
             name: space.name,
             slug: space.slug,
             org_id: space.org_id,
             description: space.description,
             kind: space.kind,
             participants: added,
             skipped: skipped
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error,
           %{
             error: "space_create: #{inspect_errors(changeset)}",
             recoverable: true,
             suggestion:
               "A slug collision is the usual cause — pick a different `slug`, or call `space_list` to find the existing channel."
           }}

        {:error, reason} ->
          {:error,
           %{
             error: "space_create failed: #{inspect(reason)}",
             recoverable: true,
             suggestion:
               "Retry; if the org is archived or suspended, channel creation is blocked."
           }}
      end
    end
  end

  def execute("space_list", args, context) do
    agent_id = Map.get(context, :agent_id)
    kind = Map.get(args, "kind")

    spaces = Chat.list_spaces_for_agent(agent_id, kind: kind)

    {:ok,
     Enum.map(spaces, fn s ->
       %{id: s.id, name: s.name, kind: s.kind, description: s.description}
     end)}
  end

  def execute("space_list_agents", args, _context) do
    space_id = Map.get(args, "space_id")
    participants = Chat.list_participants(space_id, participant_type: "agent")
    agent_ids = Enum.map(participants, & &1.participant_id) |> Enum.uniq()

    agents_by_id =
      if agent_ids == [] do
        %{}
      else
        Repo.all(from(a in Agent, where: a.id in ^agent_ids))
        |> Map.new(&{&1.id, &1})
      end

    rows =
      Enum.flat_map(participants, fn p ->
        case Map.get(agents_by_id, p.participant_id) do
          nil ->
            []

          %Agent{} = agent ->
            [
              %{
                agent_id: agent.id,
                slug: agent.slug,
                name: agent.name,
                display_name: p.display_name || agent.name,
                participant_id: p.id,
                joined_at: p.joined_at
              }
            ]
        end
      end)

    {:ok, rows}
  end

  def execute("space_leave", args, context) do
    space_id = Map.get(args, "space_id")
    calling_agent_id = Map.get(context, :agent_id)
    target_agent_id = Map.get(args, "agent_id") || calling_agent_id

    cond do
      not is_binary(target_agent_id) or target_agent_id == "" ->
        {:error,
         %{
           error: "Caller identity unresolved and no agent_id supplied",
           recoverable: false,
           suggestion:
             "This tool needs either a context-bound calling agent or an explicit agent_id parameter"
         }}

      true ->
        case find_active_agent_participant(space_id, target_agent_id) do
          nil ->
            {:error,
             %{
               error:
                 "Agent #{target_agent_id} is not an active participant in space #{space_id}",
               recoverable: false,
               suggestion:
                 "Verify the space_id and agent_id. The agent may already have left, or was never added. Non-agent (human) participants cannot be removed via this tool."
             }}

          %Participant{} = participant ->
            case Chat.remove_participant(participant) do
              {:ok, removed} ->
                ActiveAgentStore.clear_if_match(space_id, removed.id)

                {:ok,
                 %{
                   space_id: space_id,
                   agent_id: target_agent_id,
                   participant_id: removed.id,
                   removed: true,
                   removed_at: DateTime.utc_now(),
                   self_removed: target_agent_id == calling_agent_id
                 }}

              {:error, reason} ->
                {:error,
                 %{
                   error: "Failed to remove participant: #{inspect(reason)}",
                   recoverable: true,
                   suggestion: "Retry; if this persists the participant record may be corrupt"
                 }}
            end
        end
    end
  end

  # ── Canvas tools (ADR 0036) ─────────────────────────────────────────────

  def execute("canvas.create", args, context),
    do: Platform.Chat.Canvas.ToolHandlers.create(args, context)

  def execute("canvas.patch", args, context),
    do: Platform.Chat.Canvas.ToolHandlers.patch(args, context)

  def execute("canvas.describe", args, context),
    do: Platform.Chat.Canvas.ToolHandlers.describe(args, context)

  def execute("canvas.list_kinds", args, context),
    do: Platform.Chat.Canvas.ToolHandlers.list_kinds(args, context)

  def execute("canvas.template", args, context),
    do: Platform.Chat.Canvas.ToolHandlers.template(args, context)

  def execute("canvas.versions", args, context),
    do: Platform.Chat.Canvas.VersionHandlers.versions(args, context)

  def execute("canvas.restore", args, context),
    do: Platform.Chat.Canvas.VersionHandlers.restore(args, context)

  # ── Skill tools ─────────────────────────────────────────────────────────

  def execute("skill.list", args, context),
    do: Platform.Skills.ToolHandlers.list(args, context)

  def execute("skill.get", args, context),
    do: Platform.Skills.ToolHandlers.get(args, context)

  def execute("skill.upsert", args, context),
    do: Platform.Skills.ToolHandlers.upsert(args, context)

  # ── Attachment tools (ADR 0039) ─────────────────────────────────────────

  def execute("attachment.upload_inline", args, context),
    do: Platform.Chat.Attachments.ToolHandlers.upload_inline(args, context)

  def execute("attachment.upload_start", args, context),
    do: Platform.Chat.Attachments.ToolHandlers.upload_start(args, context)

  def execute("attachment.get_inline", args, context),
    do: Platform.Chat.Attachments.ToolHandlers.get_inline(args, context)

  # Legacy underscore-names kept for one release — delegate to the new handlers.
  def execute("canvas_create", args, context) do
    case Platform.Chat.Canvas.ToolHandlers.create(args, context) do
      {:ok, payload} ->
        {:ok,
         %{
           id: payload.canvas_id,
           title: payload.title,
           kind: payload.kind,
           # `Map.get/2`, not dot-access: this clause is wrapped in a `rescue`
           # that turns any raise into "Failed to create canvas" for a canvas
           # that WAS created, inviting a duplicate-creating retry. A missing
           # key must not be able to produce that.
           view_url: Map.get(payload, :view_url)
         }}

      {:error, _} = err ->
        err
    end
  rescue
    e ->
      {:error,
       %{
         error: "Failed to create canvas: #{Exception.message(e)}",
         recoverable: true,
         suggestion: "Verify the space_id is valid and the agent is a participant"
       }}
  end

  def execute("canvas_update", args, context) do
    # Legacy canvas_update wrote without base_revision; use a describe lookup
    # to fetch current so callers that haven't migrated don't crash.
    canvas_id = Map.get(args, "canvas_id")

    with {:ok, %{revision: rev}} <- Platform.Chat.Canvas.Server.describe(canvas_id) do
      patched_args = Map.put(args, "base_revision", rev)

      case Platform.Chat.Canvas.ToolHandlers.patch(patched_args, context) do
        {:ok, payload} ->
          canvas = Chat.get_canvas(canvas_id)

          {:ok,
           %{
             id: payload.canvas_id,
             title: canvas && canvas.title,
             kind: canvas && Platform.Chat.CanvasDocument.root_kind(canvas.document),
             revision: payload.revision
           }}

        {:error, _} = err ->
          err
      end
    else
      {:error, reason} ->
        {:error, %{error: "canvas_update: #{inspect(reason)}", recoverable: true}}
    end
  end

  # ── Agent-initiated DM (task 01a04ad4) ──────────────────────────────────
  #
  # THE SHAPE OF THE SAFETY ARGUMENT, because it is easy to misread this as a
  # relaxation of the DM privacy contract and it is not one.
  #
  # This tool takes a PERSON, never a space. There is no `space_id` argument,
  # so there is no input by which it could be aimed at a conversation between
  # two other people. What it produces is always a space whose entire roster
  # is the calling agent plus the addressee — `Chat.find_or_create_agent_dm/2`
  # pins both halves of that roster in its lookup and writes both of them on
  # its insert.
  #
  # Three rules are LEFT ALONE and this tool depends on all three staying
  # that way:
  #
  #   * `chat.ex`'s "DMs are private-to-participants by contract — no observer
  #     agents" — nothing here adds an observer.
  #   * `chat.ex`'s "DMs are exempt: mentioning an agent in a DM must NOT
  #     auto-add them" — untouched, so an agent still cannot be talked into a
  #     DM it is not on.
  #   * `PlatformWeb.ChatLive`'s `@implicitly_joinable_kinds` (PR #835) —
  #     untouched, so `dm` still requires a pre-existing participant row to
  #     open by URL.
  #
  # The POST leg goes through `Chat.SpaceAccess.authorize_writer/2`, the
  # repo's space-write choke point, rather than looking the participant row up
  # directly. That is deliberate: it means the message can only ever land in a
  # space the agent already holds a `chat_participants` row in, by the same
  # predicate that guards `Chat.pin_message/2`. If the create leg ever handed
  # back a space the agent is not in, this leg refuses rather than writing.
  def execute("dm_create", args, context) do
    with {:ok, user_id} <- require_string(args, "user_id", "dm_create"),
         {:ok, message} <- require_string(args, "message", "dm_create"),
         {:ok, agent} <- dm_create_agent(context),
         :ok <- authorize_dm_target(agent, user_id) do
      deliver_agent_dm(agent, user_id, message)
    end
  end

  # ── Context read tools ──────────────────────────────────────────────────

  def execute("space_get_context", args, context) do
    space_id = Map.get(args, "space_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      bundle = ContextPlane.build_context_bundle(space_id)

      # Enrich with space metadata from DB
      space_meta =
        case Chat.get_space(space_id) do
          nil -> %{}
          s -> %{id: s.id, name: s.name, kind: s.kind, description: s.description}
        end

      {:ok, Map.put(bundle, :space, space_meta)}
    end
  end

  def execute("space_search_messages", args, context) do
    space_id = Map.get(args, "space_id")
    query = Map.get(args, "query", "")
    limit = args |> Map.get("limit", 10) |> min(10)

    with :ok <- assert_agent_in_space(space_id, context) do
      # Guard (task 01a006c2 stage 4): a query that parses to an EMPTY tsquery
      # — punctuation only, or otherwise no word token the `english` config
      # will keep — matches nothing by construction. Returning a bare `[]` for
      # that reads to the caller as "no such message" when the truth is "your
      # probe had nothing to search with". Return a distinguishable envelope.
      #
      # Authorization is deliberately checked BEFORE this branch: an
      # unauthorized caller must not learn anything, including how their query
      # parsed.
      if Chat.searchable_query?(query) do
        search_hits(space_id, query, limit)
      else
        {:ok,
         %{
           results: [],
           no_searchable_terms: true,
           note:
             "The query contained no searchable terms after full-text parsing " <>
               "(e.g. punctuation only), so it matched nothing by construction. " <>
               "This is NOT evidence that the space contains no such message. " <>
               "Retry with ordinary words, or use space_get_messages."
         }}
      end
    end
  end

  def execute("space_get_messages", args, context) do
    space_id = Map.get(args, "space_id")
    limit = args |> Map.get("limit", 20) |> min(20)
    before_id = Map.get(args, "before_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      opts = [limit: limit, top_level_only: true]
      opts = if before_id, do: Keyword.put(opts, :before_id, before_id), else: opts

      messages = Chat.list_messages(space_id, opts)
      attachments_by_msg = Chat.list_attachments_for_messages(Enum.map(messages, & &1.id))

      {:ok,
       Enum.map(messages, fn m ->
         {trimmed_content, truncated?} = cap_content(m.content || "")

         %{
           id: m.id,
           participant_id: m.participant_id,
           content_type: m.content_type,
           content: trimmed_content,
           content_truncated: truncated?,
           thread_id: m.thread_id,
           inserted_at: format_datetime(m.inserted_at),
           attachments: serialize_attachments(Map.get(attachments_by_msg, m.id, []))
         }
       end)}
    end
  end

  # `canvas_list` stays on `assert_agent_in_space/2` while `canvas_get` moved onto
  # `Platform.Chat.Canvas.ToolAccess` (task 019fb01b stage 4). Deliberate, not an
  # oversight left behind by that move: this tool takes a `space_id` and
  # ENUMERATES a space, so there is no canvas to resolve a grant from.
  # `CanvasAccess` answers "may this actor read THIS canvas", and every grant it
  # knows — space membership, a task attachment, an org — is a fact about one
  # canvas row. Asked about a space with no canvas in hand it has nothing to add,
  # and space participation is the right question about an enumeration.
  #
  # The consequence, stated here so it is not refiled later as an inconsistency:
  # an agent holding `:task_agent` on a canvas in a space it is not rostered in
  # can read that canvas by id and cannot list the space. That is correct. The
  # grant is scoped to the canvas someone attached to its task, not to
  # everything sitting next to it.
  def execute("canvas_list", args, context) do
    space_id = Map.get(args, "space_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      canvases = Chat.list_canvases(space_id)

      {:ok,
       Enum.map(canvases, fn c ->
         %{
           id: c.id,
           title: c.title,
           kind: Platform.Chat.CanvasDocument.root_kind(c.document),
           view_url: Platform.Chat.Canvas.Links.view_url(c.id),
           inserted_at: format_datetime(c.inserted_at),
           updated_at: format_datetime(c.updated_at)
         }
       end)}
    end
  end

  # Task 019fb01b stage 4 moved this read onto the shared canvas authorization
  # seam. See the "canvas_get is WIDER than it was" section of this module's
  # moduledoc for what changed and why. `ToolAccess` is referenced in full,
  # matching `Platform.Chat.Canvas.Links` and `Platform.Chat.CanvasDocument`
  # below it, so the move adds no line to the alias block.
  def execute("canvas_get", args, context) do
    canvas_id = Map.get(args, "canvas_id")
    mode = Map.get(args, "mode", "summary")

    with {:ok, canvas} <- Platform.Chat.Canvas.ToolAccess.fetch_for_read(canvas_id, context) do
      result = %{
        id: canvas.id,
        title: canvas.title,
        kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
        space_id: canvas.space_id,
        view_url: Platform.Chat.Canvas.Links.view_url(canvas.id),
        inserted_at: format_datetime(canvas.inserted_at),
        updated_at: format_datetime(canvas.updated_at)
      }

      result =
        if mode == "full" do
          Map.put(result, :document, canvas.document)
        else
          result
        end

      {:ok, result}
    end
  end

  def execute("principal_search", args, _context) do
    query_raw = Map.get(args, "query", "")
    type_filter = Map.get(args, "type", "any")
    limit = args |> Map.get("limit", 20) |> normalize_limit()

    query_trimmed = if is_binary(query_raw), do: String.trim(query_raw), else: ""

    cond do
      not is_binary(query_raw) ->
        {:error,
         %{
           error: "principal_search: `query` must be a string",
           recoverable: true,
           suggestion: "Pass a plain-text search fragment as `query`."
         }}

      type_filter not in ["user", "agent", "any"] ->
        {:error,
         %{
           error: "principal_search: `type` must be one of \"user\", \"agent\", \"any\"",
           recoverable: true,
           suggestion: "Omit `type` to search both, or pass one of the allowed values."
         }}

      String.length(query_trimmed) < 2 ->
        {:ok, %{results: []}}

      true ->
        query_norm = String.downcase(query_trimmed)
        like_pattern = "%#{query_trimmed}%"
        prefix_pattern = "#{query_trimmed}%"

        users =
          if type_filter in ["user", "any"] do
            search_users(query_trimmed, query_norm, like_pattern, prefix_pattern, limit)
          else
            []
          end

        agents =
          if type_filter in ["agent", "any"] do
            search_agents(query_trimmed, like_pattern, prefix_pattern, limit)
          else
            []
          end

        {:ok, %{results: users ++ agents}}
    end
  end

  # ── Task tools ───────────────────────────────────────────────────────────

  # TODO(scope): this handler ignores its `_context` and returns every project
  # in every org. It cannot be fixed by swapping in
  # `Tasks.list_projects_for_user/2`: the MCP context built by
  # `PlatformWeb.MCPController.build_context/2` carries `agent_id` /
  # `runtime_id` / `space_id` and NO user, while the viewer filter is keyed on
  # `user_id` via `org_memberships`. Scoping an agent principal to orgs is a
  # separate design with its own authorization layer
  # (`Platform.Federation.ToolAuthorization`) — deliberately deferred rather
  # than papered over with an invented agent-to-org mapping.
  def execute("project_list", args, _context) do
    opts =
      case Map.get(args, "org_id") do
        org_id when is_binary(org_id) and org_id != "" -> [org_id: org_id]
        _ -> []
      end

    projects =
      opts
      |> Tasks.list_projects_unscoped()
      |> Repo.preload(:org)
      |> Enum.map(fn p ->
        %{
          id: p.id,
          name: p.name,
          slug: p.slug,
          repo_url: p.repo_url,
          org_id: p.org_id,
          org_slug: p.org && p.org.slug
        }
      end)

    {:ok, projects}
  end

  def execute("org_list_descendants", args, _context) do
    list_org_descendants(Map.get(args, "org_id"))
  end

  def execute("project_update", args, context) do
    project_id = Map.get(args, "project_id")

    case Tasks.get_project(project_id) do
      nil ->
        {:error,
         %{
           error: "Project not found: #{project_id}",
           recoverable: false,
           suggestion: "Use project_list to find available projects"
         }}

      project ->
        # `config` is deliberately absent from this list. See the tool's
        # `limitations` and `Platform.Design.Brand`'s moduledoc: an
        # agent-writable `config` blob would let a malformed
        # `brand_decision` land, which resolve/1 reads as NO decision —
        # silently re-opening the once-per-project re-ask loop. A named
        # enum param cannot do that.
        update_attrs =
          args
          |> Map.take(["name", "repo_url", "default_branch", "deploy_config", "dispatch_paused"])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)
          |> put_plan_auto_approve(project, Map.get(args, "plan_auto_approve"))

        with {:ok, updated} <- Tasks.update_project(project, update_attrs),
             {:ok, updated} <-
               apply_brand_decision(updated, Map.get(args, "brand_decision"), context) do
          {:ok,
           %{
             id: updated.id,
             name: updated.name,
             slug: updated.slug,
             repo_url: updated.repo_url,
             default_branch: updated.default_branch,
             deploy_config: updated.deploy_config,
             dispatch_paused: updated.dispatch_paused,
             brand_decision: brand_decision_of(updated),
             plan_auto_approve: Map.get(updated.config || %{}, "plan_auto_approve")
           }}
        else
          {:error, :invalid_brand_decision} ->
            {:error,
             %{
               error:
                 "project_update: `brand_decision` must be one of " <>
                   Enum.join(Brand.recordable_modes(), ", "),
               recoverable: true,
               suggestion:
                 "Pass one of #{Enum.join(Brand.recordable_modes(), ", ")}, or omit brand_decision to leave the project's brand decision unchanged."
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update project: #{inspect_errors_safe(changeset)}",
               recoverable: true,
               suggestion:
                 "Check that deploy_config.default_strategy uses a valid strategy type (none, pr_merge, docker_deploy, fly, skill_driven, manual, project_files) and that plan_auto_approve is {enabled: boolean, max_stages: positive integer, allow_manual_approval?: boolean}"
             }}
        end
    end
  end

  def execute("epic_list", args, _context) do
    project_id = Map.get(args, "project_id")

    epics =
      Tasks.list_epics_for_project(project_id)
      |> Enum.map(fn e ->
        %{
          id: e.id,
          name: e.name,
          description: e.description,
          project_id: e.project_id,
          status: e.status
        }
      end)

    {:ok, epics}
  end

  def execute("epic_update", args, _context) do
    epic_id = Map.get(args, "epic_id")

    case Tasks.get_epic(epic_id) do
      nil ->
        {:error,
         %{
           error: "Epic not found: #{epic_id}",
           recoverable: false,
           suggestion: "Use epic_list to find available epics"
         }}

      epic ->
        attrs =
          args
          |> Map.take(["name", "description", "status", "target_branch", "deploy_target"])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

        case Tasks.update_epic(epic, attrs) do
          {:ok, updated} ->
            # Broadcast happens inside Tasks.update_epic/2 so all callers
            # (UI + MCP) get parity with create_task/update_task.
            {:ok,
             %{
               id: updated.id,
               name: updated.name,
               status: updated.status,
               target_branch: updated.target_branch,
               deploy_target: updated.deploy_target
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update epic: #{inspect_errors(changeset)}",
               recoverable: true
             }}
        end
    end
  end

  def execute("epic_create", args, _context) do
    attrs =
      %{
        project_id: Map.get(args, "project_id"),
        name: Map.get(args, "name"),
        description: Map.get(args, "description"),
        acceptance_criteria: Map.get(args, "acceptance_criteria"),
        status: Map.get(args, "status", "open"),
        target_branch: Map.get(args, "target_branch"),
        deploy_target: Map.get(args, "deploy_target")
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    # NOTE: Tasks.create_epic/1 broadcasts {:epic_created, epic} itself
    # (centralized in stage 1, commit c69e878), so do NOT broadcast here.
    case Tasks.create_epic(attrs) do
      {:ok, epic} ->
        {:ok,
         %{
           id: epic.id,
           name: epic.name,
           description: epic.description,
           project_id: epic.project_id,
           status: epic.status,
           target_branch: epic.target_branch,
           deploy_target: epic.deploy_target
         }}

      {:error, changeset} ->
        {:error,
         %{
           error: "Failed to create epic: #{inspect_errors(changeset)}",
           recoverable: true,
           suggestion: "Check that project_id is valid and name is provided"
         }}
    end
  end

  # `task_create` — canonical shape defined by
  # `Platform.Federation.TaskAttrs.build_task_attrs/3` (ADR 0044). Accepts
  # flat `assignee_id + assignee_type` OR structured `phase_assignees`;
  # flat writes are auto-routed to `phase_assignees["planning"]` (new
  # tasks start at the planning phase) so the write survives the next
  # phase transition — this fixes the historical silent-clobber where a
  # `task_create` flat assignee was overwritten when the task moved out
  # of planning.
  def execute("task_create", args, context) do
    # Legacy defaults preserved for wire compatibility: title, status,
    # priority, and auto_approve_plan drop to their historical defaults
    # only when the key is entirely absent (Map.put_new). Present-and-nil
    # is left to `build_task_attrs/3`'s nil-drop rules.
    args_with_defaults =
      args
      |> Map.put_new("title", "Untitled Task")
      |> Map.put_new("status", "backlog")
      |> Map.put_new("priority", "medium")
      |> Map.put_new("auto_approve_plan", false)

    with {:ok, flat_attrs, phase_attrs} <-
           TaskAttrs.build_task_attrs(args_with_defaults, :create,
             auto_route_flat_assignee_current_phase: true,
             current_phase: "planning"
           ),
         :ok <- TaskAttrs.check_auto_approve_preconditions(flat_attrs, phase_attrs, nil),
         {:ok, task} <-
           Tasks.create_task(flat_attrs, actor: actor_from_mcp_context(context)),
         {:ok, task} <- maybe_apply_phase_assignees(task, phase_attrs) do
      # Preload sponsor so the return envelope shows the shape a
      # subsequent `task_get` would — the `create_task` result may not
      # have :sponsor loaded even when sponsor_user_id is set. When
      # `set_phase_assignees/2` also ran, it returned an unpreloaded
      # struct too, so this preload covers both branches.
      task = Repo.preload(task, :sponsor)
      Tasks.broadcast_board({:task_created, task})

      # Stage 4 (019f3dbb): advisory self-similarity search. Empty
      # array on failure (never blocks the create). See
      # `similar_tasks_for/1` below for the threshold + shape.
      similar_tasks = similar_tasks_for(task)

      case Map.get(args, "stack_id") do
        nil ->
          # Hotfix (post-PR #550): auto-transition `backlog → planning`
          # when the caller supplied an agent-typed planning-phase
          # assignee. Without this, `TaskRouterWatcher.should_run?/1`
          # never spawns a router for a fresh `backlog` task and the
          # planner never dispatches — so `phase_assignees["planning"]`
          # would be a silent no-op. See
          # `Tasks.maybe_start_planning_on_create/1` for the invariant
          # and the log-and-swallow failure model. Stack members
          # (`stack_id != nil` in `args`) skip this branch entirely —
          # `Stacks.start_planning/1` owns wave-gated dispatch for them.
          {:ok, task} = Tasks.maybe_start_planning_on_create(task)

          {:ok,
           %{
             id: task.id,
             title: task.title,
             status: task.status,
             priority: task.priority,
             project_id: task.project_id,
             epic_id: task.epic_id,
             sponsor: serialize_sponsor(task.sponsor),
             auto_approve_plan: task.auto_approve_plan,
             similar_tasks: similar_tasks
           }}

        stack_id ->
          case Stacks.add_task(stack_id, task) do
            {:ok, updated} ->
              updated = Repo.preload(updated, :sponsor)

              {:ok,
               %{
                 id: updated.id,
                 title: updated.title,
                 status: updated.status,
                 priority: updated.priority,
                 project_id: updated.project_id,
                 epic_id: updated.epic_id,
                 sponsor: serialize_sponsor(updated.sponsor),
                 stack_id: updated.stack_id,
                 stack_position: updated.stack_position,
                 auto_approve_plan: updated.auto_approve_plan,
                 similar_tasks: similar_tasks
               }}

            {:error, _} = err ->
              stack_add_error_envelope(err)
          end
      end
    else
      # Task 01a05877 stage 2: recoverable refusals echo the submitted
      # arguments (post-defaults) back in the response envelope ONLY —
      # never a log line, never telemetry, never an audit event (title/
      # description are user content; docs/decisions/0005) — so a retry
      # is patch-one-field instead of rebuild-everything.
      {:error, {:invalid_phase_keys, keys}} ->
        {:error,
         %{
           error: "Invalid phase_assignees keys: #{Enum.join(keys, ", ")}",
           recoverable: true,
           suggestion: "Use 'planning', 'execution', or 'review'",
           submitted_args: args_with_defaults
         }}

      {:error, {:invalid_phase_assignees_shape, _}} ->
        {:error,
         %{
           error: "phase_assignees must be a map keyed by phase name",
           recoverable: true,
           suggestion:
             "Pass %{\"planning\" => %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\"}}",
           submitted_args: args_with_defaults
         }}

      {:error,
       {:auto_approve_precondition_missing,
        %{missing_phases: phases, merged_phase_assignees: merged}}} ->
        corrected = TaskAttrs.auto_approve_corrected_args(args_with_defaults, merged, phases)

        {:error,
         auto_approve_precondition_envelope(phases, args_with_defaults, corrected, :create)}

      {:error, :project_archived} ->
        {:error, project_archived_envelope("create a task in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect_errors(changeset)}",
           recoverable: true,
           suggestion: "Check that project_id is valid and title is provided",
           submitted_args: args_with_defaults
         }}

      {:error, other} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect(other)}",
           recoverable: true,
           suggestion: "Check the request shape",
           submitted_args: args_with_defaults
         }}
    end
  end

  def execute("meeting_create", args, context) do
    # Both intended-time endpoints are parsed BEFORE anything is written. A
    # malformed one short-circuits with an error envelope naming the offending
    # parameter and no meeting row — see `parse_optional_datetime/2` for why
    # neither coercing to nil nor raising is an acceptable alternative.
    with {:ok, scheduled_start_at} <- parse_optional_datetime(args, "scheduled_start_at"),
         {:ok, scheduled_end_at} <- parse_optional_datetime(args, "scheduled_end_at") do
      attrs =
        %{
          project_id: Map.get(args, "project_id"),
          name: Map.get(args, "name"),
          slug: Map.get(args, "slug"),
          host_participant_id: Map.get(args, "host_participant_id"),
          scheduled_start_at: scheduled_start_at,
          scheduled_end_at: scheduled_end_at
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      case Meetings.create_meeting(attrs) do
        {:ok, meeting} ->
          meeting = maybe_default_host_participant(meeting, args, context)
          {:ok, serialize_meeting(meeting)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error,
           %{
             error: "Failed to create meeting: #{inspect_errors(changeset)}",
             recoverable: true,
             suggestion:
               "Check that project_id is valid; if you passed an explicit slug it must be unique within the project. scheduled_start_at and scheduled_end_at must be supplied together, with the end strictly after the start."
           }}

        {:error, reason} ->
          {:error, %{error: "Failed to create meeting: #{inspect(reason)}", recoverable: true}}
      end
    end
  end

  # ── meeting_say (task 01a06672 stage 2) ─────────────────────────────
  # Everything that matters happens in `Meetings.say/4`: the participant
  # guard, the text cap, the runtime broadcast and the ack rendezvous. This
  # clause only names the caller and translates refusals into envelopes an
  # agent can act on. It must NOT broadcast on its own — the guard lives
  # behind `say/4`, and a direct `Endpoint.broadcast` here would put an
  # uninvited agent's voice into a room.
  def execute("meeting_say", args, context) do
    room_name = Map.get(args, "room_name")
    text = Map.get(args, "text")

    case load_agent(context) do
      nil ->
        {:error,
         %{
           error: "meeting_say: no calling agent in context",
           recoverable: false,
           suggestion:
             "This tool must be called from an agent runtime; the caller's agent could not be resolved."
         }}

      %Agent{} = agent ->
        case Meetings.say(agent, to_string(room_name), to_string(text)) do
          {:ok, ack} ->
            {:ok,
             %{
               utterance_id: ack.utterance_id,
               status: ack.status,
               duration_s: Map.get(ack, :duration_s),
               # The worker's own failure string, relayed verbatim. It is
               # the only thing that distinguishes one `failed` from
               # another, and dropping it here left the tool description
               # promising an `error` the agent could never see.
               error: Map.get(ack, :error),
               room_name: Map.get(ack, :room_name) || room_name
             }}

          {:error, reason} ->
            {:error, meeting_say_error(reason, room_name)}
        end
    end
  end

  # ── meeting_activity_push (task 01a07400 stage 1) ───────────────────
  # The agent declares its OWN state, in a meeting it is seated in. Three
  # things this clause deliberately does not do:
  #
  #   * It does not take an agent_id parameter. The agent is always
  #     `load_agent(context)`, so a runtime can only ever speak for itself
  #     — `:thinking` on someone else's tile would be a lie core relayed.
  #   * It does not `String.to_atom/1` the state. `@pushed_state_names`
  #     is an explicit two-entry map, so an unknown string is a refusal
  #     rather than a new atom on a public endpoint.
  #   * It registers NOTHING to clean the push up — no monitor, no
  #     terminate hook, no presence-drop handler. The whole safety
  #     argument for pushed state is that the SERVER expires it; a
  #     cleanup path here would work only when the runtime dies politely,
  #     which is the case that does not need it.
  def execute("meeting_activity_push", args, context) do
    meeting_id = Map.get(args, "meeting_id")

    with {:ok, %Agent{} = agent} <- activity_push_agent(context),
         {:ok, state} <- activity_push_state(Map.get(args, "state")),
         {:ok, meeting} <- activity_push_meeting(meeting_id),
         :ok <- activity_push_seated(meeting, agent) do
      case AgentActivity.push(meeting.id, agent.id, state, reason: Map.get(args, "reason")) do
        {:ok, entry} ->
          {:ok,
           %{
             meeting_id: meeting.id,
             agent_id: agent.id,
             state: Atom.to_string(entry.state),
             reason: entry.reason,
             pushed_at: DateTime.to_iso8601(entry.pushed_at),
             ttl_ms: entry.ttl_ms,
             expires_at:
               entry.pushed_at
               |> DateTime.add(entry.ttl_ms, :millisecond)
               |> DateTime.to_iso8601()
           }}

        {:error, reason} ->
          {:error,
           %{
             error: "meeting_activity_push: could not record the state (#{inspect(reason)})",
             recoverable: true,
             suggestion:
               "The activity store was not available. Retry shortly; nothing was recorded."
           }}
      end
    end
  end

  def execute("task_get", args, _context) do
    task_id = Map.get(args, "task_id") || Map.get(args, "id")

    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        {:ok, serialize_task(task)}
    end
  end

  # Read-only over `task_phase_transitions`. There is deliberately NO writer
  # here: the rows are written by `prepare_changes(&record_status_transition/1)`
  # in `Platform.Tasks.Task`, last in the changeset pipeline and inside the same
  # Repo transaction as the update they describe. A second, non-transactional
  # copy would diverge on rollback and is forbidden.
  def execute("task_transition_list", args, context) do
    # `require_string/3` first, with no `"id"` fallback: the declared
    # `required: true` must be HONEST. An absent task_id must refuse rather
    # than fall through to `list_for_task(nil)`, which would return the
    # zero-row "predates instrumentation" shape for a call that named no task
    # at all — the precise confusion this tool exists to remove.
    #
    # Authorize BEFORE serializing — a denied caller must see no actor label,
    # no `via`, and no status prose.
    with {:ok, task_id} <- require_string(args, "task_id", "task_transition_list"),
         :ok <- authorize_review_access(context, task_id) do
      # `list_for_task/2`'s second argument is a Repo, not options. One arg.
      transitions = PhaseTransitions.list_for_task(task_id)

      {:ok,
       %{
         task_id: task_id,
         count: length(transitions),
         transitions: Enum.map(transitions, &serialize_phase_transition/1),
         note: transition_list_note(transitions)
       }}
    end
  end

  # Read-only over `runtime_events`. No writer here and no migration: the rows
  # are written by `Platform.Orchestration.RuntimeSupervision` in the same
  # transaction as the lease upsert they accompany. Query lives in the
  # Orchestration context (`Diagnostics`), not inline here — same separation as
  # `PhaseTransitions.list_for_task/1` above.
  def execute("runtime_event_list", args, context) do
    # Required-arg guard FIRST, no `"id"` alias. Stage 1 of this task found
    # that omitting it lets a call naming no task at all fall through and
    # return a confident zero-row answer about a task the caller never
    # identified — the exact misreading these diagnostics exist to prevent.
    #
    # Authorize BEFORE serializing: a denial must carry no payload fragment
    # and no runtime_id.
    with {:ok, task_id} <- require_string(args, "task_id", "runtime_event_list"),
         :ok <- authorize_review_access(context, task_id) do
      limit = Diagnostics.clamp_limit_for(Map.get(args, "limit"))

      events =
        Diagnostics.list_runtime_events(task_id,
          event_type: Map.get(args, "event_type"),
          limit: limit
        )

      {:ok,
       %{
         task_id: task_id,
         count: length(events),
         limit: limit,
         events: Enum.map(events, &serialize_runtime_event/1)
       }}
    end
  end

  # Read-only over `execution_leases`. See `runtime_event_list` above for why
  # an empty result here is normal rather than a defect.
  def execute("execution_lease_list", args, context) do
    with {:ok, task_id} <- require_string(args, "task_id", "execution_lease_list"),
         :ok <- authorize_review_access(context, task_id),
         limit = Diagnostics.clamp_limit_for(Map.get(args, "limit")),
         {:ok, leases} <-
           lease_list_result(task_id, Map.get(args, "status"), limit) do
      {:ok,
       %{
         task_id: task_id,
         count: length(leases),
         # The EFFECTIVE (clamped) limit, not what the caller asked for: a
         # response reporting `limit: 500` while the query ran with 200 would
         # make a truncated list read as exhaustive.
         limit: limit,
         status_filter: Map.get(args, "status"),
         leases: Enum.map(leases, &serialize_execution_lease/1)
       }}
    end
  end

  def execute("task_complete", %{"task_id" => task_id} = args, context) do
    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        # `transition_task_status/2` deliberately takes no actor (the router,
        # Stacks, CommencementGate and ChatPins all call it). The MCP caller's
        # identity travels out-of-band so the recorded transition is attributed
        # to the calling agent instead of `unknown` — the same shape
        # `maybe_transition_status/3` uses for task_update. The `via` differs on
        # purpose: an agent ruling its own gate delivered via `task_complete`
        # must stay distinguishable from the same agent's `task_update`.
        actor = actor_from_mcp_context(context)

        # COMPARE-AND-SET (task 01a094d4 stage 3). `base_updated_at` (alias
        # `if_unmodified_since`) guards THE STATUS WRITE, which is the only
        # write this tool makes — so unlike `task_update`, where the base
        # covers the plain-field statement and leaves the status statement
        # unguarded, here the guard's scope is the tool's whole effect.
        # Absent → unguarded, last-write-wins, exactly as before.
        # Unparseable → refused before any write.
        result =
          with {:ok, base} <- parse_base_updated_at(args, "task_complete") do
            Tasks.TransitionActor.with_actor(actor, "mcp_task_complete", fn ->
              case base do
                nil -> Tasks.transition_task_status(task, "done")
                %DateTime{} -> Tasks.transition_task_status_if_unmodified(task, "done", base)
              end
            end)
          end

        case result do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})

            # `previous_updated_at` is the PRE-call stamp (`task` was read at
            # the top of this function), mirroring the task_update envelope:
            # a caller that passed no base can still see what it displaced.
            {:ok,
             %{
               task_id: updated.id,
               status: updated.status,
               updated_at: updated.updated_at,
               previous_updated_at: task.updated_at
             }}

          {:error, {:stale_base, %{current_updated_at: ts, base_updated_at: supplied}}} ->
            # A retryable CONFLICT, not a fatal error. The task was NOT
            # transitioned and no `task_phase_transitions` row was written.
            {:error,
             %{
               error:
                 "stale_base: task was modified at #{stale_base_stamp(ts)}, after the base you supplied (#{stale_base_stamp(supplied)}). Your task_complete was REFUSED and nothing was changed \u2014 the task is still '#{task.status}'.",
               recoverable: true,
               submitted_args: args,
               suggestion:
                 "Re-read the task with task_get. Whoever moved it may already have completed it, or may have moved it somewhere `done` is not reachable from \u2014 check the current status before retrying with base_updated_at set to the updated_at you just read."
             }}

          {:error, %{error: _} = err} ->
            {:error, err}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Cannot transition task from '#{task.status}' to 'done'",
               recoverable: false,
               suggestion:
                 "Only in_progress, in_review and deploying can move to 'done'. " <>
                   "Do NOT reach for 'cancelled' here: it is terminal, it has no outbound " <>
                   "edges, and it means the work was ABANDONED \u2014 recording delivered work " <>
                   "as cancelled is unrecoverable and is the corruption task 01a049be exists " <>
                   "to stop. If the work genuinely shipped without a plan cycle, call " <>
                   "task_close_as_delivered with a merge/PR reference \u2014 it is callable when " <>
                   "the runtime you are calling through is owned by a Fabrikam admin, and it " <>
                   "verifies the reference against the project's repo before writing. If you " <>
                   "have no such runtime, ask a Fabrikam admin to run it. If it truly was " <>
                   "abandoned or superseded, then " <>
                   "task_update with status='cancelled' is correct."
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to complete task: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion: "Check that the task_id is valid"
             }}
        end
    end
  end

  # ── task_close_as_delivered — THE PERMISSION DECISION (task 01a0a552) ──
  #
  # An agent may call this ONLY when the AgentRuntime it is calling
  # through is owned by a user who satisfies `Platform.Tenancy.fabrikam_admin?/1`.
  # THE AUTHORITY IS THE OWNER'S, DELEGATED; the agent is the instrument.
  # That is why `Tasks.close_as_delivered/4` receives the owner as `admin`
  # (so `actor_kind` on the recorded transition is `"user"`) and the agent
  # only as `via_agent_id` beside it: the authority and the actor are
  # separately readable afterwards, which they would not be if the agent
  # were the actor.
  #
  # Two alternatives were considered and REJECTED, recorded here because
  # the next person to widen this will face the same two:
  #
  #   (a) "any agent holding the `task` bundle may call it". That makes
  #       every agent a Fabrikam admin for this one verb — precisely the
  #       widening task 01a049be exists to prevent — and it detaches the
  #       closure from any human who could be asked why.
  #
  #   (b) "a new capability bundle, e.g. `task_admin`". A bundle is a
  #       VISIBILITY SCOPE, not a privilege level:
  #       `Platform.Federation.ToolAuthorization` deliberately reads
  #       `allowed_bundles` and nothing else, so encoding privilege there
  #       would put an admin grant in a column any runtime row can be
  #       given — an escalation one UPDATE wide, invisible to every
  #       membership check.
  #
  # `fabrikam_admin?/1` is install-coupled: it means "an admin of the ROOT
  # org" (`Platform.Tenancy` root-membership), which on this install is
  # Fabrikam. Whoever generalises admin-ness later wants this call site and
  # the two in `Platform.Tasks` (`reinstate_cancelled_task/3`,
  # `close_as_delivered/4`) — those three are the set today.
  #
  # ORDER IS SECURITY-RELEVANT. The principal is resolved and refused
  # FIRST, before the task is read, so a non-admin cannot use the refusal
  # text to probe whether an id names a row or what status it is in. Same
  # rationale as `Platform.Tasks.close_as_delivered/4`'s own first cond
  # clause.
  def execute("task_close_as_delivered", args, context) do
    with {:ok, admin} <- delivery_closure_principal(context),
         {:ok, task_id} <- require_string(args, "task_id", "task_close_as_delivered"),
         {:ok, reference} <-
           require_non_blank_string(args, "delivery_reference", "task_close_as_delivered"),
         {:ok, parsed} <- parse_delivery_reference(reference),
         {:ok, task} <- fetch_task_for_delivery(task_id),
         {:ok, resolution} <- resolve_delivery_reference(parsed, task) do
      case Tasks.close_as_delivered(task.id, reference, admin,
             via_agent_id: Map.get(context, :agent_id),
             delivery_reference_resolution: resolution
           ) do
        {:ok, updated} ->
          Tasks.broadcast_board({:task_updated, updated})

          {:ok,
           %{
             task_id: updated.id,
             status: updated.status,
             delivery_reference: reference,
             resolution: resolution
           }}

        {:error, :not_correctable} ->
          {:error,
           %{
             error:
               "Task is '#{task.status}', which is not_correctable by this tool: " <>
                 "only #{Enum.join(Tasks.undeliverable_statuses(), ", ")} can be closed as " <>
                 "delivered. Anything else already has a legitimate route to 'done'.",
             recoverable: false,
             suggestion:
               "in_progress, in_review and deploying reach 'done' through the pipeline — " <>
                 "use task_complete. 'cancelled' must be walked back with " <>
                 "Platform.Tasks.reinstate_cancelled_task/3 first, so the repair leaves two " <>
                 "auditable steps rather than one silent jump."
           }}

        {:error, :not_found} ->
          {:error, delivery_task_not_found(task_id)}

        {:error, :not_authorized} ->
          # Unreachable through this clause (the principal was checked
          # first) and deliberately answered identically if it ever is.
          {:error, delivery_not_authorized()}

        {:error, :delivery_reference_required} ->
          {:error,
           %{
             error: "task_close_as_delivered: delivery_reference is required",
             recoverable: true,
             suggestion: "Pass a commit sha, `#1018`, or a github.com pull/commit URL."
           }}

        {:error, other} ->
          {:error,
           %{
             error: "Failed to close task as delivered: #{inspect(other)}",
             recoverable: true,
             suggestion: "Check that the task_id is valid and retry."
           }}
      end
    end
  end

  def execute("task_list", args, _context) do
    # Compose every supplied filter together — passing project_id and status
    # both must AND, not pick one branch. The old `cond` was mutually
    # exclusive and silently dropped the status filter when project_id was
    # also present, producing false positives.
    opts =
      [
        project_id: Map.get(args, "project_id"),
        epic_id: Map.get(args, "epic_id"),
        status: Map.get(args, "status")
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    # Task 01a049de — `task_list` on the 807-task project measured 3_366_819
    # bytes, 83% of it `description`. Two bounds, both additive:
    #
    #   * `detail` defaults to "summary", which SNIPPETS description rather
    #     than dropping it. A caller that reads `description` still gets a
    #     string plus `description_truncated` / `description_length`; the full
    #     text is one `task_get` away. Dropping the key would have made an
    #     existing caller silently read nil, which is the failure mode the
    #     ticket explicitly warns against.
    #   * `limit`/`offset` default to #{ResultBound.default_limit()}/0.
    #
    # Task 01a04a7a made the truncation VISIBLE. #840 left a caller able to
    # page but unable to tell whether it needed to: the result was a bare JSON
    # array, and "50 rows" and "50 of 807 rows" were the same eight hundred
    # bytes. The orchestrator's measured cost was having to answer "how big is
    # the backlog?" with "at least 50, upper bound unknown".
    #
    # A JSON array is structurally incapable of carrying that signal, so the
    # result is now an envelope: `%{tasks:, total:, limit:, offset:,
    # has_more:}`. `total` is a real `SELECT count(*)` over the same filters
    # (`Tasks.count_tasks/1`), NOT an inference from the page length — see
    # `has_more` below.
    #
    # Paging moved from `Enum.drop |> Enum.take` into SQL
    # (`Tasks.list_tasks_page/2`). The two share a private query builder with
    # `Tasks.list_tasks/1`, so the count and the page can never be taken over
    # different sets, and the order is now total (`inserted_at`, then `id`) so
    # two pages cannot skip or repeat a row.
    {limit, offset} = ResultBound.page(args)

    total = Tasks.count_tasks(opts)

    rows =
      opts
      |> Tasks.list_tasks_page(limit: limit, offset: offset)
      |> Enum.map(&serialize_task_row(&1, full_detail?(args)))

    # `offset + length(rows) < total`, never `length(rows) == limit`. The
    # cheap form is wrong at exactly the boundary that matters: a corpus of
    # exactly 50 with a limit of 50 reports "there is more", the caller pages
    # again, and gets nothing. A flag that fires on a full page is not
    # reporting truncation, it is restating the page size.
    #
    # `total` and the page are two statements, so a concurrent insert between
    # them can make `has_more` stale by one call. That is a race a caller
    # re-paging resolves on its own; a transaction here would buy consistency
    # nobody asked for at the cost of a read lock on the hottest list in the
    # product.
    {:ok,
     %{
       tasks: rows,
       total: total,
       limit: limit,
       offset: offset,
       has_more: offset + length(rows) < total
     }}
  end

  # `task_update` — canonical shape defined by
  # `Platform.Federation.TaskAttrs.build_task_attrs/3` (ADR 0044). The
  # helper owns the nilable-semantics contract: `sponsor_user_id` and
  # `deploy_target` propagate explicit nil (clears the field);
  # everything else is dropped when nil (unset ≠ clear). Flat assignee
  # writes are auto-routed to the task's CURRENT-phase slot (from
  # `Tasks.current_phase/1`) so a mid-task reassignment survives the
  # next phase transition.
  #
  # If someone reintroduces a blanket `Map.reject(fn {_k, v} -> is_nil(v)
  # end)` inline here, the sponsor + deploy_target clear-tests will go
  # red — that's the guard. See ADR 0042 for the sponsor null-clears
  # contract and ADR 0044 for the assignee auto-routing.
  # As of ADR 0042 §sponsor-bypass (task 019f6380 stage 2), MCP-initiated
  # status transitions in `task_update` invoke `Tasks.require_approved_plan_for/3`
  # with an agent-typed actor derived from the MCP call context. Previously
  # this path routed straight through `Tasks.transition_task_status/2`
  # (the base primitive, no gate), which meant an agent calling `task_update`
  # could self-transition to `in_progress` / `done` without an approved
  # plan — precisely the pathology the gate exists to prevent. The gate
  # call below closes that hole so the sponsor-bypass rule remains a
  # HUMAN-only exemption regardless of entry surface.
  def execute("task_update", args, context) do
    task_id = Map.get(args, "task_id") || Map.get(args, "id")
    actor = actor_from_mcp_context(context)

    # Parsed FIRST, before the row is even read, so an unparseable token can
    # never reach a writer. `nil` (the overwhelmingly common case — every
    # pre-existing agent caller omits it) flows through as nil and the whole
    # path below behaves exactly as it did before this parameter existed.
    with {:ok, base_updated_at} <- parse_base_updated_at(args) do
      task_update_with_base(task_id, args, actor, base_updated_at)
    end
  end

  def execute("task_attach_canvas", args, context) do
    task_id = Map.get(args, "task_id")
    canvas_id = Map.get(args, "canvas_id")
    note = Map.get(args, "note")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error,
         %{
           error: "task_attach_canvas requires task_id (string)",
           recoverable: true,
           suggestion: "Pass the UUID of the task as task_id"
         }}

      not is_binary(canvas_id) or canvas_id == "" ->
        {:error,
         %{
           error: "task_attach_canvas requires canvas_id (string)",
           recoverable: true,
           suggestion: "Pass the UUID of the canvas as canvas_id"
         }}

      true ->
        attached_by = resolve_attached_by(context)

        # `attached_by` is attribution; `canvas_authorization_actor/1` is the
        # authorization subject. Same context, deliberately read twice —
        # conflating the two is exactly the bug this gate closes.
        case CanvasAttachments.attach_canvas(
               canvas_authorization_actor(context),
               task_id,
               canvas_id,
               note: note,
               attached_by: attached_by
             ) do
          {:ok, attachment} ->
            {:ok,
             %{
               attachment_id: attachment.id,
               task_id: attachment.task_id,
               canvas_id: attachment.canvas_id,
               note: attachment.note
             }}

          {:error, :task_not_found} ->
            {:error,
             %{
               error: "Task not found: #{task_id}",
               recoverable: false,
               suggestion: "Use task_list to find available tasks"
             }}

          # THE DENIAL IS A RECOVERY MECHANISM, not just a refusal (task
          # 019fb581 stage 3). A designer dispatched to a task she has no
          # binding to would otherwise sit on an open pre-plan design step
          # until its 30-minute hold expires and records `failed`. Naming
          # `task_design_decline` in the suggestion turns that into a
          # one-call exit she can take from the error message itself,
          # without any grant changing hands.
          {:error, :task_forbidden} ->
            {:error,
             %{
               error: "Access denied: you cannot attach a canvas to task #{task_id}.",
               code: :task_forbidden,
               recoverable: false,
               task_id: task_id,
               suggestion:
                 "Attaching a canvas to a task is a write to that task, so you must already be " <>
                   "working on it: its assignee or phase assignee, a participant in its " <>
                   "execution space, its sponsor, or a member of its project's org. If you were " <>
                   "dispatched to give this task design direction and cannot deliver, close " <>
                   "your step with task_design_decline instead of waiting out the design hold."
             }}

          {:error, :canvas_not_found} ->
            {:error,
             %{
               error: "Canvas not found or soft-deleted: #{canvas_id}",
               recoverable: false,
               suggestion:
                 "Verify the canvas_id is correct and the canvas has not been soft-deleted upstream"
             }}

          {:error, :canvas_forbidden} ->
            {:error,
             %{
               error:
                 "Access denied: you cannot attach canvas #{canvas_id} because you cannot read it.",
               recoverable: false,
               canvas_id: canvas_id,
               suggestion:
                 "Attaching a canvas to a task grants everyone who can read that task the ability to read the canvas, so you must be able to read it yourself first. Join the canvas's space, or attach a canvas you created."
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error,
             %{
               error: "Failed to attach canvas: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion:
                 "task_attach_canvas requires the caller to be identifiable — pass `agent_id` (or `user_id`) in the tool context."
             }}
        end
    end
  end

  # ADR-0046 member 7, task `019fa504` stage 2 — the designer's decline.
  #
  # Argument shape is checked BEFORE the lookup, so a caller that sends a
  # blank reason against a real task hears about the reason rather than
  # about whichever check happened to run first.
  def execute("task_design_decline", args, context) do
    with {:ok, task_id} <- design_decline_task_id_arg(Map.get(args, "task_id")),
         {:ok, note} <- design_decline_reason_arg(Map.get(args, "reason")),
         {:ok, task} <- design_decline_task(task_id) do
      record_design_decline(task, note, context)
    end
  end

  # `context` was ignored here until task 019fb581 stage 3: detach is a WRITE
  # to the task's grant graph and was reachable by any runtime that knew two
  # ids. It now resolves its subject through the same
  # `canvas_authorization_actor/1` seam `task_attach_canvas` uses.
  def execute("task_detach_canvas", args, context) do
    task_id = Map.get(args, "task_id")
    canvas_id = Map.get(args, "canvas_id")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error,
         %{
           error: "task_detach_canvas requires task_id (string)",
           recoverable: true,
           suggestion: "Pass the UUID of the task as task_id"
         }}

      not is_binary(canvas_id) or canvas_id == "" ->
        {:error,
         %{
           error: "task_detach_canvas requires canvas_id (string)",
           recoverable: true,
           suggestion: "Pass the UUID of the canvas as canvas_id"
         }}

      true ->
        case CanvasAttachments.detach_canvas(
               canvas_authorization_actor(context),
               task_id,
               canvas_id
             ) do
          :ok ->
            {:ok, %{detached: true}}

          {:error, :not_found} ->
            {:error,
             %{
               error: "No attachment found for task #{task_id} and canvas #{canvas_id}",
               recoverable: false,
               suggestion: "Use task_list_canvases to see what is currently attached to the task."
             }}

          {:error, :task_not_found} ->
            {:error,
             %{
               error: "Task not found: #{task_id}",
               recoverable: false,
               suggestion: "Use task_list to find available tasks"
             }}

          {:error, :task_forbidden} ->
            {:error,
             %{
               error: "Access denied: you cannot detach a canvas from task #{task_id}.",
               code: :task_forbidden,
               recoverable: false,
               task_id: task_id,
               suggestion:
                 "Detaching is a write to the task, so you must already be working on it: its " <>
                   "assignee or phase assignee, a participant in its execution space, its " <>
                   "sponsor, or a member of its project's org."
             }}
        end
    end
  end

  # `context` was ignored here until task 019fb581 stage 4. Same door as the
  # two writes above, through `CanvasAttachments.ensure_task_touchable/3`.
  #
  # DEFENCE IN DEPTH, stated honestly rather than oversold: this tool returns
  # attachment METADATA (`attachment_id`, `canvas_id`, `title`, `note`,
  # `attached_at`, `canvas_present`), never a canvas document. Bodies go
  # through `canvas.describe`, which is a different surface with its own gate.
  # What the gate closes is the cheap enumeration of which canvases hang off a
  # task the caller has nothing to do with, and the titles that come with it.
  #
  # A DENIAL, NOT AN EMPTY LIST. The reasoning, and the `task_get` coupling it
  # rests on, are recorded in `Platform.Tasks.TaskAccess`'s moduledoc; the
  # coupling is pinned by a test rather than left to prose.
  def execute("task_list_canvases", args, context) do
    task_id = Map.get(args, "task_id")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error,
         %{
           error: "task_list_canvases requires task_id (string)",
           recoverable: true,
           suggestion: "Pass the UUID of the task as task_id"
         }}

      true ->
        case CanvasAttachments.ensure_task_touchable(
               task_id,
               canvas_authorization_actor(context),
               "task_list_canvases"
             ) do
          :ok ->
            entries = CanvasAttachments.list_task_canvases(task_id)

            canvases =
              Enum.map(entries, fn %{attachment: attachment, canvas: canvas_env} ->
                %{
                  attachment_id: attachment.id,
                  canvas_id: attachment.canvas_id,
                  title: canvas_env && canvas_env.title,
                  note: attachment.note,
                  attached_at: format_datetime(attachment.inserted_at),
                  canvas_present: not is_nil(canvas_env)
                }
              end)

            {:ok, %{canvases: canvases}}

          # Previously `{:ok, %{canvases: []}}`: an unknown task id read as
          # "no attachments". Now it matches its two siblings.
          {:error, :task_not_found} ->
            {:error,
             %{
               error: "Task not found: #{task_id}",
               recoverable: false,
               suggestion: "Use task_list to find available tasks"
             }}

          {:error, :task_forbidden} ->
            {:error,
             %{
               error: "Access denied: you cannot list the canvases attached to task #{task_id}.",
               code: :task_forbidden,
               recoverable: false,
               task_id: task_id,
               suggestion:
                 "Attachments name canvases that may live in spaces you are nowhere near, so " <>
                   "reading the list requires the same standing the writes do: the task's " <>
                   "assignee or phase assignee, a participant in its execution space, its " <>
                   "sponsor, or a member of its project's org. This is a refusal, not an empty " <>
                   "list. An empty list means the task has no attachments."
             }}
        end
    end
  end

  def execute("task_start", args, _context) do
    task_id = Map.get(args, "task_id")

    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        task =
          case {Map.get(args, "assignee_id"), Map.get(args, "assignee_type", "agent")} do
            {nil, _} ->
              task

            {assignee_id, assignee_type} ->
              case Tasks.update_task(task, %{
                     assignee_id: assignee_id,
                     assignee_type: assignee_type
                   }) do
                {:ok, updated} -> updated
                _ -> task
              end
          end

        case Tasks.transition_task(task, "in_progress") do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})

            {:ok,
             %{
               id: updated.id,
               title: updated.title,
               status: updated.status,
               assignee_id: updated.assignee_id,
               assignee_type: updated.assignee_type
             }}

          {:error, :invalid_transition} ->
            {:error, invalid_start_envelope(task)}

          {:error, :no_approved_plan} ->
            {:error,
             %{
               error:
                 "Cannot start task: no approved plan exists for task #{task.id}. Per ADR 0029, plan approval is the start signal.",
               recoverable: false,
               suggestion:
                 "Create a plan with plan_create, submit it with plan_submit, and have it approved (plan_approve) before starting the task. Approval transitions the task into in_progress automatically."
             }}

          {:error, :stack_plans_pending, %{stack_id: stack_id, waiting_on: waiting_on}} ->
            {:error, stack_plans_pending_envelope(stack_id, waiting_on)}

          {:error, reason} ->
            {:error, %{error: "Failed to start task: #{inspect(reason)}", recoverable: true}}
        end
    end
  end

  # ── task_ack (task 019f640d stage 5) ──────────────────────────────────
  # Emits an `execution.acked` runtime_event so the TaskRouter can extend
  # its safety-net timer and suppress the no-ack alert. Also writes to
  # LeaseManager directly as a belt-and-braces path — the router might
  # not be alive during a boot race, and LeaseManager is a global
  # singleton owned by Platform.Application.
  def execute("task_ack", args, context) do
    task_id = Map.get(args, "task_id")
    supplied_stage_id = Map.get(args, "stage_id")
    supplied_subagent_id = Map.get(args, "subagent_id")

    case validate_subagent_id(supplied_subagent_id) do
      {:error, envelope} ->
        {:error, envelope}

      {:ok, subagent_id} ->
        case Tasks.get_task_record(task_id) do
          nil ->
            {:error,
             %{
               error: "Task not found: #{task_id}",
               recoverable: false,
               suggestion:
                 "Verify the task_id matches your dispatch payload; use task_list to enumerate live tasks."
             }}

          _task ->
            case resolve_ack_stage_id(task_id, supplied_stage_id) do
              {:error, :no_running_stage} ->
                {:error,
                 %{
                   error:
                     "task_id=#{task_id} has no running stage — cannot ack without a stage_id.",
                   recoverable: true,
                   suggestion:
                     "Supply the stage_id from your dispatch payload, or call task_start first if the task hasn't been transitioned into in_progress yet."
                 }}

              {:ok, stage_id} ->
                emit_task_ack(task_id, stage_id, subagent_id, context)

              {:error, reason} ->
                {:error, supplied_stage_id_envelope(reason, supplied_stage_id, task_id)}
            end
        end
    end
  end

  # ── intent_ack (task 019f70b8 stage 3) ────────────────────────────────
  # The runtime-facing half of the meeting intent queue's ack contract.
  # Shares `validate_subagent_id/1` with task_ack verbatim — same three-way
  # error envelope, same 128-byte cap — because it is the same promise:
  # you cannot ack work you never spawned.
  #
  # ORDERING IS LOAD-BEARING. The subagent_id is validated BEFORE the queue
  # is touched, and a rejected ack records only a counter in the queue
  # server's own state. The ETS row stays byte-identical: still :dispatched,
  # subagent_id still nil, acked_at still nil, and no :intent_acked event on
  # the wire. A half-applied ack would be worse than no ack, because the
  # queue would believe a subagent exists that does not.
  def execute("intent_ack", args, _context) do
    intent_id = Map.get(args, "intent_id")
    supplied_subagent_id = Map.get(args, "subagent_id")
    supplied_status = Map.get(args, "status")
    note = Map.get(args, "note")

    with {:ok, meeting_id} <- locate_intent_meeting(intent_id),
         {:ok, ack_status} <- validate_intent_ack_status(supplied_status),
         {:ok, subagent_id} <-
           validate_intent_subagent_id(meeting_id, intent_id, supplied_subagent_id) do
      apply_intent_ack(meeting_id, intent_id, subagent_id, ack_status, note)
    end
  end

  # ── alarm_silence (task 019f6791-c01b stage 3) ────────────────────────
  # Operator escape hatch for the `execution.no_ack_timeout` alarm when
  # the MCP client cache lacks `task_ack`. Sets `silenced_until` on the
  # LeaseManager row so the router's `:check_no_ack` handler reschedules
  # instead of firing. Emits a persistent runtime_event AND telemetry
  # (bridged to Audit by Platform.Audit.TelemetryHandler).
  def execute("alarm_silence", args, context) do
    task_id = Map.get(args, "task_id")
    supplied_stage_id = Map.get(args, "stage_id")
    until_seconds = Map.get(args, "until_seconds")
    reason = Map.get(args, "reason")

    with :ok <- validate_alarm_silence_task_id(task_id),
         :ok <- validate_alarm_silence_until_seconds(until_seconds),
         :ok <- validate_alarm_silence_reason(reason),
         {:ok, _task} <- fetch_alarm_silence_task(task_id),
         {:ok, stage_id} <- resolve_ack_stage_id(task_id, supplied_stage_id) do
      until = DateTime.add(DateTime.utc_now(), until_seconds, :second)
      emit_alarm_silence(task_id, stage_id, until, reason, context)
    else
      {:error, :no_running_stage} ->
        {:error,
         %{
           error: "task_id=#{task_id} has no running stage — cannot silence without a stage_id.",
           recoverable: true,
           suggestion:
             "Supply the stage_id from your dispatch payload, or call task_start first if the task hasn't been transitioned into in_progress yet."
         }}

      {:error, envelope} when is_map(envelope) ->
        {:error, envelope}

      # Supplied-stage_id refusals from `resolve_ack_stage_id/2` — silencing
      # an alarm on a stage that is not this task's running stage suppresses
      # the wrong lease just as an ack does.
      {:error, reason} ->
        {:error, supplied_stage_id_envelope(reason, supplied_stage_id, task_id)}
    end
  end

  def execute("task_dependencies", args, _context) do
    task_id = Map.get(args, "task_id")

    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      %Task{} = task ->
        {:ok,
         %{
           deps: build_dependency_entries(task),
           unmet: task |> Tasks.unmet_dependencies() |> Enum.map(& &1.id),
           dependents: build_dependent_entries(task)
         }}
    end
  end

  # ── Stack tools (ADR 0041) ───────────────────────────────────────────────

  def execute("stack_create", args, _context) do
    slug = Map.get(args, "slug")

    attrs =
      %{
        project_id: Map.get(args, "project_id"),
        slug: slug,
        name: Map.get(args, "name"),
        description: Map.get(args, "description"),
        epic_id: Map.get(args, "epic_id"),
        sponsor_user_id: Map.get(args, "sponsor_user_id"),
        rollup_branch: slug && Stacks.rollup_branch_name(slug)
      }
      |> maybe_put_base_branch(Map.get(args, "base_branch"))
      |> maybe_put_boolean(:auto_plan, Map.get(args, "auto_plan"))
      |> maybe_put_boolean(:auto_accept_plan, Map.get(args, "auto_accept_plan"))

    case Stacks.create_stack(attrs) do
      {:ok, %Stack{} = stack} ->
        # Eagerly ensure the rollup branch exists on origin at create-time
        # (fire-and-forget, idempotent against the stack_start trigger).
        StackDeployer.handle_stack_created(stack)
        # Preload sponsor so the return envelope shows the shape a
        # subsequent `stack_get` would — the `create_stack` result does
        # not auto-preload :sponsor even when sponsor_user_id is set.
        # Mirrors the task_create envelope sponsor preload (ADR 0042).
        stack = Repo.preload(stack, :sponsor)

        {:ok,
         %{
           stack_id: stack.id,
           rollup_branch: stack.rollup_branch,
           sponsor: serialize_sponsor(stack.sponsor)
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        cond do
          slug_taken?(changeset) ->
            {:error,
             %{
               code: "slug_taken",
               error: "Slug '#{slug}' is already in use in this project",
               recoverable: true,
               suggestion: "Pick a different slug or reuse the existing stack"
             }}

          sponsor_fk_violation?(changeset) ->
            {:error,
             %{
               code: "sponsor_fk",
               error: "sponsor_user_id references an unknown user",
               recoverable: true,
               suggestion:
                 "Pass a valid user UUID for sponsor_user_id, or omit the key to leave the stack unsponsored"
             }}

          true ->
            {:error,
             %{
               error: "Failed to create stack: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion:
                 "Check that project_id, slug, and name are provided and that slug is valid"
             }}
        end
    end
  end

  # `stack_update` — mirrors `task_update`'s canonical nilable-semantics
  # contract for the stack surface (ADR 0042 Decision 8). Only supplied
  # keys are written; `sponsor_user_id` explicitly propagates `nil` to
  # clear the slot, everything else is dropped when nil (unset ≠ clear).
  def execute("stack_update", args, _context) do
    stack_id = Map.get(args, "stack_id")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           code: "stack_not_found",
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        attrs = build_stack_update_attrs(args)
        clear_conflict? = Map.get(args, "clear_conflict") == true

        # `clear_conflict` is the only status exit on this surface (task
        # 01a05393 stage 4). The precondition is checked BEFORE the attrs
        # write so a refused clear leaves the row untouched, and
        # `Stacks.clear_conflict/2` does the metadata+status write as one
        # changeset — the shape `Stack.changeset/2`'s conflict-held guard
        # requires. No general `status` writer exists here on purpose.
        with :ok <- stack_update_conflict_precheck(stack, clear_conflict?),
             {:ok, %Stack{} = updated} <- Stacks.update_stack(stack, attrs),
             {:ok, %Stack{} = updated} <- maybe_clear_stack_conflict(updated, clear_conflict?) do
          # Refresh :sponsor so the envelope reflects the current shape —
          # otherwise a caller that just cleared the sponsor via
          # `sponsor_user_id: nil` would still see the pre-update user
          # struct on the response.
          updated = Repo.preload(updated, :sponsor, force: true)
          Tasks.broadcast_board({:stack_updated, updated})

          envelope = serialize_stack(updated)

          if clear_conflict? do
            {:ok, Map.put(envelope, :conflict_cleared, true)}
          else
            {:ok, envelope}
          end
        else
          {:error, :not_conflicted} ->
            {:error,
             %{
               code: "not_conflicted",
               error:
                 "Stack #{stack.slug} is not conflict-held (status=#{stack.status}, no metadata.conflict); nothing to clear",
               recoverable: true,
               suggestion:
                 "Omit clear_conflict, or use stack_get to confirm the stack is blocked on a rollup-merge conflict"
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            if sponsor_fk_violation?(changeset) do
              {:error,
               %{
                 code: "sponsor_fk",
                 error: "sponsor_user_id references an unknown user",
                 recoverable: true,
                 suggestion:
                   "Pass a valid user UUID for sponsor_user_id, or set it to null to clear the sponsor"
               }}
            else
              {:error,
               %{
                 error: "Failed to update stack: #{inspect_errors(changeset)}",
                 recoverable: true,
                 suggestion: "Check that the provided values are valid"
               }}
            end
        end
    end
  end

  def execute("stack_get", args, _context) do
    stack_id = Map.get(args, "stack_id")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        members = Stacks.members(stack)
        merge_order_ids = stack |> Stacks.members_in_merge_order() |> Enum.map(& &1.id)
        {edges, cross_stack_deps} = classify_member_edges(members)

        # Serialization and the runnable partition live in
        # `stack_runnable_partition/2` so the mutation tools can report the
        # same status-aware `executable_now` (task 01a0562f-28ad).
        %{members: serialized, executable_now: executable_ids, blocked_now: blocked_ids} =
          stack_runnable_partition(stack, members)

        {:ok,
         %{
           stack: serialize_stack(stack),
           members: serialized,
           edges: edges,
           executable_now: executable_ids,
           blocked_now: blocked_ids,
           members_in_merge_order: merge_order_ids,
           cross_stack_deps: cross_stack_deps
         }}
    end
  end

  # `stack_get` also surfaces the stack-level phase_assignees default and a
  # per-member inherited-vs-overridden flag (see serialize_stack/1 and
  # serialize_stack_member/1).

  def execute("stack_list", args, _context) do
    filters =
      %{}
      |> maybe_put_filter(:project_id, Map.get(args, "project_id"))
      |> maybe_put_filter(:status, Map.get(args, "status"))

    # Task 01a05394-8300 stage 4. Mirrors `task_list` (task 01a04a7a): an
    # ENVELOPE, never a bare array, because a JSON array cannot say whether
    # it is the whole answer. `total` is a real `SELECT count(*)` over the
    # same filters (`Stacks.count_stacks/1`), the page is SQL-paged in the
    # same total order (`Stacks.list_stacks_page/2`; both share one private
    # query builder), and every row is `serialize_stack_row/1` — identity
    # and state, with `description` snippeted and the truncation VISIBLE —
    # rather than the full `stack_get` shape, whose `description` grows
    # unboundedly (abandon/complete append to it forever).
    {limit, offset} = ResultBound.page(args)

    total = Stacks.count_stacks(filters)

    rows =
      filters
      |> Stacks.list_stacks_page(limit: limit, offset: offset)
      |> Enum.map(&serialize_stack_row/1)

    # `offset + length(rows) < total`, never `length(rows) == limit`: the
    # cheap form reports "more" on a corpus of exactly `limit` and sends the
    # caller to fetch an empty page. See `task_list` for the full argument.
    {:ok,
     %{
       stacks: rows,
       total: total,
       limit: limit,
       offset: offset,
       has_more: offset + length(rows) < total
     }}
  end

  def execute("stack_add", args, _context) do
    stack_id = Map.get(args, "stack_id")
    task_id = Map.get(args, "task_id")

    case Stacks.add_task_with_report(stack_id, task_id) do
      {:ok, %Task{} = task, report} ->
        {:ok,
         %{
           task_id: task.id,
           stack_id: task.stack_id,
           stack_position: task.stack_position,
           status: task.status,
           warning: report.warning,
           gate_closed: report.gate_closed,
           waiting_on: report.waiting_on
         }}

      {:error, _} = err ->
        stack_add_error_envelope(err)

      {:error, _, _} = err ->
        stack_add_error_envelope(err)
    end
  end

  # `result.executable_now` from the context is the raw Kahn level-0 set over
  # every member regardless of status; the tool reports `stack_get`'s
  # status-aware partition instead, reloaded after the write committed.
  def execute("stack_add_dependency", args, _context) do
    stack_id = Map.get(args, "stack_id")
    from_task_id = Map.get(args, "from_task_id")
    to_task_id = Map.get(args, "to_task_id")
    kind = Map.get(args, "kind", "blocks")

    case Stacks.add_dependency_edge(stack_id, from_task_id, to_task_id, kind: kind) do
      {:ok, %{} = result} ->
        %{executable_now: executable_now, blocked_now: blocked_now} =
          stack_runnable_partition(stack_id)

        {:ok,
         %{
           from_task_id: result.from_task_id,
           to_task_id: result.to_task_id,
           kind: result.kind,
           executable_now: executable_now,
           blocked_now: blocked_now
         }}

      {:error, _} = err ->
        stack_dependency_error_envelope(err)

      {:error, _, _} = err ->
        stack_dependency_error_envelope(err)
    end
  end

  # `result.executable_now` from the context is the raw DAG level-0 set,
  # computed inside the transaction BEFORE the post-commit
  # `promote_freed_dependent/1` flips a freed `stack_pending` member; the
  # tool reloads `stack_get`'s status-aware partition after both have run.
  def execute("stack_remove_dependency", args, _context) do
    stack_id = Map.get(args, "stack_id")
    from_task_id = Map.get(args, "from_task_id")
    to_task_id = Map.get(args, "to_task_id")
    kind = Map.get(args, "kind", "blocks")

    case Stacks.remove_dependency_edge(stack_id, from_task_id, to_task_id, kind: kind) do
      {:ok, %{} = result} ->
        %{executable_now: executable_now, blocked_now: blocked_now} =
          stack_runnable_partition(stack_id)

        {:ok,
         %{
           from_task_id: result.from_task_id,
           to_task_id: result.to_task_id,
           executable_now: executable_now,
           blocked_now: blocked_now,
           promoted: Map.get(result, :promoted, [])
         }}

      {:error, _} = err ->
        stack_dependency_error_envelope(err)

      {:error, _, _} = err ->
        stack_dependency_error_envelope(err)
    end
  end

  def execute("stack_eject", args, _context) do
    stack_id = Map.get(args, "stack_id")
    task_id = Map.get(args, "task_id")

    case Stacks.eject_task(stack_id, task_id) do
      {:ok, %Task{} = task} ->
        {:ok, %{task_id: task.id, stack_id: stack_id}}

      {:error, :not_in_stack} ->
        {:error,
         %{
           code: "not_in_stack",
           error: "Task #{task_id} is not a member of stack #{stack_id}",
           recoverable: false,
           suggestion: "Use stack_get to inspect the stack's current members"
         }}

      {:error, {:has_dependents, dependents}} ->
        {:error,
         %{
           code: "has_dependents",
           error: "Task #{task_id} cannot be ejected: other in-stack members depend on it",
           recoverable: true,
           suggestion: "Eject the dependent members first or remove the dep edge before retrying",
           dependents: Enum.map(dependents, fn d -> %{id: d.id, title: d.title} end)
         }}

      {:error, :stack_not_found} ->
        {:error,
         %{
           error: "Stack not found: #{stack_id}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      {:error, :task_not_found} ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to eject task: #{inspect(reason)}",
           recoverable: true
         }}
    end
  end

  def execute("stack_abandon", args, _context) do
    stack_id = Map.get(args, "stack_id")
    reason = Map.get(args, "reason")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        case Stacks.abandon_stack(stack, reason) do
          {:ok, %Stack{} = updated} ->
            {:ok, serialize_stack(updated)}

          {:error, :invalid_stack_status} ->
            {:error,
             %{
               error:
                 "Stack #{stack.id} is already done; abandoning it would flip shipped work to abandoned. " <>
                   "Use stack_eject to detach an individual member.",
               recoverable: false
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to abandon stack: #{inspect_errors(changeset)}",
               recoverable: true
             }}
        end
    end
  end

  def execute("stack_complete", args, _context) do
    stack_id = Map.get(args, "stack_id")
    note = Map.get(args, "note")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        case Stacks.complete_stack(stack, note) do
          {:ok, %Stack{} = updated} ->
            {:ok, serialize_stack(updated)}

          {:error, :invalid_stack_status} ->
            {:error,
             %{
               error: "Stack #{stack.id} is abandoned and cannot be completed.",
               recoverable: false
             }}

          {:error, :members_not_done, %{pending: pending}} ->
            {:error,
             %{
               error: "Stack has members that are not done",
               code: "members_not_done",
               pending: pending,
               recoverable: true,
               suggestion:
                 "Finish or eject the pending members, then retry. Use stack_eject to remove a task without completing it."
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to complete stack: #{inspect_errors(changeset)}",
               recoverable: true
             }}
        end
    end
  end

  def execute("stack_start", args, _context) do
    stack_id = Map.get(args, "stack_id")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        case Stacks.start_stack(stack) do
          {:ok, %{stack: updated, started: started, parked: parked}} ->
            {:ok, stack_start_payload(updated, started, parked, [])}

          {:partial, %{stack: updated, started: started, parked: parked, errors: errors}} ->
            {:ok, stack_start_payload(updated, started, parked, errors)}

          {:error, :invalid_stack_status} ->
            {:error,
             %{
               error:
                 "Stack is not at `forming`; only forming stacks can be started. This stack is #{stack.status}.",
               recoverable: false,
               suggestion: stack_start_refusal_suggestion(stack)
             }}

          {:error, :stack_plans_pending, %{waiting_on: waiting_on}} ->
            # ADR 0042 Decision 4: refuse to start when any member is still
            # missing an approved plan. Surface the blocking members — title,
            # id, and WHY — so the caller can chase them down.
            {:error,
             %{
               error:
                 "Stack cannot start yet — the following members are missing an approved plan: " <>
                   Enum.join(describe_waiting_on(stack.id, waiting_on), ", "),
               recoverable: true,
               suggestion:
                 "Approve the missing plans (via plan_approve) before calling stack_start again."
             }}

          {:error, {:rollup_branch_unavailable, reason}} ->
            # Task 01a05392 stage 1: the rollup branch is now created
            # SYNCHRONOUSLY before any member is promoted, so a git failure
            # fails the whole start rather than quietly dispatching members off
            # the default branch. Nothing started and the stack is still
            # `forming`, so this is retryable — but the caller has to be told
            # WHICH branch and WHY, or "failed to start" is unactionable.
            {:error,
             %{
               error:
                 "Stack not started — the rollup branch `#{stack.rollup_branch}` could not be " <>
                   "created on origin (#{inspect(reason)}). No members were started and the " <>
                   "stack is still `forming`.",
               recoverable: true,
               suggestion:
                 "Fix the underlying git failure (check the project's repo_url and that the " <>
                   "base branch `#{stack.base_branch}` exists on origin), then call stack_start again."
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error,
             %{
               error: "Failed to start stack: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion: "Check the stack's current status"
             }}

          {:error, other} ->
            {:error,
             %{
               error: "Failed to start stack: #{inspect(other)}",
               recoverable: true
             }}
        end
    end
  end

  # Task 01a05392 stage 3 — the named retry for a paused stack member.
  #
  # Considered and REJECTED: overloading `task_update status: in_review` so
  # that a no-op status write re-runs the merge. That attaches a real side
  # effect to a call that is a status NO-OP (in_review -> in_review); it
  # appears in no tool list; its documentation would have to describe a side
  # effect that fires on a non-transition, which reads as a bug to every
  # future reader; and `task_update` returns a task, so the caller learns
  # nothing about whether the merge succeeded, was already merged, or
  # diverged again. A named tool is in `tools/list`, is greppable, and
  # returns the outcome. Do NOT add the overload as well — two triggers for
  # one action is two things to keep in sync.
  #
  # BINDING (stage 2 finding): the deployer is called with the task ID, not
  # the struct. `StackDeployer.merge_member_into_rollup(%TaskRecord{})`
  # reloads nothing — its already-merged short-circuit and the divergence
  # dedupe read whatever metadata they are handed — so only the id arity is
  # guaranteed to judge the row as it is at the moment of the call.
  def execute("stack_retry_member_merge", args, _context) do
    with {:ok, task_id} <- require_string(args, "task_id", "stack_retry_member_merge") do
      case Tasks.get_task_record(task_id) do
        nil ->
          {:error,
           %{
             code: :task_not_found,
             error: "Task not found: #{inspect(task_id)}",
             recoverable: false,
             suggestion:
               "Pass the MEMBER task id (the blocker's `member_task_id`), not the stack id."
           }}

        %Task{stack_id: nil} = task ->
          {:error,
           %{
             code: :not_in_stack,
             error:
               "Task #{task.id} is not a stack member; there is no rollup branch to merge it into.",
             recoverable: false,
             suggestion:
               "stack_retry_member_merge only applies to tasks with a `stack_id`. " <>
                 "Check `task_get` — a task that was ejected from its stack lands via its own PR."
           }}

        %Task{stack_id: stack_id} = task when is_binary(stack_id) ->
          rollup_branch =
            case Stacks.get_stack(stack_id) do
              %Stack{rollup_branch: branch} -> branch
              _ -> nil
            end

          task.id
          |> StackDeployer.merge_member_into_rollup()
          |> retry_merge_envelope(task, rollup_branch)
      end
    end
  end

  def execute("stack_start_planning", args, _context) do
    stack_id = Map.get(args, "stack_id")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        case Stacks.start_planning(stack) do
          {:ok,
           %{
             stack: updated,
             planning: planning,
             unassigned: unassigned,
             edges_authored: edges_authored,
             edges_skipped_reason: edges_skipped_reason,
             mode: mode,
             waves_total: waves_total
           }} ->
            {:ok,
             stack_start_planning_payload(
               updated,
               planning,
               unassigned,
               [],
               edges_authored,
               edges_skipped_reason,
               mode: mode,
               waves_total: waves_total
             )}

          {:partial,
           %{
             stack: updated,
             planning: planning,
             unassigned: unassigned,
             errors: errors,
             edges_authored: edges_authored,
             edges_skipped_reason: edges_skipped_reason,
             mode: mode,
             waves_total: waves_total
           }} ->
            {:ok,
             stack_start_planning_payload(
               updated,
               planning,
               unassigned,
               errors,
               edges_authored,
               edges_skipped_reason,
               mode: mode,
               waves_total: waves_total
             )}

          {:noop, reason} ->
            # Stack v2 (task 019f487e stage 3): manual-mode idempotency
            # short-circuit. Surface as a soft-success payload so the
            # caller can re-render UI state without treating it as an
            # error, but include the reason for LiveView telemetry.
            {:ok,
             %{
               stack_id: stack.id,
               planning: [],
               errors: [],
               noop: true,
               noop_reason: reason
             }}

          {:error, :cycle, path} ->
            {:error,
             %{
               error: "Cycle detected in stack DAG",
               recoverable: false,
               cycle_path: Enum.map(path, & &1.id),
               suggestion: "Remove one edge to break the cycle before re-invoking"
             }}

          {:error, :cross_stack_dep, %{from: from, to_task_id: to_id}} ->
            {:error,
             %{
               error: "Cross-stack dependency detected",
               recoverable: false,
               from_task_id: from.id,
               to_task_id: to_id,
               suggestion: "Eject one endpoint or add both tasks to the same stack"
             }}

          {:error, :stack_not_found} ->
            {:error,
             %{
               error: "Stack not found: #{inspect(stack_id)}",
               recoverable: false,
               suggestion: "Use stack_list to find available stacks"
             }}

          {:error, other} ->
            {:error,
             %{
               error: "Failed to start planning: #{inspect(other)}",
               recoverable: true
             }}
        end
    end
  end

  def execute("stack_assign_agents", args, _context) do
    stack_id = Map.get(args, "stack_id")

    case stack_id && Stacks.get_stack(stack_id) do
      nil ->
        {:error,
         %{
           error: "Stack not found: #{inspect(stack_id)}",
           recoverable: false,
           suggestion: "Use stack_list to find available stacks"
         }}

      %Stack{} = stack ->
        attrs_by_phase = build_stack_assignee_attrs(args)

        case Stacks.set_stack_phase_assignees(stack, attrs_by_phase) do
          {:ok, %{stack: updated, percolated: percolated, skipped: skipped}} ->
            {:ok,
             %{
               stack_id: updated.id,
               phase_assignees: Stacks.stack_phase_assignees(updated),
               percolated: Enum.map(percolated, & &1.id),
               skipped:
                 Enum.map(skipped, fn %Task{id: id} ->
                   %{task_id: id, reason: "individual_override"}
                 end)
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error,
             %{
               error: "Failed to assign agents: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion: "Check the assignee ids are valid"
             }}

          {:error, other} ->
            {:error,
             %{
               error: "Failed to assign agents: #{inspect(other)}",
               recoverable: true
             }}
        end
    end
  end

  # ── Plan / Stage / Validation tools ──────────────────────────────────────

  def execute("plan_create", args, _context) do
    task_id = Map.get(args, "task_id")
    raw_stages_input = Map.get(args, "stages", [])

    # Task 01a006d1 stage 3 — the gate runs BEFORE the rewrite pipe and before
    # the transaction opens, so a refused plan writes nothing at all. Rejecting
    # after a draft row exists would leave the author unable to retry
    # (`plan_create` refuses while a draft/pending_review plan is live), which
    # is the same lockout this guard exists to prevent.
    #
    # Task 01a00b91 stage 3 chains a SECOND guard into the same pre-transaction
    # position for the same reason: a manual_approval that cannot name the UI
    # surface it will show is refused before anything is written. Both guards
    # run before `do_plan_create/2`; neither may move below the rewrite pipe.
    #
    # PROBE RECORD (01a00b91 stage 5). PROBE C moved the
    # `detect_unnamed_manual_gate/1` call from here to AFTER `Tasks.create_plan/1`,
    # returning the same envelope from inside the transaction so the draft row
    # committed. Predicted: the persistence control detonates and NOTHING ELSE
    # does. That is exactly what happened, on the full suite — one failure,
    # `assert Tasks.latest_plan(task.id) == nil`, left a `%Plan{status: "draft"}`.
    # Every envelope assertion in the same test passed under the mutant, which
    # is the point: the envelope is byte-identical whether or not a draft was
    # left behind, so the nil check is the ONLY instrument that sees this
    # ordering. Delete that one assertion and this line is free to move.
    # (Two `Platform.Execution.ProofRunTest` failures in the same run are the
    # known IO-contention flake; re-run green in isolation.)
    case Platform.Tasks.PlanEngine.detect_e2e_host_collision(raw_stages_input) do
      {:error, info} ->
        {:error, e2e_host_collision_envelope(info)}

      :ok ->
        case Platform.Tasks.PlanEngine.detect_unnamed_manual_gate(raw_stages_input) do
          {:error, info} ->
            {:error, unnamed_manual_gate_envelope(info)}

          :ok ->
            do_plan_create(task_id, raw_stages_input)
        end
    end
  end

  # Task 01a006c2 stage 3 — `plan_get` widened with an explicit,
  # default-preserving `status`. Deliberately NOT a sibling tool: a sibling
  # means a caller must know to try a second tool after the first says
  # not-found, which is precisely the round trip that cost an agent a cycle
  # when it could not read a rejected plan's `rejection_reason`.
  #
  # The `"id"` alias is kept because the registration declares it — removing
  # it here would make the registration lie to callers. What is added is the
  # guard: a call naming NO task used to fall into `current_plan(nil)` and
  # come back "No approved plan for task", a confident answer about a task
  # the caller never identified.
  #
  # Cross-tenant fix (01a006c2, post-e2e): this clause used to take `_context`
  # and no authorization ran anywhere in the chain, so any agent that could
  # name a task_id read its plan. Stage 3 widened the OUTPUT CLASS — rejected
  # and pending_review plans carry `rejection_reason` and
  # `architecture_verdict`, human-written prose — which re-opened the
  # authorization question on a line the stage never edited. The check is the
  # same `authorize_review_access/2` stages 1 and 2 use, and it runs BEFORE
  # `plan_get_resolution/1` and any serialization so the denial envelope
  # carries no plan id, no status, no rejection prose. It runs before the
  # status parse too: a denied caller must not learn which statuses exist.
  # Omitting `status` is authorized identically — that is the path every
  # existing caller uses — and its not-found envelope is untouched.
  def execute("plan_get", args, context) do
    task_id = Map.get(args, "task_id") || Map.get(args, "id")

    with {:ok, task_id} <- require_string(%{"task_id" => task_id}, "task_id", "plan_get"),
         :ok <- authorize_review_access(context, task_id),
         {:ok, resolution} <- plan_get_resolution(args),
         {:ok, plan} <- resolve_plan_by_status(task_id, resolution) do
      {:ok, serialize_plan(Repo.preload(plan, stages: :validations))}
    end
  end

  def execute("plan_submit", args, _context) do
    plan_id = Map.get(args, "plan_id")

    case Tasks.get_plan(plan_id) do
      nil ->
        {:error,
         %{
           error: "Plan not found: #{plan_id}",
           recoverable: false,
           suggestion: "Use plan_create to create a plan first"
         }}

      plan ->
        case Tasks.submit_plan_for_review(plan) do
          {:ok, updated} ->
            {:ok, serialize_plan(Repo.preload(updated, :stages))}

          # Task 01a0588e stage 2. The refusal NAMES THE OMISSION, because
          # the caller's mistake is invisible from a stage count: a plan
          # carrying only the engine's synthesized task-level review stage
          # has one stage and no work in it. Recoverable — nothing was
          # written, the plan is still a draft, and plan_update fixes it in
          # place. No error `code` is added: plan_submit does not carry a
          # code taxonomy and inventing one here would be the only member of
          # it. Tone mirrors require_plan_update_stages/1, which refuses the
          # same omission one call earlier.
          {:error, :no_authored_stages} ->
            {:error,
             %{
               error:
                 "plan_submit: this plan has no planner-authored implementation stage, so there " <>
                   "is nothing for the architecture review to review or for an executor to run. " <>
                   "A plan carrying only the engine's synthesized task-level review stage counts " <>
                   "as none — that stage is a review host the engine adds, not work you authored.",
               recoverable: true,
               suggestion:
                 "Add at least one implementation stage with plan_update (same shape and " <>
                   "contract as plan_create's `stages`), then submit again — or discard the " <>
                   "draft with plan_reject. The plan is untouched and still in draft."
             }}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error:
                 "Plan must be in draft status to submit for review (current: #{plan.status})",
               recoverable: false,
               suggestion: "Only draft plans can be submitted for review"
             }}

          {:error, reason} ->
            {:error,
             %{
               error: "Failed to submit plan: #{inspect(reason)}",
               recoverable: true,
               suggestion: "Check the plan status"
             }}
        end
    end
  end

  def execute("plan_approve", args, _context) do
    plan_id = Map.get(args, "plan_id")
    approved_by = Map.get(args, "approved_by", "system")

    case get_by_uuid(Plan, plan_id) do
      nil ->
        {:error,
         %{
           error: "Plan not found: #{plan_id}",
           recoverable: false,
           suggestion: "Use plan_get to find the plan ID for a task"
         }}

      plan ->
        case Tasks.approve_plan(plan, approved_by) do
          {:ok, approved} ->
            {:ok,
             %{
               id: approved.id,
               task_id: approved.task_id,
               status: approved.status,
               approved_by: approved.approved_by
             }}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Cannot approve plan with status #{plan.status}. Must be pending_review.",
               recoverable: true,
               suggestion: "Use plan_submit first to move the plan to pending_review"
             }}

          # ADR-0046 member 5 stage 3. This tool is the agent-reachable
          # approval writer: it lives in the `plan` capability bundle and
          # defaults `approved_by` to `"system"`, so without an explicit
          # arm here the refusal would arrive as an untyped
          # "Failed to approve plan" with no suggestion. The guard itself
          # is in `Tasks.approve_plan/3`, not here — this arm only names it.
          {:error, :architecture_gate_open} ->
            {:error,
             %{
               error:
                 "Plan #{plan_id} is held by the architecture gate: the architect has not returned a verdict yet.",
               recoverable: true,
               suggestion:
                 "Wait for the architect's verdict or the gate deadline. An agent cannot approve past an open gate; a human reviewer can, from the task UI."
             }}

          {:error, reason} ->
            {:error, %{error: "Failed to approve plan: #{inspect(reason)}", recoverable: true}}
        end
    end
  end

  # Task 01a05b32 stage 1 — the planner's self-service draft exit. A draft
  # plan blocks every subsequent plan_create, and until this tool existed a
  # stuck draft had NO reject affordance anywhere (the UI control only
  # appears once the plan reaches pending_review), so the only exit was a
  # human. The tool GATES ON DRAFT here, in the tool layer, even though
  # `Tasks.reject_plan/3` now also accepts draft for this path: the
  # pending_review / approved / completed statuses stay immutable to agents
  # (the Plan-State Lock), and each refusal names the right path for the
  # status the caller actually hit. The rejection must NOT transition the
  # task — the draft never moved it past planning, so plan_create must work
  # immediately after.
  def execute("plan_reject", args, context) do
    plan_id = Map.get(args, "plan_id")

    with {:ok, rejection_reason} <-
           require_non_blank_string(args, "rejection_reason", "plan_reject") do
      case get_by_uuid(Plan, plan_id) do
        nil ->
          {:error,
           %{
             error: "Plan not found: #{plan_id}",
             recoverable: false,
             suggestion:
               "Use plan_get with the task_id and status \"latest\" to find the plan ID for a task"
           }}

        %Plan{status: "draft"} = plan ->
          {rejected_by, actor_type} = plan_reject_actor(args, context)

          case Tasks.reject_plan(plan, rejected_by, rejection_reason) do
            {:ok, rejected} ->
              emit_plan_rejected(rejected, rejected_by, actor_type)

              {:ok, serialize_plan(Repo.preload(rejected, :stages))}

            {:error, reason} ->
              {:error,
               %{
                 error: "Failed to reject plan: #{inspect(reason)}",
                 recoverable: true,
                 suggestion: "Check the plan status and retry"
               }}
          end

        %Plan{status: status} = plan ->
          {:error,
           %{
             error: "plan_reject only accepts draft-status plans (current: #{plan.status}).",
             recoverable: false,
             suggestion: plan_reject_suggestion(status)
           }}
      end
    end
  end

  # ── Task 01a05b32 stage 2 — the planner's in-place draft correction ──────
  #
  # plan_reject (stage 1) is the DISCARD half of the draft exit: throw the
  # wrong draft away and mint a new plan row with plan_create. plan_update is
  # the CORRECT half: fix the wrong draft (stages, positions, validations,
  # evaluation_payloads) where it stands and plan_submit it — plan_id and
  # version stay stable, so a caller holding the old plan id keeps working.
  #
  # The tool GATES ON DRAFT through `Tasks.replace_plan_stages/3`'s
  # :invalid_transition, the same error contract plan_reject uses: a
  # pending_review plan is the Plan-State Lock itself (agents cannot withdraw
  # a submitted plan), and approved/completed plans are immutable here. Each
  # refusal names the path the caller should take INSTEAD.
  #
  # The pre-persistence passes are the SAME ones plan_create runs, in the
  # same order (collision + unnamed-gate detectors, then the
  # route/manual-approval/zero-validation rewrite pipe). Skipping them would
  # let an updated draft carry e2e_behavior checks that never got lifted into
  # the task-level review stage — an inconsistency plan_create cannot
  # produce. They also run BEFORE anything is written, so a refusal leaves
  # the draft's CURRENT tree byte-identical (recoverable: fix and retry).
  def execute("plan_update", args, context) do
    plan_id = Map.get(args, "plan_id")

    with {:ok, stages_input} <- require_plan_update_stages(args) do
      case get_by_uuid(Plan, plan_id) do
        nil ->
          {:error,
           %{
             error: "Plan not found: #{plan_id}",
             recoverable: false,
             suggestion:
               "Use plan_get with the task_id and status \"draft\" (or \"latest\") to find the draft plan ID for a task"
           }}

        plan ->
          case Platform.Tasks.PlanEngine.detect_e2e_host_collision(stages_input) do
            {:error, info} ->
              {:error, e2e_host_collision_envelope(info)}

            :ok ->
              case Platform.Tasks.PlanEngine.detect_unnamed_manual_gate(stages_input) do
                {:error, info} ->
                  {:error, unnamed_manual_gate_envelope(info)}

                :ok ->
                  do_plan_update(plan, stages_input, args, context)
              end
          end
      end
    end
  end

  # ── ADR-0046 member 5 stage 4: the architect's verdict surface ────────
  #
  # ONE of the two ways a verdict gets in (the other is
  # `Handlers.ArchitectureReviewPlan.handle_output/3`, for an external
  # architect that can only reply with text). Neither re-implements the
  # state machine: both end in `Tasks.resolve_architecture_gate/3`, the
  # single exit stage 3 built, which is one-shot because it arbitrates on
  # the persisted row. A duplicate call is therefore harmless — it lands
  # on `gate_already_resolved` and changes nothing.
  #
  # THE CONTRACT IS ENFORCED HERE, NOT REQUESTED IN THE PROMPT.
  # `0046-design-and-architecture-phases-in-planning.md § Architect prompt contract`
  # says the architect rejects for architecture and explicitly
  # not for taste, naming or style. "Don't reject for style" is
  # unenforceable as prose — it produces a differently-worded rejection,
  # not a better one. A closed `constraint` vocabulary means a style
  # objection has NO REPRESENTABLE VALUE. Stage 1 asserted that at the
  # schema layer; this asserts it at the boundary an agent actually
  # touches, because the schema is only reached by callers who already
  # decided to write.
  #
  # Every refusal carries a `code` and every code is named in the tool's
  # `limitations`, with a test that the two sets are equal.
  def execute("plan_architecture_verdict", args, context) do
    plan_id = Map.get(args, "plan_id")

    with {:ok, plan} <- verdict_plan(plan_id),
         {:ok, resolution} <- verdict_resolution_arg(Map.get(args, "verdict")),
         {:ok, summary} <- verdict_summary_arg(Map.get(args, "summary")),
         {:ok, findings} <- verdict_findings_arg(Map.get(args, "findings"), resolution, plan),
         :ok <- verdict_gate_open(plan) do
      resolve_architecture_verdict(plan, resolution, summary, findings, context)
    end
  end

  # Task 019fa61c stage 3. The counterpart to `plan_architecture_verdict`
  # above, for the OTHER architect surface — and the reason this task
  # exists. `review_plan` was observable because it had a tool that wrote
  # a row; `audit_diff` asked for a side effect in prose and named no tool
  # at all, so 28 fires in a 3.3-hour window left no evidence anywhere.
  #
  # This clause validates and refuses; it does not implement the state
  # machine. Everything past the argument checks goes through
  # `StageAudit.record_note/3`, the single writer that persists the row
  # and posts the annotation together. The tool RESOLVES the stage itself
  # rather than letting `record_note/3` do it, for the same reason
  # `task_design_decline` resolves its own task: it is what separates
  # `stage_not_found` from `audit_not_open`, and an architect who mistyped
  # a stage id must not be told the audit already closed.
  #
  # Every refusal carries a `code` and every code is named in the tool's
  # `limitations`, with a test that the two sets are equal.
  def execute("stage_architecture_audit", args, context) do
    with {:ok, stage} <- stage_audit_stage(Map.get(args, "stage_id")),
         {:ok, summary} <- stage_audit_summary_arg(Map.get(args, "summary")),
         {:ok, findings} <- stage_audit_findings_arg(Map.get(args, "findings")) do
      record_stage_audit_note(stage, summary, findings, context)
    end
  end

  def execute("stage_start", args, _context) do
    stage_id = Map.get(args, "stage_id")

    case PlanEngine.start_stage(stage_id) do
      {:ok, stage} ->
        {:ok, serialize_stage(stage)}

      {:error, :invalid_transition} ->
        {:error,
         %{
           error: "Stage must be in pending status to start",
           recoverable: false,
           suggestion: "Check the stage's current status with stage_list"
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to start stage: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Verify the stage_id is valid"
         }}
    end
  end

  def execute("stage_list", args, _context) do
    with {:ok, plan_id} <- resolve_stage_list_plan(args) do
      {limit, offset} = ResultBound.page(args)

      # Task 01a049de. Measured live: 4 stages = 47_048 bytes, of which stage
      # `description` plus validation `evidence`/`evaluation_payload` is 89.9%.
      # A plan's stage count is small, so `limit` matters far less here than
      # the per-field snippet does — `evidence` is the field that grows without
      # bound, because runners write logs into it.
      stages =
        plan_id
        |> Tasks.list_stages()
        |> Repo.preload(:validations)
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.map(&serialize_stage_with_validations(&1, full_detail?(args)))

      {:ok, stages}
    end
  end

  def execute("validation_evaluate", args, _context) do
    validation_id = Map.get(args, "validation_id")
    status = Map.get(args, "status")
    evidence = Map.get(args, "evidence", %{})
    evaluated_by = Map.get(args, "evaluated_by", "system")

    unless status in ~w(passed failed) do
      {:error,
       %{
         error: "Invalid status: #{inspect(status)}. Must be \"passed\" or \"failed\"",
         recoverable: true,
         suggestion: "Use status \"passed\" or \"failed\""
       }}
    else
      case PlanEngine.evaluate_validation(validation_id, %{
             status: status,
             evidence: evidence,
             evaluated_by: evaluated_by
           }) do
        {:ok, validation} ->
          {:ok, serialize_validation(validation)}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to evaluate validation: #{inspect(reason)}",
             recoverable: true,
             suggestion: "Verify the validation_id is valid"
           }}
      end
    end
  end

  def execute("validation_pass", args, context) do
    execute(
      "validation_evaluate",
      %{
        "validation_id" => Map.get(args, "validation_id"),
        "status" => "passed",
        "evidence" => Map.get(args, "evidence", %{}),
        "evaluated_by" => Map.get(args, "evaluated_by", "system")
      },
      context
    )
  end

  def execute("stage_complete", args, context) do
    stage_id = Map.get(args, "stage_id") || Map.get(args, "id")
    completed_by = Map.get(context, :agent_id) || Map.get(context, :user_id) || "agent"

    # NOTE: superseded-plan guard runs BEFORE :not_running / :pending_validations
    # so an executor whose task was returned-to-planning mid-flight gets a
    # decisive stop signal (recoverable: false) rather than a retry-friendly
    # "pending validations" hint. `&&` (not `||`) is the correct operator for
    # the negative-guard pattern here: a `false` helper result short-circuits
    # to `false`, which matches `false <-` and continues the chain; a `true`
    # result yields `{:error, :plan_superseded}` for the else branch.
    with %Stage{} = stage <- get_by_uuid(Stage, stage_id),
         %Plan{} = current_plan <- Repo.get(Plan, stage.plan_id),
         false <- plan_superseded?(current_plan) && {:error, :plan_superseded},
         true <- stage.status in ["running", "passed"] || {:error, :not_running},
         validations <- Tasks.list_validations(stage.id),
         true <-
           Enum.all?(validations, &(&1.status == "passed")) || validations == [] ||
             {:error, :pending_validations},
         # Scoped to the asserted stage (task 019fec3a): the admission guard
         # above deliberately accepts an already-`passed` stage so idempotent
         # re-calls succeed, but such a call must not advance a stage it does
         # not name. `advance/2` no-ops unless `stage` IS the current stage.
         {:ok, advanced_plan} <-
           PlanEngine.advance(stage.plan_id,
             stage_id: stage.id,
             completed_by: completed_by
           ) do
      fresh_stage = Enum.find(advanced_plan.stages || [], &(&1.id == stage.id))

      {:ok,
       %{
         stage_id: stage.id,
         stage_status: fresh_stage && fresh_stage.status,
         plan_id: advanced_plan.id,
         plan_status: advanced_plan.status
       }}
    else
      nil ->
        {:error,
         %{
           error: "Stage not found: #{inspect(stage_id)}",
           recoverable: true,
           suggestion: "Verify the stage_id is valid"
         }}

      {:error, :plan_superseded} ->
        {:error,
         %{
           error: "plan_superseded",
           recoverable: false,
           suggestion:
             "This task has been returned to planning; the current plan is superseded. Stop this executor — a new plan will dispatch a fresh execution when approved."
         }}

      {:error, :not_running} ->
        {:error,
         %{
           error: "Stage must be running before it can be completed",
           recoverable: false,
           suggestion: "Use stage_list to inspect the current stage status"
         }}

      {:error, :pending_validations} ->
        {:error,
         %{
           error: "Stage still has pending or failed validations",
           recoverable: true,
           suggestion: "Use validation_pass or validation_evaluate before stage_complete"
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to complete stage: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Verify the stage state and validations"
         }}
    end
  end

  def execute("report_blocker", args, context) do
    with :ok <- validate_blocker_args(args),
         :ok <- refuse_infra_needs_human(args) do
      record_blocker(args, context)
    end
  end

  def execute("validation_list", args, _context) do
    stage_id = Map.get(args, "stage_id")
    validations = Tasks.list_validations(stage_id)
    {:ok, Enum.map(validations, &serialize_validation/1)}
  end

  def execute("prompt_template_list", _args, _context) do
    templates = Platform.Orchestration.PromptTemplates.list_templates()

    result =
      Enum.map(templates, fn t ->
        %{
          slug: t.slug,
          name: t.name,
          description: t.description,
          variables: t.variables,
          updated_by: t.updated_by,
          updated_at: format_datetime(t.updated_at)
        }
      end)

    {:ok, result}
  end

  def execute("prompt_template_update", args, _context) do
    slug = Map.get(args, "slug")
    content = Map.get(args, "content")

    case Platform.Orchestration.PromptTemplates.get_template_by_slug(slug) do
      nil ->
        {:error,
         %{
           error: "Template not found: #{slug}",
           recoverable: true,
           suggestion: "Use prompt_template_list to see available slugs, or check spelling"
         }}

      template ->
        case Platform.Orchestration.PromptTemplates.update_template(template, %{
               "content" => content,
               "updated_by" => "agent"
             }) do
          {:ok, updated} ->
            {:ok,
             %{
               slug: updated.slug,
               name: updated.name,
               description: updated.description,
               variables: updated.variables,
               updated_by: updated.updated_by,
               updated_at: format_datetime(updated.updated_at)
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update template: #{inspect_errors_safe(changeset)}",
               recoverable: true,
               suggestion: "Check that content is not empty"
             }}
        end
    end
  end

  # ── Federation tools ─────────────────────────────────────────────────

  def execute("federation_status", _args, _context) do
    status = Platform.Federation.federation_status()

    runtimes =
      Enum.map(status, fn r ->
        %{
          runtime_id: r.runtime_id,
          agent_name: r.agent_name,
          agent_slug: r.agent_slug,

          # 1. Connection. `online` is the socket and only the socket.
          online: r.online,
          connected_at: format_datetime(r.connected_at),
          last_seen_at: format_datetime(r.last_seen_at),
          last_connected_at: format_datetime(r.last_connected_at),

          # 2. Build. Independent of connection: a runtime that is offline
          # right now still reports the build from its last handshake.
          client_build: format_build(r.client_build),
          process_started_at: format_datetime(r.process_started_at),

          # 3. Proven — what core observed, `never` where it observed nothing.
          proven: format_proven(r.proven),

          # 4. Declared — what the runtime asserted. Last, after everything
          # core measured itself.
          declared_features: r.declared_features
        }
      end)

    {:ok, %{runtimes: runtimes}}
  end

  # ── Memory tool dispatch (ADR-0041 T5) ──────────────────────────────────
  # Thin adapter: every clause gates through `Wiki.Routing` then routes to
  # `Wiki` (pages/private) or `Wiki.Journal` (journal). No direct `Repo`
  # calls here — the routing+domain modules own DB access.

  def execute("memory_view", args, context) do
    with {:ok, path} <- require_string(args, "path", "memory_view"),
         agent = load_agent(context),
         :ok <- gate_to_envelope(Routing.gate_read(agent, path)) do
      class = Routing.classify(path)
      workspace_id = Map.get(args, "workspace_id")
      view_range = Map.get(args, "view_range")

      case class.kind do
        :page -> view_page(path, view_range, workspace_id, class)
        :private -> view_page(path, view_range, workspace_id, class)
        :journal -> view_journal(path, class, view_range, workspace_id)
      end
    end
  end

  def execute("memory_create", args, context) do
    with {:ok, path} <- require_string(args, "path", "memory_create"),
         {:ok, text} <- require_string(args, "file_text", "memory_create"),
         agent = load_agent(context) do
      class = Routing.classify(path)
      workspace_id = Map.get(args, "workspace_id")

      existing =
        if class.kind in [:page, :private],
          do: Wiki.get_page(path, workspace_id: workspace_id),
          else: nil

      gate_opts = if existing, do: [existing_page: existing], else: []

      case gate_to_envelope(Routing.gate_write(agent, path, gate_opts)) do
        :ok ->
          do_memory_create(class, path, text, agent, workspace_id)

        {:error, _} = err ->
          err
      end
    end
  end

  def execute("memory_str_replace", args, context) do
    with {:ok, path} <- require_string(args, "path", "memory_str_replace"),
         {:ok, old_str} <- require_string(args, "old_str", "memory_str_replace"),
         {:ok, new_str} <- require_string(args, "new_str", "memory_str_replace"),
         agent = load_agent(context),
         :ok <- ensure_page_kind(path, "memory_str_replace"),
         existing = Wiki.get_page(path, workspace_id: Map.get(args, "workspace_id")),
         :ok <- gate_to_envelope(Routing.gate_write(agent, path, existing_page: existing)) do
      apply_str_replace(existing, path, old_str, new_str, agent, Map.get(args, "workspace_id"))
    end
  end

  def execute("memory_insert", args, context) do
    with {:ok, path} <- require_string(args, "path", "memory_insert"),
         {:ok, insert_text} <- require_string(args, "insert_text", "memory_insert"),
         {:ok, insert_line} <- require_integer(args, "insert_line", "memory_insert"),
         agent = load_agent(context),
         :ok <- ensure_page_kind(path, "memory_insert"),
         existing = Wiki.get_page(path, workspace_id: Map.get(args, "workspace_id")),
         :ok <- gate_to_envelope(Routing.gate_write(agent, path, existing_page: existing)) do
      apply_insert(existing, path, insert_line, insert_text, agent, Map.get(args, "workspace_id"))
    end
  end

  def execute("memory_delete", args, context) do
    with {:ok, path} <- require_string(args, "path", "memory_delete"),
         agent = load_agent(context),
         :ok <- ensure_page_kind(path, "memory_delete"),
         existing = Wiki.get_page(path, workspace_id: Map.get(args, "workspace_id")),
         :ok <- gate_to_envelope(Routing.gate_write(agent, path, existing_page: existing)) do
      do_memory_delete(path, Map.get(args, "workspace_id"))
    end
  end

  def execute("memory_rename", args, context) do
    with {:ok, old_path} <- require_string(args, "old_path", "memory_rename"),
         {:ok, new_path} <- require_string(args, "new_path", "memory_rename"),
         agent = load_agent(context),
         workspace_id = Map.get(args, "workspace_id"),
         :ok <- ensure_page_kind(old_path, "memory_rename"),
         :ok <- ensure_page_kind(new_path, "memory_rename"),
         :ok <- ensure_same_kind(old_path, new_path),
         existing_old = Wiki.get_page(old_path, workspace_id: workspace_id),
         existing_new = Wiki.get_page(new_path, workspace_id: workspace_id),
         :ok <-
           gate_to_envelope(Routing.gate_write(agent, old_path, existing_page: existing_old)),
         :ok <-
           gate_to_envelope(Routing.gate_write(agent, new_path, existing_page: existing_new)) do
      do_memory_rename(old_path, new_path, agent, workspace_id)
    end
  end

  # ── memory_search payload bound ──────────────────────────────────────
  #
  # `Search.search/2` hydrates each hit with the FULL body (`page.content`
  # / `entry.content`). Twenty full org pages serialize to a six-figure
  # JSON string, which is unusable as a single MCP tool result.
  #
  # The bound lives HERE, on the MCP dispatch head, and deliberately NOT
  # inside `Search.search/2`: that function has a second consumer with no
  # token budget — the org-memory LiveView search pane, which renders full
  # content and clamps to its own 240-char preview. Narrowing the shared
  # function would silently degrade that surface. A token cap is a
  # property of the MCP transport, so it belongs on the transport's head.
  @memory_search_snippet_chars 500
  @memory_search_max_payload_bytes 20_000

  def execute("memory_search", args, context) do
    with {:ok, query} <- require_string(args, "query", "memory_search") do
      agent = load_agent(context)

      with :ok <- authorize_org_filter(agent, Map.get(args, "org_id")),
           {:ok, opts} <- search_opts_from(args, agent) do
        query |> Search.search(opts) |> bound_memory_search_payload()
      end
    end
  end

  # ── Memory-feedback read tools (task 019f6381 stage 4) ───────────────────
  #
  # These three tools thinly wrap `Platform.MemoryFeedback.list_recent/1`.
  # They are READ-ONLY by construction — no `record_*` write path is
  # exposed here. Humans (and the in-tree capture hooks at
  # `Platform.Org.Context.upsert_context_file/3` + `delete_file/2`) own
  # the write side of the corpus; agents may only inspect it.
  #
  # The default namespace lives on `Platform.MemoryFeedback` itself
  # (`@default_namespace`), so we deliberately do NOT pass it here —
  # keeps the tool_surface source clean of any bundle-name-adjacent
  # string literals that the T5 scope-creep guard forbids.

  def execute("org_memory_recently_edited", args, _context) do
    opts = feedback_read_opts(args, "edit")
    {:ok, Enum.map(Platform.MemoryFeedback.list_recent(opts), &serialize_feedback_entry/1)}
  end

  def execute("org_memory_recently_deleted", args, _context) do
    opts = feedback_read_opts(args, "delete")
    {:ok, Enum.map(Platform.MemoryFeedback.list_recent(opts), &serialize_feedback_entry/1)}
  end

  def execute("org_memory_feedback_at_path", args, _context) do
    with {:ok, path} <- require_string(args, "path", "org_memory_feedback_at_path") do
      workspace_id = Map.get(args, "workspace_id")

      # Two `list_recent/1` calls (one per feedback_kind) rather than a
      # single unfiltered call + Elixir-side partition — keeps the query
      # narrow enough that the ceiling of 100 per side is enforced by
      # the DB, not by an in-BEAM filter that would need a much larger
      # buffer to guarantee the same result for pathological corpora.
      edits =
        [feedback_kind: "edit", path_prefix: path, workspace_id: workspace_id, limit: 100]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Platform.MemoryFeedback.list_recent()
        |> Enum.filter(&(&1.path == path))
        |> Enum.map(&serialize_feedback_entry/1)

      deletes =
        [feedback_kind: "delete", path_prefix: path, workspace_id: workspace_id, limit: 100]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Platform.MemoryFeedback.list_recent()
        |> Enum.filter(&(&1.path == path))
        |> Enum.map(&serialize_feedback_entry/1)

      {:ok, %{path: path, edits: edits, deletes: deletes}}
    end
  end

  # ── Files MCP dispatch (ADR-0042 Stage 4) ──────────────────────────────

  def execute("file_list", args, context) do
    with {:ok, project_id} <- require_string(args, "project_id", "file_list"),
         {:ok, project} <- fetch_project_for_files(project_id, "file_list"),
         :ok <- authorize_org_filter_for_explicit(args, context),
         :ok <- authorize_file_access(context, project) do
      limit = Map.get(args, "limit") |> normalize_limit(50, 200)
      content_type = Map.get(args, "content_type")

      files =
        Platform.Files.list_files_for_project(project.id,
          limit: limit,
          content_type: content_type
        )

      {:ok,
       %{
         project_id: project.id,
         count: length(files),
         files: Enum.map(files, &file_summary/1)
       }}
    end
  end

  def execute("file_get_text", args, context) do
    if truthy?(Map.get(args, "binary")) do
      file_get_text_binary(args, context)
    else
      file_get_text_text(args, context)
    end
  end

  def execute("file_get_metadata", args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_get_metadata"),
         %Platform.Files.File{} = file <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_get_metadata"),
         :ok <- authorize_file_access(context, project) do
      {:ok, file_metadata(file)}
    else
      nil ->
        file_metadata_not_found_error(Map.get(args, "file_id"))

      {:error, _} = err ->
        err
    end
  end

  def execute("file_search", args, context) do
    with {:ok, project_id} <- require_string(args, "project_id", "file_search"),
         {:ok, query} <- require_string(args, "query", "file_search"),
         {:ok, project} <- fetch_project_for_files(project_id, "file_search"),
         :ok <- authorize_org_filter_for_explicit(args, context),
         :ok <- authorize_file_access(context, project) do
      limit = Map.get(args, "limit") |> normalize_limit(20, 100)

      memory_opts =
        [
          project_id: project.id,
          org_id: project.org_id,
          memory_type: "document",
          limit: limit
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Platform.Memory.search(query, memory_opts) do
        {:ok, results} ->
          hits =
            results
            |> Enum.map(&format_file_hit(&1, project.id))
            |> Enum.reject(&is_nil/1)

          {:ok,
           %{
             project_id: project.id,
             count: length(hits),
             hits: hits
           }}

        {:error, reason} ->
          {:error,
           %{
             error: "file_search: memory service error (#{inspect(reason)})",
             code: :memory_service_error,
             recoverable: true,
             suggestion:
               "The embedding service is unavailable or returned an error. Retry shortly; fall back to file_list if it persists."
           }}
      end
    end
  end

  def execute("file_add", args, context) do
    with {:ok, project_id} <- require_string(args, "project_id", "file_add"),
         {:ok, filename} <- require_string(args, "filename", "file_add"),
         {:ok, content_type} <- require_string(args, "content_type", "file_add"),
         {:ok, project} <- fetch_project_for_files(project_id, "file_add"),
         :ok <- authorize_org_filter_for_explicit(args, context),
         :ok <- authorize_file_access(context, project) do
      cond do
        is_binary(Map.get(args, "data_base64")) ->
          file_add_inline(args, project, filename, content_type)

        is_integer(Map.get(args, "byte_size")) and Map.get(args, "byte_size") > 0 ->
          file_add_presigned(args, project, filename, content_type)

        true ->
          {:error,
           %{
             error:
               "file_add: pass either `data_base64` (inline branch) or `byte_size` (presigned branch)",
             recoverable: true,
             suggestion:
               "For small files pass base64-encoded bytes as `data_base64`; for files over 25 MB pass `byte_size` (positive integer) to reserve a presigned upload slot."
           }}
      end
    end
  end

  def execute("file_delete", args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_delete"),
         %Platform.Files.File{} = file <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_delete"),
         :ok <- authorize_org_filter_for_explicit(args, context),
         :ok <- authorize_file_access(context, project) do
      # Task 019f7cb0 stage 4: agent deletes ride the same soft-delete
      # path as humans. `Platform.Files.delete_file/2` marks the row
      # deleted (30-day restore window — the Purger owns permanent
      # removal of row AND stored bytes after retention), scrubs the AI
      # search index, writes the audit row with the acting agent
      # attributed, and broadcasts {:file_deleted, id} on the project
      # topic — so no Storage.delete and no handler-side broadcast here.
      case Platform.Files.delete_file(file_delete_actor(context), file) do
        {:ok, _deleted} ->
          {:ok, %{file_id: file.id, deleted: true}}

        {:error, :already_deleted} ->
          # Race: another caller soft-deleted the row between our
          # `get_file` and the write. Same envelope as the get-miss —
          # a re-delete must look identical to a never-existed id.
          file_delete_not_found_error(file.id)

        {:error, :unauthorized} ->
          {:error,
           %{
             error: "file_delete: caller identity could not be resolved for audit attribution",
             code: :unauthorized,
             recoverable: false,
             suggestion:
               "Deletes are audit-logged and require an acting agent. Call through the MCP endpoint (which always supplies agent_id) rather than bare-invoking the tool surface."
           }}

        {:error, :project_archived} ->
          {:error,
           %{
             error: "file_delete: project is archived (read-only)",
             code: :project_archived,
             recoverable: false,
             suggestion:
               "Archived projects refuse writes. Unarchive the project before deleting its files."
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error,
           %{
             error: "file_delete: row update failed (#{inspect(changeset.errors)})",
             code: :delete_failed,
             recoverable: true,
             suggestion: "Transient write failure — re-issue the call."
           }}
      end
    else
      nil ->
        file_delete_not_found_error(Map.get(args, "file_id"))

      {:error, _} = err ->
        err
    end
  end

  def execute(unknown_tool, _args, _context) do
    tool_names =
      tool_definitions()
      |> Enum.map(& &1.name)
      |> Enum.join(", ")

    {:error,
     %{
       error: "Unknown tool: #{unknown_tool}",
       recoverable: false,
       suggestion: "Available tools: #{tool_names}"
     }}
  end

  # `base_updated_at` (alias `if_unmodified_since`) is the caller's
  # compare-and-set token. Absent → `{:ok, nil}` → last-write-wins, unchanged.
  # Present but unparseable → a recoverable rejection, never a write.
  # The tool name is a PARAMETER, not a literal: `task_complete` accepts the
  # same token (task 01a094d4 stage 3), and a rejection naming `task_update`
  # would send the caller to read the wrong tool's contract.
  defp parse_base_updated_at(args, tool \\ "task_update") do
    case Map.get(args, "base_updated_at") || Map.get(args, "if_unmodified_since") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _utc_offset} -> {:ok, dt}
          {:error, _reason} -> {:error, base_updated_at_error(value, tool)}
        end

      other ->
        {:error, base_updated_at_error(other, tool)}
    end
  end

  defp base_updated_at_error(value, tool) do
    %{
      error:
        "#{tool}: `base_updated_at` must be an ISO8601 timestamp, got #{inspect(value)}. No write was attempted.",
      recoverable: true,
      suggestion:
        "Pass the `updated_at` value verbatim from the task_get / #{tool} response you composed your edit against, e.g. \"2026-09-10T19:33:15.879562Z\". Omit the parameter entirely to keep the pre-existing last-write-wins behaviour."
    }
  end

  defp task_update_with_base(task_id, args, actor, base_updated_at) do
    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        with {:ok, flat_attrs, phase_attrs} <-
               TaskAttrs.build_task_attrs(args, :update,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: Tasks.current_phase(task),
                 # The :update auto-approve fill (ADR 0044 §5, task
                 # 01a0589b) is keyed off the task's persisted slots
                 # overlaid by this call's routed slots, so a present
                 # slot is never overwritten by the flat pair.
                 existing_phase_assignees: task.phase_assignees || %{}
               ) do
          # Status transitions still route through
          # `Tasks.transition_task_status/2` (validates the edge), while
          # everything else flows through `Tasks.update_task/2`. Split
          # so the two writers don't step on each other.
          status_change = Map.get(flat_attrs, :status)
          non_status_flat = Map.delete(flat_attrs, :status)

          # If `auto_approve_plan` will be `true` after this update (in
          # this call or already-true on the task with phase_assignees
          # being rewritten), hard-reject when the execution and/or
          # review phases don't resolve to a live agent. Silent
          # auto-approve without a valid downstream agent is the bug
          # this guards against — the plan flips to approved but no
          # planner picks it up. See task 019f42fd session note
          # 2026-07-08 (initial guard) and 019f5145 (hardened per ADR
          # 0044). Gate lives inside `TaskAttrs.check_auto_approve_preconditions/4`.
          auto_check =
            TaskAttrs.check_auto_approve_preconditions(flat_attrs, phase_attrs, task)

          # Order: flat_attrs → phase_attrs → status_change. Phase-attrs
          # writer (`Tasks.set_phase_assignees/2`) uses the task's
          # CURRENT status to derive the flat pointer, so we apply it
          # before any status transition — otherwise a same-call
          # phase-slot write for the target phase would still see the
          # old phase's derivation. The plan-approval gate runs AFTER
          # phase_attrs so a same-call `phase_assignees.execution =
          # <user>` rewrite is visible to `sponsor_bypasses_plan_gate?/2`
          # (the predicate reads phase-resolved assignees, not the
          # pre-update snapshot).
          # SCOPE OF THE COMPARE-AND-SET GUARD — a PARTIAL guarantee, stated
          # deliberately. `base_updated_at` guards the FIELD write below and
          # nothing else. `maybe_transition_status/3` is a SEPARATE statement
          # with its own WHERE clause and is NOT covered by the CAS filter, so
          # a call supplying a base alongside a status change gets: field write
          # guarded (refused if the row moved), transition unguarded (applied
          # on whatever the row is by then). Ordering is what makes that safe
          # to reason about — the guarded write runs FIRST, so a stale base
          # short-circuits the `with` and the transition never runs at all.
          # The residual exposure is the reverse window only: a row that
          # advances BETWEEN the two statements. Making the transition atomic
          # with the field write is deliberately out of scope for this stage;
          # do not silently widen it here without saying so in the tool's
          # `limitations` prose, which currently documents exactly this.
          with :ok <- auto_check,
               {:ok, updated} <-
                 maybe_update_task(task, non_status_flat, actor, base_updated_at),
               {:ok, updated} <- maybe_apply_phase_assignees(updated, phase_attrs),
               :ok <- maybe_check_plan_gate(updated, status_change, actor),
               {:ok, updated} <- maybe_transition_status(updated, status_change, actor) do
            # `Tasks.update_task/2` and `Tasks.transition_task_status/2`
            # return the un-preloaded struct. Refresh sponsor so
            # `serialize_task` can emit the current shape — otherwise a
            # caller that just cleared the sponsor via `sponsor_user_id:
            # nil` would still see the pre-update Sponsor%User in the
            # response envelope.
            updated = Repo.preload(updated, :sponsor, force: true)
            Tasks.broadcast_board({:task_updated, updated})

            # DISPLACEMENT DISCLOSURE (task 01a08a80 stage 3). `updated_at` in
            # the envelope is the NEW stamp, which says nothing about what this
            # write displaced. `task` is the PRE-update struct read at the top
            # of this function, so `task.updated_at` is the revision this call
            # overwrote. A caller who passed no `base_updated_at` can compare it
            # against the `updated_at` it last saw and discover after the fact
            # that it clobbered someone.
            #
            # Deliberately added HERE and not inside `serialize_task/1`:
            # `task_get`, `task_list` and every other consumer share that
            # serializer and have no meaningful "previous", so widening it
            # would put a nil key on every task read. This is an audit trail,
            # not an alarm — nothing makes a losing writer notice it. Prevention
            # is `base_updated_at` (stage 2).
            #
            # Note the key is present but EQUAL to `updated_at` on a no-op call
            # (empty attrs short-circuit in `maybe_update_task/4`), because
            # nothing was displaced. Strict inequality holds for real writes.
            {:ok, Map.put(serialize_task(updated), :previous_updated_at, task.updated_at)}
          else
            {:error, {:stale_base, %{current_updated_at: ts, base_updated_at: supplied}}} ->
              # A retryable CONFLICT, not a fatal error — `recoverable: true`
              # is what tells the caller to re-read and come back rather than
              # give up. Naming both timestamps is the point: the caller can
              # see how far behind it was without a second round trip.
              {:error,
               %{
                 error:
                   "stale_base: task was modified at #{stale_base_stamp(ts)}, after the base you supplied (#{stale_base_stamp(supplied)}). Your write was REFUSED and nothing was changed.",
                 recoverable: true,
                 submitted_args: args,
                 suggestion:
                   "Re-read the task with task_get, re-compose your edit against the current description, and retry with base_updated_at set to the updated_at you just read. " <>
                     "Do NOT simply retry the same body with the new timestamp — that reintroduces the overwrite the refusal just prevented."
               }}

            {:error, :invalid_transition} ->
              # Task 01a05394 stage 3: name the legal exits, derived from
              # `Tasks.valid_task_transitions/0` (never a second copy of the
              # table). An empty exit list says so in words rather than
              # rendering a dangling enumeration.
              exits = Map.get(Tasks.valid_task_transitions(), task.status, [])

              exits_sentence =
                case exits do
                  [] ->
                    "'#{task.status}' has no valid outbound transitions."

                  _ ->
                    "Valid next statuses from '#{task.status}': #{Enum.join(exits, ", ")}."
                end

              {:error,
               %{
                 error:
                   "Invalid status transition from '#{task.status}' to '#{status_change}'. " <>
                     exits_sentence,
                 recoverable: true,
                 submitted_args: args,
                 suggestion:
                   exits_sentence <>
                     " 'cancelled' is TERMINAL \u2014 it has no outbound edges and it means the " <>
                     "work was ABANDONED. Use it only to retire work that was genuinely " <>
                     "abandoned or superseded, never to close work that actually shipped. " <>
                     "Delivered-but-unplanned work is recorded with " <>
                     "task_close_as_delivered, which requires a merge/PR reference and is " <>
                     "callable when the runtime you are calling through is owned by a Fabrikam " <>
                     "admin (otherwise ask one to run it); a task already cancelled by " <>
                     "mistake is corrected via Platform.Tasks.reinstate_cancelled_task/3."
               }}

            {:error, :no_approved_plan} ->
              # Task 019f6380 stage 2: agent MCP calls that try to
              # transition into an execution phase without an approved
              # plan get the same friendly envelope shape as the
              # `:invalid_transition` case. Sponsor-bypass does NOT fire
              # for agent actors — that's the whole point of the actor
              # check in `sponsor_bypasses_plan_gate?/2`.
              {:error,
               %{
                 error:
                   "Cannot transition to '#{status_change}': task has no approved plan and is not a sponsor-bypass candidate",
                 recoverable: true,
                 submitted_args: args,
                 suggestion:
                   "Create a plan (plan_create) and approve it (plan_approve) before transitioning to an execution phase. " <>
                     "The sponsor-bypass exemption only applies to human-initiated moves on sponsor-only tasks with no agent involvement."
               }}

            {:error, :no_deploy_target_resolved} ->
              # `Tasks.transition_task_status/2` refuses `:deploying` when
              # neither the task nor the project supplies a target. The
              # atom would otherwise fall through to the changeset
              # catch-all below, where `inspect_errors/1` calls
              # `Ecto.Changeset.traverse_errors/2` on an atom and crashes.
              # Mirror the `:invalid_transition` friendly envelope shape.
              {:error,
               %{
                 error: "unresolved_deploy_target",
                 recoverable: true,
                 submitted_args: args,
                 suggestion:
                   "Set task.deploy_target explicitly (e.g. task_update(deploy_target: \"production\")) " <>
                     "or configure a project-level default via " <>
                     "project_update(deploy_config: %{\"default_deploy_target\" => ...}) " <>
                     "before transitioning to deploying."
               }}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:error,
               %{
                 error: "Failed to update task: #{inspect_errors(changeset)}",
                 recoverable: true,
                 submitted_args: args,
                 suggestion: "Check that the provided values are valid"
               }}

            {:error,
             {:auto_approve_precondition_missing,
              %{missing_phases: phases, merged_phase_assignees: merged}}} ->
              corrected = TaskAttrs.auto_approve_corrected_args(args, merged, phases)

              {:error, auto_approve_precondition_envelope(phases, args, corrected, :update)}

            # The commencement gate's 3-tuple. Without this clause the
            # `with` has no matching `else` branch (every other clause is
            # a 2-tuple) and raises `WithClauseError` → 500.
            {:error, :stack_plans_pending, %{stack_id: stack_id, waiting_on: waiting_on}} ->
              # Recoverable refusal → echo the submitted arguments in the
              # response envelope only (task 01a05877 stage 2). The
              # delegating `waiting_on == []` envelope's recoverable flag
              # depends on the observed stack status, so the echo is
              # added only when the envelope is actually recoverable.
              gate_envelope = stack_plans_pending_envelope(stack_id, waiting_on)

              {:error,
               if(Map.get(gate_envelope, :recoverable),
                 do: Map.put(gate_envelope, :submitted_args, args),
                 else: gate_envelope
               )}

            # ADR 0045 decision 7 (task 01a05393 stage 3): a member of a
            # stack that already SHIPPED through its rollup cannot re-enter
            # an execution status. Not recoverable on this task — the
            # message itself says where the work goes instead.
            {:error, :stack_already_shipped, %{message: message}} ->
              {:error,
               %{
                 error: message,
                 recoverable: false,
                 suggestion:
                   "Create a new individual task (task_create) for the post-ship change. " <>
                     "This task may still be cancelled."
               }}

            # Task 01a05393 stage 6 (defect D): `stack_pending` is the
            # parked-behind-a-stack status. A task with no `stack_id`
            # moved there is invisible to the dispatcher, to the promote
            # sweep AND to the board's drag-out — nothing can move it
            # again. `Tasks.require_stack_commencement_for/2` refuses the
            # write; this arm keeps the refusal from falling into the
            # changeset catch-all (a 3-tuple → `WithClauseError` → 500).
            {:error, :stack_pending_requires_stack, _} ->
              {:error,
               %{
                 error:
                   "Cannot transition to 'stack_pending': task #{task.id} is not in a stack. " <>
                     "'stack_pending' means \"parked until the stack's dependencies land\" and is " <>
                     "unreachable by the dispatcher, the promote sweep and the board once set on a stackless task.",
                 recoverable: true,
                 suggestion:
                   "Put the task in a stack first with stack_add(stack_id, task_id) — a started stack " <>
                     "parks the newcomer at 'stack_pending' itself. To simply pause a stackless task, " <>
                     "use 'blocked' instead.",
                 submitted_args: args
               }}
          end
        else
          # Recoverable refusals echo the submitted arguments in the
          # response envelope only (task 01a05877 stage 2).
          {:error, {:invalid_phase_keys, keys}} ->
            {:error,
             %{
               error: "Invalid phase_assignees keys: #{Enum.join(keys, ", ")}",
               recoverable: true,
               suggestion: "Use 'planning', 'execution', or 'review'",
               submitted_args: args
             }}

          {:error, {:invalid_phase_assignees_shape, _}} ->
            {:error,
             %{
               error: "phase_assignees must be a map keyed by phase name",
               recoverable: true,
               suggestion:
                 "Pass %{\"planning\" => %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\"}}",
               submitted_args: args
             }}
        end
    end
  end

  # Task 01a05b32 stage 1 — the audit trail for the planner-rejected draft.
  # Emitted through telemetry so Platform.Audit.TelemetryHandler bridges it
  # into the append-only audit stream (the handler's documented preferred
  # entry point); the event is registered in the handler's @events list.
  # Metadata mirrors the existing plan emit sites (auto_approved /
  # architecture_gate_opened): resource_type/resource_id/action/actor_type
  # top-level for the Audit.Event columns, the event-specific fields
  # alongside. Synchronous emit + sync handler clause, so the audit row
  # exists by the time the tool response returns.
  defp emit_plan_rejected(plan, rejected_by, actor_type) do
    :telemetry.execute(
      [:platform, :tasks, :plan_rejected],
      %{count: 1},
      %{
        plan_id: plan.id,
        task_id: plan.task_id,
        rejected_by: rejected_by,
        rejection_reason: plan.rejection_reason,
        resource_type: "plan",
        resource_id: plan.id,
        action: "plan_rejected",
        actor_type: actor_type
      }
    )
  end

  # WHO discarded the draft. An explicit `rejected_by` argument wins;
  # otherwise the execute context's caller identity (the agent the runtime
  # runs as), then "system" — mirroring plan_approve's approved_by
  # convention. Returns {identity, audit actor_type}.
  defp plan_reject_actor(args, context) do
    case Map.get(args, "rejected_by") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> context_caller_identity(context)
          trimmed -> {trimmed, "agent"}
        end

      _ ->
        context_caller_identity(context)
    end
  end

  defp context_caller_identity(context) when is_map(context) do
    case load_agent(context) do
      %Agent{slug: slug} when is_binary(slug) and slug != "" ->
        {slug, "agent"}

      %Agent{id: id} ->
        {id, "agent"}

      _ ->
        case Map.get(context, :agent_id) do
          id when is_binary(id) and id != "" -> {id, "agent"}
          _ -> {"system", "system"}
        end
    end
  end

  defp context_caller_identity(_context), do: {"system", "system"}

  # The refusal must name the path the caller should take INSTEAD, per
  # status. pending_review is the Plan-State Lock itself: agents cannot
  # withdraw a submitted plan.
  defp plan_reject_suggestion("pending_review"),
    do:
      "wait for the human reviewer; agents cannot withdraw a submitted plan (only a human can reject it)"

  defp plan_reject_suggestion("rejected"),
    do: "the plan is already rejected; there is nothing to discard"

  defp plan_reject_suggestion(_status),
    do: "the plan is immutable to this tool"

  defp do_plan_update(plan, raw_stages_input, args, context) do
    # BEFORE summary from the tree as it stands — this is the audit trail's
    # "who changed what": what the draft looked like before the rewrite.
    before_summary = plan_update_summary(Repo.preload(plan, stages: :validations))

    stages_input =
      raw_stages_input
      # Task 01a0588e. FIRST, and before the engine's own rewrite: `origin`
      # is the engine's marker, so a planner-supplied
      # `"origin": "synthesized"` is dropped here rather than honoured.
      # Stripping after `route_e2e_behavior_validations/1` would erase the
      # engine's marker instead of the planner's forgery.
      |> Platform.Tasks.PlanEngine.strip_planner_origin()
      |> Platform.Tasks.PlanEngine.route_e2e_behavior_validations()
      |> Platform.Tasks.PlanEngine.check_manual_approval_heuristic()
      |> Platform.Tasks.PlanEngine.check_zero_validation_stages()

    case Tasks.replace_plan_stages(plan, stages_input) do
      {:ok, updated} ->
        {updated_by, actor_type} = plan_update_actor(args, context)
        emit_plan_updated(updated, updated_by, actor_type, before_summary)

        {:ok, serialize_plan(updated)}

      {:error, :invalid_transition} ->
        {:error,
         %{
           error: "plan_update only accepts draft-status plans (current: #{plan.status}).",
           recoverable: false,
           suggestion: plan_update_suggestion(plan.status)
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to update plan: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Check that stages have valid fields and retry"
         }}
    end
  end

  # The audit trail for the in-place correction, via the same telemetry →
  # TelemetryHandler bridge plan_reject uses (the event is registered in the
  # handler's @events list; an unregistered emit fails SILENTLY). Metadata
  # carries plan_id, task_id, updated_by, and a before/after summary (stage
  # count, stage names+positions, validation kinds per stage), plus
  # resource_type/resource_id/action/actor_type for the Audit.Event columns.
  # Sync (default handle_event clause) so the audit row exists by the time
  # the tool response returns.
  defp emit_plan_updated(plan, updated_by, actor_type, before_summary) do
    :telemetry.execute(
      [:platform, :tasks, :plan_updated],
      %{count: 1},
      %{
        plan_id: plan.id,
        task_id: plan.task_id,
        updated_by: updated_by,
        before: before_summary,
        after: plan_update_summary(plan),
        resource_type: "plan",
        resource_id: plan.id,
        action: "plan_updated",
        actor_type: actor_type
      }
    )
  end

  # WHO corrected the draft. Same convention as plan_reject's rejected_by:
  # an explicit `updated_by` argument wins, otherwise the execute context's
  # caller identity, then "system".
  defp plan_update_actor(args, context) do
    case Map.get(args, "updated_by") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> context_caller_identity(context)
          trimmed -> {trimmed, "agent"}
        end

      _ ->
        context_caller_identity(context)
    end
  end

  # The refusal names the path the caller should take INSTEAD, per status —
  # the same discipline as plan_reject_suggestion/1.
  defp plan_update_suggestion("pending_review"),
    do:
      "wait for the human reviewer; agents cannot withdraw or edit a submitted plan (only a human can reject it, after which plan_create can start over)"

  defp plan_update_suggestion("rejected"),
    do:
      "the plan is already rejected; there is nothing to update (call plan_create to start a fresh plan)"

  defp plan_update_suggestion(_status),
    do: "the plan is immutable to this tool"

  # `stages` is REQUIRED and must be a non-empty list: the parameter contract
  # mirrors plan_create's (same shape), but an EMPTY array is refused here —
  # a draft keeps at least one stage (auto_approve_precondition/2 skips on
  # empty_plan, so an empty draft would submit a plan the engine treats as
  # unapprovable). Missing/non-list and empty are distinct envelopes so the
  # caller knows which mistake they made. Both are parameter errors
  # (recoverable: true — fix the argument and retry); nothing was written.
  defp require_plan_update_stages(args) do
    case Map.get(args, "stages") do
      stages when is_list(stages) and stages != [] ->
        {:ok, stages}

      [] ->
        {:error,
         %{
           error:
             "plan_update: `stages` must not be empty — a draft plan keeps at least one stage",
           recoverable: true,
           suggestion:
             "Pass the corrected stages (same shape as plan_create's `stages`), or discard the draft with plan_reject instead"
         }}

      _ ->
        {:error,
         %{
           error:
             "plan_update: `stages` is required and must be a non-empty array of stage objects",
           recoverable: true,
           suggestion:
             "Provide the replacement stages — same shape and contract as plan_create's `stages` parameter"
         }}
    end
  end

  # The before/after summary for the audit event: stage count, stage
  # names+positions, validation kinds per stage. Tolerates a non-preloaded
  # association (summarises as empty) rather than raising.
  defp plan_update_summary(plan) do
    stages =
      case plan.stages do
        %Ecto.Association.NotLoaded{} ->
          []

        stages ->
          stages |> Enum.sort_by(&(&1.position || 0))
      end

    %{
      stage_count: length(stages),
      stages:
        Enum.map(stages, fn stage ->
          %{
            position: stage.position,
            name: stage.name,
            validation_kinds: plan_update_summary_validation_kinds(stage)
          }
        end)
    }
  end

  defp plan_update_summary_validation_kinds(stage) do
    case stage.validations do
      %Ecto.Association.NotLoaded{} -> []
      validations when is_list(validations) -> Enum.map(validations, & &1.kind)
      _ -> []
    end
  end

  defp normalize_send_media_attachments(args) do
    file_paths =
      case Map.get(args, "file_paths") do
        paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
        _ -> []
      end

    attachment_specs =
      cond do
        file_paths != [] ->
          Enum.map(file_paths, fn path ->
            %{path: path, filename: Path.basename(path)}
          end)

        is_binary(Map.get(args, "file_path")) and Map.get(args, "file_path") != "" ->
          file_path = Map.get(args, "file_path")
          filename = Map.get(args, "filename") || Path.basename(file_path)
          [%{path: file_path, filename: filename}]

        true ->
          []
      end

    case attachment_specs do
      [] -> {:error, "Failed to send media: no file path provided"}
      specs -> {:ok, specs}
    end
  end

  defp persist_send_media_attachments(attachment_specs) do
    attachment_specs
    |> Enum.reduce_while({:ok, []}, fn %{path: path, filename: filename}, {:ok, acc} ->
      case Chat.AttachmentStorage.persist_upload(path, filename) do
        {:ok, file_meta} -> {:cont, {:ok, [Map.put(file_meta, :message_id, nil) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attachment_attrs} -> {:ok, Enum.reverse(attachment_attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp react_after_validation(space_id, message_id, emoji, context) do
    case Chat.get_message(message_id) do
      nil ->
        {:error,
         %{
           error: "Message #{message_id} not found",
           recoverable: false,
           suggestion: "Verify the message_id exists and is accessible to the agent"
         }}

      %{space_id: msg_space_id} when msg_space_id != space_id ->
        {:error,
         %{
           error: "Message does not belong to space #{space_id}",
           recoverable: false,
           suggestion: "Pass the space_id that owns the target message"
         }}

      _message ->
        participant_id =
          Map.get(context, :agent_participant_id) ||
            get_agent_participant_id_for_space(space_id, context)

        if is_nil(participant_id) do
          {:error,
           %{
             error: "Access denied: agent is not a participant in space #{space_id}",
             recoverable: false,
             suggestion: "Use space_list to find spaces the agent has access to"
           }}
        else
          persist_reaction(space_id, message_id, participant_id, emoji)
        end
    end
  end

  defp persist_reaction(space_id, message_id, participant_id, emoji) do
    case Chat.add_reaction(%{
           message_id: message_id,
           participant_id: participant_id,
           emoji: emoji
         }) do
      {:ok, _reaction} ->
        {:ok,
         %{
           message_id: message_id,
           space_id: space_id,
           emoji: emoji,
           status: "added"
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        if already_reacted?(changeset) do
          {:ok,
           %{
             message_id: message_id,
             space_id: space_id,
             emoji: emoji,
             status: "already_reacted"
           }}
        else
          {:error,
           %{
             error: "Failed to add reaction: #{inspect_errors_safe(changeset)}",
             recoverable: true,
             suggestion: "Verify message_id, participant_id, and emoji are valid"
           }}
        end
    end
  end

  defp already_reacted?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :emoji) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  # Error translation is deliberately per-term rather than a catch-all
  # string: a caller that receives a wrong `recoverable` flag retries
  # something that cannot work, or abandons something that would have.
  defp design_critique_error(:responsibility_unfilled) do
    %{
      error:
        "No agent holds the Designer role's `design.critique` duty, so no design review can be obtained.",
      recoverable: false,
      suggestion:
        "Assign the Designer role (or a `design.critique` override) to an external agent. Until then, create the review request anyway and note that design review is missing."
    }
  end

  defp design_critique_error(:responsibility_not_registered) do
    %{
      error: "`design.critique` is not registered on this instance.",
      recoverable: false,
      suggestion:
        "Create the review request anyway and note that design review is unavailable here."
    }
  end

  defp design_critique_error({:assignee_not_external, kind}) do
    %{
      error:
        "The `design.critique` assignee is a #{kind} agent; a synchronous critique needs an external one.",
      recoverable: false,
      suggestion:
        "Point the Designer role at an external agent, or proceed without design review and say so."
    }
  end

  defp design_critique_error(:no_canvas_resolved) do
    %{
      error: "No canvas could be resolved for the critique, so nothing was sent for review.",
      recoverable: true,
      suggestion: "Pass an explicit `canvas_id` for the evidence canvas holding your screenshots."
    }
  end

  defp design_critique_error({:dispatch_raised, message}) do
    %{
      error: "The design critique dispatch failed: #{message}",
      recoverable: true,
      suggestion: "Retry once; if it fails again, create the review request noting the failure."
    }
  end

  defp design_critique_error({:dispatch_exited, reason}) do
    %{
      error: "The design critique dispatch exited: #{inspect(reason)}",
      recoverable: true,
      suggestion: "Retry once; if it fails again, create the review request noting the failure."
    }
  end

  defp design_critique_error(reason) do
    %{
      error: "Could not obtain a design critique: #{inspect(reason)}",
      recoverable: true,
      suggestion: "Retry once; if it fails again, create the review request noting the failure."
    }
  end

  # Look up the agent's participant row in a space. Post-ADR-0038 there is
  # no dismissed-but-present state — the row exists iff the agent is in the
  # space. Scoped to participant_type="agent" so a user participant with a
  # colliding UUID can't be matched here.
  defp find_active_agent_participant(space_id, agent_id) do
    from(p in Participant,
      where:
        p.space_id == ^space_id and
          p.participant_id == ^agent_id and
          p.participant_type == "agent"
    )
    |> Repo.one()
  end

  defp search_hits(space_id, query, limit) do
    messages = Chat.search_messages(space_id, query, limit: limit)

    {:ok,
     Enum.map(messages, fn m ->
       {trimmed_content, truncated?} = cap_content(m.content || "")

       %{
         id: m.id,
         participant_id: m.participant_id,
         content: trimmed_content,
         content_truncated: truncated?,
         search_headline: m.search_headline,
         inserted_at: format_datetime(m.inserted_at)
       }
     end)}
  end

  defp cap_content(content) when is_binary(content) do
    if String.length(content) > @message_content_cap do
      {String.slice(content, 0, @message_content_cap), true}
    else
      {content, false}
    end
  end

  defp serialize_attachments(attachments) do
    Enum.map(attachments, fn a ->
      %{
        url: "/chat/attachments/#{a.id}",
        content_type: a.content_type,
        byte_size: a.byte_size,
        filename: a.filename
      }
    end)
  end

  defp normalize_limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp normalize_limit(_), do: 20

  defp search_users(query_trimmed, query_norm, like_pattern, prefix_pattern, limit) do
    from(u in Platform.Accounts.User,
      where:
        fragment("LOWER(?)", u.email) == ^query_norm or
          ilike(u.name, ^like_pattern),
      order_by: [
        desc: fragment("LOWER(?) = ?", u.email, ^query_norm),
        desc: fragment("LOWER(?) = LOWER(?)", u.name, ^query_trimmed),
        desc: fragment("? ILIKE ?", u.name, ^prefix_pattern),
        asc: u.name
      ],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&format_principal_user/1)
  end

  defp search_agents(query_trimmed, like_pattern, prefix_pattern, limit) do
    from(a in Agent,
      where:
        ilike(a.name, ^like_pattern) or
          ilike(a.slug, ^like_pattern),
      order_by: [
        desc: fragment("LOWER(?) = LOWER(?)", a.slug, ^query_trimmed),
        desc: fragment("LOWER(?) = LOWER(?)", a.name, ^query_trimmed),
        desc: fragment("? ILIKE ?", a.name, ^prefix_pattern),
        asc: a.name
      ],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&format_principal_agent/1)
  end

  defp format_principal_user(%Platform.Accounts.User{} = u) do
    %{
      type: "user",
      id: u.id,
      display_name: u.name,
      email: u.email,
      avatar_url: u.avatar_url
    }
  end

  defp format_principal_agent(%Agent{} = a) do
    %{
      type: "agent",
      id: a.id,
      display_name: a.name,
      slug: a.slug,
      kind: a.kind,
      classification: Atom.to_string(Platform.Agents.Kind.classify(a))
    }
  end

  # Applies a per-phase assignee map through the canonical writer
  # (`Tasks.set_phase_assignees/2`), which re-derives the flat
  # `assignee_id + assignee_type` pointer from the current phase. Called
  # from both `task_create` and `task_update` after `build_task_attrs/3`
  # emits a non-nil `phase_attrs`.
  defp maybe_apply_phase_assignees(task, nil), do: {:ok, task}

  defp maybe_apply_phase_assignees(task, phase_attrs) when is_map(phase_attrs),
    do: Tasks.set_phase_assignees(task, phase_attrs)

  # Single source of truth for the `similar_tasks` cutoff. Was an inline
  # `>= 0.5` literal against a reciprocal-rank score, where 0.5 meant
  # "rank 2 or better in some channel". Against the overlap coefficient
  # 0.5 would mean "half the query's non-stopword vocabulary appears in
  # the candidate", which is a different quantity, so the constant was
  # recalibrated rather than carried across. Calibrated against the two
  # scoring tests in `tool_surface_test.exs` and nothing else.
  @similarity_threshold 0.35

  # Deliberately small and hand-listed, not a linguistics dependency.
  # These are the tokens that appear in almost every ticket body and
  # would otherwise inflate `|Q ∩ C|` for any two unrelated tasks. The
  # list is dropped from BOTH the query and the candidate.
  @similarity_stopwords MapSet.new(~w(
    a about after all also an and any are as at be because been before being
    but by can could did do does doing for from had has have he her here hers
    him his how i if in into is it its just me more most my no nor not of off
    on once only or other our out over own same she should so some such than
    that the their them then there these they this those through to too under
    until up very was we were what when where which while who whom why will
    with would you your
  ))

  # Stage 4 (019f3dbb) — advisory self-similarity search for
  # `task_create`. Runs synchronously post-create because the caller
  # needs the field in the same response envelope (a follow-up
  # `memory_search` round-trip would double the create's latency).
  #
  # ## Score and threshold (task 01a08a27 stage 3)
  #
  # `similarity_score` is a MATCH-QUALITY measure and reads NEITHER
  # channel rank. It is the overlap coefficient
  #
  #     |Q ∩ C| / min(|Q|, |C|)
  #
  # where `Q` is the tokenised new-ticket body (`normalize_similarity_query/1`
  # output, downcased, deduped) and `C` is the tokenised `hit.content`
  # (which `Search` builds as `title` or `title <> " — " <> description`).
  # A small English stopword list is dropped from BOTH sides before
  # intersecting. Rounded to 3 places. See `@similarity_threshold`.
  #
  # What this replaced and why: the score used to be
  # `1.0 / min(semantic_rank, lexical_rank)`, i.e. a POSITIONAL score. It
  # reported 1.000 — "certain duplicate" — for whatever the lexical
  # channel happened to return first, regardless of subject. The old
  # comment here conceded that rank 1 "usually" means the title tokens
  # overlap fully; that `usually` WAS the defect, and the rank-1/rank-2/
  # rank-3 confidence table it carried is deleted rather than adjusted
  # because it describes a quantity this function no longer computes.
  # Since task 01a08a27 stage 2 widened the lexical channel from an
  # implicit AND to a capped OR-alternation, a positional score would be
  # actively worse than before: it would stamp 1.000 on the first row of
  # a much wider candidate set.
  #
  # Overlap coefficient rather than Jaccard, deliberately: a
  # ticket-length new body against a one-line seeded task has wildly
  # asymmetric set sizes, and Jaccard would drive every genuine
  # duplicate toward zero purely on length. Admitted cost, kept
  # admitted: this is UNSTEMMED, so `returns` and `return` do not
  # intersect. That is a symmetric loss — it lowers all scores slightly
  # rather than biasing between candidates — and it keeps the score
  # computable in pure Elixir with no DB round-trip and no dependence on
  # the semantic channel, which matters because that channel is dropped
  # on task scope until task 01a08a6e-973f lands.
  #
  # ## Structural bound on this whole feature — read before calling a
  # ## residual duplicate filing a regression of task 01a08a27
  #
  # `similar_tasks` is computed and returned by `task_create` AFTER the
  # row has been written. Even a perfect implementation therefore cannot
  # PREVENT two agents filing the same ticket within sixty seconds of
  # each other: by the time either caller sees this field, both rows
  # exist. This is a post-hoc account of a race, not a check against
  # one. The only thing that prevents the duplicate is announcing a
  # claim before the write. So "success" here means the advisory list is
  # honest about match quality — not that duplicates stop happening.
  #
  # ## Advisory guarantees
  #
  # - Never blocks the create — a raise or `{:error, _}` from `Search`
  #   surfaces as `similar_tasks: []` and a `:warning` log line.
  # - Self-match is excluded (the just-created task will often lexical-
  #   match its own title at rank 1).
  # - Project scope is enforced through the `project_id` filter passed
  #   to `Search.search`; cross-project leakage cannot occur because the
  #   lexical `tasks` channel joins projects and the semantic channel
  #   filters on the `project_id` provider option.
  #
  # Task 01a01041 stage 2: an `{:error, reason}` arm on the `case` below was
  # unreachable and has been removed. `Org.Wiki.Search.search/2` is total —
  # `@spec` (search.ex:147) declares only `{:ok, %{results: …}}`, the
  # blank-query short-circuit returns `{:ok, …}`, and `do_search/2` absorbs
  # every channel failure (`Task.async_stream` with `:kill_task`, plus the
  # `{:error, _} -> []` provider arms) precisely so a degraded channel
  # contributes no hits instead of failing the search. That is deliberate for
  # an advisory search, so the callee's return type is not the bug and the
  # branch was dead rather than the spec being too narrow. The failure paths
  # that DO fire here are the `rescue`/`catch` below, which stay: a provider
  # crash surfaces as a raise or an EXIT, never as an error tuple.
  defp similar_tasks_for(task) do
    try do
      query_text =
        [task.title, task.description]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
        |> normalize_similarity_query()

      query_tokens = similarity_tokens(query_text)

      case Search.search(query_text,
             source: "task",
             project_id: task.project_id,
             # Pull one extra so we still return up to 5 after dropping
             # the self-match.
             limit: 6,
             # Task creation may run under a system context with no
             # caller agent; tenancy is enforced via `project_id`.
             agent: nil
           ) do
        {:ok, %{results: results}} ->
          results
          |> Enum.reject(fn hit -> hit.id == task.id end)
          |> Enum.map(&similar_task_entry(&1, query_tokens))
          |> Enum.filter(fn entry -> entry.similarity_score >= @similarity_threshold end)
          |> Enum.take(5)
      end
    rescue
      error ->
        Logger.warning("task_create similarity search raised: #{Exception.message(error)}")

        []
    catch
      # `Search.search` fans channels through `Task.async_stream` — a
      # crash in a semantic-provider `search/3` implementation surfaces
      # as an EXIT that leaks out of the stream. Treat it identically
      # to the rescue path: advisory search, never blocks the create.
      kind, reason when kind in [:exit, :throw] ->
        Logger.warning("task_create similarity search exited: #{inspect({kind, reason})}")

        []
    end
  end

  # Project a `Platform.Org.Wiki.Search` task hit into the advisory
  # `similar_tasks` entry the plan spec calls out. Fields flow through
  # from stage 3's hydration — see `Search.task_to_hit/2`.
  defp similar_task_entry(hit, query_tokens) do
    %{
      id: hit.id,
      title: hit_title(hit),
      status: hit.status,
      priority: hit.priority,
      similarity_score: hit_similarity_score(hit, query_tokens),
      updated_at: hit.updated_at,
      merged_pr_url: hit.merged_pr_url,
      follow_up_task_ids: hit.follow_up_task_ids,
      cancellation_note: hit.cancellation_note
    }
  end

  # `Search` builds `content` as `title` or `title <> " — " <> description`.
  # Recover the title cheaply without re-fetching the task row.
  defp hit_title(%{content: content}) when is_binary(content) do
    case String.split(content, " — ", parts: 2) do
      [title | _] -> title
      _ -> content
    end
  end

  defp hit_title(_), do: ""

  # Overlap coefficient between the query token set and the hit's own
  # content tokens — see `similar_tasks_for/1` for why this shape and
  # not Jaccard, and for the admitted unstemmed cost.
  #
  # Deliberately reads NEITHER `semantic_rank` NOR `lexical_rank`. A
  # rank is a position in a result list; it says how a candidate placed
  # against the other candidates, never how well it matches the query.
  # If this function ever grows a rank argument again, the score has
  # stopped measuring match quality.
  defp hit_similarity_score(%{content: content}, query_tokens) when is_binary(content) do
    overlap_coefficient(query_tokens, similarity_tokens(content))
  end

  defp hit_similarity_score(_hit, _query_tokens), do: 0.0

  # Empty on either side scores 0.0 rather than dividing by zero. An
  # empty set is "nothing to compare", which is the weakest possible
  # match, not the strongest.
  defp overlap_coefficient(query_tokens, content_tokens) do
    q_size = MapSet.size(query_tokens)
    c_size = MapSet.size(content_tokens)

    if q_size == 0 or c_size == 0 do
      0.0
    else
      shared = MapSet.size(MapSet.intersection(query_tokens, content_tokens))

      Float.round(shared / min(q_size, c_size), 3)
    end
  end

  # Tokenise for scoring: split on the same non-alphanumeric class
  # `normalize_similarity_query/1` uses, downcase, drop stopwords, dedupe
  # (MapSet). Applied to BOTH sides — an asymmetric stopword policy would
  # shrink one set and not the other and skew `min(|Q|, |C|)`.
  defp similarity_tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&MapSet.member?(@similarity_stopwords, &1))
    |> MapSet.new()
  end

  defp similarity_tokens(_), do: MapSet.new()

  # `Search.search` funnels the query into `websearch_to_tsquery('english', ?)`,
  # which treats `-` as a NOT operator (`meeting -fix` → `meeting & !fix`),
  # `"..."` as a phrase, and `OR` as alternation. A task's title +
  # description is arbitrary prose — an em-dash inside "the summarizer
  # leaks memory each meeting - fix it" would silently exclude every
  # candidate that mentions "fix". Normalise punctuation to whitespace
  # so the query is a plain token bag and the tsquery only carries the
  # implicit-AND of stems.
  defp normalize_similarity_query(text) do
    text
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  # `Tasks.update_task_if_unmodified/4` re-reads the row to report the current
  # stamp, and that re-read returns nil if the task was DELETED between the
  # refused write and the re-read. Rendering "nil" into the message would be
  # worse than saying so, hence the explicit clause rather than a bare
  # `DateTime.to_iso8601/1` that would raise.
  defp stale_base_stamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stale_base_stamp(nil), do: "unknown (the task could not be re-read)"

  defp maybe_update_task(task, attrs, _actor, _base) when map_size(attrs) == 0, do: {:ok, task}

  # No base supplied: the pre-existing writer, untouched. This is the path
  # every current agent caller takes and it must stay byte-identical in
  # behaviour — routing it through the compare-and-set writer with an implicit
  # base would wedge every caller that reads a task and edits it later.
  defp maybe_update_task(task, attrs, actor, nil),
    do: Tasks.update_task(task, attrs, actor: actor)

  # Base supplied: the guard goes in the WHERE clause of the write. `base` is
  # the CALLER'S token from `args`, never `task.updated_at` — the struct here
  # was reloaded moments ago and is current by construction, so seeding the
  # filter from it would make the guard a no-op that still passes any test
  # built on a stale struct.
  defp maybe_update_task(task, attrs, actor, %DateTime{} = base),
    do: Tasks.update_task_if_unmodified(task, attrs, base, actor: actor)

  defp maybe_transition_status(task, nil, _actor), do: {:ok, task}

  # `transition_task_status/2` deliberately takes no actor (it is called by
  # the router, Stacks, CommencementGate, ChatPins and more). The MCP
  # caller's identity is supplied out-of-band so the recorded transition is
  # attributed to the calling agent instead of `unknown`.
  defp maybe_transition_status(task, new_status, actor),
    do:
      Tasks.TransitionActor.with_actor(actor, "mcp_task_update", fn ->
        Tasks.transition_task_status(task, new_status)
      end)

  # Task 019f6380 stage 2: consult `Tasks.require_approved_plan_for/3`
  # before an MCP-initiated status transition. When there's no status
  # change in this call (`nil`), skip the check entirely — bare
  # metadata updates should never hit the plan gate. Also skip when the
  # transition would fail as `:invalid_transition` in
  # `transition_task_status/2` — otherwise the gate would mask the more-
  # specific transition-table error (e.g. `cancelled → in_progress`
  # would surface as `:no_approved_plan` instead of the terminal-state
  # refusal). When the gate returns `{:error, :no_approved_plan}`,
  # propagate as-is so the outer `with` chain hits the friendly envelope
  # branch above.
  defp maybe_check_plan_gate(_task, nil, _actor), do: :ok

  defp maybe_check_plan_gate(task, new_status, actor) do
    if Tasks.transition_valid?(task, new_status) do
      Tasks.require_approved_plan_for(task, new_status, actor)
    else
      :ok
    end
  end

  # Derive an `actor` tuple for the plan-gate call from the MCP call
  # context. MCP callers are agents by default — the `:agent_id` key
  # is the standard shape (see e.g. `space_leave`, `space_list` above).
  # An absent `:agent_id` falls back to the bare `:agent` atom, which
  # `sponsor_bypasses_plan_gate?/2` treats as non-human and therefore
  # never grants the sponsor-bypass exemption.
  defp actor_from_mcp_context(context) when is_map(context) do
    case Map.get(context, :agent_id) do
      id when is_binary(id) -> {:agent, id}
      _ -> :agent
    end
  end

  defp actor_from_mcp_context(_context), do: :agent

  # Shared envelope for `TaskAttrs.check_auto_approve_preconditions/4`
  # rejections — both `task_create` and `task_update` surface the identical
  # shape so callers can dispatch on `envelope.code` without checking which
  # tool produced the error. `missing_phases` retains stable
  # `[\"execution\", \"review\"]` ordering from TaskAttrs.
  # Shared envelope for the Stack-v2 commencement gate's 3-tuple refusal
  # `{:error, :stack_plans_pending, %{stack_id, waiting_on}}`. BOTH MCP
  # entry points that can transition a member into `in_progress`
  # (`task_start` and `task_update`) route here so the wording lives in
  # exactly one place.
  #
  # Two branches, because the atom is overloaded:
  #
  #   * `waiting_on != []` — siblings are still missing approved plans.
  #     Wording is copied from the `stack_start` handler below so an
  #     agent that has seen one message recognises the other.
  #
  #   * `waiting_on == []` — every member IS planned, but
  #     `CommencementGate.open?/1` still returns false because the stack
  #     row itself is not `"in_progress"`. Rendering the blocker list
  #     here would emit a dangling empty enumeration ("waiting on: "),
  #     so this branch names the real cause instead — and the cause
  #     depends on the stack's CURRENT status (task 01a05393 stage 4).
  #     `stack_start` is only the answer for a `forming` stack;
  #     `Stacks.start_stack/1` refuses every other status, so telling
  #     an agent to call it on an `abandoned` stack sends it round a
  #     loop between this envelope and the `stack_start` refusal.
  defp stack_plans_pending_envelope(stack_id, []) do
    stack_id
    |> Stacks.get_stack()
    |> stack_not_open_envelope(stack_id)
  end

  defp stack_plans_pending_envelope(stack_id, waiting_on) when is_list(waiting_on) do
    %{
      error:
        "Stack cannot start yet — the following members are missing an approved plan: " <>
          Enum.join(describe_waiting_on(stack_id, waiting_on), ", "),
      recoverable: true,
      suggestion: "Approve the missing plans (via plan_approve) before starting this task again."
    }
  end

  # The `waiting_on == []` envelope, keyed on the stack row's status.
  # Every branch names an action that is actually legal for the status
  # observed. Wording for `abandoned` is derived from what
  # `Stacks.abandon_stack/2` does on THIS branch (`abandon_member_target/1`):
  # `stack_pending` / `planning` / `backlog` members go to `backlog` and are
  # detached; members that landed on the rollup keep their membership. So a
  # `stack_pending` task that still points at an abandoned stack was attached
  # after the sweep or slipped past it. It must not mention `stack_start` —
  # that is the loop.
  defp stack_not_open_envelope(%Stack{status: "forming"}, stack_id) do
    %{
      error:
        "Cannot start task: stack #{stack_id} has not started yet. Every member holds an approved plan, but the stack itself is not in_progress, so the commencement gate stays closed.",
      recoverable: true,
      suggestion: "Call stack_start with stack_id #{stack_id} to open the stack, then retry."
    }
  end

  defp stack_not_open_envelope(%Stack{status: "abandoned"}, stack_id) do
    %{
      error:
        "Cannot start task: stack #{stack_id} is abandoned, so its commencement gate will never open. Abandoning a stack returns stack_pending members to backlog and detaches them, while members that landed on the rollup keep their membership; this task is still stack_pending and still belongs to the stack, so it was not released.",
      recoverable: true,
      suggestion:
        "Detach this task with stack_eject (a stack_pending member is returned to backlog), or move it with task_update status: \"backlog\". Once it no longer belongs to the stack, task_start runs it as a solo task."
    }
  end

  defp stack_not_open_envelope(%Stack{status: "blocked"}, stack_id) do
    %{
      error:
        "Cannot start task: stack #{stack_id} is blocked. A member branch failed to merge into the rollup and the conflict is recorded in the stack's metadata; the commencement gate stays closed until the stack is back at in_progress.",
      recoverable: true,
      suggestion:
        "Resolve the rollup merge conflict recorded on the stack (an operator returns the stack to in_progress), or detach this task with stack_eject and run it as a solo task."
    }
  end

  defp stack_not_open_envelope(%Stack{status: status}, stack_id)
       when status in ["in_review", "deploying", "done"] do
    %{
      error:
        "Cannot start task: stack #{stack_id} is #{status}, past the point where members are started. New execution inside it cannot begin.",
      recoverable: true,
      suggestion:
        "Detach this task with stack_eject and run it as a solo task, or create a new stack with stack_create and add it there."
    }
  end

  defp stack_not_open_envelope(%Stack{status: status}, stack_id) do
    # `in_progress` cannot reach here (the gate is open once every member
    # is planned), but a new status added to `Stack.@statuses` would. Say
    # what was seen rather than guess an action.
    %{
      error:
        "Cannot start task: stack #{stack_id} is #{status} and the commencement gate is closed.",
      recoverable: true,
      suggestion: "Detach this task with stack_eject and run it as a solo task."
    }
  end

  defp stack_not_open_envelope(nil, stack_id) do
    %{
      error:
        "Cannot start task: it belongs to stack #{stack_id}, which no longer exists, so the commencement gate cannot open.",
      recoverable: true,
      suggestion: "Detach this task with stack_eject and run it as a solo task."
    }
  end

  # `task_start`'s `:invalid_transition` envelope (task 01a05393 stage 4).
  # The allowed sources are READ from `Tasks.valid_task_transitions/0`
  # rather than hand-listed: the old text said "Must be backlog or
  # planning", which was false for `stack_pending`, `blocked`, `in_review`
  # and `deploying`. `stack_pending -> in_progress` IS in the table; a
  # `stack_pending` member is refused by the commencement gate, which
  # runs first in `Tasks.transition_task_status/2` and returns the
  # `:stack_plans_pending` 3-tuple, not `:invalid_transition`. The
  # `stack_pending` head below is therefore defensive — reachable only if
  # the gate ordering changes — and says so rather than blaming the table.
  defp invalid_start_envelope(%Task{status: "stack_pending"} = task) do
    %{
      error:
        "Cannot start task from status stack_pending: the transition itself is allowed, so the refusal is the stack's commencement gate, not the transition table.",
      recoverable: true,
      suggestion:
        "Call stack_get with stack_id #{task.stack_id} to see which members are unplanned or unlanded, or detach this task with stack_eject to run it solo."
    }
  end

  defp invalid_start_envelope(%Task{status: status}) do
    sources =
      Tasks.valid_task_transitions()
      |> Enum.filter(fn {_from, targets} -> "in_progress" in targets end)
      |> Enum.map(fn {from, _targets} -> from end)
      |> Enum.sort()

    %{
      error:
        "Cannot start task from status #{status}. in_progress is reachable from: #{Enum.join(sources, ", ")} (per ADR 0029, plan approval transitions to in_progress automatically).",
      recoverable: true,
      suggestion: "Check task status with task_get first"
    }
  end

  # Resolve blocking member ids to `"<title> (<id>) — <reason>"` via
  # `CommencementGate.waiting_detail/1`, which reads the same member set
  # `waiting_on/1` did and attaches WHY each is still waiting. An id
  # that isn't in the detail list (deleted mid-flight) degrades to the
  # bare id rather than dropping out.
  defp describe_waiting_on(stack_id, waiting_on) do
    details =
      stack_id
      |> CommencementGate.waiting_detail()
      |> Map.new(fn detail -> {detail.task_id, detail} end)

    Enum.map(waiting_on, fn id ->
      case Map.get(details, id) do
        nil -> id
        %{title: title, reason: reason} -> "#{title} (#{id}) — #{waiting_reason_text(reason)}"
      end
    end)
  end

  defp waiting_reason_text(:no_planner_assigned), do: "no planner assigned"
  defp waiting_reason_text(:plan_pending_review), do: "plan pending review"
  defp waiting_reason_text(:no_plan), do: "no plan yet"

  # Auto-approve precondition refusal (task_create + task_update). The
  # echo fields live in the RESPONSE ENVELOPE ONLY — never a log line,
  # never telemetry (args carry user content; docs/decisions/0005).
  # `submitted_args` lets a retry be patch-one-field instead of
  # rebuild-everything; `corrected_args`
  # (`TaskAttrs.auto_approve_corrected_args/3`) appears only when the
  # repair is mechanical. The suggestion is per-site because ADR 0044 §5
  # changed what a flat assignee means on task_create (fan-out) and, since
  # task 01a0589b, on task_update (route to the current-phase slot AND fill
  # every absent slot behind the persisted-slot merge).
  defp auto_approve_precondition_envelope(phases, submitted_args, corrected_args, site) do
    suggestion =
      case site do
        :create ->
          "Pass phase_assignees with agent-typed assignee_id + assignee_type for execution and review. " <>
            "Since ADR 0044 §5, task_create fans a flat agent-typed assignee_id into every absent phase " <>
            "slot when auto_approve_plan is true — so this refusal means the flat assignee was user-typed " <>
            "or missing (or a slot was explicitly nil): supply explicit agent-typed phase_assignees."

        :update ->
          "On task_update a flat agent-typed assignee_id + assignee_type with auto_approve_plan true routes " <>
            "to the current-phase slot AND fills every absent phase slot (ADR 0044 §5), so this refusal " <>
            "means the flat assignee was user-typed or missing, or a failing slot is present-but-invalid — " <>
            "user-typed, explicitly nil, or an id that does not resolve: supply explicit agent-typed " <>
            "phase_assignees."
      end

    suggestion =
      if corrected_args do
        suggestion <>
          " corrected_args carries this call's arguments with the absent phase slots filled — resubmit it verbatim."
      else
        suggestion
      end

    envelope = %{
      error:
        "auto_approve_plan requires an agent assignee on both the execution and review phases.",
      code: :auto_approve_precondition_missing,
      missing_phases: phases,
      suggestion: suggestion,
      recoverable: true,
      submitted_args: submitted_args
    }

    case corrected_args do
      nil -> envelope
      corrected -> Map.put(envelope, :corrected_args, corrected)
    end
  end

  # Resolve the `attached_by` identity from the federated tool context.
  # Prefers explicit kind+id pairs (agent/user); falls back to nil so the
  # changeset surface returns a friendly `attached_by` validation error
  # rather than silently mis-attributing the row.
  defp resolve_attached_by(context) when is_map(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) ->
        %{kind: "agent", id: Map.get(context, :agent_id)}

      is_binary(Map.get(context, :user_id)) ->
        %{kind: "user", id: Map.get(context, :user_id)}

      true ->
        %{}
    end
  end

  defp resolve_attached_by(_), do: %{}

  # The AUTHORIZATION subject for canvas-touching task tools (task 019e2c4b
  # stage 2). Shaped like `resolve_attached_by/1` and read from the same
  # context, but kept separate on purpose: that one produces the attribution
  # recorded on the row, which is caller-supplied metadata, while this one
  # answers "who is asking".
  #
  # Neither key present → `nil`, which `Platform.Chat.CanvasAccess` treats as
  # no principal and denies. It deliberately does not fall back to `:system`.
  defp canvas_authorization_actor(context) when is_map(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) -> {:agent, Map.get(context, :agent_id)}
      is_binary(Map.get(context, :user_id)) -> {:user, Map.get(context, :user_id)}
      true -> nil
    end
  end

  defp canvas_authorization_actor(_), do: nil

  # ── The canvas-attachment refusal taxonomy (task 019fb581 stage 5) ───────

  # The CLOSED set of refusal atoms each canvas-attachment clause must handle,
  # keyed by tool. These are `Platform.Tasks.CanvasAttachments`' return atoms,
  # which is the boundary the three clauses actually pattern-match on — so a
  # fifth atom added there with no clause here is a `CaseClauseError` at
  # runtime, i.e. a 500 rather than a refusal.
  #
  # Declared rather than inferred so a test can drive every atom for real and
  # compare the driven set against this one, the same way
  # `@design_decline_error_codes` above is compared against
  # `task_design_decline`'s emissions. Restating the taxonomy in a test would
  # only pin the test against itself.
  #
  # `attach_canvas/4` can also return `{:error, %Ecto.Changeset{}}`, which is
  # a struct rather than an atom and is deliberately NOT in this set: it is a
  # validation failure on `attached_by`, not an authorization outcome, and it
  # has no place in a taxonomy an agent branches on.
  @canvas_attachment_error_codes %{
    "task_attach_canvas" => [
      :task_forbidden,
      :task_not_found,
      :canvas_forbidden,
      :canvas_not_found
    ],
    "task_detach_canvas" => [:task_forbidden, :task_not_found, :not_found],
    "task_list_canvases" => [:task_forbidden, :task_not_found]
  }

  # THE ASYMMETRY, DECLARED RATHER THAN DISCOVERED. Only `:task_forbidden`
  # reaches the caller as a machine-readable `code` key. The other four are
  # prose-only: the caller has to string-match `error` to tell them apart.
  #
  # Stage 5 did NOT widen this. Adding `code:` to the other four envelopes is
  # additive on the wire (`MCPController.error_content/1` drops nil keys, so
  # nothing currently branches on their absence) and would make the taxonomy
  # usable, but it is a wire-behaviour change and this is the stage that
  # catches wrongness rather than the stage that introduces it. Recorded here
  # and pinned by a test so the next person decides it deliberately instead of
  # inheriting it. Raised to the review stage of task 019fb581.
  @canvas_attachment_coded_errors [:task_forbidden]

  @doc """
  The closed set of refusal atoms each canvas-attachment tool must handle.

  Public so the guard that keeps the three tools' `limitations` prose honest
  can compare the documented taxonomy against the emitted one instead of
  restating either. Keyed by tool name; see `@canvas_attachment_error_codes`
  for why the set is the `Platform.Tasks.CanvasAttachments` boundary atoms
  rather than the envelope `code` values.
  """
  @spec canvas_attachment_error_codes() :: %{String.t() => [atom()]}
  def canvas_attachment_error_codes, do: @canvas_attachment_error_codes

  @doc """
  The subset of `canvas_attachment_error_codes/0` that reaches the caller as a
  machine-readable `code` key rather than as prose in `error`.
  """
  @spec canvas_attachment_coded_errors() :: [atom()]
  def canvas_attachment_coded_errors, do: @canvas_attachment_coded_errors

  # ── ADR-0046 member 7 stage 2: task_design_decline internals ─────────────

  # The closed set of refusal codes the `task_design_decline` clause can
  # emit. The tool's `limitations` prose names exactly these, and a test
  # compares the two sets rather than restating either — documentation that
  # drifts from the code is worse than none, because remote runtimes branch
  # on it.
  @design_decline_error_codes [
    :missing_task_id,
    :missing_reason,
    :task_not_found,
    :step_not_open,
    :decline_failed
  ]

  # A reason short enough to be a placeholder ("n/a", "none", "no") is worse
  # than no decline at all: the step closes and the classifier observation
  # that justified recording anything is lost. Eight graphemes is the
  # cheapest bar that rejects every placeholder anyone actually types.
  @design_decline_min_reason 8

  @doc """
  The closed set of `code` values `task_design_decline` refuses with.

  Public so the guard that keeps the tool's `limitations` prose honest can
  compare the documented taxonomy against the emitted one instead of
  restating it.
  """
  @spec design_decline_error_codes() :: [atom()]
  def design_decline_error_codes, do: @design_decline_error_codes

  defp design_decline_task_id_arg(task_id) when is_binary(task_id) do
    case String.trim(task_id) do
      "" -> design_decline_error(:missing_task_id, task_id)
      trimmed -> {:ok, trimmed}
    end
  end

  defp design_decline_task_id_arg(task_id), do: design_decline_error(:missing_task_id, task_id)

  defp design_decline_reason_arg(reason) when is_binary(reason) do
    case String.trim(reason) do
      trimmed when byte_size(trimmed) == 0 ->
        design_decline_error(:missing_reason, reason)

      trimmed ->
        if String.length(trimmed) < @design_decline_min_reason do
          design_decline_error(:missing_reason, reason)
        else
          {:ok, trimmed}
        end
    end
  end

  defp design_decline_reason_arg(reason), do: design_decline_error(:missing_reason, reason)

  # `Platform.UUID.cast/1`, not a bare `Repo.get/2`: `task_id` arrives
  # straight off an agent's tool payload, and `repo_lookup_boundary_test.exs`
  # ratchets against bare casts on agent-facing paths. Resolving HERE rather
  # than letting `decline/3` do it is what separates `task_not_found` from
  # `step_not_open` — `decline/3` collapses both to `{:ok, :noop}`, and a
  # designer who mistyped a task id must not be told her step already settled.
  defp design_decline_task(task_id) do
    with {:ok, uuid} <- Platform.UUID.cast(task_id),
         %Task{} = task <- Repo.get(Task, uuid) do
      {:ok, task}
    else
      _ -> design_decline_error(:task_not_found, task_id)
    end
  end

  defp record_design_decline(%Task{} = task, note, context) do
    case PreplanStep.decline(task, note, declined_by: resolve_attached_by(context)) do
      {:ok, :noop} ->
        design_decline_error(:step_not_open, task.id)

      {:ok, outcome} ->
        {:ok, design_decline_result(task, outcome)}

      # UNREACHABLE from here — `design_decline_reason_arg/1` already refused
      # every non-binary note. Mapped anyway, and mapped to `missing_reason`
      # rather than `decline_failed`: `:invalid_note` is the caller's own bad
      # argument, and reporting it as "the step already settled" or "the write
      # failed" would misattribute a client error to task state.
      {:error, :invalid_note} ->
        design_decline_error(:missing_reason, note)

      {:error, reason} ->
        design_decline_error(:decline_failed, reason)
    end
  end

  # `declined_after_timeout` is read back off the PERSISTED entry rather than
  # inferred: `decline/3` returns only the outcome, and the upgrade marker is
  # the anti-collapse property this tool's caller most needs reported.
  defp design_decline_result(%Task{} = task, outcome) do
    entry =
      case Tasks.get_task_record(task.id) do
        %Task{planning_step_outcomes: %{"design" => %{} = entry}} -> entry
        _ -> %{}
      end

    %{
      task_id: task.id,
      outcome: to_string(outcome),
      reason: PreplanStep.reasons().declined,
      declined_after_timeout: Map.get(entry, "declined_after_timeout") == true
    }
  end

  defp design_decline_error(:missing_task_id, task_id) do
    design_decline_refusal(
      :missing_task_id,
      "task_design_decline requires task_id (non-blank string), got #{inspect(task_id)}.",
      true,
      "Pass the UUID printed as `task_id:` in the design dispatch prompt."
    )
  end

  defp design_decline_error(:missing_reason, _reason) do
    design_decline_refusal(
      :missing_reason,
      "reason is required and must be a non-blank string of at least #{@design_decline_min_reason} characters.",
      true,
      "One sentence: why this task needs no design direction. A decline with no stated reason closes the step but tells nobody whether the UI classifier misfired, which is the only thing this record is for."
    )
  end

  defp design_decline_error(:task_not_found, task_id) do
    design_decline_refusal(
      :task_not_found,
      "Task not found: #{inspect(task_id)}",
      false,
      "Use the `task_id` printed in the design dispatch prompt, or task_list to look it up."
    )
  end

  # Named against the ACTUAL state, not "the step is not open": a designer who
  # calls twice, or who declines a task the deadline already closed and reopened
  # by some other path, has to read an explanation rather than a mystery.
  defp design_decline_error(:step_not_open, task_id) do
    design_decline_refusal(
      :step_not_open,
      "The design step for task #{task_id} is not open: it already settled, was skipped, or never fired.",
      false,
      "Nothing changed — a decline never overwrites a delivered canvas or a completed step. If you already attached a canvas for this task, that delivery stands. Use task_get to see the recorded planning-step outcome."
    )
  end

  defp design_decline_error(:decline_failed, reason) do
    design_decline_refusal(
      :decline_failed,
      "Failed to record the decline: #{inspect_errors_safe(reason)}",
      true,
      "The step was left as it was. Retry once; if it refuses again, report a blocker rather than attaching a canvas you do not believe in."
    )
  end

  defp design_decline_refusal(code, error, recoverable, suggestion)
       when code in @design_decline_error_codes do
    {:error, %{code: code, error: error, recoverable: recoverable, suggestion: suggestion}}
  end

  defp locate_intent_meeting(intent_id) do
    case Meetings.IntentQueue.locate(intent_id) do
      {:ok, meeting_id} ->
        {:ok, meeting_id}

      {:error, :not_found} ->
        {:error,
         %{
           error: "Intent not found: #{intent_id}",
           recoverable: false,
           suggestion:
             "The intent queue is meeting-lifetime — if the meeting has ended its queue is gone, and there is nothing left to ack. Verify the intent_id came from a live meeting's dispatch signal."
         }}
    end
  end

  # Explicit string -> atom table rather than `String.to_existing_atom/1`:
  # this is a remote-supplied value, and an allowlist that can't depend on
  # which modules happen to be loaded is the honest way to convert it.
  @intent_ack_statuses %{
    "working" => :working,
    "completed" => :completed,
    "rejected" => :rejected,
    "cancel_honored" => :cancel_honored
  }

  defp validate_intent_ack_status(status) when is_binary(status) do
    case Map.fetch(@intent_ack_statuses, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> invalid_intent_ack_status(status)
    end
  end

  defp validate_intent_ack_status(status) when is_atom(status) and not is_nil(status) do
    validate_intent_ack_status(Atom.to_string(status))
  end

  defp validate_intent_ack_status(status), do: invalid_intent_ack_status(status)

  defp invalid_intent_ack_status(status) do
    allowed = @intent_ack_statuses |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    {:error,
     %{
       error: "status must be one of #{allowed} (got #{inspect(status)})",
       recoverable: true,
       suggestion:
         "Use `working` right after spawning the subagent, `completed` when it finishes, `rejected` if the intent isn't yours, `cancel_honored` after stopping a cancelled subagent."
     }}
  end

  # A rejected subagent_id is EVIDENCE, not just an error: it means the
  # runtime tried to ack and could not name a subagent. The queue counts
  # those attempts so an eventual timeout is reported as
  # `:no_ack_spawn_failed` (broken target) rather than `:timed_out`
  # (nothing came back). Recording the attempt does not touch the row.
  defp validate_intent_subagent_id(meeting_id, intent_id, supplied) do
    case validate_subagent_id(supplied) do
      {:ok, subagent_id} ->
        {:ok, subagent_id}

      {:error, envelope} ->
        _ = Meetings.IntentQueue.record_rejected_ack(meeting_id, intent_id)
        {:error, envelope}
    end
  end

  defp apply_intent_ack(meeting_id, intent_id, subagent_id, ack_status, note) do
    case Meetings.IntentQueue.ack(meeting_id, intent_id, subagent_id, ack_status, note) do
      {:ok, row} ->
        {:ok,
         %{
           intent_id: intent_id,
           meeting_id: meeting_id,
           status: row.status,
           subagent_id: row.subagent_id,
           acked_at: row.acked_at
         }}

      {:error, {:invalid_ack_state, current}} ->
        {:error,
         %{
           error: "Intent #{intent_id} is #{current} — cannot ack it with #{ack_status}.",
           recoverable: false,
           suggestion:
             "Only a dispatched or acked intent can be acked. A `queued` intent hasn't been sent to you yet; a terminal one has already been resolved (completed, cancelled, or timed out)."
         }}

      {:error, :not_found} ->
        {:error,
         %{
           error: "Intent not found: #{intent_id}",
           recoverable: false,
           suggestion:
             "The row was removed from its meeting's queue — most likely the meeting's producer cancelled it, or the meeting ended."
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to ack intent: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Retry once; if it persists the meeting's queue is no longer running."
         }}
    end
  end

  # Presence + shape guard for the `subagent_id` param on task_ack. Hard-rejects
  # (task 019f6c73) rather than warn-and-drift: any in-flight dispatch that
  # skips the param fails its next ack immediately rather than silently drifting
  # into a 90-minute no-ack stall. No format policing beyond presence + byte cap
  # so both openclaw runtime slugs (e.g. `higgins.moon`) and Claude Code
  # Task-tool agentIds (e.g. `afd767f1e0cc81633`) fit through the same gate.
  defp validate_subagent_id(nil) do
    {:error,
     %{
       error: "subagent_id is required",
       recoverable: true,
       suggestion:
         "Spawn the subagent (SuiteExecutor / SuiteReviewer via the Agent tool) FIRST, then pass its returned agent id here."
     }}
  end

  defp validate_subagent_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error,
         %{
           error: "subagent_id is required",
           recoverable: true,
           suggestion:
             "Spawn the subagent (SuiteExecutor / SuiteReviewer via the Agent tool) FIRST, then pass its returned agent id here."
         }}

      String.trim(id) == "" ->
        {:error,
         %{
           error: "subagent_id must not be whitespace-only",
           recoverable: true,
           suggestion:
             "subagent_id was whitespace-only — pass the spawn call's returned agent id verbatim."
         }}

      byte_size(id) > 128 ->
        {:error,
         %{
           error: "subagent_id exceeds 128 bytes",
           recoverable: true,
           suggestion:
             "Truncate to the spawn call's returned id — free-form annotations don't belong in this field."
         }}

      true ->
        {:ok, id}
    end
  end

  defp validate_subagent_id(_) do
    {:error,
     %{
       error: "subagent_id must be a string",
       recoverable: true,
       suggestion:
         "Pass the spawn call's returned agent id as a plain string (e.g. `higgins.moon` or `afd767f1e0cc81633`)."
     }}
  end

  # Prefer the explicit stage_id from args; otherwise resolve from the
  # task's current plan. Both branches return {:ok, stage_id} or an error
  # the caller maps to a recoverable envelope.
  #
  # THE SUPPLIED ID IS CHECKED, NOT TRUSTED (task 01a0a633 stage 1).
  # Before this guard the supplied clause accepted any non-empty binary:
  # it never asked whether the stage existed, whether it belonged to
  # `task_id`, or whether it was running. That matters because
  # `TaskRouter.live_acked_executor?/2` suppresses dispatch whenever
  # `Orchestration.last_stage_ack_at(task_id, stage.id)` falls inside the
  # safety-net window, consulting neither the acker's identity nor its
  # liveness — so an ack naming a stage that is not the one being worked
  # parks that stage for the whole window (~90m; 120m in planning).
  #
  # SCOPE, stated as scope and not as an exception: this guard covers
  # acks naming a stage of the SAME task the caller passed. It is not a
  # cross-task defence and does not need to be — `last_stage_ack_at/2`
  # keys on (task_id, stage_id) and the event is written under the
  # CALLER's task_id, so an ack can never write a suppression row a
  # sibling task's router would read.
  #
  # Three distinct errors, not one "invalid stage": a caller holding a
  # stale id, a caller holding another task's id, and a caller racing a
  # stage transition have three different next actions.
  defp resolve_ack_stage_id(task_id, stage_id) when is_binary(stage_id) and stage_id != "" do
    # `Platform.UUID.cast/1`, not a bare `Repo.get/2`: the id arrives
    # straight off an agent's tool payload, and `repo_lookup_boundary_test.exs`
    # ratchets against bare casts on agent-facing paths.
    with {:ok, uuid} <- Platform.UUID.cast(stage_id),
         %Stage{} = stage <- Repo.get(Stage, uuid) |> Repo.preload(:plan) do
      cond do
        is_nil(stage.plan) or stage.plan.task_id != task_id ->
          {:error, {:stage_wrong_task, stage.plan && stage.plan.task_id}}

        stage.status != "running" ->
          {:error, {:stage_not_running, stage.status}}

        true ->
          {:ok, stage.id}
      end
    else
      _ -> {:error, :stage_not_found}
    end
  end

  defp resolve_ack_stage_id(task_id, _) do
    case Tasks.current_plan(task_id) do
      nil ->
        {:error, :no_running_stage}

      plan ->
        case Enum.find(plan.stages || [], &(&1.status == "running")) do
          nil -> {:error, :no_running_stage}
          stage -> {:ok, stage.id}
        end
    end
  end

  # Envelope for the supplied-stage_id refusals. `:no_running_stage` is
  # deliberately NOT handled here — its wording is asserted verbatim by
  # `prompt_templates.ex`, `heartbeat_scheduler.ex` and
  # `dispatch_planning_ack_test.exs`, and it differs per calling tool
  # ("cannot ack" vs "cannot silence"), so each call site keeps its own.
  defp supplied_stage_id_envelope(:stage_not_found, stage_id, _task_id) do
    %{
      error: "stage_id=#{stage_id} does not exist.",
      recoverable: true,
      suggestion:
        "Re-read the stage_id from your dispatch payload, or omit stage_id entirely to let the system derive the task's running stage."
    }
  end

  defp supplied_stage_id_envelope({:stage_wrong_task, owner_task_id}, stage_id, task_id) do
    %{
      error:
        "stage_id=#{stage_id} belongs to task_id=#{owner_task_id || "unknown"}, not task_id=#{task_id}.",
      recoverable: true,
      suggestion:
        "Use the stage_id from THIS task's dispatch payload, or omit stage_id entirely to let the system derive the task's running stage."
    }
  end

  defp supplied_stage_id_envelope({:stage_not_running, status}, stage_id, _task_id) do
    %{
      error: "stage_id=#{stage_id} is #{status}, not running.",
      recoverable: true,
      suggestion:
        "Only a running stage can be acked. Re-read the stage_id from your dispatch payload, or omit stage_id entirely to let the system derive the task's running stage."
    }
  end

  # Catch-all. The three heads above are shape-complete only by
  # coincidence of today's atom set in `resolve_ack_stage_id/2`: a fourth
  # reason added later would raise FunctionClauseError from inside the
  # `else` that exists to turn crashes into refusals. This head keeps the
  # tool boundary refusal-only whatever reason arrives.
  defp supplied_stage_id_envelope(reason, stage_id, task_id) do
    %{
      error: "stage_id=#{stage_id} was refused for task_id=#{task_id}: #{inspect(reason)}.",
      recoverable: true,
      suggestion:
        "Re-read the stage_id from your dispatch payload, or omit stage_id entirely to let the system derive the task's running stage."
    }
  end

  # Persist + broadcast the execution.acked runtime_event and refresh the
  # LeaseManager row belt-and-braces. Returns the tool envelope with
  # `next_safety_net_at` reflecting whatever the lease now holds (nil
  # when no lease is armed — planning phase or manual_approval stages).
  defp emit_task_ack(task_id, stage_id, subagent_id, context) do
    acked_at = DateTime.utc_now()

    attrs = %{
      "task_id" => task_id,
      "phase" => current_phase_for_blocker(task_id),
      "runtime_id" => Map.get(context, :runtime_id) || "tool-surface",
      "event_type" => "execution.acked",
      "execution_space_id" => execution_space_id_for_task(task_id),
      "occurred_at" => acked_at,
      "payload" => %{
        "stage_id" => stage_id,
        "acked_at" => DateTime.to_iso8601(acked_at),
        "runtime_id" => Map.get(context, :runtime_id) || "tool-surface",
        "subagent_id" => subagent_id
      }
    }

    # LeaseManager write is best-effort — a `:not_found` here is expected
    # when the router hasn't recorded the dispatch yet (boot race, or the
    # ack raced ahead of the arm-liveness path). The runtime_event still
    # persists and the router's own `apply_runtime_event/2` clause will
    # call `record_ack/1` again when the PubSub broadcast arrives.
    # Task 01a007bf stage 4: match on the return so the `:not_found` is
    # visible in the log instead of vanishing into `_`. Worded as
    # "expected" — this site runs BEFORE `record_runtime_event/1`.
    case Platform.Orchestration.LeaseManager.record_ack(task_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "[ToolSurface.task_ack] task #{task_id} stage #{stage_id} — LeaseManager.record_ack/1 returned :not_found: no ETS lease armed yet (expected during the dispatch race); the durable execution.acked row is still being written. No operator action needed."
        )
    end

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, event} ->
        next_safety_net_at =
          case Platform.Orchestration.LeaseManager.get(task_id) do
            %{safety_net_at: %DateTime{} = ts} -> ts
            _ -> nil
          end

        {:ok,
         %{
           task_id: task_id,
           stage_id: stage_id,
           event_id: event.id,
           acked_at: acked_at,
           next_safety_net_at: next_safety_net_at
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to record ack: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Retry task_ack or push validation_pass evidence to prove liveness."
         }}
    end
  end

  defp validate_alarm_silence_task_id(nil), do: alarm_silence_missing_field_error("task_id")
  defp validate_alarm_silence_task_id(""), do: alarm_silence_missing_field_error("task_id")
  defp validate_alarm_silence_task_id(id) when is_binary(id), do: :ok
  defp validate_alarm_silence_task_id(_), do: alarm_silence_missing_field_error("task_id")

  defp validate_alarm_silence_until_seconds(nil),
    do: alarm_silence_missing_field_error("until_seconds")

  defp validate_alarm_silence_until_seconds(n) when is_integer(n) and n >= 60 and n <= 86_400,
    do: :ok

  defp validate_alarm_silence_until_seconds(_) do
    {:error,
     %{
       error: "until_seconds must be an integer in the range 60..86_400 (1m..24h)",
       recoverable: true,
       suggestion:
         "Pass a positive integer between 60 (1 minute floor) and 86_400 (24 hour cap). Re-silence if you need to extend."
     }}
  end

  defp validate_alarm_silence_reason(reason)
       when is_binary(reason) and byte_size(reason) >= 8,
       do: :ok

  defp validate_alarm_silence_reason(_) do
    {:error,
     %{
       error: "reason must be a string of at least 8 characters",
       recoverable: true,
       suggestion:
         "Describe why you're silencing the alarm — the reason is audit-logged so operators can later explain the override."
     }}
  end

  defp alarm_silence_missing_field_error(field) do
    {:error,
     %{
       error: "#{field} is required",
       recoverable: true,
       suggestion:
         "alarm_silence needs task_id, until_seconds (60..86_400), and reason (>= 8 chars). Optional: stage_id (resolves from current running stage if omitted)."
     }}
  end

  defp fetch_alarm_silence_task(task_id) do
    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion:
             "Verify the task_id matches your dispatch payload; use task_list to enumerate live tasks."
         }}

      task ->
        {:ok, task}
    end
  end

  # Persist the runtime_event, emit telemetry, and call LeaseManager.silence/3.
  # The LeaseManager call is the source of truth for the router — if it
  # returns :not_found, we surface a recoverable error without emitting
  # audit noise for a lease that doesn't exist.
  defp emit_alarm_silence(task_id, stage_id, until, reason, context) do
    case Platform.Orchestration.LeaseManager.silence(task_id, until, reason) do
      :ok ->
        record_alarm_silence_side_effects(task_id, stage_id, until, reason, context)

      {:error, :not_found} ->
        {:error,
         %{
           error: "No active lease for task #{task_id} — dispatch not yet recorded.",
           recoverable: true,
           suggestion:
             "Wait for the router to arm liveness (typically <1s post-dispatch) then retry."
         }}

      {:error, :invalid_until} ->
        {:error,
         %{
           error: "silenced_until must be strictly in the future",
           recoverable: true,
           suggestion:
             "The lease manager rejected the computed silenced_until as non-future — this usually means clock skew; try a slightly larger until_seconds."
         }}

      {:error, :cap_exceeded} ->
        {:error,
         %{
           error: "silenced_until exceeds the 24h cap",
           recoverable: true,
           suggestion:
             "Silence is capped at 24 hours to prevent indefinite alarm suppression. Use a smaller until_seconds and re-silence if the condition persists."
         }}
    end
  end

  defp record_alarm_silence_side_effects(task_id, stage_id, until, reason, context) do
    silenced_at = DateTime.utc_now()
    runtime_id = Map.get(context, :runtime_id) || "tool-surface"

    attrs = %{
      "task_id" => task_id,
      "phase" => current_phase_for_blocker(task_id),
      "runtime_id" => runtime_id,
      "event_type" => "execution.alarm_silenced",
      "execution_space_id" => execution_space_id_for_task(task_id),
      "occurred_at" => silenced_at,
      "payload" => %{
        "stage_id" => stage_id,
        "silenced_until" => DateTime.to_iso8601(until),
        "reason" => reason,
        "runtime_id" => runtime_id
      }
    }

    # Persist the runtime_event first — it's the durable audit trail and
    # PubSub broadcast target. Telemetry is fire-and-forget on top; a
    # runtime_event persist failure returns an error envelope without
    # emitting telemetry (which would create an audit row for a silence
    # that never actually landed in the event stream).
    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, _event} ->
        # silenced_until is passed as ISO-8601 because the audit
        # TelemetryHandler's ensure_json_safe/1 recurses into maps and
        # DateTime (which IS a map) doesn't implement Enumerable — an
        # unwrapped %DateTime{} in the metadata crashes the handler.
        # actor_type is "system" (not "runtime") because
        # Platform.Audit.Event's actor_type enum only accepts
        # system|user|agent|anonymous|federated_user, and actor_id is
        # left nil because runtime IDs are opaque strings, not UUIDs
        # (the schema casts actor_id as Ecto.UUID). runtime_id + the
        # opaque caller identity ride in metadata for correlation.
        :telemetry.execute(
          [:platform, :orchestration, :alarm_silence],
          %{count: 1},
          %{
            task_id: task_id,
            stage_id: stage_id,
            silenced_until: DateTime.to_iso8601(until),
            reason: reason,
            runtime_id: runtime_id,
            actor_type: "system",
            resource_type: "task",
            resource_id: task_id,
            action: "silence"
          }
        )

        {:ok,
         %{
           task_id: task_id,
           stage_id: stage_id,
           silenced_until: until,
           reason: reason
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to record alarm silence: #{inspect(reason)}",
           recoverable: true,
           suggestion:
             "Retry alarm_silence. LeaseManager.silence has already applied; the runtime_event will re-emit on retry."
         }}
    end
  end

  # Resolves a task's declared dependency entries into the canonical
  # `[%{task_id, title, kind, status}]` shape, preserving the order the
  # author wrote them in. Missing/deleted dep ids return entries with
  # `title: nil` and `status: nil` but always carry the `task_id` and
  # `kind` from the source map (so callers can still see the broken
  # reference rather than silently dropping it).
  defp build_dependency_entries(%Task{dependencies: deps}) when is_list(deps) do
    ids =
      deps
      |> Enum.map(&Map.get(&1, "task_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    rows_by_id =
      case ids do
        [] ->
          %{}

        ids ->
          Repo.all(
            from(t in Task,
              where: t.id in ^ids,
              select: %{id: t.id, title: t.title, status: t.status}
            )
          )
          |> Map.new(&{&1.id, &1})
      end

    Enum.map(deps, fn dep ->
      task_id = Map.get(dep, "task_id")
      kind = Map.get(dep, "kind")
      row = Map.get(rows_by_id, task_id)

      %{
        task_id: task_id,
        title: row && row.title,
        kind: kind,
        status: row && row.status
      }
    end)
  end

  defp build_dependency_entries(_), do: []

  # Inverse: tasks that declare this task as one of their dependencies.
  # Uses the same JSONB containment query the unblock sweep relies on
  # (`fragment("? @> ?", t.dependencies, ^[%{"task_id" => id}])`). Sorted
  # by `inserted_at` so the result is deterministic across runs.
  defp build_dependent_entries(%Task{id: id}) do
    match = [%{"task_id" => id}]

    Repo.all(
      from(t in Task,
        where:
          fragment("? @> ?", t.dependencies, ^match) and
            is_nil(t.deleted_at),
        order_by: [asc: t.inserted_at, asc: t.id],
        select: %{id: t.id, title: t.title, status: t.status}
      )
    )
    |> Enum.map(fn row -> %{task_id: row.id, title: row.title, status: row.status} end)
  end

  # `stack_update` conflict exit helpers (task 01a05393 stage 4).
  defp stack_update_conflict_precheck(_stack, false), do: :ok

  defp stack_update_conflict_precheck(%Stack{} = stack, true) do
    if Platform.Tasks.Stacks.ShipState.conflict_held?(stack),
      do: :ok,
      else: {:error, :not_conflicted}
  end

  defp maybe_clear_stack_conflict(%Stack{} = stack, false), do: {:ok, stack}

  defp maybe_clear_stack_conflict(%Stack{} = stack, true) do
    # The handler broadcasts the final envelope once; suppress the
    # function's own event so one clear yields one `:stack_updated`.
    Stacks.clear_conflict(stack, broadcast: false)
  end

  # Nilable-semantics writer: only `sponsor_user_id` propagates explicit
  # nil (clears the slot); `name` and `description` are dropped when
  # omitted OR when nil (unset ≠ clear for those). Mirrors the
  # `TaskAttrs.build_task_attrs/3` contract for the stack surface.
  defp build_stack_update_attrs(args) do
    base = %{}

    base =
      case Map.fetch(args, "name") do
        {:ok, nil} -> base
        {:ok, value} -> Map.put(base, :name, value)
        :error -> base
      end

    base =
      case Map.fetch(args, "description") do
        {:ok, nil} -> base
        {:ok, value} -> Map.put(base, :description, value)
        :error -> base
      end

    case Map.fetch(args, "sponsor_user_id") do
      {:ok, value} -> Map.put(base, :sponsor_user_id, value)
      :error -> base
    end
  end

  # Build the `attrs_by_phase` map from the tool args. If any per-phase id
  # (`planning`/`execution`/`review`) is present, advanced mode is used and
  # the simple `assignee_id` is ignored; otherwise simple mode applies the
  # single `assignee_id` to all three phases. An empty string clears a
  # phase. Phases entirely absent from the args are omitted from the map so
  # `set_stack_phase_assignees/2` merges them phase-by-phase.
  defp build_stack_assignee_attrs(args) do
    per_phase = ["planning", "execution", "review"]
    has_per_phase? = Enum.any?(per_phase, &Map.has_key?(args, &1))

    if has_per_phase? do
      per_phase
      |> Enum.filter(&Map.has_key?(args, &1))
      |> Map.new(fn phase -> {phase, stack_phase_entry(Map.get(args, phase))} end)
    else
      case Map.fetch(args, "assignee_id") do
        {:ok, id} ->
          entry = stack_phase_entry(id)
          %{"planning" => entry, "execution" => entry, "review" => entry}

        :error ->
          %{}
      end
    end
  end

  defp stack_phase_entry(id) when is_binary(id) and id != "",
    do: %{"assignee_id" => id, "assignee_type" => "agent"}

  defp stack_phase_entry(_), do: %{}

  # `stack_start`'s `:invalid_stack_status` suggestion (task 01a05393
  # stage 4). The handler already holds the `%Stack{}`, so name the action
  # that is legal for the status it saw instead of sending the caller to
  # `stack_get` — a read, and one that `stack_plans_pending_envelope/2`
  # used to point back at. The `abandoned` wording states what
  # `Stacks.abandon_stack/2` does on this branch: `stack_pending` /
  # `planning` / `backlog` members go to `backlog`, `in_progress` members
  # go to `blocked`, and those demoted members are detached; members that
  # landed on the rollup keep their membership.
  defp stack_start_refusal_suggestion(%Stack{status: "abandoned"}) do
    "This stack is abandoned; abandoning it released its unfinished members (stack_pending, planning and backlog members were returned to backlog and detached, in_progress members were moved to blocked and detached; members that landed on the rollup keep their membership). Start a released task directly with task_start, or create a new stack with stack_create."
  end

  defp stack_start_refusal_suggestion(%Stack{status: "in_progress"}) do
    "This stack is already in_progress; there is nothing to start. Members still parked at stack_pending are promoted by the in-stack sweep once their predecessors land on the rollup."
  end

  defp stack_start_refusal_suggestion(%Stack{status: "blocked"}) do
    "This stack is blocked on a rollup merge conflict recorded in its metadata. Resolve the conflict (an operator returns the stack to in_progress); no member can be started until then."
  end

  defp stack_start_refusal_suggestion(%Stack{status: "done"}) do
    "This stack is done; its work has shipped. Create a new stack with stack_create for further work."
  end

  defp stack_start_refusal_suggestion(%Stack{status: status})
       when status in ["in_review", "deploying"] do
    "This stack is #{status}; its rollup is already landing. Wait for it to finish, then stack_complete once every member is done, or create a new stack with stack_create for further work."
  end

  defp stack_start_refusal_suggestion(%Stack{status: status}) do
    "This stack is #{status}, which stack_start does not accept. Create a new stack with stack_create if you need one that can be started."
  end

  defp stack_start_payload(%Stack{} = stack, started, parked, errors) do
    payload =
      stack
      |> serialize_stack()
      |> Map.merge(%{
        started: Enum.map(started, &serialize_stack_member/1),
        parked: Enum.map(parked, &serialize_stack_member/1)
      })

    case errors do
      [] -> payload
      _ -> Map.put(payload, :cascade_errors, errors)
    end
  end

  # `unassigned` (task 01a05394 stage 4) is ALWAYS emitted — `[]` when
  # every considered member resolved a planner — so a caller can tell
  # "none unassigned" from "old server that never reported the key".
  defp stack_start_planning_payload(
         %Stack{} = stack,
         planning,
         unassigned,
         errors,
         edges_authored,
         edges_skipped_reason,
         opts
       ) do
    payload =
      stack
      |> serialize_stack()
      |> Map.put(:planning, Enum.map(planning, &serialize_stack_member/1))
      |> Map.put(:unassigned, Enum.map(unassigned, &serialize_stack_member/1))
      |> Map.put(:edges_authored, edges_authored)
      |> maybe_put_edges_skipped_reason(edges_skipped_reason)
      |> maybe_put_mode(Keyword.get(opts, :mode))
      |> maybe_put_waves_total(Keyword.get(opts, :waves_total))

    case errors do
      [] -> payload
      _ -> Map.put(payload, :cascade_errors, errors)
    end
  end

  # `mode` and `waves_total` are Stack v2 stage 6 fields on the
  # `start_planning/1` return shape. Emit them on the payload when the
  # caller passes them through so the MCP contract matches the tool
  # `returns` doc without breaking legacy callers that still use the
  # 5-arity form.
  defp maybe_put_mode(payload, nil), do: payload
  defp maybe_put_mode(payload, mode) when is_atom(mode), do: Map.put(payload, :mode, mode)

  defp maybe_put_waves_total(payload, nil), do: payload

  defp maybe_put_waves_total(payload, waves_total) when is_integer(waves_total),
    do: Map.put(payload, :waves_total, waves_total)

  # Include `edges_skipped_reason` only when inference was skipped or
  # terminally failed — the happy path (inference ran and wrote edges)
  # doesn't need a nil key cluttering the payload. Dep-inference stage 4
  # (ADR 0045).
  defp maybe_put_edges_skipped_reason(payload, nil), do: payload

  defp maybe_put_edges_skipped_reason(payload, reason) when is_atom(reason),
    do: Map.put(payload, :edges_skipped_reason, reason)

  # ── stack_retry_member_merge envelopes (task 01a05392 stage 3) ──────────

  defp retry_merge_envelope({:ok, %{status: :merged, merge_sha: sha}}, %Task{} = task, rollup) do
    {:ok,
     %{
       outcome: "merged",
       task_id: task.id,
       stack_id: task.stack_id,
       rollup_branch: rollup,
       merge_sha: sha,
       task: serialize_task(Tasks.get_task_record(task.id))
     }}
  end

  defp retry_merge_envelope({:ok, :already_merged}, %Task{} = task, rollup) do
    reloaded = Tasks.get_task_record(task.id)

    {:ok,
     %{
       outcome: "already_merged",
       task_id: task.id,
       stack_id: task.stack_id,
       rollup_branch: rollup,
       merged_into_rollup_at: metadata_map_field(reloaded, "merged_into_rollup_at"),
       task: serialize_task(reloaded)
     }}
  end

  defp retry_merge_envelope({:ok, {:not_ready, reason}}, %Task{} = task, rollup) do
    {:error,
     %{
       code: :member_not_ready,
       outcome: "not_ready",
       error:
         "Task #{task.id} is not in a state the deployer will merge into " <>
           "#{inspect(rollup)}: #{retry_not_ready_detail(task, reason)}",
       recoverable: reason != :member_past_review,
       reason: retry_not_ready_reason(reason),
       suggestion: retry_not_ready_suggestion(reason)
     }}
  end

  defp retry_merge_envelope(
         {:error, :not_fast_forwardable, %{member_sha: member_sha, rollup_sha: rollup_sha}},
         %Task{} = task,
         rollup
       ) do
    {:error,
     %{
       code: :rollup_diverged,
       outcome: "still_diverged",
       error:
         "Task #{task.id} is still not fast-forwardable onto rollup #{rollup}: member branch " <>
           "#{StackDeployer.member_branch_for(task)} is at #{member_sha}, rollup HEAD is at " <>
           "#{rollup_sha}, and the member is not a descendant of it.",
       recoverable: true,
       rollup_branch: rollup,
       rollup_sha: rollup_sha,
       member_sha: member_sha,
       suggestion:
         "git fetch origin && git rebase origin/#{rollup} && git push --force-with-lease, " <>
           "then call stack_retry_member_merge again with task_id #{task.id}."
     }}
  end

  defp retry_merge_envelope({:error, :conflict, files}, %Task{} = task, rollup) do
    {:error,
     %{
       code: :merge_conflict,
       outcome: "conflict",
       error:
         "Task #{task.id} conflicts with rollup #{rollup} in #{length(List.wrap(files))} file(s); " <>
           "the stack has been flipped to `blocked`.",
       recoverable: false,
       rollup_branch: rollup,
       files: List.wrap(files),
       suggestion:
         "Resolve the conflict on the member branch against origin/#{rollup}, then have a " <>
           "human unblock the stack (stack_update status) before retrying."
     }}
  end

  defp retry_merge_envelope({:error, reason}, %Task{} = task, rollup)
       when reason in [:task_not_found, :not_in_stack, :stack_not_found, :project_not_found] do
    {:error,
     %{
       code: reason,
       outcome: "error",
       error: "Cannot merge task #{task.id} into #{inspect(rollup)}: #{inspect(reason)}",
       recoverable: false,
       suggestion:
         "Check the task's stack via task_get / stack_get; the record the merge needs is missing."
     }}
  end

  defp retry_merge_envelope({:error, :no_repo_url}, %Task{} = task, rollup) do
    {:error,
     %{
       code: :no_repo_url,
       outcome: "error",
       error:
         "Cannot merge task #{task.id} into #{inspect(rollup)}: the project has no repo_url.",
       recoverable: false,
       suggestion: "Set the project's repo_url (project_update) before retrying."
     }}
  end

  defp retry_merge_envelope({:error, other}, %Task{} = task, rollup) do
    {:error,
     %{
       code: :merge_failed,
       outcome: "error",
       error:
         "Rollup merge for task #{task.id} into #{inspect(rollup)} failed: #{inspect(other)}",
       recoverable: true,
       suggestion:
         "Fix the underlying git failure (see the reason above), then call " <>
           "stack_retry_member_merge again."
     }}
  end

  defp retry_not_ready_reason({:stages_pending, passed, total}),
    do: %{kind: "stages_pending", passed: passed, total: total}

  defp retry_not_ready_reason(reason) when is_atom(reason), do: %{kind: Atom.to_string(reason)}

  defp retry_not_ready_detail(%Task{status: status}, :member_not_in_review),
    do: "the member is at `#{status}`; the deployer merges only members at `in_review`."

  defp retry_not_ready_detail(%Task{status: status}, :member_past_review),
    do:
      "the member is at `#{status}` with no `merged_into_rollup_at` stamp, which no " <>
        "sanctioned path produces."

  defp retry_not_ready_detail(_task, {:stages_pending, passed, total}),
    do: "#{passed}/#{total} review-stage validations are `passed`."

  defp retry_not_ready_suggestion(:member_not_in_review),
    do:
      "Required prior step: finish the task's stages so it transitions to `in_review` " <>
        "(stage_complete on the last running stage); the deployer merges eagerly on that " <>
        "transition and this tool retries it."

  defp retry_not_ready_suggestion(:member_past_review),
    do:
      "This is an invariant violation, not a retryable state — a human must investigate " <>
        "before re-stamping by hand."

  defp retry_not_ready_suggestion({:stages_pending, _passed, _total}),
    do:
      "Required prior step: pass the remaining review-stage validations (validation_pass), " <>
        "then call stack_retry_member_merge again."

  # ── Stack helpers ────────────────────────────────────────────────────────

  defp serialize_stack(%Stack{} = stack) do
    %{
      id: stack.id,
      slug: stack.slug,
      name: stack.name,
      status: stack.status,
      rollup_branch: stack.rollup_branch,
      base_branch: stack.base_branch,
      description: stack.description,
      project_id: stack.project_id,
      epic_id: stack.epic_id,
      # Stack v2 lifecycle flags (task 019f487e stage 6). `auto_plan`
      # governs how many waves `stack_start_planning` fans out per call
      # (default false: only wave 0). `auto_accept_plan` governs whether
      # submitted member plans skip human review. Both surface here so
      # `stack_get` callers can see current mode without a follow-up
      # query. Documented on the `stack_create` and `stack_get` tool
      # entries.
      auto_plan: stack.auto_plan,
      auto_accept_plan: stack.auto_accept_plan,
      # Stack-level agent assignment default (ADR 0041). `%{}` when unset.
      phase_assignees: Stacks.stack_phase_assignees(stack),
      # ADR 0042 Decision 8 — Sponsor slot. `sponsor_user_id` is the raw
      # FK (nil when unsponsored); `sponsor` is the hydrated envelope
      # (`nil` when unsponsored or when :sponsor preload was skipped).
      # Mirrors the task serializer's shape.
      sponsor_user_id: Map.get(stack, :sponsor_user_id),
      sponsor: serialize_sponsor(Map.get(stack, :sponsor)),
      # Task 01a05392 stage 3. The `rollup_branch_ready` stamp
      # (`%{"at", "base_sha"}`, written by StackDeployer once the rollup
      # branch exists on origin) or nil while it does not. Together with the
      # members' `paused_reason` this lets `stack_get` alone answer "is the
      # rollup live, and is any member paused". The stamp only — not the
      # whole metadata blob.
      rollup_branch_ready: metadata_map_field(stack, "rollup_branch_ready"),
      # Task 01a05394-8300 stage 2. Curated view of `metadata["rollup_pr"]`
      # or nil while the deployer has never touched it. The stamp has (at
      # least) three live shapes — `%{"status" => "opening", "at"}` (the
      # lock placeholder: no number/url), `%{"number", "url", "opened_at",
      # "auto_merge_armed"}`, and the same plus `"merged_at"` — so every
      # key is read individually and nil when absent; nothing is invented.
      rollup_pr: serialize_rollup_pr(metadata_map_field(stack, "rollup_pr")),
      inserted_at: format_datetime(stack.inserted_at),
      updated_at: format_datetime(stack.updated_at)
    }
  end

  # The 1-arity resolves the member's context on its own (one plan query
  # plus one sibling-members query per call) for the callers that hand
  # over a handful of members; `stack_get` builds the context ONCE via
  # `stack_member_context/1` and uses the 2-arity.
  defp serialize_stack_member(%Task{} = task) do
    siblings =
      case task.stack_id do
        nil -> [task]
        stack_id -> Stacks.members(stack_id)
      end

    serialize_stack_member(task, stack_member_context(siblings))
  end

  defp serialize_stack_member(%Task{} = task, %{plan_status: plan_status, members: by_id}) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      stack_position: task.stack_position,
      dependencies: task.dependencies || [],
      # Whether this member follows the stack-level default (`"inherited"`)
      # or carries an individual assignee override (`"override"`).
      assignment: if(Stacks.member_overridden?(task), do: "override", else: "inherited"),
      assignee_id: task.assignee_id,
      assignee_type: task.assignee_type,
      # Task 01a05392 stage 3. The member's pause stamp (e.g.
      # `%{"kind" => "rollup_diverged", "member_sha", "rollup_sha", ...}`)
      # or nil. See `serialize_task/1` for why this is one key, not `metadata`.
      paused_reason: metadata_map_field(task, "paused_reason"),
      # Task 01a05394-8300 stage 2. Same stamp predicate as
      # `serialize_task_stack/1` (`Stacks.member_has_merged_into_rollup_at?/1`).
      landed_at: stack_member_landed_at(task),
      # Status of the member's LATEST plan (highest version, any status) —
      # the same "current plan" `CommencementGate` keys its approved-set
      # query on — or nil when the member has no plan.
      plan_status: Map.get(plan_status, task.id),
      # In-stack dep ids the engine does not yet consider satisfied
      # (`MemberSet.dependency_satisfied?/1`: cancelled releases; otherwise
      # `in_review|deploying|done` AND stamped). `[]` when unblocked or
      # when the member has no in-stack deps. Deps outside the stack are
      # not this list's business (see `cross_stack_deps`).
      blocked_by: stack_member_blocked_by(task, by_id)
    }
  end

  # Per-member-set context for `serialize_stack_member/2`: the latest plan
  # status per member id (one query) and the members keyed by id (for the
  # in-stack dep lookup). Built once per `stack_get`.
  defp stack_member_context(members) when is_list(members) do
    %{
      plan_status: latest_plan_status_by_task_id(Enum.map(members, & &1.id)),
      members: Map.new(members, &{&1.id, &1})
    }
  end

  # Latest-plan-per-task in ONE round-trip. Mirrors `CommencementGate`'s
  # notion of a member's current plan (highest `version`, any status); the
  # gate's batched query is private and only returns the approved subset,
  # so the reduction happens here over `{task_id, version, status}` rows.
  defp latest_plan_status_by_task_id([]), do: %{}

  defp latest_plan_status_by_task_id(task_ids) when is_list(task_ids) do
    from(p in Plan,
      where: p.task_id in ^task_ids,
      select: {p.task_id, p.version, p.status}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {task_id, version, status}, acc ->
      case Map.get(acc, task_id) do
        {seen, _} when seen >= version -> acc
        _ -> Map.put(acc, task_id, {version, status})
      end
    end)
    |> Map.new(fn {task_id, {_version, status}} -> {task_id, status} end)
  end

  defp stack_member_landed_at(%Task{} = task) do
    if Stacks.member_has_merged_into_rollup_at?(task),
      do: Map.get(task.metadata, "merged_into_rollup_at"),
      else: nil
  end

  defp stack_member_blocked_by(%Task{} = task, by_id) when is_map(by_id) do
    task
    |> Tasks.dependency_task_ids()
    |> Enum.reject(&(&1 == task.id))
    |> Enum.uniq()
    |> Enum.filter(fn dep_id ->
      case Map.get(by_id, dep_id) do
        %Task{} = dep -> not Platform.Tasks.Stacks.MemberSet.dependency_satisfied?(dep)
        nil -> false
      end
    end)
  end

  # Serialized members plus the status-aware runnable partition `stack_get`
  # reports (task 01a0562f-28ad stage 1 hoisted this out of the handler so
  # the dependency mutation tools can reuse it). Returns
  # `%{members: [serialized member], executable_now: [id], blocked_now: [id]}`;
  # ids stay in `stack_position` order because `Stacks.members/1` orders
  # by it.
  #
  # `Stacks.executable_members/1` stays the DAG source: it is `[]`
  # when the in-stack DAG is invalid (cycle / cross-stack dep), and
  # a valid DAG over a non-empty member set always has a level-0.
  #
  # Task 01a05394-8300 stage 2. Plans and dep-landing are resolved
  # ONCE for the whole member set here and handed to the serializer,
  # so a ten-member stack costs one plan query, not ten.
  #
  # Status-aware `executable_now` — the members the engine would
  # actually run right now. A member is runnable iff BOTH:
  #   * its status is in the dispatcher's live set
  #     (`TaskRouterWatcher.active_statuses/0`: the same set
  #     `TaskRouterWatcher` scans for dispatch, so a `done`,
  #     `backlog`, `cancelled` or `stack_pending` root is NOT
  #     runnable); and
  #   * `blocked_by == []` — every in-stack dep passes
  #     `MemberSet.dependency_satisfied?/1`, the per-dep predicate
  #     `Stacks.unblocked_in_stack?/1` (→ `try_promote/1` and the
  #     redrive gate's `handle_member_regression/2`) is built on.
  # Roots have no in-stack deps, so a runnable-status root is always
  # listed; a promoted non-root whose deps all landed is listed too.
  # Everything else — including a `stack_pending` member whose deps
  # all landed but which the promotion sweep has not flipped yet —
  # goes to `blocked_now`, so the two lists partition `members`.
  defp stack_runnable_partition(%Stack{} = stack, members) when is_list(members) do
    dag_valid? = members == [] or Stacks.executable_members(stack) != []
    context = stack_member_context(members)
    serialized = Enum.map(members, &serialize_stack_member(&1, context))

    executable_ids =
      if dag_valid?,
        do: serialized |> Enum.filter(&stack_member_runnable_now?/1) |> Enum.map(& &1.id),
        else: []

    blocked_ids = serialized |> Enum.map(& &1.id) |> Enum.reject(&(&1 in executable_ids))

    %{members: serialized, executable_now: executable_ids, blocked_now: blocked_ids}
  end

  # Reload-by-id clause for the dependency mutation tools: a fresh
  # `get_stack/1` + `members/1` after the context's transaction (and, on
  # remove, its post-commit promotion) has run. `stack_id` is the raw args
  # string, safe here because the context has just resolved it via
  # `load_stack/1` and `get_stack/1` is `Platform.UUID.valid?/1`-guarded.
  # A nil stack is a MatchError on purpose — never fall back to `[]`.
  defp stack_runnable_partition(stack_id) when is_binary(stack_id) do
    %Stack{} = stack = Stacks.get_stack(stack_id)
    stack_runnable_partition(stack, Stacks.members(stack))
  end

  # See the comment on `stack_runnable_partition/2` for the predicate.
  defp stack_member_runnable_now?(%{status: status, blocked_by: blocked_by}) do
    status in Platform.Orchestration.TaskRouterWatcher.active_statuses() and blocked_by == []
  end

  # One `stack_list` row (task 01a05394-8300 stage 4). Deliberately NOT
  # `serialize_stack/1`: a list row is identity plus state, no prose and no
  # sub-records. Dropped on purpose — `members`-style hydration never lived
  # here, but `phase_assignees`, `sponsor`, `sponsor_user_id`, `auto_plan`
  # and `auto_accept_plan` did, and they are `stack_get`'s to answer.
  # `description` is kept as a snippet rather than dropped, so an existing
  # caller reading it still gets a string, and `description_truncated` /
  # `description_length` say whether it is the whole thing. The rollup
  # stamps reuse the `stack_get` helpers so the two tools cannot drift.
  defp serialize_stack_row(%Stack{} = stack) do
    %{
      id: stack.id,
      slug: stack.slug,
      name: stack.name,
      status: stack.status,
      rollup_branch: stack.rollup_branch,
      base_branch: stack.base_branch,
      description: stack.description,
      project_id: stack.project_id,
      epic_id: stack.epic_id,
      rollup_branch_ready: metadata_map_field(stack, "rollup_branch_ready"),
      rollup_pr: serialize_rollup_pr(metadata_map_field(stack, "rollup_pr")),
      inserted_at: format_datetime(stack.inserted_at),
      updated_at: format_datetime(stack.updated_at)
    }
    |> ResultBound.snippet(:description)
    # `snippet/2` leaves a nil field untouched, which would make the row's
    # key set depend on whether anyone ever wrote a description. Pin the
    # markers so a caller can always read them.
    |> Map.put_new(:description_truncated, false)
    |> Map.put_new(:description_length, 0)
  end

  defp serialize_rollup_pr(nil), do: nil

  defp serialize_rollup_pr(%{} = pr) do
    %{
      status: Map.get(pr, "status"),
      number: Map.get(pr, "number"),
      url: Map.get(pr, "url"),
      merged_at: Map.get(pr, "merged_at"),
      auto_merge_armed: Map.get(pr, "auto_merge_armed")
    }
  end

  # A single map-valued key out of a record's `metadata`, or nil when the
  # key is absent or not a map. Used for the pause / readiness stamps that
  # `task_get` and `stack_get` expose (task 01a05392 stage 3) so the wire
  # contract names each stamp explicitly instead of leaking every metadata
  # key any writer ever adds.
  defp metadata_map_field(record, key) when is_binary(key) do
    case Map.get(record, :metadata) do
      %{} = meta ->
        case Map.get(meta, key) do
          %{} = value -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Partition each member's declared dep edges into:
  #   * in-stack edges  → `%{from_task_id, to_task_id, kind}` lists keyed by
  #     whether the dep target is one of the current members.
  #   * cross-stack edges → deps pointing at tasks that exist in some OTHER
  #     stack. We surface these separately so the caller can see WHY a
  #     validate_dag-driven `executable_now` came back empty.
  #
  # Self-edges are dropped (matches Stacks/Tasks conventions). Edges to
  # tasks with no stack_id are silently dropped (they don't block the
  # in-stack DAG per ADR 0041).
  defp classify_member_edges(members) do
    member_ids = MapSet.new(members, & &1.id)

    {in_stack_edges, external_edges, external_ids} =
      Enum.reduce(members, {[], [], MapSet.new()}, fn %Task{id: from_id, dependencies: deps} =
                                                        _member,
                                                      {in_acc, ext_acc, ext_ids} ->
        deps
        |> List.wrap()
        |> Enum.reduce({in_acc, ext_acc, ext_ids}, fn dep, {ia, ea, ei} ->
          dep_id = Map.get(dep, "task_id")
          kind = Map.get(dep, "kind")

          cond do
            is_nil(dep_id) or dep_id == from_id ->
              {ia, ea, ei}

            MapSet.member?(member_ids, dep_id) ->
              {[%{from_task_id: from_id, to_task_id: dep_id, kind: kind} | ia], ea, ei}

            true ->
              {ia, [{from_id, dep_id, kind} | ea], MapSet.put(ei, dep_id)}
          end
        end)
      end)

    foreign_stack_by_id =
      case MapSet.size(external_ids) do
        0 ->
          %{}

        _ ->
          ids = MapSet.to_list(external_ids)

          from(t in Task,
            where: t.id in ^ids and not is_nil(t.stack_id),
            select: {t.id, t.stack_id}
          )
          |> Repo.all()
          |> Map.new()
      end

    cross_stack =
      external_edges
      |> Enum.filter(fn {_from_id, dep_id, _kind} ->
        Map.has_key?(foreign_stack_by_id, dep_id)
      end)
      |> Enum.map(fn {from_id, dep_id, kind} ->
        %{from_task_id: from_id, to_task_id: dep_id, kind: kind}
      end)
      |> Enum.reverse()

    {Enum.reverse(in_stack_edges), cross_stack}
  end

  # Map `Stacks.add_task/2` error shapes to MCP envelopes with stable
  # `code` keys.
  defp stack_add_error_envelope({:error, :already_in_stack}) do
    {:error,
     %{
       code: "already_in_stack",
       error: "Task is already a member of a stack",
       recoverable: false,
       suggestion: "Eject the task from its current stack before attaching it elsewhere"
     }}
  end

  defp stack_add_error_envelope({:error, :stack_not_found}) do
    {:error,
     %{
       error: "Stack not found",
       recoverable: false,
       suggestion: "Use stack_list to find available stacks"
     }}
  end

  defp stack_add_error_envelope({:error, :task_not_found}) do
    {:error,
     %{
       error: "Task not found",
       recoverable: false,
       suggestion: "Use task_list to find available tasks"
     }}
  end

  defp stack_add_error_envelope({:error, :cycle, path}) when is_list(path) do
    {:error,
     %{
       code: "cycle",
       error: "Adding the task would introduce a cycle in the in-stack dependency DAG",
       recoverable: true,
       suggestion: "Remove the offending dep edge(s) before re-attaching",
       path: Enum.map(path, & &1.id)
     }}
  end

  defp stack_add_error_envelope({:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}) do
    {:error,
     %{
       code: "cross_stack_dep",
       error:
         "Member declares a dependency on a task in another stack — cross-stack deps are forbidden",
       recoverable: true,
       suggestion:
         "Move both tasks into the same stack, or drop the cross-stack dep edge before re-attaching",
       from_task_id: from.id,
       to_task_id: to_id
     }}
  end

  defp stack_add_error_envelope({:error, :stack_terminal, %{stack_status: status}}) do
    {:error,
     %{
       code: "stack_terminal",
       error: "Stack is #{status} and no longer accepts members",
       recoverable: false,
       stack_status: status,
       suggestion:
         "Create a new stack for this task, or attach it to a stack that is still forming or in progress"
     }}
  end

  defp stack_add_error_envelope({:error, %Ecto.Changeset{} = changeset}) do
    {:error,
     %{
       error: "Failed to attach task to stack: #{inspect_errors(changeset)}",
       recoverable: true
     }}
  end

  defp stack_add_error_envelope({:error, reason}) do
    {:error, %{error: "Failed to attach task to stack: #{inspect(reason)}", recoverable: true}}
  end

  # Map `Stacks.add_dependency_edge/4` and `remove_dependency_edge/4`
  # error shapes to MCP envelopes with stable `code` keys. Reuses the
  # `cycle` and `cross_stack_dep` codes verbatim from
  # `stack_add_error_envelope/1` so callers see the same envelope shape
  # regardless of which surface produced it.
  defp stack_dependency_error_envelope({:error, :self_edge}) do
    {:error,
     %{
       code: "self_edge",
       error: "from_task_id and to_task_id must differ — a task cannot depend on itself",
       recoverable: true,
       suggestion: "Pass two distinct task ids for from_task_id / to_task_id"
     }}
  end

  defp stack_dependency_error_envelope({:error, :not_in_stack, task_id})
       when is_binary(task_id) do
    {:error,
     %{
       code: "not_in_stack",
       error: "Task #{task_id} is not a member of the given stack",
       recoverable: true,
       suggestion: "Add the task to this stack first via stack_add.",
       offending_task_id: task_id
     }}
  end

  # Retained for backward compatibility — the wrapper now threads the
  # offending task id (3-tuple), but anything that still surfaces the
  # bare 2-tuple keeps mapping to the same code without an id.
  defp stack_dependency_error_envelope({:error, :not_in_stack}) do
    {:error,
     %{
       code: "not_in_stack",
       error: "Both endpoints must be members of the given stack",
       recoverable: true,
       suggestion:
         "Use stack_get to inspect the stack's members and stack_add to attach any missing endpoint"
     }}
  end

  defp stack_dependency_error_envelope({:error, :duplicate_edge}) do
    {:error,
     %{
       code: "duplicate_edge",
       error: "from_task already declares this (to_task_id, kind) dependency",
       recoverable: false,
       suggestion: "Inspect the from task's dependencies before re-adding the edge"
     }}
  end

  defp stack_dependency_error_envelope({:error, :not_an_edge}) do
    {:error,
     %{
       code: "not_an_edge",
       error: "from_task does not declare a (to_task_id, kind) dependency to remove",
       recoverable: false,
       suggestion:
         "Use task_dependencies on from_task_id to inspect its current edges before removing"
     }}
  end

  defp stack_dependency_error_envelope({:error, :stack_not_found}) do
    {:error,
     %{
       error: "Stack not found",
       recoverable: false,
       suggestion: "Use stack_list to find available stacks"
     }}
  end

  defp stack_dependency_error_envelope({:error, :task_not_found}) do
    {:error,
     %{
       error: "Task not found",
       recoverable: false,
       suggestion: "Use task_list to find available tasks"
     }}
  end

  defp stack_dependency_error_envelope({:error, :cycle, path}) when is_list(path) do
    {:error,
     %{
       code: "cycle",
       error: "Adding the dependency edge would introduce a cycle in the in-stack DAG",
       recoverable: true,
       suggestion: "Remove the offending dep edge(s) before re-adding",
       path: Enum.map(path, & &1.id)
     }}
  end

  defp stack_dependency_error_envelope(
         {:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}
       ) do
    {:error,
     %{
       code: "cross_stack_dep",
       error:
         "Member declares a dependency on a task in another stack — cross-stack deps are forbidden",
       recoverable: true,
       suggestion:
         "Move both tasks into the same stack, or drop the cross-stack dep edge before retrying",
       from_task_id: from.id,
       to_task_id: to_id
     }}
  end

  defp stack_dependency_error_envelope(
         {:error, :dependent_already_started, %{task_id: task_id, status: status}}
       ) do
    {:error,
     %{
       code: "dependent_already_started",
       error:
         "Task #{task_id} is already at #{status} — a member that has started cannot acquire a new predecessor; nothing would enforce the edge",
       recoverable: false,
       suggestion:
         "Declare dependencies before the dependent starts. If the ordering matters, move the dependent back to stack_pending via task_update first.",
       task_id: task_id,
       status: status
     }}
  end

  defp stack_dependency_error_envelope({:error, %Ecto.Changeset{} = changeset}) do
    {:error,
     %{
       error: "Failed to update dependency edge: #{inspect_errors(changeset)}",
       recoverable: true
     }}
  end

  defp stack_dependency_error_envelope({:error, reason}) do
    {:error, %{error: "Failed to update dependency edge: #{inspect(reason)}", recoverable: true}}
  end

  # The composite unique index `task_stacks_slug_project_uniq` is on
  # `[:project_id, :slug]`; Ecto surfaces the violation on whichever field
  # the unique_constraint/3 call named, which currently is `:project_id`
  # (Stack.changeset/2). Match either so renaming the constraint anchor
  # later doesn't silently break this detection.
  defp slug_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {field, {_msg, opts}} when field in [:slug, :project_id] ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  # Detect the `foreign_key_constraint(:sponsor_user_id)` violation
  # surfaced by `Stack.changeset/2` when the supplied UUID references no
  # existing user. Lets `stack_create` / `stack_update` return a
  # structured `sponsor_fk` envelope instead of the generic
  # changeset-inspect fallback.
  defp sponsor_fk_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:sponsor_user_id, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :foreign

      _ ->
        false
    end)
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp maybe_put_base_branch(attrs, nil), do: attrs
  defp maybe_put_base_branch(attrs, value), do: Map.put(attrs, :base_branch, value)

  # Accept an optional boolean arg from the MCP call. Any non-boolean
  # value (including nil / missing) is skipped so the Ecto default from
  # `Stack.changeset/2` wins. This keeps callers from having to send an
  # explicit `false` to preserve the default.
  defp maybe_put_boolean(attrs, _key, nil), do: attrs
  defp maybe_put_boolean(attrs, key, value) when is_boolean(value), do: Map.put(attrs, key, value)
  defp maybe_put_boolean(attrs, _key, _value), do: attrs

  defp do_plan_create(task_id, raw_stages_input) do
    # Pre-persistence rewrites:
    # 1. Lift any e2e_behavior validations into a single task-level review stage.
    # 2. Log advisory warnings about manual_approval scoping (planner authority wins).
    # 3. Log advisory warnings about stages with zero validations (also advisory).
    stages_input =
      raw_stages_input
      # Task 01a0588e. FIRST, and before the engine's own rewrite: `origin`
      # is the engine's marker, so a planner-supplied
      # `"origin": "synthesized"` is dropped here rather than honoured.
      # Stripping after `route_e2e_behavior_validations/1` would erase the
      # engine's marker instead of the planner's forgery.
      |> Platform.Tasks.PlanEngine.strip_planner_origin()
      |> Platform.Tasks.PlanEngine.route_e2e_behavior_validations()
      |> Platform.Tasks.PlanEngine.check_manual_approval_heuristic()
      |> Platform.Tasks.PlanEngine.check_zero_validation_stages()

    Repo.transaction(fn ->
      case Tasks.create_plan(%{task_id: task_id}) do
        {:ok, plan} ->
          stages =
            Enum.map(stages_input, fn stage_input ->
              stage_attrs = %{
                plan_id: plan.id,
                name: Map.get(stage_input, "name"),
                description: Map.get(stage_input, "description"),
                position: Map.get(stage_input, "position"),
                expected_artifacts: Map.get(stage_input, "expected_artifacts", []),
                # Task 01a0588e. Built key-by-key, so an unnamed key is
                # dropped: carried explicitly, defaulting to "authored".
                # Planner-supplied values were already stripped above.
                origin: Map.get(stage_input, "origin", "authored")
              }

              case Tasks.create_stage(stage_attrs) do
                {:ok, stage} ->
                  validations =
                    stage_input
                    |> Map.get("validations", [])
                    |> Enum.map(fn v_input ->
                      attrs =
                        %{
                          stage_id: stage.id,
                          kind: Map.get(v_input, "kind")
                        }
                        |> maybe_put_evaluation_payload(v_input)

                      case Tasks.create_validation(attrs) do
                        {:ok, validation} -> validation
                        {:error, reason} -> Repo.rollback(reason)
                      end
                    end)

                  Map.put(stage, :validations, validations)

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)

          Map.put(plan, :stages, stages)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, plan} ->
        # ADR-0046 member 7 stage 4 — the false-negative audit for the
        # pre-plan design step. This is the first moment in the lifecycle
        # when stage DESCRIPTIONS exist, which is the real subject of
        # `PlanEngine.ui_touching?/1`; a design step that skipped as
        # `"no_ui_surface"` gets re-checked against them here. Inert unless
        # that exact reason is recorded, never raises, and deliberately does
        # not flip the outcome to `failed` — an under-trigger the designer
        # was never asked about must be visible, not merge-blocking.
        _ = Platform.Design.PreplanStep.audit_ui_prediction(task_id, plan.stages)

        {:ok, serialize_plan(plan)}

      {:error, :project_archived} ->
        {:error, project_archived_envelope("start a plan in")}

      {:error, :plan_pending_review} ->
        existing = Tasks.latest_plan(task_id)

        # Task 01a05b32 stage 1 — a DRAFT blocker is self-service now: the
        # planner can discard it with plan_reject (or — stage 2 — fix it in
        # place with plan_update) and call plan_create again, no human
        # round-trip. pending_review KEEPS the wait-for-human wording with
        # recoverable: false: agents still cannot withdraw a submitted plan
        # (Plan-State Lock; do not loosen it here).
        if is_map(existing) and existing.status == "draft" do
          {:error,
           %{
             error:
               "A plan for this task is already draft (v#{existing.version}, #{existing.id}); it blocks plan_create until it is discarded.",
             recoverable: true,
             suggestion:
               "Fix it in place with plan_update, or discard it with plan_reject, then call plan_create again."
           }}
        else
          {:error,
           %{
             error:
               "A plan for this task is already #{existing.status}; create a new plan only after the existing one is rejected.",
             recoverable: false,
             suggestion:
               "Wait for human approval (or rejection) of plan v#{existing.version} (#{existing.id}). Use plan_get to read it; do not call plan_create again."
           }}
        end

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to create plan: #{inspect_errors_safe(reason)}",
           recoverable: true,
           suggestion: "Check that task_id is valid and stages have valid fields"
         }}
    end
  end

  # A guard that fires without explaining itself is the failure mode this
  # ticket is about, so the envelope IS the explanation: it names the stage,
  # the position, the substring that matched IN QUOTES (the author cannot see
  # `"review"` inside `"task_plan_review"` otherwise), and the consequence.
  # `recoverable: true` is literal — nothing was persisted, so the author can
  # fix and immediately retry.
  defp e2e_host_collision_envelope(info) do
    %{
      error:
        "Stage #{info.stage_position} (\"#{info.stage_name}\") contains the e2e host trigger " <>
          "\"#{info.matched_substring}\", so all #{info.e2e_case_count} e2e_behavior case(s) in " <>
          "this plan would attach to that stage instead of the synthesised task-level review " <>
          "gate — a failing case would then fail that stage, which can leave the task with no " <>
          "dispatchable stage.",
      recoverable: true,
      suggestion:
        "Either rename the stage using a neutral verb (Add, Wire, Surface, Guard, Expose) so it " <>
          "no longer contains \"review\" or \"validation\", or set \"e2e_host\": true on the " <>
          "stage that should genuinely host the e2e cases. Nothing was written; retry " <>
          "plan_create once the stages are adjusted."
    }
  end

  # Same discipline as the envelope above: the guard explains itself, quotes the
  # field name the author must add, names the stage AND its position, and states
  # both exits — because a manual_approval that cannot name a surface is as
  # often a gate that should not exist as one that is merely under-specified.
  # `recoverable: true` is literal: nothing was persisted, so the author can fix
  # and retry immediately.
  defp unnamed_manual_gate_envelope(info) do
    %{
      error:
        "Stage #{info.stage_position} (\"#{info.stage_name}\") declares a \"manual_approval\" " <>
          "validation (validation ##{info.validation_index}) that does not name the UI surface a " <>
          "human is being asked to look at. A manual_approval means \"here is the UI, does it fit " <>
          "the brief\" — it is not a place to show test summaries or caveats, and a gate that " <>
          "cannot say what it will show cannot earn the interruption.",
      recoverable: true,
      suggestion:
        "Either add \"ui_surface\": \"<the screen or component the human will look at>\" to that " <>
          "validation's \"evaluation_payload\" (for example \"evaluation_payload\": " <>
          "{\"ui_surface\": \"the task detail page's stage timeline at 375px\"}), or DROP the " <>
          "gate — a manual_approval showing test results or caveats instead of a rendered " <>
          "surface is a notification, not a gate, and the automated validations already cover " <>
          "it. Nothing was written; retry plan_create once the stage is adjusted."
    }
  end

  # ── stage_list plan resolution (task 019fa609 stage 5) ──────────────────
  #
  # `stage_list` accepts `plan_id` OR `task_id`. That is a CONDITIONAL
  # requirement, so both parameters are declared `required: false` and the
  # tool sits outside `Platform.Federation.ToolArguments` entirely — a
  # per-parameter gate cannot express "exactly one of these two", and having
  # it pretend to would be the same defect this task exists to close. The
  # precedent is `skill.get`'s "exactly one of `slug` or `id`".
  #
  # The rule below is stated in the tool's own `description` and its refusal
  # codes in `limitations`, both guarded by tests. Underdetermination is the
  # thing being fixed here: a caller who supplies a combination this function
  # cannot honour is told which combination it was, never handed a plausible
  # answer derived from an argument it did not intend.

  # The closed set of refusal codes the `stage_list` clause can emit. The
  # tool's `limitations` prose names exactly these, and a test compares the
  # two sets rather than restating either.
  @stage_list_error_codes [
    :missing_plan_reference,
    :plan_task_mismatch,
    :no_current_plan
  ]

  @doc """
  The closed set of `code` values `stage_list` refuses with.

  Exposed so the tool's `limitations` prose can be compared against the
  clause's actual behaviour by a test instead of by hand.
  """
  @spec stage_list_error_codes() :: [atom()]
  def stage_list_error_codes, do: @stage_list_error_codes

  defp resolve_stage_list_plan(args) do
    # Blank strings count as absent, matching `ToolArguments`' presence rule
    # — `%{"plan_id" => "   "}` names nothing a query can use, and treating it
    # as present would hand the caller the same nil-shaped failure in disguise.
    case {named_argument(args, "plan_id"), named_argument(args, "task_id")} do
      {nil, nil} -> {:error, stage_list_missing_reference()}
      {plan_id, nil} -> {:ok, plan_id}
      {nil, task_id} -> stage_list_plan_for_task(task_id)
      {plan_id, task_id} -> stage_list_reconcile(plan_id, task_id)
    end
  end

  defp named_argument(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      nil -> nil
      value -> value
    end
  end

  defp stage_list_missing_reference do
    %{
      error: "stage_list: exactly one of plan_id or task_id is required",
      code: :missing_plan_reference,
      recoverable: true,
      suggestion:
        "Pass `plan_id` to list a specific plan's stages, or `task_id` to list the stages of " <>
          "that task's current (approved) plan. Call tools/list for the full inputSchema."
    }
  end

  defp stage_list_plan_for_task(task_id) do
    case stage_list_task_plan(&Tasks.current_plan/1, task_id) do
      %Plan{id: plan_id} -> {:ok, plan_id}
      nil -> {:error, stage_list_no_current_plan(task_id)}
    end
  end

  # `Tasks.current_plan/1` and `latest_plan/1` cast `task_id` into their
  # queries, so a malformed argument would raise an `Ecto.Query.CastError`
  # instead of resolving to "no such task" — the same class of failure this
  # whole task exists to remove. Same reasoning as `get_by_uuid/2`, which
  # cannot be reused here because these are context functions rather than a
  # `Repo.get/2` on a schema.
  defp stage_list_task_plan(fun, task_id) do
    if Platform.UUID.valid?(task_id), do: fun.(task_id)
  end

  defp stage_list_no_current_plan(task_id) do
    %{
      error: "stage_list: task #{task_id} has no current plan",
      code: :no_current_plan,
      recoverable: true,
      suggestion: stage_list_no_current_plan_suggestion(task_id)
    }
  end

  defp stage_list_no_current_plan_suggestion(task_id) do
    case stage_list_task_plan(&Tasks.latest_plan/1, task_id) do
      nil ->
        "This task has no plan at all (or the task_id names no task). Create one with " <>
          "plan_create, or pass `plan_id` directly."

      plan ->
        # The pending-v2 case, and the reason this refuses instead of
        # returning []: an empty array reads as "this task has no stages"
        # when in fact a plan is sitting in review.
        "The task's latest plan is #{plan.id} (version #{plan.version}, status #{plan.status}), " <>
          "which is not approved — `task_id` resolves only to an approved or completed plan. " <>
          "Pass `plan_id` #{plan.id} directly to inspect that plan's stages, or approve it first."
    end
  end

  defp stage_list_reconcile(plan_id, task_id) do
    # `get_by_uuid/2` rather than `Tasks.get_plan/1`: only `task_id` is needed
    # to reconcile the pair, and the context function preloads stages.
    case get_by_uuid(Plan, plan_id) do
      %{task_id: ^task_id} ->
        {:ok, plan_id}

      %{task_id: other_task_id} ->
        {:error,
         stage_list_mismatch(
           "stage_list: plan #{plan_id} belongs to task #{other_task_id}, not to task #{task_id}",
           "Drop one of the two arguments. `plan_id` alone lists that plan's stages; `task_id` " <>
             "alone resolves to task #{task_id}'s current plan."
         )}

      nil ->
        {:error,
         stage_list_mismatch(
           "stage_list: plan_id #{plan_id} names no plan, so it cannot be a plan of task #{task_id}",
           "Pass `task_id` alone to resolve task #{task_id}'s current plan, or correct `plan_id`."
         )}
    end
  end

  defp stage_list_mismatch(error, suggestion) do
    %{
      error: error,
      code: :plan_task_mismatch,
      recoverable: true,
      suggestion: suggestion
    }
  end

  defp plan_superseded?(%Plan{status: "superseded"}), do: true
  defp plan_superseded?(_), do: false

  # Snippet each hit's `:content`, then drop hits from the TAIL (the list
  # is score-sorted, so the highest-ranked survive) until the encoded
  # envelope fits the byte budget.
  #
  # `:payload_truncated` is NOT `:truncated`. `:truncated` comes from
  # `Search.search/2` and means a channel hit its `2*limit` cap — a
  # statement about the search. `:payload_truncated` means this transport
  # bound dropped hits that the search did return. Do not conflate them.
  defp bound_memory_search_payload({:ok, %{results: hits} = envelope}) when is_list(hits) do
    snipped = Enum.map(hits, &bound_memory_search_hit/1)

    # `truncated`, `dead_channels` and `dropped` ride through from
    # `Search.search/2` untouched — except that a dead-channel label is
    # a tuple (`{:semantic, :all}`), which JSON cannot carry, so it is
    # rendered as a `["semantic", "all"]` pair here.
    dead =
      envelope
      |> Map.get(:dead_channels, [])
      |> Enum.map(fn
        {channel, corpus} -> [channel, corpus]
        pair -> pair
      end)

    # ORDERING GUARD. Degraded-vs-healthy, and within degraded
    # zero-hits-vs-partial, are decided on `snipped` — the PRE-BOUND
    # list. `payload_truncated` can empty the kept list for an oversized
    # payload, so deciding on `kept` would let a byte-bound artefact
    # masquerade as a dead-channel failure: a false positive with the
    # same signature as the real thing.
    case {dead, snipped} do
      {[], _} ->
        envelope
        |> Map.put(:dead_channels, dead)
        |> Map.put(:payload_truncated, false)
        |> Map.put(:retrieval_status, "ok")
        |> bound_memory_search_fit(:results, snipped)

      {_, []} ->
        {:error, memory_search_degraded_error(dead)}

      _ ->
        # A degraded search with surviving hits carries NO `results` key.
        # The hits are reachable only through `partial_results`, whose
        # name says what they are — a caller that reads `results` gets
        # nothing rather than a partial list it would read as an answer.
        envelope
        |> Map.delete(:results)
        |> Map.put(:dead_channels, dead)
        |> Map.put(:payload_truncated, false)
        |> Map.put(:truncated, true)
        |> Map.put(:retrieval_status, "degraded")
        |> Map.put(:degraded, %{
          dead_channels: dead,
          channels_down: Enum.map(dead, &memory_search_channel_name/1),
          implication: memory_search_implication(dead)
        })
        |> bound_memory_search_fit(:partial_results, snipped)
    end
  end

  defp bound_memory_search_payload(other), do: other

  # Measure with the `payload_truncated` key (and every degraded key)
  # already present — and with `payload_truncated`'s longer `false`
  # rendering — so the flag we add can never push a payload back over
  # the budget we just measured it against.
  defp bound_memory_search_fit(base, key, snipped) do
    base = Map.put(base, key, snipped)
    {kept, dropped?} = fit_memory_search_payload(base, key, snipped)

    {:ok, base |> Map.put(key, kept) |> Map.put(:payload_truncated, dropped?)}
  end

  # Four-key error convention, mirroring `stage_list_mismatch/2`. There is
  # deliberately no `results: []` key: an empty `results` is exactly the
  # reading this branch exists to make unreachable.
  defp memory_search_degraded_error(dead) do
    names = dead |> Enum.map(&memory_search_channel_name/1) |> Enum.join(", ")

    %{
      error:
        "memory_search ran degraded: the #{names} channel(s) did not answer, and the surviving " <>
          "channel(s) matched nothing. This is a FAILED MEASUREMENT, not an absence — do not " <>
          "conclude the thing you searched for does not exist.",
      code: :search_degraded,
      recoverable: true,
      suggestion:
        "Retry; if it stays degraded, report the absence as unestablished. Raising `limit` does " <>
          "not help — a dead channel contributes no hits at any limit.",
      dead_channels: dead
    }
  end

  defp memory_search_channel_name([:semantic, _corpus]), do: "semantic"
  defp memory_search_channel_name([channel, corpus]), do: "#{channel}:#{corpus}"

  defp memory_search_implication(dead) do
    names = Enum.map(dead, &memory_search_channel_name/1)

    if "semantic" in names do
      "semantic down → results are lexical only; absence is not established"
    else
      "#{Enum.join(names, ", ")} down → those corpora contributed no hits; " <>
        "absence is not established for them"
    end
  end

  defp bound_memory_search_hit(%{content: content} = hit) when is_binary(content) do
    sliced = String.slice(content, 0, @memory_search_snippet_chars)

    hit
    |> Map.put(:content, sliced)
    |> Map.put(:content_truncated, byte_size(content) > byte_size(sliced))
    |> Map.put(:content_length, byte_size(content))
  end

  defp bound_memory_search_hit(hit), do: hit

  defp fit_memory_search_payload(base, key, hits) do
    cond do
      memory_search_payload_bytes(Map.put(base, key, hits)) <=
          memory_search_max_payload_bytes() ->
        {hits, length(hits) < length(Map.fetch!(base, key))}

      hits == [] ->
        {[], true}

      true ->
        fit_memory_search_payload(base, key, Enum.drop(hits, -1))
    end
  end

  # Runtime-overridable so a test can shrink the budget far enough to
  # empty the kept list, which real fixtures cannot do (a 500-char
  # snippet is ~1 KB and the budget is 20 KB). That case is the only one
  # in which the ordering guard above can be observed to fail, so without
  # this seam the guard's test would be vacuous. Unset in dev and prod.
  defp memory_search_max_payload_bytes do
    Application.get_env(:platform, :memory_search_max_payload_bytes) ||
      @memory_search_max_payload_bytes
  end

  defp memory_search_payload_bytes(envelope) do
    byte_size(Jason.encode!(envelope))
  end

  # Shared opt-builder for the two `recently_*` heads. `feedback_kind`
  # is caller-controlled ("edit" | "delete"); everything else comes off
  # the MCP args map.
  defp feedback_read_opts(args, feedback_kind) do
    limit_arg = Map.get(args, "limit", 20)

    limit =
      case limit_arg do
        n when is_integer(n) and n > 0 -> min(n, 100)
        _ -> 20
      end

    [
      feedback_kind: feedback_kind,
      path_prefix: Map.get(args, "path_prefix"),
      workspace_id: Map.get(args, "workspace_id"),
      limit: limit
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp file_get_text_text(args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_get_text"),
         file when not is_nil(file) <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_get_text"),
         :ok <- authorize_file_access(context, project),
         :ok <- ensure_content_readable_by_agents(file),
         text_row when not is_nil(text_row) <- Platform.Files.fetch_extracted_text(file.id) do
      page = Map.get(args, "page")
      respond_with_text(file, text_row, page)
    else
      nil ->
        # Either the file row or the text row is missing — disambiguate
        # so callers can recover.
        file_id = Map.get(args, "file_id")

        case file_id && Platform.Files.get_file(file_id) do
          nil ->
            file_not_found_error(file_id)

          _file ->
            {:error,
             %{
               error: "file_get_text: no extracted text available for file_id=#{file_id}",
               code: :no_text_available,
               recoverable: true,
               suggestion:
                 "The file may still be ingesting (ingest_status=\"pending\") or extraction may have failed. Re-check ingest_status via file_list before retrying. `binary: true` is NOT a way around this for a human-only file — both branches apply the same audience gate."
             }}
        end

      {:error, _} = err ->
        err
    end
  end

  # Second, independent barrier over `ingest_intent` (task 019fd033).
  # `Platform.Files.withdraw_from_agent_context/1` already DELETES the
  # cached text, so this looks redundant — it is not. Two cases it and
  # only it covers: a file marked human_only at upload, which never had
  # a text row for the delete to remove; and a text row arriving LATER
  # for a human_only file (a dedup copy from a byte-identical sibling).
  # Both barriers are required; neither subsumes the other.
  #
  # Applied by BOTH branches of file_get_text — see file_get_text_binary/2.
  #
  # No catch-all clause: an unrecognised intent raises rather than
  # falling through to "readable". Serving a body because of an
  # unrecognised enum value is exactly the failure being guarded.
  defp ensure_content_readable_by_agents(%Platform.Files.File{ingest_intent: "attempt"}), do: :ok

  defp ensure_content_readable_by_agents(%Platform.Files.File{
         ingest_intent: "human_only",
         id: _file_id
       }) do
    {:error,
     %{
       error:
         "file_get_text: file is marked human-only; its contents are not available to agents",
       code: :human_only,
       recoverable: false,
       suggestion:
         "The file exists and is visible to people. Tell the user you can see it (name, type, size, uploader) but cannot read it, and ask them to describe or summarise it for you."
     }}
  end

  # `binary: true` branch — skip the extracted-text cache and stream the
  # bytes back base64-encoded. Capped at 25 MB to mirror
  # `attachment.get_inline`; bigger files will need a presigned download
  # path (deferred follow-up).
  #
  # GATED on `ingest_intent`, using the SAME barrier as the text branch.
  # An earlier revision left this branch open on the reasoning that raw
  # bytes are the "human audience" path. They are not: this whole module
  # IS the agent surface. A human downloads through the Files UI, never
  # through file_get_text — so every caller here is an agent, and
  # withholding the extracted text while serving byte-identical content
  # to that same caller is not a policy, it is a one-argument bypass.
  # Both branches gate, or neither does anything.
  #
  # Gate placement is load-bearing: it sits AFTER authorize_file_access/2.
  # Before it, an out-of-org caller could distinguish :human_only from
  # `unauthorized` and use it as an existence oracle.
  defp file_get_text_binary(args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_get_text"),
         %Platform.Files.File{} = file <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_get_text"),
         :ok <- authorize_file_access(context, project),
         :ok <- ensure_content_readable_by_agents(file),
         :ok <- check_inline_file_read_size(file.byte_size),
         {:ok, bytes} <- read_file_bytes(file) do
      {:ok,
       %{
         file_id: file.id,
         content_type: file.content_type,
         original_filename: file.original_filename,
         byte_size: byte_size(bytes),
         data_base64: Base.encode64(bytes)
       }}
    else
      nil ->
        file_not_found_error(Map.get(args, "file_id"))

      {:error, _} = err ->
        err
    end
  end

  # ── Memory tool helpers (ADR-0041 T5) ───────────────────────────────────

  # Boundary-safe `Repo.get/2` for the MCP tool surface. Every id reaching a
  # tool here is a raw tool ARGUMENT — literally whatever string the agent
  # typed — so an unguarded `Repo.get/2` turns a typo into an
  # `Ecto.Query.CastError` that kills the tool call instead of returning the
  # tool's own not-found envelope. Returns `nil`, which every call site below
  # already handles as "no such row".
  #
  # `Platform.UUID.valid?/1`, NOT `Ecto.UUID.cast/1`: a bare cast hex-encodes
  # any 16-byte binary and returns `{:ok, _}`, so a 16-character argument
  # clears it and still raises inside `Repo`. Do not "simplify" this.
  defp get_by_uuid(schema, id) do
    if Platform.UUID.valid?(id), do: Repo.get(schema, id), else: nil
  end

  # Every refusal `Meetings.say/4` can return, as an envelope with a next
  # step. All recoverable: each names something the agent (or a human it
  # asks) can change.
  defp meeting_say_error(:not_in_room, room_name) do
    %{
      error: "meeting_say: you are not a participant of room #{room_name}",
      code: :not_in_room,
      recoverable: true,
      suggestion:
        "You are not a participant of this room. A human must invite you from the meeting page first."
    }
  end

  defp meeting_say_error(:room_not_found, room_name) do
    %{
      error: "meeting_say: no meeting room named #{inspect(room_name)}",
      code: :room_not_found,
      recoverable: true,
      suggestion:
        "Pass the `room_name` exactly as it appeared in your meeting_join payload (it looks like `space-<uuid>`), not a meeting id or a space name."
    }
  end

  defp meeting_say_error(:empty_text, _room_name) do
    %{
      error: "meeting_say: text is blank",
      code: :empty_text,
      recoverable: true,
      suggestion: "Pass the words you want spoken in `text`."
    }
  end

  defp meeting_say_error({:text_too_long, max}, _room_name) do
    %{
      error: "meeting_say: text exceeds #{max} characters",
      code: :text_too_long,
      recoverable: true,
      suggestion:
        "Keep one utterance to #{max} characters or fewer. Split a long passage into several calls, or post it as a chat message instead."
    }
  end

  defp meeting_say_error(:no_runtime, _room_name) do
    %{
      error: "meeting_say: your agent has no linked runtime to deliver to",
      code: :no_runtime,
      recoverable: true,
      suggestion: "A runtime must be linked to this agent before a voice dispatch can reach it."
    }
  end

  # `Meetings.resolve_voice_target/1` (task 01a06686): a runtime for this
  # agent declared `meeting_voice`, but none of those is connected right now.
  defp meeting_say_error(:voice_runtime_offline, _room_name) do
    %{
      error: "meeting_say: your voice worker is offline, so nothing can speak for you",
      code: :voice_runtime_offline,
      recoverable: true,
      suggestion:
        "Your voice runtime (the process that declared `meeting_voice`) is not connected. Start or reconnect it, then retry."
    }
  end

  defp meeting_say_error(:livekit_not_configured, _room_name) do
    %{
      error: "meeting_say: LiveKit is not configured on this deployment",
      code: :livekit_not_configured,
      recoverable: false,
      suggestion: "Meetings are disabled here; there is no room to speak into."
    }
  end

  # The reply budget (task 01a06672 stage 2). Both recoverable: time, or a
  # human speaking, clears them.
  defp meeting_say_error(:reply_budget_exhausted, _room_name) do
    %{
      error: "meeting_say: reply budget exhausted for this room",
      code: :reply_budget_exhausted,
      recoverable: true,
      suggestion:
        "You have spoken 6 times in this room in the last minute. Wait, or post the rest in chat."
    }
  end

  defp meeting_say_error(:agent_chain_too_deep, _room_name) do
    %{
      error: "meeting_say: the last three utterances in this room were all agents",
      code: :agent_chain_too_deep,
      recoverable: true,
      suggestion:
        "The last three utterances in this room were all agents. Wait for a human to speak before replying again."
    }
  end

  defp meeting_say_error(other, _room_name) do
    %{
      error: "meeting_say: #{inspect(other)}",
      recoverable: true,
      suggestion: "Retry once; if it repeats, report the error text in chat."
    }
  end

  # ── meeting_activity_push helpers (task 01a07400 stage 1) ───────────
  #
  # An explicit map rather than `String.to_atom/1`. This value arrives off
  # a public federation endpoint, so casting it would let any caller mint
  # atoms; and the closed set is the point of the feature — a runtime that
  # could name `failed` could paint over a failure core recorded.
  @pushed_state_names %{"thinking" => :thinking, "composing" => :composing}

  defp activity_push_agent(context) do
    case load_agent(context) do
      %Agent{} = agent ->
        {:ok, agent}

      nil ->
        {:error,
         %{
           error: "meeting_activity_push: no calling agent in context",
           recoverable: false,
           suggestion:
             "This tool must be called from an agent runtime; the caller's agent could not be resolved."
         }}
    end
  end

  defp activity_push_state(state) when is_binary(state) do
    case Map.fetch(@pushed_state_names, String.trim(state)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, unsupported_pushed_state(state)}
    end
  end

  defp activity_push_state(state), do: {:error, unsupported_pushed_state(state)}

  defp unsupported_pushed_state(state) do
    allowed = AgentActivity.pushed_states() |> Enum.map_join(", ", &Atom.to_string/1)

    %{
      error: "meeting_activity_push: #{inspect(state)} is not a state you can declare",
      recoverable: false,
      suggestion:
        "Pass exactly one of: #{allowed}. The other activity states are observed by the meeting itself and cannot be asserted by a runtime."
    }
  end

  defp activity_push_meeting(meeting_id) do
    case Meetings.get_meeting(meeting_id) do
      %Meetings.Meeting{} = meeting ->
        {:ok, meeting}

      nil ->
        {:error,
         %{
           error: "meeting_activity_push: no meeting #{inspect(meeting_id)}",
           recoverable: false,
           suggestion:
             "Pass the meeting_id, not a room name or a chat space id. Your meeting_join payload carries both."
         }}
    end
  end

  # The seat guard. `active_participants_for_space/1` resolves the
  # meeting's ACTIVE room and its un-departed participants, which is the
  # same "seated right now" the rail renders — so an agent can only
  # declare a state on a surface that would actually show it.
  defp activity_push_seated(%Meetings.Meeting{} = meeting, %Agent{} = agent) do
    seated? =
      meeting.chat_space_id
      |> Meetings.active_participants_for_space()
      |> Enum.any?(&(&1.agent_id == agent.id))

    if seated? do
      :ok
    else
      {:error,
       %{
         error: "meeting_activity_push: you are not seated in meeting #{meeting.id}",
         recoverable: false,
         suggestion:
           "A human has to invite you into the meeting's room first. Being a member of the meeting's chat space is not enough."
       }}
    end
  end

  defp load_agent(context) when is_map(context) do
    case Map.get(context, :agent) do
      %Agent{} = a ->
        a

      _ ->
        case Map.get(context, :agent_id) do
          id when is_binary(id) -> get_by_uuid(Agent, id)
          _ -> nil
        end
    end
  end

  defp load_agent(_), do: nil

  # The principal behind an agent call: the USER who owns the runtime the
  # call arrived on. `context.runtime_id` is present on both transports
  # (`MCPController` and `RuntimeChannel` both set it); `owner_user_id` is
  # not, so it is read off the runtime row here rather than trusted from
  # the wire.
  defp delivery_closure_principal(context) do
    with runtime_id when is_binary(runtime_id) <- Map.get(context, :runtime_id),
         %{owner_user_id: owner_id} when is_binary(owner_id) <-
           Platform.Federation.get_runtime_by_runtime_id(runtime_id),
         %{} = owner <- Platform.Accounts.get_user(owner_id),
         true <- Tenancy.fabrikam_admin?(owner) do
      {:ok, owner}
    else
      _ -> {:error, delivery_not_authorized()}
    end
  end

  # ONE envelope for every way the authorization can fail — no runtime, an
  # unknown runtime, an ownerless runtime, a non-admin owner. It names no
  # task and carries no argument echo, so a caller who is not authorized
  # cannot distinguish "that task is in backlog" from "no such task" from
  # "you may not do this": the refusal is not a read primitive.
  defp delivery_not_authorized do
    %{
      error:
        "task_close_as_delivered: not authorized. This tool exercises a Fabrikam admin's own " <>
          "authority and is callable only through a runtime owned by one.",
      recoverable: false,
      suggestion:
        "Ask a Fabrikam admin to record the delivery, either from the operator console or " <>
          "through a runtime they own."
    }
  end

  defp delivery_task_not_found(task_id) do
    %{
      error: "Task not found: #{task_id}",
      recoverable: false,
      suggestion: "Use task_list to find available tasks"
    }
  end

  defp parse_delivery_reference(reference) do
    case DeliveryReference.parse(reference) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, :unparseable} ->
        {:error,
         %{
           error:
             "#{inspect(reference)} could not be read as a delivery reference. " <>
               "A closure must name an object someone can check, and free text names none.",
           recoverable: true,
           suggestion:
             "Pass exactly one of: a commit sha (7-40 hex characters), `#1018`, " <>
               "https://github.com/<owner>/<repo>/pull/<number>, or " <>
               "https://github.com/<owner>/<repo>/commit/<sha>."
         }}
    end
  end

  defp fetch_task_for_delivery(task_id) do
    case Tasks.get_task_record(task_id) do
      nil -> {:error, delivery_task_not_found(task_id)}
      task -> {:ok, task}
    end
  end

  defp resolve_delivery_reference(parsed, task) do
    repo_url = task.project_id |> Tasks.get_project() |> then(&(&1 && &1.repo_url))

    case DeliveryReference.resolve(parsed, repo_url) do
      {:ok, resolution} ->
        {:ok, resolution}

      {:error, :not_found} ->
        {:error,
         %{
           error:
             "#{parsed.raw} does not exist on #{repo_url || "the project's repository"}. " <>
               "Nothing was recorded.",
           recoverable: false,
           suggestion:
             "Check the sha or PR number against the project's repo. A reference that does " <>
               "not resolve is not evidence that anything shipped."
         }}

      {:error, :not_merged} ->
        {:error,
         %{
           error: "#{parsed.raw} is not merged \u2014 'there was a PR' is not 'it shipped'.",
           recoverable: false,
           suggestion:
             "Close the task once the PR merges, or cite the commit that actually landed."
         }}

      {:error, {:foreign_repo, named, project_slug}} ->
        # Wrong-row attribution, refused rather than recorded: the URL
        # names `named`, the task's project is `project_slug`, and
        # resolving the number against the project's repo would answer
        # about a DIFFERENT object with the same number. Recording both
        # slugs instead would only move the decision to whoever reads the
        # stamp later.
        {:error,
         %{
           error:
             "#{parsed.raw} names the repository #{named}, but this task's project is " <>
               "#{project_slug}. Resolving it here would attribute a different " <>
               "repository's object to this task.",
           recoverable: true,
           suggestion:
             "Cite a reference in #{project_slug} \u2014 or, if the work really shipped in " <>
               "#{named}, close the task in that repository's project instead."
         }}

      {:error, {:unavailable, message}} ->
        {:error,
         %{
           error:
             "Could not verify #{parsed.raw}: #{message}. Nothing was recorded \u2014 " <>
               "'I could not check' is not 'it does not exist'.",
           recoverable: true,
           suggestion:
             "This is an environment problem (usually a missing or unauthenticated `gh` " <>
               "CLI on the server), not a bad reference. Retry once it is available."
         }}
    end
  end

  defp require_string(args, key, tool) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         %{
           error: "#{tool}: `#{key}` is required",
           recoverable: true,
           suggestion: "Provide a non-empty `#{key}` argument."
         }}
    end
  end

  # Task 01a05b32 stage 1 — `require_string/3` plus the blank-after-trim
  # case. A whitespace-only value is a PARAMETER error (recoverable: true,
  # fix the argument and retry), never a nil-reason write: plan_reject's
  # rejection_reason is the artifact future planners read to learn why the
  # draft died, so an empty one must not reach the row.
  defp require_non_blank_string(args, key, tool) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, non_blank_string_error(tool, key)}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, non_blank_string_error(tool, key)}
    end
  end

  defp non_blank_string_error(tool, key) do
    %{
      error: "#{tool}: `#{key}` is required and must be non-blank",
      recoverable: true,
      suggestion: "Provide a non-blank `#{key}` argument."
    }
  end

  defp require_integer(args, key, tool) do
    case Map.get(args, key) do
      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} -> {:ok, n}
          _ -> integer_required_error(tool, key)
        end

      _ ->
        integer_required_error(tool, key)
    end
  end

  defp integer_required_error(tool, key) do
    {:error,
     %{
       error: "#{tool}: `#{key}` must be an integer",
       recoverable: true,
       suggestion: "Provide an integer value for `#{key}`."
     }}
  end

  defp gate_to_envelope(:ok), do: :ok

  defp gate_to_envelope({:error, %{code: code, message: msg, suggestion: sug, recoverable: rec}}) do
    {:error,
     %{
       error: msg,
       code: code,
       recoverable: rec,
       suggestion: sug
     }}
  end

  defp ensure_page_kind(path, tool) do
    case Routing.classify(path) do
      %{kind: :page} ->
        :ok

      %{kind: :private} ->
        :ok

      %{kind: :journal, namespace: ns, journal_date: date} ->
        suggestion =
          "memory_create at #{ns}/journal/#{Date.to_iso8601(date || Date.utc_today())}.md"

        {:error,
         %{
           error:
             "#{tool}: journal entries are append-only. Use memory_create against the day's journal path.",
           code: :journal_immutable,
           recoverable: true,
           suggestion: suggestion
         }}

      %{kind: :unknown} ->
        gate_to_envelope(Routing.gate_read(nil, path))
    end
  end

  defp ensure_same_kind(old_path, new_path) do
    %{kind: old_kind, namespace: old_ns} = Routing.classify(old_path)
    %{kind: new_kind, namespace: new_ns} = Routing.classify(new_path)

    cond do
      old_kind != new_kind ->
        {:error,
         %{
           error:
             "memory_rename: source and target must share the same kind (#{old_kind} != #{new_kind}). Use memory_create + memory_delete to move across kinds.",
           code: :ambiguous_kind,
           recoverable: false,
           suggestion: "Pick a target path whose kind matches the source path."
         }}

      old_kind == :private and old_ns != new_ns ->
        {:error,
         %{
           error:
             "memory_rename: private paths cannot move between spaces. Source namespace=#{inspect(old_ns)} target namespace=#{inspect(new_ns)}.",
           code: :ambiguous_kind,
           recoverable: false,
           suggestion: "Keep the namespace prefix identical when renaming a private path."
         }}

      true ->
        :ok
    end
  end

  # Build `Platform.Org.Wiki.Search.search_opts()` from the federation
  # args + caller context. Validates the `since` arg via `parse_date/1`
  # (reused from the V1 surface) and surfaces a clean envelope error
  # for malformed dates rather than swallowing them.
  #
  # ADR-0042 e2e fix: when the caller didn't pass an explicit `org_id`
  # AND the agent is pinned to a tenant org via `metadata["org_id"]`,
  # default the filter to a tenant-scoped allow-list `[home_org,
  # root_org]`. Without this default, a tenant-pinned agent calling
  # memory_search with no filter gets unscoped cross-tenant results —
  # which is exactly what the V4 validation caught (a SXI-pinned agent
  # seeing Wayne-Tech content). Root-equivalent callers (no metadata
  # pin, or pinned to the root) keep the legacy "see everything"
  # behavior.
  defp search_opts_from(args, agent) do
    case parse_optional_date(Map.get(args, "since")) do
      {:error, reason} ->
        {:error,
         %{
           error: "memory_search: invalid `since` (#{reason})",
           code: :invalid_since,
           recoverable: true,
           suggestion: "Use ISO 8601 date format: YYYY-MM-DD"
         }}

      since ->
        org_filter = derive_org_filter(args, agent)

        opts =
          [
            source: Map.get(args, "source"),
            namespace: Map.get(args, "namespace"),
            since: since,
            limit: Map.get(args, "limit"),
            workspace_id: Map.get(args, "workspace_id"),
            org_id: org_filter,
            project_id: Map.get(args, "project_id"),
            memory_type: Map.get(args, "memory_type"),
            agent: agent
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, opts}
    end
  end

  # Resolve the effective `org_id` filter passed to the underlying
  # search. Precedence:
  #
  #   1. Explicit caller-supplied `org_id` (already authorized upstream
  #      via `authorize_org_filter/2`) — passed through unchanged.
  #   2. Tenant-pinned agent with no explicit filter — defaults to a
  #      list of `[home_org_id, root_org_id]` so the agent sees its
  #      own org + inherited root content but never sibling tenants.
  #   3. Root-equivalent agent (no metadata pin, or pinned to the root)
  #      — returns `nil` (no filter, see everything).
  defp derive_org_filter(args, agent) do
    case Map.get(args, "org_id") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        case tenant_scope_default(agent) do
          nil -> nil
          ids -> ids
        end
    end
  end

  defp tenant_scope_default(%Agent{} = agent) do
    case agent_home_org(agent) do
      {:tenant, tenant_id} ->
        case root_org_id() do
          nil -> [tenant_id]
          root_id when root_id == tenant_id -> [tenant_id]
          root_id -> [tenant_id, root_id]
        end

      _ ->
        nil
    end
  end

  defp tenant_scope_default(_), do: nil

  defp root_org_id do
    case Repo.one(from(o in Org, where: is_nil(o.parent_org_id), limit: 1, select: o.id)) do
      nil -> nil
      id -> id
    end
  end

  # ── ADR-0042 authorization + org descendants helpers ──────────────────

  # Tenant agents may only filter by their own org. Today the "home org"
  # link lives on `agent.metadata["org_id"]` — agents without that key
  # (the historical default) behave as root-equivalent system callers
  # and can specify any org. Root agents (`metadata["org_id"]` set to
  # the Fabrikam root id) can also specify any tenant.
  #
  # When the metadata key is present AND identifies a tenant, the
  # requested `org_id` must match. Anything else is rejected with the
  # envelope shape the plan calls out so federated callers get a clean
  # `recoverable: false` failure.
  defp authorize_org_filter(_agent, nil), do: :ok
  defp authorize_org_filter(_agent, ""), do: :ok
  defp authorize_org_filter(nil, _requested_org_id), do: :ok

  defp authorize_org_filter(%Agent{} = agent, requested_org_id)
       when is_binary(requested_org_id) do
    case agent_home_org(agent) do
      :root ->
        :ok

      {:tenant, ^requested_org_id} ->
        :ok

      {:tenant, _other_org_id} ->
        {:error,
         %{
           error: "unauthorized: not a member of org #{requested_org_id}",
           recoverable: false,
           suggestion:
             "Tenant agents may only filter memory_search by their own org_id. Drop the filter or supply your home org."
         }}
    end
  end

  # Returns `:root` when the agent has no metadata-pinned org, or is
  # pinned to the Fabrikam root. Returns `{:tenant, org_id}` when pinned to
  # a tenant.
  defp agent_home_org(%Agent{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "org_id") || Map.get(metadata, :org_id) do
      org_id when is_binary(org_id) and org_id != "" ->
        case get_by_uuid(Org, org_id) do
          %Org{parent_org_id: nil} -> :root
          %Org{} -> {:tenant, org_id}
          nil -> :root
        end

      _ ->
        :root
    end
  end

  defp agent_home_org(_), do: :root

  # ADR-0042 org_list_descendants implementation. Returns the tenants
  # under the root for the root's id, an empty list for a tenant, and
  # an envelope error for an unknown id.
  defp list_org_descendants(org_id) do
    case get_by_uuid(Org, org_id) do
      nil ->
        {:error,
         %{
           error: "org_list_descendants: org not found (#{org_id})",
           code: :not_found,
           recoverable: false,
           suggestion: "Confirm the org_id — use Platform.Tenancy.list_orgs/0 to enumerate."
         }}

      %Org{parent_org_id: nil} ->
        descendants =
          Tenancy.list_tenants()
          |> Enum.map(fn t ->
            %{id: t.id, slug: t.slug, name: t.name, role: "tenant"}
          end)

        {:ok, descendants}

      %Org{} ->
        # Today's two-tier topology has no third tier; leaf tenant returns [].
        {:ok, []}
    end
  end

  # ── Files tool helpers (ADR-0042 Stage 4) ───────────────────────────────

  # Loads a project for the file_list / file_get_text dispatch. Surfaces a
  # not-found envelope keyed to the calling tool so the caller learns
  # which arg was bad.
  defp fetch_project_for_files(project_id, tool) when is_binary(project_id) do
    case Platform.Tasks.get_project(project_id) do
      nil ->
        {:error,
         %{
           error: "#{tool}: project not found (#{project_id})",
           code: :not_found,
           recoverable: false,
           suggestion: "Confirm the project_id — list available projects via the platform UI."
         }}

      project ->
        {:ok, project}
    end
  end

  # When the caller explicitly passes `org_id` to file_list, run the same
  # authorize_org_filter guard memory_search uses so tenant-pinned agents
  # can't probe sibling orgs by manually picking an org_id. The auth
  # against the project's org_id happens in `authorize_file_access/2`
  # regardless of whether the caller passed `org_id`.
  defp authorize_org_filter_for_explicit(args, context) do
    case Map.get(args, "org_id") do
      org_id when is_binary(org_id) and org_id != "" ->
        authorize_org_filter(load_agent(context), org_id)

      _ ->
        :ok
    end
  end

  # Mirrors `memory_search` authorization: tenant-pinned agents may only
  # touch projects under their own org, root-pinned agents touch every
  # tenant. The error envelope is intentionally the same shape memory_search
  # returns so federated clients have one consistent handling path.
  #
  # When no agent is present (anonymous caller / system-level invocation)
  # we permit — same convention `authorize_org_filter/2` uses. The MCP
  # endpoint always provides an agent_id; bare-call test paths exercise
  # the agent-less branch.
  defp authorize_file_access(context, %Platform.Tasks.Project{org_id: project_org_id}) do
    agent = load_agent(context)

    cond do
      is_nil(agent) ->
        :ok

      is_nil(project_org_id) ->
        # Project with no org_id is a pre-ADR-0042 row; root-equivalent.
        :ok

      true ->
        authorize_org_filter(agent, project_org_id)
        |> case do
          :ok -> :ok
          {:error, envelope} -> {:error, file_unauthorized_envelope(envelope)}
        end
    end
  end

  defp file_unauthorized_envelope(envelope) do
    # Re-key the message so callers can tell file_list / file_get_text
    # produced the rejection (vs memory_search). The shape is identical.
    Map.put(envelope, :error, "unauthorized: file is in an org you are not a member of")
  end

  defp fetch_review_request_for_read(request_id) do
    case Platform.Tasks.ReviewRequests.fetch_request_with_items(request_id) do
      {:ok, request} ->
        {:ok, request}

      {:error, :not_found} ->
        {:error,
         %{
           error: "review_request_get: review request not found (#{request_id})",
           code: :not_found,
           recoverable: false,
           suggestion:
             "Confirm the review_request_id — list the task's items via review_item_list."
         }}
    end
  end

  # Mirrors `authorize_file_access/2` exactly, re-keyed for review reads: the
  # task resolves to a project, the project's `org_id` is the tenancy pin, and
  # `authorize_org_filter/2` is the single rule. Same four conventions:
  # nil agent permits (bare-call test paths), nil project org_id permits
  # (pre-ADR-0042 row), root-pinned agent permits, tenant-pinned agent against
  # a sibling org is refused non-recoverably.
  #
  # A task or project we cannot resolve is NOT a permit: with no org to check
  # against there is nothing to authorize, so we refuse.
  defp authorize_review_access(context, task_id) do
    agent = load_agent(context)

    if is_nil(agent) do
      :ok
    else
      case review_project_org_id(task_id) do
        {:ok, nil} ->
          # Project with no org_id is a pre-ADR-0042 row; root-equivalent.
          :ok

        {:ok, org_id} ->
          case authorize_org_filter(agent, org_id) do
            :ok -> :ok
            {:error, envelope} -> {:error, review_unauthorized_envelope(envelope)}
          end

        :error ->
          {:error,
           %{
             error: "unauthorized: review target could not be resolved to an org",
             recoverable: false,
             suggestion: "Confirm the task_id refers to an existing task."
           }}
      end
    end
  end

  # A typo'd status must REFUSE, not return every lease. Silently widening the
  # filter would hand back a full list the caller believes is filtered — and
  # silently returning [] would be indistinguishable from the genuinely-empty
  # case (no lease was ever created, which is normal) that these tools exist to
  # let a caller trust.
  defp lease_list_result(task_id, status, limit) do
    case Diagnostics.list_execution_leases(task_id, status: status, limit: limit) do
      {:ok, leases} ->
        {:ok, leases}

      {:error, :invalid_status} ->
        {:error,
         %{
           error: "execution_lease_list: unknown `status` #{inspect(status)}",
           recoverable: true,
           suggestion:
             "Use one of: #{Enum.join(ExecutionLease.statuses(), " | ")}. Omit `status` for all leases."
         }}
    end
  end

  defp serialize_runtime_event(event) do
    %{
      event_type: event.event_type,
      # Verbatim. `payload["stage_id"]` is the only stage attribution these
      # rows carry — there is no top-level stage_id column — so plucking a
      # curated subset here would destroy the field callers most need.
      payload: event.payload,
      runtime_id: event.runtime_id,
      phase: event.phase,
      lease_id: event.lease_id,
      occurred_at: event.occurred_at
    }
  end

  defp serialize_execution_lease(lease) do
    %{
      id: lease.id,
      stage_id: lease.stage_id,
      phase: lease.phase,
      runtime_id: lease.runtime_id,
      status: lease.status,
      started_at: lease.started_at,
      last_heartbeat_at: lease.last_heartbeat_at,
      last_progress_at: lease.last_progress_at,
      expires_at: lease.expires_at,
      # Human-written prose, same class as review feedback: only ever reached
      # after `authorize_review_access/2` has already returned :ok.
      block_reason: lease.block_reason,
      metadata: lease.metadata
    }
  end

  defp serialize_phase_transition(transition) do
    %{
      from_status: transition.from_status,
      to_status: transition.to_status,
      occurred_at: transition.occurred_at,
      actor_kind: transition.actor_kind,
      actor_id: transition.actor_id,
      actor_label: transition.actor_label,
      via: transition.via
    }
  end

  # Zero rows is not zero data. A bare `[]` reads as "nothing happened"; it
  # actually means the task predates the instrumentation.
  defp transition_list_note([]) do
    "No transition rows exist for this task. This means the task predates the phase-transition instrumentation, NOT that its status never changed. The history cannot be reconstructed and must not be inferred from inserted_at/updated_at."
  end

  defp transition_list_note(transitions) do
    "#{length(transitions)} recorded transition(s), oldest first. Every status change since the phase-transition instrumentation shipped is present; anything earlier was never recorded."
  end

  defp review_project_org_id(task_id) do
    # `get_by_uuid/2` rather than a bare Repo.get/2: the task_id is a raw tool
    # argument, and the helper's Platform.UUID.valid? guard is what keeps a
    # 16-byte binary from reaching Postgres.
    with task when not is_nil(task) <- get_by_uuid(Task, task_id),
         project when not is_nil(project) <- Platform.Tasks.get_project(task.project_id) do
      {:ok, project.org_id}
    else
      _ -> :error
    end
  end

  defp review_unauthorized_envelope(envelope) do
    # Re-key the message so callers can tell review_request_get /
    # review_item_list produced the rejection (vs memory_search or file_list).
    # The shape is identical. Deliberately carries no item label, feedback or
    # content — the denial must not leak the thing it is protecting.
    Map.put(envelope, :error, "unauthorized: review is in an org you are not a member of")
  end

  defp normalize_limit(nil, default, _max), do: default

  defp normalize_limit(value, _default, max) when is_integer(value) and value > 0 do
    min(value, max)
  end

  defp normalize_limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, max)
      _ -> default
    end
  end

  defp normalize_limit(_value, default, _max), do: default

  defp file_summary(%Platform.Files.File{} = file) do
    {available, note} = agent_content_availability(file)

    %{
      id: file.id,
      name: file.name || file.original_filename,
      original_filename: file.original_filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      ingest_status: file.ingest_status,
      ingest_intent: file.ingest_intent,
      agent_content_available: available,
      agent_content_note: note,
      inserted_at: format_datetime(file.inserted_at)
    }
  end

  # Derives the agent-facing readability of a file row from the
  # intent/status pair. ONE helper, shared by `file_summary/1` and
  # `file_metadata/1` — two copies of this table would drift, and the
  # drift would be invisible (both surfaces keep returning a boolean).
  #
  # The note is the point. A human-only row surfaced as a bare
  # `false` reads to an agent like a broken file; with the note it reads
  # like a decision, and the agent tells the human about the file rather
  # than denying it exists.
  #
  # No catch-all clause. An unrecognised intent/status pair raises
  # `FunctionClauseError` rather than defaulting to readable — a silent
  # default here would advertise content that is deliberately withheld,
  # and file no bug report about the enum value that caused it.
  @spec agent_content_availability(Platform.Files.File.t()) :: {boolean(), String.t() | nil}
  defp agent_content_availability(%Platform.Files.File{ingest_intent: "human_only"}) do
    {false,
     "This file is marked human-only: its contents are not extracted and are not readable by agents. The file exists and a person can see it — ask them about it rather than assuming it is absent."}
  end

  defp agent_content_availability(%Platform.Files.File{
         ingest_intent: "attempt",
         ingest_status: "ingested"
       }),
       do: {true, nil}

  defp agent_content_availability(%Platform.Files.File{
         ingest_intent: "attempt",
         ingest_status: "pending"
       }),
       do: {false, "Extraction has not finished yet; retry shortly."}

  defp agent_content_availability(%Platform.Files.File{
         ingest_intent: "attempt",
         ingest_status: "failed"
       }),
       do: {false, "Extraction failed for this file; its text is unavailable."}

  # Richer single-row view returned by `file_get_metadata`. Intentionally
  # omits `storage_key` (internal handle into the object-store adapter) and
  # the extracted text body (use `file_get_text` for that).
  defp file_metadata(%Platform.Files.File{} = file) do
    {available, note} = agent_content_availability(file)

    %{
      file_id: file.id,
      project_id: file.project_id,
      org_id: file.org_id,
      name: file.name || file.original_filename,
      original_filename: file.original_filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      content_hash: file.content_hash,
      ingest_status: file.ingest_status,
      ingest_intent: file.ingest_intent,
      agent_content_available: available,
      agent_content_note: note,
      uploaded_by_user_id: file.uploaded_by_user_id,
      inserted_at: format_datetime(file.inserted_at),
      updated_at: format_datetime(file.updated_at)
    }
  end

  # Maps a `Platform.Memory` search_result row to the public `file_search`
  # hit shape. Returns `nil` when the underlying file row has been deleted
  # under the search (skip-and-continue, not a 404) or when the file is in
  # a different project than the one we searched (defense-in-depth — the
  # Memory query already filters by project_id but a stale index entry
  # could otherwise leak across projects). The snippet is sourced from the
  # cached extracted text via `Platform.Files.fetch_extracted_text/1` —
  # the same store `file_get_text` reads from, so callers see consistent
  # bodies between the two surfaces.
  defp format_file_hit(memory_result, project_id) do
    entry_id =
      Map.get(memory_result, :entry_id) || Map.get(memory_result, "entry_id")

    score = Map.get(memory_result, :score) || Map.get(memory_result, "score")

    case entry_id && Platform.Files.get_file(entry_id) do
      # The generic `memory_search` tool is deliberately NOT gated here.
      # It runs through Platform.Org.Wiki.Search, which classifies every
      # semantic hit by its `memory_type` tag before fusion: a "document"
      # tag — the tag the file ingester writes — classifies as `:excluded`
      # and the hit is discarded on the spot. No file id is ever looked
      # up, so no file body can reach a `memory_search` result whether or
      # not that id would resolve anywhere. The exclusion is a decision
      # taken at classification, not a side effect of a later miss;
      # tool_surface_files_test.exs holds it in place.
      #
      # human_only clause FIRST — a withdrawn file must drop out of the
      # hit list even when it is still present in the index (the scrub is
      # best-effort after commit, so a memory-service outage leaves the
      # entry there). Dropping it here also suppresses the snippet, which
      # would otherwise re-serve the very body being withheld.
      %Platform.Files.File{project_id: ^project_id, ingest_intent: "human_only"} ->
        nil

      %Platform.Files.File{project_id: ^project_id} = file ->
        %{
          file_id: file.id,
          name: file.name || file.original_filename,
          original_filename: file.original_filename,
          content_type: file.content_type,
          snippet: file_snippet(file, memory_result),
          score: score
        }

      _ ->
        nil
    end
  end

  # Snippet preference order: explicit `:excerpt` on the memory result (if
  # the provider starts returning per-hit highlights), then the first 240
  # graphemes of the cached extracted text body. When no text is cached
  # the snippet is `nil` — the file is in the index but the text cache
  # row was lost (e.g. a backfill that skipped upsert_extracted_text).
  defp file_snippet(%Platform.Files.File{id: file_id}, memory_result) do
    case Map.get(memory_result, :excerpt) || Map.get(memory_result, "excerpt") do
      excerpt when is_binary(excerpt) and excerpt != "" ->
        excerpt

      _ ->
        case Platform.Files.fetch_extracted_text(file_id) do
          %Platform.Files.Text{text: text} when is_binary(text) ->
            truncate_snippet(text)

          _ ->
            nil
        end
    end
  end

  defp truncate_snippet(text) do
    text
    |> String.graphemes()
    |> Enum.take(240)
    |> Enum.join()
  end

  defp file_not_found_error(file_id) do
    {:error,
     %{
       error: "file_get_text: file not found (#{inspect(file_id)})",
       code: :not_found,
       recoverable: false,
       suggestion: "Confirm the file_id — use file_list to enumerate the project's files."
     }}
  end

  defp file_metadata_not_found_error(file_id) do
    {:error,
     %{
       error: "file_get_metadata: file not found (#{inspect(file_id)})",
       code: :not_found,
       recoverable: false,
       suggestion: "Confirm the file_id — use file_list to enumerate the project's files."
     }}
  end

  defp file_delete_not_found_error(file_id) do
    {:error,
     %{
       error: "file_delete: file not found (#{inspect(file_id)})",
       code: :not_found,
       recoverable: false,
       suggestion:
         "Idempotent: a re-delete of an already-deleted file yields this envelope. Confirm the file_id via file_list if you expected the row to exist."
     }}
  end

  # Actor for `Platform.Files.delete_file/2` audit attribution (task
  # 019f7cb0 stage 4). MCP callers are agents — resolve the acting agent
  # the same way `load_agent/1` does, falling back to the raw
  # `context.agent_id` when the row isn't loadable (the id is still the
  # truthful attribution). Non-UUID ids are dropped rather than passed
  # through: `Platform.Audit.Event` casts actor_id as Ecto.UUID, and a
  # junk id would make the bridged audit insert fail silently. `nil`
  # (no resolvable identity) makes `delete_file/2` refuse with
  # `:unauthorized` — every delete must be attributable.
  defp file_delete_actor(context) do
    case load_agent(context) do
      %Agent{id: id} ->
        %{id: id, type: "agent"}

      nil ->
        # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1 — this is a
        # FABRICATED-VALUE bug, not a raise: a bare cast hex-encodes a 16-byte
        # binary into a well-formed but INVENTED uuid, which then lands in the
        # audit event's actor_id column as a real-looking id belonging to
        # nobody. No exception is ever raised, so an assert_raise-shaped test
        # will not catch a regression here — assert on the resolved actor.
        with id when is_binary(id) <- is_map(context) && Map.get(context, :agent_id),
             {:ok, uuid} <- Platform.UUID.cast(id) do
          %{id: uuid, type: "agent"}
        else
          _ -> nil
        end
    end
  end

  # ── file_add helpers (ADR-0042 Files MCP Stage 3) ─────────────────────

  # Inline branch: decode base64 → persist via Storage.put → dedup-or-insert
  # the platform_files row → fire async ingest. Returns the ready row.
  defp file_add_inline(args, project, filename, content_type) do
    with {:ok, bytes} <- decode_file_base64(Map.get(args, "data_base64")),
         :ok <- check_inline_file_size(byte_size(bytes)) do
      case Platform.Files.Storage.put({:binary, bytes}, project.id, filename: filename) do
        {:ok, %{storage_key: storage_key, content_hash: hash, byte_size: size}} ->
          case Platform.Files.find_ingested_sibling(project.id, hash) do
            %Platform.Files.File{} = sibling ->
              # Dedup: drop the just-written bytes (Storage.put landed under
              # a fresh storage_key — the canonical row points at its own
              # key, so the new key is orphaned). Best-effort delete.
              _ = Platform.Files.Storage.delete(storage_key)

              {:ok, file_add_result_ready(sibling, true)}

            nil ->
              create_attrs = %{
                project_id: project.id,
                org_id: project.org_id,
                uploaded_by_user_id: nil,
                name: filename,
                original_filename: filename,
                content_type: content_type,
                byte_size: size,
                storage_key: storage_key,
                content_hash: hash,
                ingest_status: "pending"
              }

              case Platform.Files.create_file(create_attrs) do
                {:ok, file} ->
                  :ok = Platform.Files.Ingester.ingest_async(file)
                  {:ok, file_add_result_ready(file, false)}

                {:error, %Ecto.Changeset{} = cs} ->
                  _ = Platform.Files.Storage.delete(storage_key)

                  {:error,
                   %{
                     error: "file_add: insert failed (#{inspect(cs.errors)})",
                     recoverable: true,
                     suggestion:
                       "Validation error inserting the platform_files row — inspect the errors map and retry with corrected input."
                   }}
              end
          end

        {:error, reason} ->
          {:error,
           %{
             error: "file_add: persist failed (#{inspect(reason)})",
             recoverable: true,
             suggestion: "The storage adapter rejected the bytes. Retry shortly."
           }}
      end
    end
  end

  # Presigned branch: build a deterministic storage_key, reserve a pending
  # row (no content_hash yet — the Stage 3 migration allows NULL when
  # ingest_status="pending"), and return a presigned upload URL.
  # The byte POST lands in PlatformWeb.ChatAttachmentUploadController, whose
  # lookup_pending/1 falls through from chat_attachments to this
  # platform_files row and finalizes it via Files.finalize_presigned_upload/2
  # (task 01a091b7).
  defp file_add_presigned(args, project, filename, content_type) do
    byte_size_arg = Map.get(args, "byte_size")

    with :ok <- check_presigned_file_size(byte_size_arg) do
      file_id = Ecto.UUID.generate()
      storage_key = Platform.Files.Storage.build_key(project.id, file_id, filename)

      create_attrs = %{
        project_id: project.id,
        org_id: project.org_id,
        uploaded_by_user_id: nil,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: byte_size_arg,
        storage_key: storage_key,
        ingest_status: "pending"
      }

      case Platform.Files.create_file(create_attrs) do
        {:ok, file} ->
          case Platform.Files.Storage.presigned_url(storage_key,
                 max_bytes: presigned_file_max_bytes(),
                 ttl_s: presigned_file_ttl_seconds()
               ) do
            {:ok, %{url: url, expires_at: expires_at}} ->
              {:ok,
               %{
                 id: file.id,
                 project_id: project.id,
                 upload_url: url,
                 expires_at: expires_at,
                 max_bytes: presigned_file_max_bytes(),
                 state: "pending"
               }}

            {:error, reason} ->
              _ = Platform.Repo.delete(file)

              {:error,
               %{
                 error: "file_add: presign failed (#{inspect(reason)})",
                 recoverable: true,
                 suggestion: "Storage adapter rejected the presign request. Retry shortly."
               }}
          end

        {:error, %Ecto.Changeset{} = cs} ->
          {:error,
           %{
             error: "file_add: insert failed (#{inspect(cs.errors)})",
             recoverable: true,
             suggestion:
               "Validation error inserting the platform_files row — inspect the errors map and retry with corrected input."
           }}
      end
    end
  end

  defp file_add_result_ready(%Platform.Files.File{} = file, dedup?) do
    %{
      id: file.id,
      project_id: file.project_id,
      state: "ready",
      deduplicated: dedup?,
      byte_size: file.byte_size,
      content_hash: file.content_hash,
      content_type: file.content_type
    }
  end

  defp decode_file_base64(s) when is_binary(s) do
    case Base.decode64(s, padding: false) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        case Base.decode64(s) do
          {:ok, bytes} ->
            {:ok, bytes}

          :error ->
            {:error,
             %{
               error: "file_add: `data_base64` is not valid base64",
               recoverable: true,
               suggestion: "Pass base64-encoded bytes for the inline branch."
             }}
        end
    end
  end

  defp check_inline_file_size(size) do
    limit = inline_file_max_bytes()

    if size <= limit do
      :ok
    else
      {:error,
       %{
         error:
           "file_add: inline payload exceeds limit (#{size} > #{limit} bytes); use the `byte_size` (presigned) branch instead",
         recoverable: true,
         limit: limit
       }}
    end
  end

  defp check_presigned_file_size(size) when is_integer(size) and size > 0 do
    limit = presigned_file_max_bytes()

    if size <= limit do
      :ok
    else
      {:error,
       %{
         error: "file_add: `byte_size` exceeds max (#{size} > #{limit} bytes)",
         recoverable: true,
         limit: limit
       }}
    end
  end

  defp check_presigned_file_size(_),
    do:
      {:error,
       %{
         error: "file_add: `byte_size` must be a positive integer",
         recoverable: true,
         suggestion: "Pass a positive integer for the declared upload size."
       }}

  defp inline_file_max_bytes,
    do: Application.get_env(:platform, :inline_upload_max_bytes, 25 * 1024 * 1024)

  # Read cap for `file_get_text` with `binary: true`. Mirrors
  # `Platform.Chat.Attachments.ToolHandlers.@inline_read_max_bytes` so the
  # two inline-read paths stay consistent — bumping one without the other
  # would make the cap reachable through one tool but not the other.
  @inline_file_read_max_bytes 25 * 1024 * 1024

  defp check_inline_file_read_size(size) do
    cond do
      is_integer(size) and size <= @inline_file_read_max_bytes ->
        :ok

      is_integer(size) ->
        {:error,
         %{
           error:
             "file_get_text: file exceeds inline read cap (#{size} > #{@inline_file_read_max_bytes} bytes)",
           code: :too_large,
           recoverable: false,
           limit: @inline_file_read_max_bytes,
           suggestion:
             "Files over #{@inline_file_read_max_bytes} bytes can't be returned inline. A presigned-download path is planned but not yet shipped."
         }}

      true ->
        {:error,
         %{
           error: "file_get_text: file has no recorded byte_size; cannot enforce inline read cap",
           code: :no_byte_size,
           recoverable: false,
           suggestion:
             "The file row is missing `byte_size` — likely a not-yet-finalized presigned upload. Re-check ingest_status via file_list before retrying."
         }}
    end
  end

  defp read_file_bytes(%Platform.Files.File{storage_key: key}) do
    case Platform.Files.Storage.get(key) do
      {:ok, stream} ->
        bytes =
          stream
          |> Enum.to_list()
          |> IO.iodata_to_binary()

        {:ok, bytes}

      {:error, reason} ->
        {:error,
         %{
           error: "file_get_text: storage read failed (#{inspect(reason)})",
           code: :storage_read_failed,
           recoverable: true,
           suggestion: "The storage adapter rejected the read. Retry shortly."
         }}
    end
  end

  # Loose truthy parser for boolean-ish JSON args. Matches the agent-side
  # ergonomics seen elsewhere (string "true"/"false" come from
  # JSON-without-types runtimes).
  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?("true"), do: true
  defp truthy?("True"), do: true
  defp truthy?("TRUE"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp presigned_file_max_bytes,
    do: Application.get_env(:platform, :upload_max_bytes, 500 * 1024 * 1024)

  defp presigned_file_ttl_seconds,
    do: Application.get_env(:platform, :pending_ttl_seconds, 15 * 60)

  defp respond_with_text(file, %Platform.Files.Text{text: text, pages: pages}, page_arg) do
    case parse_page_arg(page_arg) do
      :no_page ->
        {:ok,
         %{
           file_id: file.id,
           content_type: file.content_type,
           original_filename: file.original_filename,
           total_pages: page_count(pages),
           text: text
         }}

      {:page, n} ->
        cond do
          is_nil(pages) ->
            # Flow format — return the whole body and flag that page was
            # ignored so the caller knows.
            {:ok,
             %{
               file_id: file.id,
               content_type: file.content_type,
               original_filename: file.original_filename,
               total_pages: nil,
               text: text,
               page: nil
             }}

          n < 1 or n > length(pages) ->
            {:error,
             %{
               error: "file_get_text: page #{n} out of range (file has #{length(pages)} pages)",
               code: :page_out_of_range,
               recoverable: true,
               suggestion: "Pass `page` in 1..#{length(pages)} or omit it to get the full body."
             }}

          true ->
            {:ok,
             %{
               file_id: file.id,
               content_type: file.content_type,
               original_filename: file.original_filename,
               total_pages: length(pages),
               page: n,
               text: Enum.at(pages, n - 1)
             }}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_page_arg(nil), do: :no_page
  defp parse_page_arg(n) when is_integer(n), do: {:page, n}

  defp parse_page_arg(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} ->
        {:page, n}

      _ ->
        {:error,
         %{
           error: "file_get_text: `page` must be an integer (got #{inspect(s)})",
           code: :invalid_page,
           recoverable: true,
           suggestion: "Pass a 1-based integer page number, or omit `page` for the full body."
         }}
    end
  end

  defp parse_page_arg(other) do
    {:error,
     %{
       error: "file_get_text: `page` must be an integer (got #{inspect(other)})",
       code: :invalid_page,
       recoverable: true,
       suggestion: "Pass a 1-based integer page number, or omit `page` for the full body."
     }}
  end

  defp page_count(nil), do: nil
  defp page_count(pages) when is_list(pages), do: length(pages)

  defp view_page(path, view_range, workspace_id, class) do
    case Wiki.get_page(path, workspace_id: workspace_id) do
      nil ->
        not_found_error(path)

      page ->
        {sliced, lines_label} = slice_lines(page.content, view_range)

        {:ok,
         %{
           path: path,
           kind: Atom.to_string(class.kind),
           content: sliced,
           version: page.version,
           frontmatter: page.frontmatter,
           updated_by: page.updated_by,
           updated_at: format_datetime(page.updated_at),
           lines_returned: lines_label
         }}
    end
  end

  defp view_journal(path, class, view_range, workspace_id) do
    namespace = class.namespace
    date = class.journal_date

    virtual =
      Journal.virtual_page_for(date, workspace_id: workspace_id, namespace: namespace)

    {sliced, lines_label} = slice_lines(virtual.content, view_range)

    {:ok,
     %{
       path: path,
       kind: "journal",
       content: sliced,
       date: Date.to_iso8601(date),
       namespace: namespace,
       entry_ids: virtual.entry_ids,
       lines_returned: lines_label
     }}
  end

  defp do_memory_create(%{kind: :journal} = class, path, text, agent, workspace_id) do
    attrs =
      %{
        content: text,
        date: class.journal_date,
        workspace_id: workspace_id
      }
      |> maybe_put(:authored_by, agent && agent.id)

    case Journal.append(attrs, namespace: class.namespace) do
      {:ok, entry} ->
        # Journal.append/2 is Memory-agnostic by design, so the proposal
        # sweep is explicit here — without it, `<synthesis-proposal>`
        # blocks an agent writes during a dreaming run never reach
        # `/memory/proposals`.
        JournalSweep.sweep(entry, class.namespace)

        {:ok,
         %{
           path: path,
           kind: "journal",
           entry_id: entry.id,
           date: Date.to_iso8601(entry.date),
           namespace: class.namespace,
           inserted_at: format_datetime(entry.inserted_at)
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error("memory_create", changeset)
    end
  end

  defp do_memory_create(%{kind: kind} = _class, path, text, agent, workspace_id)
       when kind in [:page, :private] do
    attrs =
      %{content: text}
      |> maybe_put(:updated_by, agent && agent.id)

    case Wiki.upsert_page(path, attrs, workspace_id: workspace_id) do
      {:ok, page} ->
        {:ok,
         %{
           path: page.file_key,
           kind: Atom.to_string(kind),
           version: page.version,
           frontmatter: page.frontmatter,
           updated_by: page.updated_by,
           updated_at: format_datetime(page.updated_at)
         }}

      {:error, :stale} ->
        version_conflict_error(path)

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error("memory_create", changeset)
    end
  end

  defp apply_str_replace(nil, path, _old, _new, _agent, _ws), do: not_found_error(path)

  defp apply_str_replace(page, path, old_str, new_str, agent, workspace_id) do
    occurrences = count_occurrences(page.content, old_str)

    cond do
      occurrences == 0 ->
        {:error,
         %{
           error: "memory_str_replace: `old_str` not found in page body.",
           code: :no_match,
           recoverable: true,
           suggestion:
             "Read the page with memory_view, copy the exact substring (including whitespace), and retry."
         }}

      occurrences > 1 ->
        {:error,
         %{
           error:
             "memory_str_replace: `old_str` appears #{occurrences} times — provide more surrounding context so the match is unique.",
           code: :ambiguous_match,
           recoverable: true,
           suggestion:
             "Expand `old_str` to include unique surrounding text (a few lines before/after) so it matches exactly once."
         }}

      true ->
        new_content = String.replace(page.content, old_str, new_str, global: false)

        upsert_with_lock(path, new_content, page.version, agent, workspace_id, :page)
    end
  end

  defp apply_insert(nil, path, _line, _text, _agent, _ws), do: not_found_error(path)

  defp apply_insert(page, path, insert_line, insert_text, agent, workspace_id) do
    lines = String.split(page.content, "\n", trim: false)
    line_count = length(lines)
    upper = line_count + 1

    if insert_line < 1 or insert_line > upper do
      {:error,
       %{
         error:
           "memory_insert: `insert_line` #{insert_line} is out of range. Valid range: 1..#{upper}.",
         code: :out_of_range,
         recoverable: true,
         suggestion:
           "Pass an `insert_line` between 1 (prepend) and #{upper} (append after the last line)."
       }}
    else
      {head, tail} = Enum.split(lines, insert_line - 1)
      new_lines = head ++ [insert_text] ++ tail
      new_content = Enum.join(new_lines, "\n")

      upsert_with_lock(path, new_content, page.version, agent, workspace_id, :page)
    end
  end

  defp upsert_with_lock(path, content, expected_version, agent, workspace_id, kind) do
    attrs =
      %{content: content}
      |> maybe_put(:updated_by, agent && agent.id)

    opts =
      [workspace_id: workspace_id, expected_version: expected_version]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case Wiki.upsert_page(path, attrs, opts) do
      {:ok, page} ->
        {:ok,
         %{
           path: page.file_key,
           kind: Atom.to_string(kind),
           version: page.version,
           frontmatter: page.frontmatter,
           updated_by: page.updated_by,
           updated_at: format_datetime(page.updated_at)
         }}

      {:error, :stale} ->
        version_conflict_error(path)

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error("memory_update", changeset)
    end
  end

  defp do_memory_delete(path, workspace_id) do
    case Wiki.delete_page(path, workspace_id: workspace_id) do
      {:ok, page} ->
        {:ok,
         %{
           path: page.file_key,
           kind: classify_kind_string(path),
           deleted: true
         }}

      {:error, :not_found} ->
        not_found_error(path)

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error("memory_delete", changeset)
    end
  end

  defp do_memory_rename(old_path, new_path, agent, workspace_id) do
    opts =
      [workspace_id: workspace_id]
      |> maybe_put(:updated_by, agent && agent.id)

    case Wiki.rename_page(old_path, new_path, opts) do
      {:ok, page} ->
        {:ok,
         %{
           path: page.file_key,
           kind: classify_kind_string(new_path),
           version: page.version,
           frontmatter: page.frontmatter,
           updated_by: page.updated_by,
           updated_at: format_datetime(page.updated_at)
         }}

      {:error, :not_found} ->
        not_found_error(old_path)

      {:error, :stale} ->
        version_conflict_error(new_path)

      {:error, :same_path} ->
        {:error,
         %{
           error: "memory_rename: `old_path` and `new_path` are identical — nothing to rename.",
           code: :same_path,
           recoverable: true,
           suggestion: "Pass a distinct `new_path`."
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_error("memory_rename", changeset)

      {:error, reason} ->
        {:error,
         %{
           error: "memory_rename failed: #{inspect(reason)}",
           code: :rename_failed,
           recoverable: false,
           suggestion: "Check both paths and the workspace_id, then retry."
         }}
    end
  end

  defp count_occurrences(string, substring) do
    case String.split(string, substring) do
      [_only] -> 0
      parts -> length(parts) - 1
    end
  end

  defp slice_lines(content, nil), do: {content, "all"}

  defp slice_lines(content, [start, stop])
       when is_integer(start) and is_integer(stop) and start >= 1 and stop >= start do
    lines = String.split(content, "\n", trim: false)
    actual_stop = min(stop, length(lines))

    if start > length(lines) do
      {"", "L#{start}-L#{stop} (empty: page has #{length(lines)} lines)"}
    else
      sliced =
        lines
        |> Enum.slice((start - 1)..(actual_stop - 1)//1)
        |> Enum.join("\n")

      {sliced, "L#{start}-L#{actual_stop}"}
    end
  end

  defp slice_lines(content, _bad_range), do: {content, "all"}

  defp not_found_error(path) do
    {:error,
     %{
       error: "Page not found at path #{inspect(path)}.",
       code: :not_found,
       recoverable: true,
       suggestion:
         "Verify the path. For pages use `memory_view` to list candidates; for journal days check that the date has entries."
     }}
  end

  defp version_conflict_error(path) do
    {:error,
     %{
       error:
         "Version conflict on #{inspect(path)} — the page was modified since your last read.",
       code: :version_conflict,
       recoverable: true,
       suggestion:
         "Re-read the page with memory_view, re-apply your change against the latest content, and retry."
     }}
  end

  # `{:error, :project_archived}` from the project write freeze
  # (`Platform.Tenancy.Lifecycle.ensure_project_writable/1`, task 019f4eaa).
  #
  # Agents, unlike humans, have no UI affordance to hide — the LiveViews stop
  # a person from ever reaching an archived project's board, but an agent
  # holding a project_id can call straight into the tool. So this atom needs a
  # real message, not the catch-all's "check the request shape".
  #
  # `recoverable: false` on purpose: retrying cannot succeed. The only way
  # forward is a human restoring the project from /admin/recovery.
  defp project_archived_envelope(verb_phrase) do
    %{
      error:
        "Cannot #{verb_phrase} an archived project. Archiving freezes a project: " <>
          "its existing work stays readable, but nothing new can be created or edited in it.",
      code: :project_archived,
      recoverable: false,
      suggestion:
        "Do not retry. If this project should be active again, a Fabrikam admin can restore it " <>
          "from the Recovery view (/admin/recovery); otherwise pick a different project."
    }
  end

  defp changeset_error(tool, %Ecto.Changeset{} = changeset) do
    # Render Ecto errors as a string so the envelope is JSON-safe and no
    # raw Changeset struct leaks across the federation boundary.
    flat = inspect_errors_safe(changeset)

    {:error,
     %{
       error: "#{tool} failed: #{flat}",
       code: :changeset_invalid,
       recoverable: false,
       suggestion: "Check the provided arguments and retry."
     }}
  end

  defp classify_kind_string(path) do
    case Routing.classify(path) do
      %{kind: kind} when kind in [:page, :private, :journal] -> Atom.to_string(kind)
      _ -> "unknown"
    end
  end

  defp maybe_put(map_or_kw, _key, nil), do: map_or_kw

  defp maybe_put(%{} = map, key, value) when not is_struct(map), do: Map.put(map, key, value)

  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)

  # ── ADR-0046 member 5 stage 4: plan_architecture_verdict internals ───

  # `Platform.UUID.cast/1`, not `Ecto.UUID.cast/1` — the same spelling the
  # rest of this module already uses. `plan_id` arrives straight off an
  # agent's tool payload, and a bare cast hex-encodes any raw 16-byte binary
  # into a well-formed UUID instead of rejecting it. The outcome is the same
  # here either way (`:plan_not_found`, because the encoded id misses), so
  # this is a convention fix rather than a behaviour fix — but the ratchet in
  # `repo_lookup_boundary_test.exs` exists precisely so bare casts do not
  # accumulate on agent-facing paths where the next one might not be benign.
  defp verdict_plan(plan_id) when is_binary(plan_id) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} ->
        case Repo.get(Plan, uuid) do
          %Plan{} = plan -> {:ok, plan}
          nil -> verdict_error(:plan_not_found, plan_id)
        end

      :error ->
        verdict_error(:plan_not_found, plan_id)
    end
  end

  defp verdict_plan(plan_id), do: verdict_error(:plan_not_found, plan_id)

  defp verdict_resolution_arg(verdict) when is_binary(verdict) do
    case verdict |> String.trim() |> String.downcase() do
      "pass" -> {:ok, :pass}
      "reject" -> {:ok, :reject}
      _ -> verdict_error(:invalid_verdict, verdict)
    end
  end

  defp verdict_resolution_arg(verdict), do: verdict_error(:invalid_verdict, verdict)

  defp verdict_summary_arg(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> verdict_error(:missing_summary, summary)
      trimmed -> {:ok, trimmed}
    end
  end

  defp verdict_summary_arg(summary), do: verdict_error(:missing_summary, summary)

  # A pass carries no findings, and one supplied on a pass is dropped
  # rather than refused: the finding vocabulary exists to make a REJECT
  # actionable, and refusing an otherwise-valid pass over decoration
  # would turn a released gate into a held one.
  defp verdict_findings_arg(_findings, :pass, _plan), do: {:ok, []}

  defp verdict_findings_arg(findings, :reject, plan) when is_list(findings) and findings != [] do
    stage_ids = plan.id |> Tasks.list_stages() |> MapSet.new(& &1.id)

    Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, acc} ->
      case validate_verdict_finding(finding, stage_ids) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _envelope} = err -> {:halt, err}
      end
    end)
  end

  defp verdict_findings_arg(findings, :reject, _plan),
    do: verdict_error(:missing_findings, findings)

  defp validate_verdict_finding(finding, stage_ids) when is_map(finding) do
    stage_id = Map.get(finding, "stage_id")
    constraint = Map.get(finding, "constraint")
    detail = Map.get(finding, "detail")

    cond do
      not (is_binary(constraint) and constraint in Plan.architecture_constraints()) ->
        verdict_error(:invalid_constraint, constraint)

      # A finding may OMIT `stage_id` (or send it as null) to object to the
      # plan as a whole: a decomposition that is wrong even though no single
      # stage is, or a sequencing defect spread across stages with no one
      # stage at fault. A gate whose only expressible verdict shape is
      # per-stage cannot state those, and an architect with nowhere to put
      # them passes instead. Anything else present in `stage_id` — a foreign
      # UUID, a number, a map — is still refused: relaxing THAT is what would
      # let an architect invent an id.
      not is_nil(stage_id) and
          not (is_binary(stage_id) and MapSet.member?(stage_ids, stage_id)) ->
        verdict_error(:foreign_stage_id, stage_id)

      not (is_binary(detail) and String.trim(detail) != "") ->
        verdict_error(:malformed_finding, detail)

      true ->
        {:ok,
         %{
           "stage_id" => stage_id,
           "constraint" => constraint,
           "detail" => String.trim(detail)
         }}
    end
  end

  defp validate_verdict_finding(finding, _stage_ids),
    do: verdict_error(:malformed_finding, finding)

  # Named against the ACTUAL state, not "the gate is not open". A
  # duplicate call has to read as an explanation, not a mystery.
  defp verdict_gate_open(plan) do
    case Tasks.architecture_gate(plan) do
      {:open, _verdict} -> :ok
      :none -> verdict_error(:gate_not_open, nil)
      {:resolved, verdict} -> verdict_error(:gate_already_resolved, Map.get(verdict, "state"))
    end
  end

  defp resolve_architecture_verdict(plan, resolution, summary, findings, context) do
    opts = [
      summary: summary,
      findings: findings,
      resolved_by: Map.get(context, :agent_id) || Map.get(context, :user_id) || "architect",
      # THIS clause is what `"mcp"` means. `Tasks` cannot infer it — the
      # same three resolutions arrive through `handle_output` too — so
      # the channel names itself here or the distinction does not exist.
      source: "mcp"
    ]

    case Tasks.resolve_architecture_gate(plan, resolution, opts) do
      {:ok, resolved} ->
        verdict = resolved.architecture_verdict || %{}

        {:ok,
         %{
           plan_id: resolved.id,
           task_id: resolved.task_id,
           verdict: to_string(resolution),
           state: Map.get(verdict, "state"),
           resolved_at: Map.get(verdict, "resolved_at"),
           findings_count: length(Map.get(verdict, "findings") || [])
         }}

      # Lost a race between the read above and the guarded UPDATE — the
      # deadline, or a second architect, got there first. Same envelope
      # the level check produces, so a caller cannot tell (and does not
      # need to tell) which of the two refused it.
      {:error, :gate_already_resolved} ->
        verdict_error(:gate_already_resolved, nil)

      {:error, :gate_not_open} ->
        verdict_error(:gate_not_open, nil)

      {:error, reason} ->
        verdict_error(:verdict_rejected, reason)
    end
  end

  # The closed set of refusal codes this clause can emit. The tool's
  # `limitations` prose names exactly these, and a test asserts the two
  # agree — documentation that drifts from the code is worse than none,
  # because remote runtimes branch on it.
  @architecture_verdict_error_codes [
    :plan_not_found,
    :invalid_verdict,
    :missing_summary,
    :missing_findings,
    :malformed_finding,
    :invalid_constraint,
    :foreign_stage_id,
    :gate_not_open,
    :gate_already_resolved,
    :verdict_rejected
  ]

  @doc """
  The closed set of `code` values `plan_architecture_verdict` refuses with.

  Public so the guard that keeps the tool's `limitations` prose honest
  can compare the documented taxonomy against the emitted one instead of
  restating it.
  """
  @spec architecture_verdict_error_codes() :: [atom()]
  def architecture_verdict_error_codes, do: @architecture_verdict_error_codes

  defp verdict_error(:plan_not_found, plan_id) do
    verdict_refusal(
      :plan_not_found,
      "Plan not found: #{inspect(plan_id)}",
      false,
      "Use the `plan_id` printed in the architecture-review prompt, or plan_get to look it up."
    )
  end

  defp verdict_error(:invalid_verdict, verdict) do
    verdict_refusal(
      :invalid_verdict,
      "verdict must be \"pass\" or \"reject\" (got #{inspect(verdict)}).",
      true,
      "There is no third value. If you have a concern that is not one of the four architectural constraints, pass and put it in `summary`."
    )
  end

  defp verdict_error(:missing_summary, _summary) do
    verdict_refusal(
      :missing_summary,
      "summary is required and must be a non-empty string.",
      true,
      "One paragraph: what you checked and what you found. A pass with an empty summary is indistinguishable from an architect that never read the plan."
    )
  end

  defp verdict_error(:missing_findings, _findings) do
    verdict_refusal(
      :missing_findings,
      "verdict \"reject\" requires a non-empty `findings` array.",
      true,
      "Send one finding per objection: [{\"stage_id\": \"<a stage of this plan>\", \"constraint\": \"#{hd(Plan.architecture_constraints())}\", \"detail\": \"<what to change>\"}]. A finding about the plan AS A WHOLE rather than one stage — a wrong decomposition, a sequencing defect with no single stage at fault — may OMIT `stage_id` (or send it as null); it renders to the planner as a plan-wide objection. A rejection with no findings at all is still unactionable and still refused — the planner cannot tell what to write differently."
    )
  end

  defp verdict_error(:malformed_finding, finding) do
    verdict_refusal(
      :malformed_finding,
      "each finding must be an object with `constraint`, a non-empty `detail` and an optional `stage_id` (got #{inspect(finding)}).",
      true,
      "`detail` must state WHAT TO CHANGE, not what is wrong — \"This is unsound\" tells the planner nothing it can act on."
    )
  end

  defp verdict_error(:invalid_constraint, constraint) do
    verdict_refusal(
      :invalid_constraint,
      "#{inspect(constraint)} is not an architectural constraint. Allowed: #{Enum.join(Plan.architecture_constraints(), ", ")}.",
      true,
      "0046-design-and-architecture-phases-in-planning.md § Architect prompt contract — the architect rejects for architecture, not for taste, naming or style. There is deliberately no `constraint` value for a style objection: put it in `summary` and pass."
    )
  end

  defp verdict_error(:foreign_stage_id, stage_id) do
    verdict_refusal(
      :foreign_stage_id,
      "finding stage_id #{inspect(stage_id)} does not belong to this plan.",
      true,
      "Use a `stage_id` from the plan summary in your review prompt (or stage_list on this plan_id). A finding naming another plan's stage means the review ran against stale context. If the objection is not about one stage but about the plan as a whole, OMIT `stage_id` entirely rather than guessing one — a plan-level finding is accepted and renders as (plan-wide)."
    )
  end

  defp verdict_error(:gate_not_open, _detail) do
    verdict_refusal(
      :gate_not_open,
      "the architecture gate never opened for this plan version.",
      false,
      "Nothing is waiting on a verdict. This happens when the plan was submitted before the gate existed, or when a newer plan version superseded the one you reviewed."
    )
  end

  defp verdict_error(:gate_already_resolved, state) do
    verdict_refusal(
      :gate_already_resolved,
      "the architecture gate is already resolved#{if is_binary(state), do: " as #{state}", else: ""}.",
      false,
      "Nothing to do — the verdict is recorded and the plan has moved on. A duplicate call is harmless; the first writer won."
    )
  end

  defp verdict_error(:verdict_rejected, reason) do
    verdict_refusal(
      :verdict_rejected,
      "the verdict failed validation: #{inspect_errors_safe(reason)}",
      true,
      "Check `constraint` against #{Enum.join(Plan.architecture_constraints(), ", ")} and that every finding carries a non-empty `detail`."
    )
  end

  defp verdict_refusal(code, error, recoverable, suggestion)
       when code in @architecture_verdict_error_codes do
    {:error, %{code: code, error: error, recoverable: recoverable, suggestion: suggestion}}
  end

  # ── task 019fa61c stage 3: stage_architecture_audit internals ────────

  # The closed set of refusal codes this clause can emit. The tool's
  # `limitations` prose names exactly these, and a test compares the two
  # sets rather than restating either.
  #
  # `note_rejected` is the residual slot, the same one `verdict_rejected`
  # and `decline_failed` occupy on the sibling tools. It covers the two
  # ways `record_note/3` can refuse after the arguments are already
  # valid: the changeset rejected the merged row, or the annotation could
  # not be posted (the task has no execution space). Both leave NOTHING
  # written — the row and the note land together or not at all — so
  # collapsing them onto one recoverable code is honest.
  @stage_audit_error_codes [
    :stage_not_found,
    :missing_summary,
    :malformed_finding,
    :invalid_constraint,
    :audit_not_open,
    :audit_already_recorded,
    :note_rejected
  ]

  @doc """
  The closed set of `code` values `stage_architecture_audit` refuses with.

  Public so the guard that keeps the tool's `limitations` prose honest can
  compare the documented taxonomy against the emitted one instead of
  restating it.
  """
  @spec stage_audit_error_codes() :: [atom()]
  def stage_audit_error_codes, do: @stage_audit_error_codes

  # `Platform.UUID.cast/1`, not a bare `Repo.get/2`: `stage_id` arrives
  # straight off an agent's tool payload, and `repo_lookup_boundary_test.exs`
  # ratchets against bare casts on agent-facing paths.
  defp stage_audit_stage(stage_id) when is_binary(stage_id) do
    with {:ok, uuid} <- Platform.UUID.cast(stage_id),
         %Stage{} = stage <- Repo.get(Stage, uuid) do
      {:ok, stage}
    else
      _ -> stage_audit_error(:stage_not_found, stage_id)
    end
  end

  defp stage_audit_stage(stage_id), do: stage_audit_error(:stage_not_found, stage_id)

  defp stage_audit_summary_arg(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> stage_audit_error(:missing_summary, summary)
      trimmed -> {:ok, trimmed}
    end
  end

  defp stage_audit_summary_arg(summary), do: stage_audit_error(:missing_summary, summary)

  # A clean audit carries no findings, and that is the COMMON case — the
  # prompt asks for an explicit "clean" summary. So an absent or empty
  # list is accepted rather than refused; the summary is the required
  # part, because a note with findings but no summary is a list of
  # complaints and a note with neither is silence with extra steps.
  defp stage_audit_findings_arg(nil), do: {:ok, []}
  defp stage_audit_findings_arg([]), do: {:ok, []}

  defp stage_audit_findings_arg(findings) when is_list(findings) do
    Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, acc} ->
      case validate_stage_audit_finding(finding) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _envelope} = err -> {:halt, err}
      end
    end)
  end

  defp stage_audit_findings_arg(findings), do: stage_audit_error(:malformed_finding, findings)

  # No `stage_id` key on an audit finding, unlike a verdict finding: a
  # verdict covers a whole plan and has to name WHICH stage it objects to,
  # while an audit is already scoped to exactly one stage. Carrying the id
  # a second time would create a value that can disagree with the row it
  # is stored on.
  defp validate_stage_audit_finding(finding) when is_map(finding) do
    constraint = Map.get(finding, "constraint")
    detail = Map.get(finding, "detail")

    cond do
      not (is_binary(constraint) and constraint in Plan.architecture_constraints()) ->
        stage_audit_error(:invalid_constraint, constraint)

      not (is_binary(detail) and String.trim(detail) != "") ->
        stage_audit_error(:malformed_finding, detail)

      true ->
        {:ok, %{"constraint" => constraint, "detail" => String.trim(detail)}}
    end
  end

  defp validate_stage_audit_finding(finding),
    do: stage_audit_error(:malformed_finding, finding)

  defp record_stage_audit_note(%Stage{} = stage, summary, findings, context) do
    opts = [
      # THIS clause is what `"mcp"` means. `StageAudit` cannot infer it —
      # the external `handle_output` path reaches the same writer — so the
      # channel names itself here or the distinction does not exist.
      source: "mcp",
      resolved_by: stage_audit_resolved_by(context)
    ]

    case StageAudit.record_note(stage, %{summary: summary, findings: findings}, opts) do
      {:ok, audit} ->
        {:ok,
         %{
           stage_id: stage.id,
           task_id: Map.get(audit, "task_id"),
           state: Map.get(audit, "state"),
           source: Map.get(audit, "source"),
           resolved_at: Map.get(audit, "resolved_at"),
           summary: Map.get(audit, "summary"),
           findings_count: length(Map.get(audit, "findings") || []),
           # Read back off the PERSISTED row rather than recomputed: the
           # late-arrival marker is the anti-collapse property this
           # caller most needs reported, and deriving it twice is how the
           # two copies come to disagree.
           noted_after_deadline: Map.get(audit, "noted_after_deadline") == true
         }}

      {:error, :stage_not_found} ->
        stage_audit_error(:stage_not_found, stage.id)

      {:error, :audit_not_open} ->
        stage_audit_error(:audit_not_open, stage.id)

      # Lost a race between the read and the guarded UPDATE, or a plain
      # duplicate call. Same envelope either way — a caller cannot tell,
      # and does not need to.
      {:error, :audit_already_recorded} ->
        stage_audit_error(:audit_already_recorded, stage.id)

      {:error, reason} ->
        stage_audit_error(:note_rejected, reason)
    end
  end

  # String keys, because the value lands in a JSONB column: an atom-keyed
  # map would write as `{"kind": ...}` and read back string-keyed, so the
  # write and the read would not be the same shape. `Stage`'s changeset
  # only checks the TOP-LEVEL keys, so nothing else catches this.
  defp stage_audit_resolved_by(context) do
    case resolve_attached_by(context) do
      %{kind: kind, id: id} -> %{"kind" => kind, "id" => id}
      _ -> nil
    end
  end

  defp stage_audit_error(:stage_not_found, stage_id) do
    stage_audit_refusal(
      :stage_not_found,
      "Stage not found: #{inspect(stage_id)}",
      false,
      "Use the `stage_id` printed in the drift-audit prompt, or stage_list on the plan to look it up."
    )
  end

  defp stage_audit_error(:missing_summary, _summary) do
    stage_audit_refusal(
      :missing_summary,
      "summary is required and must be a non-empty string.",
      true,
      "One paragraph: what you checked and what you found. A clean stage still needs one — \"no drift, no new deps, no memory-pattern reintroduction\" — because an empty summary is indistinguishable from an architect that never read the stage."
    )
  end

  defp stage_audit_error(:malformed_finding, finding) do
    stage_audit_refusal(
      :malformed_finding,
      "each finding must be an object with a `constraint` and a non-empty `detail` (got #{inspect(finding)}).",
      true,
      "`detail` must state WHAT TO CHANGE, not what is wrong — \"this is unsound\" tells nobody what to write differently. Omit `findings` entirely if the stage is clean."
    )
  end

  defp stage_audit_error(:invalid_constraint, constraint) do
    stage_audit_refusal(
      :invalid_constraint,
      "#{inspect(constraint)} is not an architectural constraint. Allowed: #{Enum.join(Plan.architecture_constraints(), ", ")}.",
      true,
      "0046-design-and-architecture-phases-in-planning.md § Architect prompt contract — the architect reports architecture, not taste, naming or style. There is deliberately no `constraint` value for a style objection: put it in `summary`."
    )
  end

  defp stage_audit_error(:audit_not_open, stage_id) do
    stage_audit_refusal(
      :audit_not_open,
      "no architecture audit is open for stage #{inspect(stage_id)}: no fire was ever recorded for it.",
      false,
      "Nothing is waiting on an audit. This happens when the stage completed before the audit column existed, or when the drift-audit fire never reached a filled role."
    )
  end

  defp stage_audit_error(:audit_already_recorded, _stage_id) do
    stage_audit_refusal(
      :audit_already_recorded,
      "the architecture audit for this stage is already recorded.",
      false,
      "Nothing to do — the first note won and is unchanged, and no second annotation was posted. A duplicate call is harmless."
    )
  end

  defp stage_audit_error(:note_rejected, reason) do
    stage_audit_refusal(
      :note_rejected,
      "the audit note was not recorded: #{inspect_errors_safe(reason)}",
      true,
      "Nothing was written — the row and the execution-space annotation land together or not at all. Check `constraint` against #{Enum.join(Plan.architecture_constraints(), ", ")} and that every finding carries a non-empty `detail`. If the task has no execution space there is nowhere to post the note; report that to the human instead."
    )
  end

  defp stage_audit_refusal(code, error, recoverable, suggestion)
       when code in @stage_audit_error_codes do
    {:error, %{code: code, error: error, recoverable: recoverable, suggestion: suggestion}}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      project_id: task.project_id,
      epic_id: task.epic_id,
      assignee_type: task.assignee_type,
      assignee_id: task.assignee_id,
      # Task 019f42fd nice-to-have — surface the structured per-phase
      # assignee map + declared deploy target so future e2e cases can
      # observe assignee-consolidation state through MCP alone. Both
      # canonical writers (`Tasks.set_phase_assignees/2` and
      # `TaskAttrs.build_task_attrs/3`) drive these; making them
      # readable closes the write→read loop.
      phase_assignees: task.phase_assignees || %{},
      deploy_target: task.deploy_target,
      # ADR 0042 — Sponsor. `nil` when unsponsored, `%{id, name, email}`
      # when set. `Ecto.Association.NotLoaded` protects callers from an
      # accidentally-unpreloaded read (defensive; every preload site now
      # loads :sponsor per stage 1's sweep).
      sponsor: serialize_sponsor(Map.get(task, :sponsor)),
      # Task 019f25f2 stage 5 — expose the opt-in auto-approve flag on the
      # read path so `task_get`/`task_list` callers can tell which tasks
      # will bypass the review gate. The create envelope (stage 3) already
      # returns this flag inline; this pin is for downstream reads.
      auto_approve_plan: task.auto_approve_plan,
      # Task 01a05392 stage 3. Before this, a stack member whose rollup merge
      # was paused (`metadata["paused_reason"]`, kind `rollup_diverged`) could
      # not learn that through `task_get`: neither `metadata` nor `stack_id`
      # was serialized, so the stamp was read by nothing. `stack_id` says
      # whether the task is a member at all; `paused_reason` is the pause
      # stamp map or nil. Deliberately NOT the whole `metadata` blob — that
      # would widen the wire contract to every key any writer ever adds.
      stack_id: Map.get(task, :stack_id),
      paused_reason: metadata_map_field(task, "paused_reason"),
      # Task 01a05394-8300 stage 1. `stack_position` plus a CURATED `stack`
      # sub-map (`nil` for a non-member): `landed_at` is the
      # `merged_into_rollup_at` stamp — the actual release threshold — and
      # `blocked_reason`/`blocked_reason_at` are `Tasks.stamp_blocked_reason/2`'s
      # strings. Curated, not the `metadata` blob: emitting the blob would
      # widen the wire contract to every key any writer ever adds.
      stack_position: Map.get(task, :stack_position),
      stack: serialize_task_stack(task),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  # Shape a preloaded Task.sponsor for the MCP envelope. `nil` (unset)
  # and `%Ecto.Association.NotLoaded{}` (preload was skipped) both
  # collapse to `nil` — the wire contract is "nil or the user shape",
  # never a raw struct or "NotLoaded" atom.
  defp serialize_sponsor(nil), do: nil
  defp serialize_sponsor(%Ecto.Association.NotLoaded{}), do: nil

  defp serialize_sponsor(%Platform.Accounts.User{} = user) do
    %{id: user.id, name: user.name, email: user.email}
  end

  # Task 01a05394-8300 stage 1 — the curated `stack` sub-map for
  # `serialize_task/1`. `nil` when the task is not a stack member. Reuses
  # `Stacks.member_has_merged_into_rollup_at?/1` for the stamp rather than
  # re-deriving its shape here; `metadata` may be nil on old rows, so every
  # read goes through `metadata_string_field/2`.
  defp serialize_task_stack(task) do
    case Map.get(task, :stack_id) do
      nil ->
        nil

      _stack_id ->
        landed_at =
          if Stacks.member_has_merged_into_rollup_at?(task),
            do: Map.get(task.metadata, "merged_into_rollup_at"),
            else: nil

        %{
          landed_at: landed_at,
          blocked_reason: metadata_string_field(task, "blocked_reason"),
          blocked_reason_at: metadata_string_field(task, "blocked_reason_at")
        }
    end
  end

  defp metadata_string_field(record, key) when is_binary(key) do
    case Map.get(record, :metadata) do
      %{} = meta ->
        case Map.get(meta, key) do
          value when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Task 01a006c2 stage 3 — `plan_get`'s status resolution.
  #
  # The closed vocabulary. `nil` (argument omitted) and "approved" both mean
  # the historical resolution, `Tasks.current_plan/1`, whose filter is
  # `status in ["approved", "completed"]`. That is why "approved" is NOT
  # routed through the explicit-status branch: it is the default, and the
  # default must stay bit-for-bit what it was, error envelope included.
  @plan_get_statuses ~w(draft pending_review approved rejected completed)

  defp plan_get_resolution(args) do
    case Map.get(args, "status") do
      nil -> {:ok, :current}
      "approved" -> {:ok, :current}
      status when status in ["latest", "any"] -> {:ok, :latest}
      status when status in @plan_get_statuses -> {:ok, {:status, status}}
      other -> {:error, plan_get_unknown_status_error(other)}
    end
  end

  # An unknown status REFUSES rather than falling back to approved. Stage 2 of
  # this task drew the line: a clamped `limit` is visible in the echoed field,
  # so clamping is honest; a silently-widened (or silently-ignored) status
  # filter is invisible, and the caller would read the approved plan as though
  # it were the rejected one they asked for.
  defp plan_get_unknown_status_error(other) do
    %{
      error: "plan_get: unknown `status` #{inspect(other)}",
      recoverable: false,
      suggestion:
        "Use one of #{Enum.join(@plan_get_statuses, ", ")}, or \"latest\"/\"any\" for the " <>
          "highest-version plan regardless of status. Omit `status` for the current approved plan."
    }
  end

  # No new Ecto query lives here on purpose — `current_plan/1`, `latest_plan/1`
  # and `list_plans/1` already exist in `Platform.Tasks`.
  defp resolve_plan_by_status(task_id, :current) do
    case Tasks.current_plan(task_id) do
      nil ->
        # The historical envelope, preserved verbatim. Any caller that
        # pattern-matched this string still matches it.
        {:error,
         %{
           error: "No approved plan for task",
           recoverable: false,
           suggestion: "Create a plan with plan_create and approve it first"
         }}

      plan ->
        {:ok, plan}
    end
  end

  defp resolve_plan_by_status(task_id, :latest) do
    case Tasks.latest_plan(task_id) do
      nil ->
        {:error,
         %{
           error: "No plan for task",
           recoverable: false,
           suggestion: "Create a plan with plan_create."
         }}

      plan ->
        {:ok, plan}
    end
  end

  defp resolve_plan_by_status(task_id, {:status, status}) do
    task_id
    |> Tasks.list_plans()
    |> Enum.filter(&(&1.status == status))
    |> Enum.max_by(& &1.version, fn -> nil end)
    |> case do
      nil ->
        {:error,
         %{
           error: "No #{status} plan for task",
           recoverable: false,
           suggestion:
             "Call plan_get with status \"latest\" to see the highest-version plan whatever its status."
         }}

      plan ->
        {:ok, plan}
    end
  end

  defp serialize_plan(plan) do
    stages =
      case plan.stages do
        %Ecto.Association.NotLoaded{} -> []
        stages -> Enum.map(stages, &serialize_stage_with_validations/1)
      end

    %{
      id: plan.id,
      task_id: plan.task_id,
      status: plan.status,
      version: plan.version,
      # Task 01a006c2 stage 3. `plan_get` can now hand back a rejected or
      # still-unapproved plan, so the wire shape must say out loud whether
      # this is the plan the task is actually executing. Without it, a
      # caller that asked for status:"rejected" gets a plan object shaped
      # exactly like the current one and can read it as authoritative.
      is_current: plan.status in ["approved", "completed"],
      rejection_reason: plan.rejection_reason,
      architecture_verdict: plan.architecture_verdict,
      approved_by: plan.approved_by,
      approved_at: format_datetime(plan.approved_at),
      # Task 019f25f2 stage 5 — timestamp when the plan was auto-approved
      # via the `tasks.auto_approve_plan` opt-in (nil for manually approved
      # plans). Distinct from `approved_at` so operators can tell apart
      # human vs system approvals in the wire response.
      auto_approved_at: format_datetime(plan.auto_approved_at),
      stages: stages,
      inserted_at: format_datetime(plan.inserted_at),
      updated_at: format_datetime(plan.updated_at)
    }
  end

  defp serialize_stage(stage) do
    %{
      id: stage.id,
      plan_id: stage.plan_id,
      name: stage.name,
      description: stage.description,
      position: stage.position,
      status: stage.status,
      expected_artifacts: stage.expected_artifacts,
      started_at: format_datetime(stage.started_at),
      completed_at: format_datetime(stage.completed_at),
      inserted_at: format_datetime(stage.inserted_at),
      updated_at: format_datetime(stage.updated_at)
    }
  end

  defp serialize_stage_with_validations(stage, full? \\ true) do
    validations =
      case stage.validations do
        %Ecto.Association.NotLoaded{} -> []
        validations -> Enum.map(validations, &serialize_validation_row(&1, full?))
      end

    stage
    |> serialize_stage()
    |> maybe_snippet(full?, [:description])
    |> Map.put(:validations, validations)
  end

  # Task 01a049de. `evidence` and `evaluation_payload` are free-form maps, not
  # strings, so they cannot be sliced by grapheme. They are replaced wholesale
  # in summary mode by a size marker, because a HALF map is a lie — a caller
  # reading `evidence["tests_run"]` from a partial map would get a confidently
  # wrong answer, where a caller reading an absent key with
  # `evidence_omitted: true` next to it knows to go and fetch the stage.
  defp serialize_validation_row(validation, true), do: serialize_validation(validation)

  defp serialize_validation_row(validation, false) do
    row = serialize_validation(validation)

    Enum.reduce([:evidence, :evaluation_payload], row, fn key, acc ->
      case Map.get(acc, key) do
        blob when is_map(blob) and map_size(blob) > 0 ->
          acc
          |> Map.put(key, %{})
          |> Map.put(:"#{key}_omitted", true)
          |> Map.put(:"#{key}_length", byte_size(Jason.encode!(blob)))

        _ ->
          Map.put(acc, :"#{key}_omitted", false)
      end
    end)
  end

  defp serialize_task_row(task, true), do: serialize_task(task)

  defp serialize_task_row(task, false),
    do: task |> serialize_task() |> maybe_snippet(false, [:description])

  defp serialize_review_item_row(row, full?) do
    row
    |> serialize_review_item()
    |> Map.merge(%{
      review_request_id: row.review_request_id,
      request_status: row.request_status,
      validation_id: row.validation_id
    })
    |> maybe_snippet(full?, [:content, :feedback])
  end

  defp maybe_snippet(record, true, _fields), do: record

  defp maybe_snippet(record, false, fields),
    do: Enum.reduce(fields, record, &ResultBound.snippet(&2, &1))

  # `detail` selects how much of each record's prose comes back. "summary" (the
  # default) snippets; "full" restores the pre-01a049de per-record shape for a
  # caller that genuinely needs it and has narrowed the call enough to afford
  # it. Anything unrecognised means summary — an opt-in to a bigger payload
  # should require spelling it correctly.
  defp full_detail?(args) when is_map(args) do
    case Map.get(args, "detail") do
      "full" -> true
      _ -> false
    end
  end

  defp serialize_validation(validation) do
    %{
      id: validation.id,
      stage_id: validation.stage_id,
      kind: validation.kind,
      status: validation.status,
      evidence: validation.evidence,
      evaluation_payload: Map.get(validation, :evaluation_payload),
      evaluated_by: validation.evaluated_by,
      evaluated_at: format_datetime(validation.evaluated_at),
      inserted_at: format_datetime(validation.inserted_at),
      updated_at: format_datetime(validation.updated_at)
    }
  end

  # Pull `evaluation_payload` from a planner-supplied validation map (string-keyed
  # since it arrived through MCP) and merge into create-validation attrs.
  defp maybe_put_evaluation_payload(attrs, v_input) when is_map(v_input) do
    case Map.get(v_input, "evaluation_payload") || Map.get(v_input, :evaluation_payload) do
      nil -> attrs
      payload -> Map.put(attrs, :evaluation_payload, payload)
    end
  end

  defp maybe_put_evaluation_payload(attrs, _), do: attrs

  defp serialize_review_request(request) do
    items =
      case request.items do
        %Ecto.Association.NotLoaded{} -> []
        items -> Enum.map(items, &serialize_review_item/1)
      end

    %{
      id: request.id,
      validation_id: request.validation_id,
      task_id: request.task_id,
      status: request.status,
      submitted_by: request.submitted_by,
      items: items,
      inserted_at: format_datetime(request.inserted_at),
      updated_at: format_datetime(request.updated_at)
    }
  end

  defp serialize_review_item(item) do
    %{
      id: item.id,
      label: item.label,
      canvas_id: item.canvas_id,
      content: item.content,
      status: item.status,
      feedback: item.feedback,
      reviewed_by: item.reviewed_by,
      reviewed_at: format_datetime(item.reviewed_at)
    }
  end

  # `list_items_for_task/1` returns plain maps (a joined select), not
  # ReviewItem structs. `serialize_review_item/1` is reused verbatim — it only
  # dot-accesses atom keys, which the select map carries — and the parent-request
  # columns the join adds are merged on top so a reader can tell a live ruling
  # from one whose evidence was superseded.

  # MCP serializer for a `Platform.MemoryFeedback.Entry` row. The
  # `edited_content` field is nil for delete rows and populated for
  # edit rows — callers can rely on the presence to disambiguate the
  # kind without reading `feedback_kind` explicitly. `reason_text` is
  # nullable on both kinds.
  defp serialize_feedback_entry(%Platform.MemoryFeedback.Entry{} = entry) do
    %{
      path: entry.path,
      original_content: entry.original_content,
      edited_content: entry.edited_content,
      editor_id: entry.editor_id,
      original_author_id: entry.original_author_id,
      reason_text: entry.reason_text,
      inserted_at: format_datetime(entry.inserted_at)
    }
  end

  @blocker_categories ["infra", "product", "decision"]
  @blocker_min_attempts 3

  # A blocker is expensive on purpose: the cost is paid up front (three
  # distinct attempts, an org-memory read, a named unblock action) so the
  # human who reads the notice never has to ask "what did you try?". The
  # error names EVERY missing or short field, because the reader is an agent
  # that will refile from the message alone.
  defp validate_blocker_args(args) do
    attempts = Map.get(args, "attempts")

    distinct_attempts =
      if is_list(attempts) do
        attempts
        |> Enum.filter(&non_blank_string?/1)
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()
      else
        []
      end

    missing =
      [
        {"attempts (need #{@blocker_min_attempts} distinct non-blank strings)",
         length(distinct_attempts) < @blocker_min_attempts},
        {"memory_ref", not non_blank_string?(Map.get(args, "memory_ref"))},
        {"unblock_action", not non_blank_string?(Map.get(args, "unblock_action"))},
        {"category (one of #{Enum.join(@blocker_categories, "|")})",
         Map.get(args, "category") not in @blocker_categories}
      ]
      |> Enum.filter(fn {_name, bad?} -> bad? end)
      |> Enum.map(fn {name, _} -> name end)

    case missing do
      [] ->
        :ok

      missing ->
        {:error,
         %{
           error: "report_blocker refused, missing or short: " <> Enum.join(missing, ", "),
           recoverable: true,
           suggestion:
             "Try three distinct things, read org memory, name the smallest unblock action and who performs it, then refile."
         }}
    end
  end

  defp refuse_infra_needs_human(args) do
    if Map.get(args, "category") == "infra" and truthy?(Map.get(args, "needs_human", false)) do
      {:error,
       %{
         error:
           "report_blocker refused: infra blockers are the infra agent's job, not a human's. " <>
             "Post the exact error to @[Dalton] in the execution space and continue.",
         recoverable: true,
         suggestion:
           "Post the exact command and error with suite_reply in the execution space mentioning @[Dalton], keep working on what does not depend on it, or refile with needs_human: false."
       }}
    else
      :ok
    end
  end

  defp non_blank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp record_blocker(args, context) do
    task_id = Map.get(args, "task_id")
    stage_id = Map.get(args, "stage_id")
    description = Map.get(args, "description")
    needs_human = Map.get(args, "needs_human", false)

    attrs = %{
      "task_id" => task_id,
      "phase" => current_phase_for_blocker(task_id),
      "runtime_id" => Map.get(context, :runtime_id) || "tool-surface",
      "event_type" => "execution.blocked",
      "execution_space_id" => execution_space_id_for_task(task_id),
      "payload" => %{
        "stage_id" => stage_id,
        "description" => description,
        "needs_human" => needs_human,
        "reported_by" => Map.get(context, :agent_id) || "agent",
        "attempts" => Map.get(args, "attempts"),
        "memory_ref" => Map.get(args, "memory_ref"),
        "unblock_action" => Map.get(args, "unblock_action"),
        "category" => Map.get(args, "category")
      }
    }

    case Platform.Orchestration.record_runtime_event(attrs) do
      {:ok, event} ->
        if needs_human do
          if space_id = execution_space_id_for_task(task_id) do
            Platform.Orchestration.ExecutionSpace.post_engagement(
              space_id,
              "Blocker reported: #{description}",
              metadata: %{"reason" => "runtime_blocker", "stage_id" => stage_id}
            )
          end
        end

        {:ok, %{event_id: event.id, task_id: task_id, stage_id: stage_id, blocked: true}}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to record blocker: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Retry the blocker report or post the blocker in the execution space"
         }}
    end
  end

  defp current_phase_for_blocker(task_id) do
    case Platform.Tasks.current_plan(task_id) do
      %{stages: stages} ->
        cond do
          Enum.any?(
            stages || [],
            &(&1.status == "running" and
                  String.contains?(String.downcase(&1.name || ""), "review"))
          ) ->
            "review"

          Enum.any?(
            stages || [],
            &(&1.status == "running" and String.contains?(String.downcase(&1.name || ""), "plan"))
          ) ->
            "planning"

          true ->
            "execution"
        end

      _ ->
        "execution"
    end
  end

  defp execution_space_id_for_task(task_id) do
    case Platform.Orchestration.ExecutionSpace.find_by_task_id(task_id) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp assert_agent_in_space(space_id, context) do
    agent_id = Map.get(context, :agent_id)

    cond do
      is_nil(space_id) ->
        {:error,
         %{
           error: "space_id is required",
           recoverable: true,
           suggestion: "Provide a valid space_id"
         }}

      is_nil(agent_id) ->
        {:error,
         %{
           error: "Agent identity required for read operations",
           recoverable: false,
           suggestion: "Ensure the agent context includes agent_id"
         }}

      true ->
        case Chat.get_agent_participant(space_id, agent_id) do
          %Chat.Participant{} ->
            :ok

          _ ->
            {:error,
             %{
               error: "Access denied: agent is not a participant in space #{space_id}",
               recoverable: false,
               suggestion: "Use space_list to find spaces the agent has access to"
             }}
        end
    end
  end

  defp get_agent_participant_id_for_space(space_id, context) do
    agent_id = Map.get(context, :agent_id)

    if agent_id && space_id do
      case Chat.get_agent_participant(space_id, agent_id) do
        %Chat.Participant{id: id} -> id
        _ -> nil
      end
    end
  end

  # When `meeting_create` was called without an explicit host_participant_id,
  # default the host to the calling agent: add it to the meeting's backing
  # chat space as the principal participant and stamp it onto the meeting.
  # Best-effort — if the agent context is absent or the roster op fails the
  # meeting is returned host-less rather than erroring.
  defp maybe_default_host_participant(meeting, args, context) do
    agent_id = Map.get(context, :agent_id)

    cond do
      not is_nil(Map.get(args, "host_participant_id")) ->
        meeting

      is_nil(agent_id) ->
        meeting

      true ->
        with {:ok, _roster} <-
               Chat.add_space_agent(meeting.chat_space_id, agent_id, role: "principal"),
             %Chat.Participant{id: participant_id} <-
               Chat.get_agent_participant(meeting.chat_space_id, agent_id),
             {:ok, updated} <-
               meeting
               |> Ecto.Changeset.change(host_participant_id: participant_id)
               |> Repo.update() do
          updated
        else
          _ -> meeting
        end
    end
  end

  defp serialize_meeting(meeting) do
    %{
      id: meeting.id,
      project_id: meeting.project_id,
      name: meeting.name,
      slug: meeting.slug,
      status: meeting.status,
      chat_space_id: meeting.chat_space_id,
      # The room a joiner is actually minted into, NOT the row's own column
      # (task 01a06925). `meetings.livekit_room_name` holds `meeting-<id>`,
      # a name nothing joins: `MeetingHooks.do_join/1` resolves
      # `Meetings.ensure_room(space.id)`, `Meetings.invite_agent/3` is handed
      # `get_active_room(space_id)`, `meeting_say` and the LiveKit webhook
      # look rooms up by name, and `legit_room?/1` accepts only `space-`.
      # Reporting the column would hand an agent a room it cannot find anyone
      # in. The column itself is left alone — it carries a unique index and
      # repurposing it is a schema decision, not this serializer's.
      livekit_room_name: Meetings.room_name_for_space(meeting.chat_space_id),
      host_participant_id: meeting.host_participant_id,
      started_at: format_datetime(meeting.started_at),
      ended_at: format_datetime(meeting.ended_at),
      # The INTENDED time, alongside the actuals above. Both keys are always
      # emitted — nil for an ad-hoc meeting — because an absent key and a key
      # with a nil value read identically to a JSON caller only if it never
      # has to distinguish "this meeting is unscheduled" from "this tool
      # doesn't report scheduling". Dropping them when nil would make the
      # write half unreadable: an agent that scheduled a meeting could not
      # confirm what it set.
      scheduled_start_at: format_datetime(meeting.scheduled_start_at),
      scheduled_end_at: format_datetime(meeting.scheduled_end_at)
    }
  end

  # A runtime that has not told us its build reports the literal "unknown".
  #
  # Not nil, not "", not "-". A blank cell reads as a rendering gap and gets
  # skipped; "unknown" is a positive statement that core asked and was not
  # told, which is a different and reportable fact from any sha. Inventing a
  # sha here, or borrowing `version`, would be worse than saying nothing.
  defp format_build(build) when is_binary(build) and build != "", do: build
  defp format_build(_), do: "unknown"

  # Render the observed-capability map, with a cell for every capability the
  # surface always reports.
  #
  # A capability core has never observed renders as the literal "never" rather
  # than being omitted. THE EMPTY CELL IS THE INFORMATION: the whole ticket
  # exists because a runtime looked healthy while silently lacking a handler,
  # and a `transcript never` row against a green dot says so immediately.
  # Omitting unobserved capabilities would restore exactly that blind spot.
  #
  # Observations recorded under names outside `reported_capabilities/0` are
  # merged in rather than filtered out — core saw them, so it reports them.
  defp format_proven(proven) do
    always_reported =
      RuntimePresence.reported_capabilities()
      |> Map.new(&{&1, "never"})

    observed =
      (proven || %{})
      |> Enum.flat_map(fn
        {capability, %DateTime{} = at} when is_binary(capability) ->
          [{capability, format_datetime(at)}]

        _ ->
          []
      end)
      |> Map.new()

    Map.merge(always_reported, observed)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ── Brand decision (ADR 0046) ─────────────────────────────────────────
  #
  # The accepted set is `Brand.recordable_modes/0` and nothing else — the
  # parameter description above is built from the same call, so there is no
  # second copy to drift. Note `"asked"` is a valid *stored* mode that this
  # gate deliberately rejects: it is written by `Brand.escalate_once/2` and
  # is not something a caller selects.
  defp apply_brand_decision(project, nil, _context), do: {:ok, project}

  defp apply_brand_decision(project, mode, context) when is_binary(mode) do
    if mode in Brand.recordable_modes() do
      Brand.record_decision(project, mode, recorded_by: recorded_by(context))
    else
      {:error, :invalid_brand_decision}
    end
  end

  defp apply_brand_decision(_project, _mode, _context), do: {:error, :invalid_brand_decision}

  defp recorded_by(context) when is_map(context), do: Map.get(context, :agent_id)
  defp recorded_by(_), do: nil

  # `plan_auto_approve` is the second named key (after `brand_decision`)
  # that reaches `config` through `project_update`. It is merged OVER the
  # existing config so unrelated keys (brand_decision, lifecycle_pipeline)
  # survive; `Project.changeset/2` validates its shape and refuses the
  # whole update on a malformed value. Non-map values are passed through
  # so the changeset reports them rather than a `Map.merge` crash.
  defp put_plan_auto_approve(update_attrs, _project, nil), do: update_attrs

  defp put_plan_auto_approve(update_attrs, project, policy) do
    Map.put(update_attrs, :config, Map.put(project.config || %{}, "plan_auto_approve", policy))
  end

  defp brand_decision_of(%{config: config}) when is_map(config),
    do: Map.get(config, "brand_decision")

  defp brand_decision_of(_), do: nil

  # Derive a slug from the channel name when the caller omits one. Agents
  # routinely pass only a name, and inventing a slug for them is far better
  # than a required-argument round trip.
  defp dm_create_agent(context) do
    case load_agent(context) do
      %Agent{} = agent ->
        {:ok, agent}

      _ ->
        {:error,
         %{
           error: "dm_create: no calling agent in context",
           recoverable: false,
           suggestion:
             "dm_create is only callable by an agent runtime — the DM's other party is the caller itself."
         }}
    end
  end

  # Org scoping, reusing `agent_home_org/1` — literally the predicate
  # `space_create_org/2` already uses to decide which org an agent may act in.
  # A root-scoped agent (no `metadata["org_id"]`, or pinned to the root org)
  # may reach anyone internal; a tenant-pinned agent may reach only people
  # holding a membership in its own org. Nothing new is invented here.
  #
  # The EXTERNAL-user refusal is NOT here — it lives at the seam in
  # `Chat.find_or_create_agent_dm/2`, so it holds for every future caller and
  # not just for this tool.
  defp authorize_dm_target(agent, user_id) do
    case agent_home_org(agent) do
      :root ->
        :ok

      {:tenant, org_id} ->
        member? =
          case Platform.Accounts.get_user(user_id) do
            nil ->
              false

            user ->
              user
              |> Tenancy.list_user_memberships()
              |> Enum.any?(&(&1.org_id == org_id))
          end

        if member? do
          :ok
        else
          {:error,
           %{
             error: "dm_create: #{user_id} is not reachable from your org",
             recoverable: false,
             suggestion:
               "A tenant-pinned agent may only DM people who hold a membership in its own org. Post in a shared channel instead, or ask a person in your org to relay."
           }}
        end
    end
  end

  defp deliver_agent_dm(%Agent{} = agent, user_id, message) do
    with {:ok, space} <- Chat.find_or_create_agent_dm(agent.id, user_id),
         {:ok, %Participant{} = participant} <-
           Chat.SpaceAccess.authorize_writer(space.id, {:agent, agent.id}),
         {:ok, msg} <-
           Chat.post_message(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: message
           }) do
      {:ok,
       %{
         space_id: space.id,
         message_id: msg.id,
         user_id: user_id,
         agent_participant_id: participant.id
       }}
    else
      {:error, :user_not_found} ->
        {:error,
         %{
           error: "dm_create: no such user (#{user_id})",
           recoverable: true,
           suggestion:
             "Resolve the person with `principal_search` (type: \"user\") and pass the `id` from the row it returns."
         }}

      {:error, :agent_not_found} ->
        {:error,
         %{
           error: "dm_create: the calling agent no longer resolves",
           recoverable: false,
           suggestion: "The agent row may have been archived or deleted."
         }}

      {:error, :dm_not_allowed} ->
        {:error,
         %{
           error: "dm_create: DMs to external users are not permitted",
           recoverable: false,
           suggestion:
             "The external chat surface is scoped to allowlisted humans and agent DMs are out of scope for it, in both directions. Reach this person through the space they already share with you."
         }}

      {:error, :forbidden} ->
        {:error,
         %{
           error: "dm_create: the calling agent is not a participant in the resolved DM",
           recoverable: false,
           suggestion:
             "This should be unreachable — dm_create only ever resolves a DM the caller is a party to. Report it."
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "dm_create failed: #{inspect_errors_safe(reason)}",
           recoverable: true,
           suggestion: "Retry; if the message body is empty or oversized, shorten it."
         }}
    end
  end

  defp space_create_slug(args, name) do
    raw =
      case Map.get(args, "slug") do
        slug when is_binary(slug) and slug != "" -> slug
        _ -> name
      end

    slug =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      {:error,
       %{
         error: "space_create: could not derive a slug from `name`",
         recoverable: true,
         suggestion: "Pass an explicit `slug` containing at least one letter or digit."
       }}
    else
      {:ok, slug}
    end
  end

  # Org scoping mirrors `authorize_org_filter/2`: a tenant-pinned agent may only
  # act in its own org, a root agent anywhere. Omitting `org_id` means "my home
  # org", which is what an agent almost always wants.
  defp space_create_org(args, context) do
    agent = load_agent(context)

    case Map.get(args, "org_id") do
      org_id when is_binary(org_id) and org_id != "" ->
        case authorize_org_filter(agent, org_id) do
          :ok -> {:ok, org_id}
          {:error, _} = err -> err
        end

      _ ->
        case agent && agent_home_org(agent) do
          {:tenant, org_id} -> {:ok, org_id}
          _ -> {:ok, nil}
        end
    end
  end

  defp inspect_errors_safe(%Ecto.Changeset{} = changeset), do: inspect_errors(changeset)
  defp inspect_errors_safe(reason), do: inspect(reason)

  defp inspect_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  # Parse an optional ISO8601 timestamp argument by name.
  #
  # Returns `{:ok, nil}` for an absent parameter and `{:error, envelope}` —
  # not nil, and not a raise — for one that is present but unparseable. Both
  # of the obvious shortcuts are wrong for the same reason, in opposite
  # directions:
  #
  #   * Coercing to nil silently downgrades a scheduled meeting to an ad-hoc
  #     one. `Map.reject/2` in the caller drops nils, so the parse failure
  #     becomes indistinguishable from never having passed the parameter: the
  #     row is created, the caller is told `{:ok, ...}`, and the meeting never
  #     appears on the calendar it was scheduled for. Nobody is told why.
  #   * Raising turns a caller's typo into a tool-surface crash rather than a
  #     recoverable answer the agent can act on — the federation contract is
  #     that a bad argument comes back as an error envelope naming the
  #     argument.
  #
  # The offending parameter is named in the message so an agent that passed
  # both endpoints knows which one to fix.
  defp parse_optional_datetime(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _utc_offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, invalid_datetime_error(key, value)}
        end

      value ->
        {:error, invalid_datetime_error(key, value)}
    end
  end

  defp invalid_datetime_error(key, value) do
    %{
      error: "Invalid #{key}: #{inspect(value)} is not an ISO8601 timestamp",
      recoverable: true,
      suggestion:
        "Pass #{key} as an ISO8601 timestamp with an offset, e.g. \"2026-08-01T15:00:00Z\". No meeting was created."
    }
  end

  defp parse_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      {:error, _} -> {:error, date_str}
    end
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_optional_date(nil), do: nil

  defp parse_optional_date(date_str) do
    case parse_date(date_str) do
      {:error, _} = err -> err
      date -> date
    end
  end
end
