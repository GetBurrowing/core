defmodule Platform.Federation.ToolSurface do
  @moduledoc """
  Tool surface for federated agents.
  Same tools available to built-in and external runtimes.
  Includes both write tools and bounded read tools for space context.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, ContextPlane, Participant}
  alias Platform.Meetings
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Journal, Routing, Search}
  alias Platform.Tasks

  alias Platform.Tasks.{
    CanvasAttachments,
    Plan,
    PlanEngine,
    Stack,
    StackDeployer,
    Stacks,
    Stage,
    Task,
    Validation
  }

  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Repo

  alias Platform.Federation.TaskAttrs

  import Ecto.Query, only: [from: 2]

  @bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files)

  # Per-message content cap (graphemes) for space_get_messages /
  # space_search_messages. Anything longer is sliced and flagged via the
  # `content_truncated` boolean on the returned map.
  @message_content_cap 64_000

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
  defp tools_for_bundle(_), do: []

  defp tag(tools, bundle), do: Enum.map(tools, &Map.put(&1, :bundle, bundle))

  defp federation_tools do
    [
      %{
        name: "federation_status",
        description:
          "Check the connection status of all registered agent runtimes. Shows which runtimes are online, when they connected, and when they last sent a message.",
        parameters: %{},
        returns:
          "Array of runtime status objects with runtime_id, agent_name, online, connected_at, last_seen_at, last_connected_at",
        limitations:
          "Only shows active runtimes. Presence data is in-memory and resets on restart.",
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
          "%{files: [%{id, name, original_filename, content_type, byte_size, inserted_at, ingest_status}], project_id, count}",
        limitations:
          "Tenant-pinned agents calling with a sibling-org project return an `unauthorized: …` envelope (NOT an empty list, so existence can't be probed). Unknown project_id returns `:not_found`. Files still ingesting carry `ingest_status: \"pending\"` — call file_get_text only on \"ingested\" rows.",
        when_to_use:
          "When you need to enumerate the documents in a project — e.g. before calling file_get_text to read one, or to surface the right file to the user."
      },
      %{
        name: "file_get_text",
        description:
          "Fetch the extracted text body for a single file (ADR 0042). Returns the full body or — when `page` is supplied and the file has a per-page split (PDF, gdoc) — that page only. Reads from the `platform_file_texts` cache populated at ingest time; no re-extraction. Set `binary: true` to skip the text cache and return the raw bytes base64-encoded — agents almost always want text, so reach for `binary: true` only when handing the file off to another tool that needs the actual bytes (zip, image, raw blob the extractor can't read).",
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
              "Default `false`. When `true`, skip the extracted-text lookup and return the raw bytes as base64 in `data_base64`. Capped at 25 MB — larger files return `:too_large`. Use sparingly: agents nearly always want text."
          }
        },
        returns:
          "Default: %{file_id, content_type, text, page?, total_pages?, original_filename}. With `binary: true`: %{file_id, content_type, byte_size, data_base64, original_filename}.",
        limitations:
          "Authorization mirrors file_list. Unknown `file_id` → `:not_found`. File not yet ingested / extraction failed → `:no_text_available` (consider retrying with `binary: true` if you just need the raw bytes). `page` out of range → `:page_out_of_range`. Tenant-pinned agents reading a sibling-org file → `unauthorized: …`. `binary: true` over 25 MB → `:too_large` (a presigned-download path is planned but not yet shipped).",
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
          "%{file_id, project_id, org_id, name, original_filename, content_type, byte_size, content_hash, ingest_status, uploaded_by_user_id, inserted_at, updated_at}",
        limitations:
          "Authorization mirrors file_list / file_get_text. Unknown `file_id` → `:not_found`. Tenant-pinned agents reading a sibling-org file → `unauthorized: …`. `storage_key` is intentionally omitted — it's an internal handle into the object store, not a stable public identifier.",
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
          "Upload a file into a project's document store (ADR 0042). One tool, two branches — pass `data_base64` for the inline path (small bytes, capped at 25 MB) or pass `byte_size` alone for the presigned-upload path (large files up to 500 MB). Inline branch persists bytes, dedups against prior `(project_id, content_hash)` siblings, fires extract + Memory ingest async, and returns the file id with `state: \"ready\"`. Presigned branch reserves a `platform_files` row in `ingest_status: \"pending\"`, returns an `upload_url` the caller POSTs raw bytes to within `expires_at`, and surfaces `state: \"pending\"` — finalization happens via the upload-controller boot reconciliation / LiveView upload path; the file is not searchable until then.",
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
          "Delete a file (ADR 0042). Removes the underlying R2/S3 object FIRST, then the `platform_files` row. Idempotent — re-deleting a non-existent file returns the standard `:not_found` envelope rather than crashing. Broadcasts `{:file_deleted, file_id}` on the project topic so live UIs (FilesLive) drop the row without a manual refresh.",
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
          "Authorization mirrors file_list / file_get_text. Unknown `file_id` → `:not_found` (idempotent — second delete looks the same as a never-existed id). Tenant-pinned agents deleting a sibling-org file → `unauthorized: …` envelope. Storage object deletion is best-effort and `:ok`-on-missing; if the row delete fails after the object is gone the caller sees an error envelope but the bytes are not restored — re-issuing the call clears the row.",
        when_to_use:
          "When a file should be removed from a project entirely — either to retract content or to free storage. For just dropping the extracted-text cache without removing the row, use the appropriate Files context helper directly (no public tool for that today)."
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
          "Hybrid (semantic + lexical) search across memory pages, journal entries, chat messages, and tasks. Results are source-tagged and ranked via Reciprocal Rank Fusion (k=60) across corpora. Message hits are filtered to spaces the calling agent participates in.",
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
          "%{results: [%{source, id, path, space_id, content, score, semantic_rank, lexical_rank, authored_by, date_or_inserted_at}], fusion_constant_k: 60, truncated: boolean}. Task hits (source: \"task\") carry additional advisory fields: `status`, `priority`, `updated_at`, `merged_pr_url` (or nil), `follow_up_task_ids` (list of open tasks that reference this one), and `cancellation_note` (rework directive for cancelled tasks).",
        limitations:
          "Message hits are filtered to spaces the calling agent participates in (anonymous callers get no message hits). Deleted or orphaned rows are silently dropped. `truncated: true` indicates a channel hit its `2*limit` cap and a higher `limit` may surface more hits.",
        when_to_use:
          "When you need to recall information beyond the org preamble — past decisions, journal entries, relevant chat threads, prior tasks (shipped or in-flight), or any cross-corpus lookup."
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
      }
    ]
  end

  defp space_tools do
    [
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
          "Array of message objects with id, participant_id, content, search_headline, inserted_at",
        limitations:
          "Only searches spaces the agent is a participant in. Max 10 results. Uses PostgreSQL full-text search.",
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
        description:
          "List all canvases in a space with summary information (id, title, type, timestamps).",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns: "Array of canvas summary objects with id, title, type, inserted_at, updated_at",
        limitations: "Only works for spaces the agent is a participant in.",
        when_to_use:
          "When you need to discover what canvases exist in a space before reading or updating one"
      },
      %{
        name: "canvas_get",
        description:
          "Get a canvas by ID. Returns summary by default, or full document state with mode=full.",
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
          "Canvas object with id, title, type, space_id, and optionally the full state document",
        limitations:
          "Only works for canvases in spaces the agent is a participant in. Full mode may return large payloads for complex canvases.",
        when_to_use:
          "When you need to inspect a canvas's content before updating it, or to present canvas data to a user"
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
        description:
          "Create a live canvas with a canonical document (ADR 0036). The document is a node tree whose root type is one of the registered kinds.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "Target space UUID"},
          title: %{type: "string", required: false, description: "Human-readable title"},
          document: %{
            type: "object",
            required: true,
            description:
              "Canonical document. See canvas.describe on an existing canvas for a valid shape. Pass as a nested object, not a JSON string.",
            schema: Platform.Chat.Canvas.Tools.document_schema()
          }
        },
        returns: "%{canvas_id, title, kind, revision}",
        limitations: "Canvas kinds are defined in the kind registry.",
        when_to_use: "When you need to present structured, interactive, or visual data to users"
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
          "Read the current document, revision, presence, and recent events for a canvas. Cheap, idempotent — call before patching so base_revision is fresh.",
        parameters: %{
          canvas_id: %{type: "string", required: true}
        },
        returns:
          "%{canvas_id, title, space_id, kind, revision, document, presence, recent_events}",
        limitations: "Only works for canvases in spaces the agent is a participant in.",
        when_to_use: "Before emitting canvas.patch, or to present canvas state to a user"
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
          "List a canvas's revision history newest-first. Each entry is the revision number, write timestamp, written_by attribution snapshot, and a 1-sentence op_summary derived from the patch ops. Pair with canvas.restore to roll back.",
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
        limitations:
          "Only works for canvases in spaces the agent is a participant in. Versions older than the table's existence are not back-filled.",
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
              "Project-wide deploy config. Set deploy_config.default_strategy to a strategy map (e.g. %{\"type\" => \"pr_merge\"}) to provide a fallback for tasks whose deploy_target is unset. Valid strategy types: none, pr_merge, docker_deploy, fly, skill_driven, manual."
          }
        },
        returns: "The updated project object",
        limitations:
          "deploy_config.default_strategy is validated; unknown strategy types are rejected",
        when_to_use:
          "When you need to set a project-level default deploy strategy or update other project fields"
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
          "Create a new task in a project. Tasks track work items on the kanban board. Optionally set a Sponsor (human shepherd, ADR 0042) distinct from the current-phase technical assignee. Set auto_approve_plan: true to skip human review when the plan is submitted (requires an assigned agent). Canonical shape is documented in ADR 0044 and shared with task_update via `Platform.Federation.TaskAttrs.build_task_attrs/3` — flat assignee_id + assignee_type writes auto-route into `phase_assignees[\"planning\"]` (new tasks start at planning phase), so the write survives future phase transitions.",
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
              "When true, auto-approve the plan the planner submits and skip the human review step. Precondition: both the execution-phase and review-phase assignees must resolve to an agent (via assignee_id + assignee_type OR phase_assignees). If either is missing, the auto-approve is silently skipped and the plan stays in pending_review for human review. Defaults to false."
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
          "The created task object with id, title, status, priority, and sponsor (nil unless sponsor_user_id was supplied, else %{id, name, email}). When stack_id is supplied, the response also includes stack_id and stack_position. Response also includes advisory `similar_tasks: [%{id, title, status, priority, similarity_score, updated_at, merged_pr_url, follow_up_task_ids, cancellation_note}]` (0-5 near-duplicate hits with similarity_score >= 0.5, scoped to the same project) so the caller can detect near-duplicates and decide to fold, reference, or file fresh without a follow-up memory_search. Empty array (not nil) when no matches or when the similarity search fails.",
        limitations:
          "Requires a valid project_id. If stack_id is supplied, the stack must exist and the resulting in-stack DAG must remain acyclic with no cross-stack dependency edges. If sponsor_user_id is supplied it must reference an existing user (FK enforced). When auto_approve_plan is true, the plan won't auto-approve unless every phase assignee resolves to an agent.",
        when_to_use: "When you need to track a work item, feature, bug, or action item"
      },
      %{
        name: "task_get",
        description: "Get a single task by ID with full details.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"}
        },
        returns:
          "Task object with id, title, description, status, priority, project_id, epic_id, and sponsor (nil or %{id, name, email} per ADR 0042).",
        limitations: "Returns nil if task not found",
        when_to_use: "When you need to check the current state of a specific task"
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
          }
        },
        returns:
          "Array of task objects. Each entry includes sponsor (nil or %{id, name, email}) per ADR 0042.",
        limitations: "Returns all matching tasks; no pagination yet",
        when_to_use:
          "When you need to see what tasks exist, check the backlog, or find tasks in a specific state"
      },
      %{
        name: "task_complete",
        description: "Mark a task as done.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID to complete"}
        },
        returns: "The updated task object with id and status",
        limitations: "Task must exist and allow transition to done status",
        when_to_use: "When you need to mark a task as complete/done"
      },
      %{
        name: "task_update",
        description:
          "Update a task's fields (title, description, status, priority, assignee, sponsor, etc.). Omitted fields are left untouched; sponsor_user_id explicitly accepts null to unset (clears the Sponsor per ADR 0042). Flat assignee_id + assignee_type writes are auto-routed to the task's current-phase slot in phase_assignees (survives phase transitions per ADR 0044). Pass phase_assignees directly to set multiple phase slots in one call — when both are supplied, phase_assignees wins.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to update"},
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
              "When true, the engine auto-approves the task's submitted plan without waiting for a human approval — the task moves straight from plan_submit to in_progress. Useful for well-scoped low-risk tasks where plan review is procedural. Defaults to false on new tasks."
          },
          phase_assignees: %{
            type: "object",
            required: false,
            description:
              "Granular per-phase assignees keyed by phase (\"planning\" | \"execution\" | \"review\") with values %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\" | \"user\"}. Canonical writer per ADR 0044 — only the slots supplied are written; other slots stay untouched. Wins over flat assignee_id + assignee_type when both are supplied in the same call."
          }
        },
        returns: "The updated task object (includes sponsor: nil | %{id, name, email}).",
        limitations:
          "Status transitions are validated; not all transitions are allowed. sponsor_user_id must reference an existing user; passing an unknown UUID returns a recoverable FK error.",
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
          "Soft-reference contract: the canvas is checked at attach time but not FK-enforced. If the canvas is soft-deleted later, `task_list_canvases` will surface it with `canvas_present: false` so callers can detach. Idempotent re-attach updates the note + attribution but never produces a duplicate row.",
        when_to_use:
          "When you (or an upstream planner) want a canvas to ride along in the next dispatch payload for a task, without copy-pasting it into a chat message."
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
          "Returns `not_found` if no matching `(task_id, canvas_id)` pair exists. Does not delete the canvas itself — only the attachment row.",
        when_to_use:
          "When a canvas should no longer ride along with a task's dispatch payload, or to clean up a stale attachment whose underlying canvas was soft-deleted."
      },
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
          "Returns an empty list (not an error) for tasks with no attachments. Does not return the full canvas document — call `canvas.describe` with the `canvas_id` to fetch it.",
        when_to_use:
          "When you need to see which canvases will ride along in the next dispatch for a task, or to find stale attachments whose underlying canvas was soft-deleted."
      },
      %{
        name: "stack_create",
        description:
          "Create a new task stack (ADR 0041). Task stacks group co-related tasks that ship together as a single rollup PR. The rollup branch is auto-derived from the slug as `stack/<slug>`.",
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
          }
        },
        returns: "%{stack_id, rollup_branch} — the new stack id and its derived rollup branch.",
        limitations:
          "Slug must be unique within the project and pass valid_slug?/1. Stack starts in `forming` status with no members.",
        when_to_use:
          "When you need to group multiple co-related tasks into a single ship-unit with one rollup PR."
      },
      %{
        name: "stack_get",
        description:
          "Get a task stack with its members, in-stack dependency edges, and which members are executable right now (no in-stack predecessors).",
        parameters: %{
          stack_id: %{type: "string", required: true, description: "The stack to fetch"}
        },
        returns:
          "%{stack: %{id, slug, name, status, rollup_branch, base_branch, description}, members: [%{id, title, status, stack_position, dependencies}], edges: [%{from_task_id, to_task_id, kind}], executable_now: [task_id], cross_stack_deps: [%{from_task_id, to_task_id, kind}]}. `edges` are in-stack dep edges only; cross-stack dep edges (deps to tasks in OTHER stacks) surface separately under `cross_stack_deps`. Deps pointing at non-stack tasks are silently dropped per ADR 0041.",
        limitations:
          "Returns an error envelope if the stack does not exist. `executable_now` is empty when the in-stack DAG fails validation (cycle or cross-stack-dep) — inspect `edges` / `cross_stack_deps` to diagnose.",
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
          }
        },
        returns:
          "Array of stack objects (same shape as `stack_get`'s `stack` field), ordered by inserted_at descending.",
        limitations: "Returns all matching stacks; no pagination yet (matches list_stacks/1).",
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
          "%{task_id, stack_id, stack_position} on success. Error envelopes carry a `code` field: `already_in_stack`, `cycle` (with `path` of task ids), `cross_stack_dep` (with `from_task_id` and `to_task_id`).",
        limitations:
          "Task must not already be in any stack. The in-stack DAG must remain acyclic and contain no cross-stack dep edges after the add; otherwise the attach is rolled back.",
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
          "%{from_task_id, to_task_id, kind, executable_now} on success, where `executable_now` is the recomputed in-stack ready set (member ids with no unresolved in-stack deps).",
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
          "%{from_task_id, to_task_id, executable_now} on success. `executable_now` is the recomputed in-stack ready set after the removal.",
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
        name: "stack_start_planning",
        description:
          "Stack-level \"Start Planning\" lifecycle action. Fans the `backlog -> planning` transition out to every constituent member currently at `backlog`; members already past `backlog` (`planning`, `stack_pending`, `in_progress`, …) are left untouched — the cascade is additive. Does not write the stack status itself: an all-`planning` stack rolls up to `forming` per the ADR 0041 status mapping.",
        parameters: %{
          stack_id: %{
            type: "string",
            required: true,
            description: "The stack to start planning"
          }
        },
        returns:
          "The stack record plus `planning` (the members moved from `backlog` to `planning`). Per-member transition failures surface in a `cascade_errors` array. An empty stack — or one with no `backlog` members — returns an empty `planning` list.",
        limitations:
          "Members that fail the `planning` transition appear in `cascade_errors`; the stack-level status still recomputes from its members. Safe to re-invoke: a stack with no `backlog` members is a no-op returning an empty `planning` list.",
        when_to_use:
          "When you want every backlog member of a stack to enter the planning phase at once — the headless mirror of the per-task \"Start Planning\" button."
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
      },
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
          }
        },
        returns:
          "The created meeting map: id, project_id, name, slug, status, chat_space_id, livekit_room_name, host_participant_id, started_at, ended_at.",
        limitations:
          "Requires a valid project_id and name. If an explicit slug collides with an existing meeting in the project, a clean changeset error is returned (auto-generated slugs are de-duplicated instead).",
        when_to_use:
          "When you need to spin up a persistent meeting surface for a project — a kickoff, sync, design review, or retro."
      }
    ]
  end

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
            description:
              "Array of IMPLEMENTATION stage objects: {name, description, position, validations: [{kind, evaluation_payload?}]}. Valid validation kinds for planner-authored stages: lint_pass, type_check, test_pass, manual_approval, e2e_behavior. Do NOT include a deploy stage — the system auto-injects one (with ci_passed / pr_merged / etc. validations) at deploying time from the project's resolved deploy strategy. The e2e_behavior kind requires an evaluation_payload map with keys setup/actions/expected (the planner authors an adversarial test plan the review agent will execute — include 2-5 e2e_behavior validations covering happy path, edges, and regression-prone scenarios; do NOT pre-write failure_feedback, the review agent observes failures at review time)."
          }
        },
        returns: "The created plan with stages and validations preloaded",
        limitations:
          "Requires a valid task_id. Stages must have unique positions. Do not include a deploy stage; the system auto-injects one from the resolved deploy strategy.",
        when_to_use: "When you need to define a multi-stage execution plan for a task"
      },
      %{
        name: "plan_get",
        description: "Get the current approved plan for a task with full stage/validation tree.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"}
        },
        returns: "Plan object with stages and validations preloaded",
        limitations: "Returns error if no approved plan exists for the task",
        when_to_use: "When you need to check the current execution plan for a task"
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
        limitations: "Plan must be in pending_review status",
        when_to_use:
          "After plan_submit, when you want to approve a plan and kick off task execution without waiting for human review"
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
          "List all stages for a plan, ordered by position, with validations preloaded.",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID"}
        },
        returns: "Array of stage objects with validations",
        limitations: "None",
        when_to_use: "When you need to see all stages and their validation status for a plan"
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
          stage_id: %{type: "string", required: true, description: "The running stage ID"}
        },
        returns: "Structured result describing the completed stage and updated plan state",
        limitations: "Fails if the stage is not running or still has pending/failed validations.",
        when_to_use: "When you have completed a running stage and need the plan engine to advance"
      },
      %{
        name: "report_blocker",
        description:
          "Report a blocker for the current task stage. Records a structured execution.blocked event so the router can stop treating silence as liveness.",
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
            description: "Whether the blocker requires human intervention"
          }
        },
        returns: "Structured blocker acknowledgement with event ID and escalation hint",
        limitations: "Requires task_id and stage_id from the current execution context.",
        when_to_use:
          "When you cannot proceed and need the orchestrator to pause silence-based escalation"
      },
      %{
        name: "validation_list",
        description: "List all validations for a stage.",
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

  @doc """
  Execute a tool call.

  context must include :space_id and :agent_participant_id.
  Returns {:ok, result} | {:error, %{error: string, recoverable: boolean, suggestion: string}}
  """

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

  def execute("react", args, context) do
    space_id = Map.get(args, "space_id")
    message_id = Map.get(args, "message_id")
    emoji = Map.get(args, "emoji")

    cond do
      not is_binary(space_id) or space_id == "" ->
        {:error,
         %{
           error: "space_id is required",
           recoverable: false,
           suggestion: "Pass the UUID of the Suite space as space_id"
         }}

      not is_binary(message_id) or message_id == "" ->
        {:error,
         %{
           error: "message_id is required",
           recoverable: false,
           suggestion: "Pass the UUID of the message to react to as message_id"
         }}

      not is_binary(emoji) or emoji == "" ->
        {:error,
         %{
           error: "emoji is required",
           recoverable: false,
           suggestion: "Pass a single emoji grapheme as emoji (e.g. \"👍\")"
         }}

      true ->
        react_after_validation(space_id, message_id, emoji, context)
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

  # ── Review tools ────────────────────────────────────────────────────────

  def execute("review_request_create", args, context) do
    validation_id = Map.get(args, "validation_id")
    items = Map.get(args, "items", [])

    with validation when not is_nil(validation) <- Repo.get(Validation, validation_id),
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

  # ── Space tools ─────────────────────────────────────────────────────────

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

    if not is_binary(space_id) or space_id == "" do
      {:error,
       %{
         error: "space_id is required",
         recoverable: false,
         suggestion: "Provide a valid Suite space UUID"
       }}
    else
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
  end

  def execute("space_leave", args, context) do
    space_id = Map.get(args, "space_id")
    calling_agent_id = Map.get(context, :agent_id)
    target_agent_id = Map.get(args, "agent_id") || calling_agent_id

    cond do
      not is_binary(space_id) or space_id == "" ->
        {:error,
         %{
           error: "space_id is required",
           recoverable: false,
           suggestion: "Provide a valid Suite space UUID"
         }}

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
        {:ok, %{id: payload.canvas_id, title: payload.title, kind: payload.kind}}

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
           inserted_at: format_datetime(c.inserted_at),
           updated_at: format_datetime(c.updated_at)
         }
       end)}
    end
  end

  def execute("canvas_get", args, context) do
    canvas_id = Map.get(args, "canvas_id")
    mode = Map.get(args, "mode", "summary")

    case Chat.get_canvas(canvas_id) do
      nil ->
        {:error,
         %{
           error: "Canvas not found: #{canvas_id}",
           recoverable: false,
           suggestion: "Use canvas_list to find available canvases in the space"
         }}

      canvas ->
        with :ok <- assert_agent_in_space(canvas.space_id, context) do
          result = %{
            id: canvas.id,
            title: canvas.title,
            kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
            space_id: canvas.space_id,
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

  # ── Task tools ───────────────────────────────────────────────────────────

  def execute("project_list", args, _context) do
    opts =
      case Map.get(args, "org_id") do
        org_id when is_binary(org_id) and org_id != "" -> [org_id: org_id]
        _ -> []
      end

    projects =
      opts
      |> Tasks.list_projects()
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
    case Map.get(args, "org_id") do
      org_id when is_binary(org_id) and org_id != "" ->
        list_org_descendants(org_id)

      _ ->
        {:error,
         %{
           error: "org_list_descendants: `org_id` is required",
           recoverable: true,
           suggestion: "Provide a non-empty `org_id` argument."
         }}
    end
  end

  def execute("project_update", args, _context) do
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
        update_attrs =
          args
          |> Map.take(["name", "repo_url", "default_branch", "deploy_config"])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

        case Tasks.update_project(project, update_attrs) do
          {:ok, updated} ->
            {:ok,
             %{
               id: updated.id,
               name: updated.name,
               slug: updated.slug,
               repo_url: updated.repo_url,
               default_branch: updated.default_branch,
               deploy_config: updated.deploy_config
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update project: #{inspect_errors_safe(changeset)}",
               recoverable: true,
               suggestion:
                 "Check that deploy_config.default_strategy uses a valid strategy type (none, pr_merge, docker_deploy, fly, skill_driven, manual)"
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
  def execute("task_create", args, _context) do
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
         :ok <- check_auto_approve_requires_assignee(flat_attrs, phase_attrs, "planning", nil),
         {:ok, task} <- Tasks.create_task(flat_attrs),
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
      {:error, {:invalid_phase_keys, keys}} ->
        {:error,
         %{
           error: "Invalid phase_assignees keys: #{Enum.join(keys, ", ")}",
           recoverable: true,
           suggestion: "Use 'planning', 'execution', or 'review'"
         }}

      {:error, {:invalid_phase_assignees_shape, _}} ->
        {:error,
         %{
           error: "phase_assignees must be a map keyed by phase name",
           recoverable: true,
           suggestion:
             "Pass %{\"planning\" => %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\"}}"
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect_errors(changeset)}",
           recoverable: true,
           suggestion: "Check that project_id is valid and title is provided"
         }}

      {:error, other} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect(other)}",
           recoverable: true,
           suggestion: "Check the request shape"
         }}
    end
  end

  # Applies a per-phase assignee map through the canonical writer
  # (`Tasks.set_phase_assignees/2`), which re-derives the flat
  # `assignee_id + assignee_type` pointer from the current phase. Called
  # from both `task_create` and `task_update` after `build_task_attrs/3`
  # emits a non-nil `phase_attrs`.
  defp maybe_apply_phase_assignees(task, nil), do: {:ok, task}

  defp maybe_apply_phase_assignees(task, phase_attrs) when is_map(phase_attrs),
    do: Tasks.set_phase_assignees(task, phase_attrs)

  # Stage 4 (019f3dbb) — advisory self-similarity search for
  # `task_create`. Runs synchronously post-create because the caller
  # needs the field in the same response envelope (a follow-up
  # `memory_search` round-trip would double the create's latency).
  #
  # ## Threshold
  #
  # The plan (task 019f3dbb stage 4) expresses the "strong match" cutoff
  # as `similarity_score >= 0.5`. `Platform.Org.Wiki.Search` produces
  # RRF-fused scores bounded by roughly `2 * 1/(k + 1) ≈ 0.033` at k=60,
  # so the fused `score` on the hit envelope never crosses 0.5 in
  # practice. We derive `similarity_score` from the hit's channel ranks
  # instead — `1.0 / min(semantic_rank, lexical_rank)` — which cleanly
  # maps to the plan's mental model:
  #
  #   * rank 1 → 1.0 (near-identical content, both channels rank 1
  #     usually means the title tokens overlap fully)
  #   * rank 2 → 0.5 (still a plausible duplicate)
  #   * rank 3 → 0.33 (weak — filtered out)
  #
  # So the effective filter is "top-2 in at least one channel," which
  # is the "strong match" bar the plan describes.
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
  defp similar_tasks_for(task) do
    try do
      query_text =
        [task.title, task.description]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
        |> normalize_similarity_query()

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
          |> Enum.map(&similar_task_entry/1)
          |> Enum.filter(fn entry -> entry.similarity_score >= 0.5 end)
          |> Enum.take(5)

        {:error, reason} ->
          Logger.warning("task_create similarity search returned error: #{inspect(reason)}")

          []
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
  defp similar_task_entry(hit) do
    %{
      id: hit.id,
      title: hit_title(hit),
      status: hit.status,
      priority: hit.priority,
      similarity_score: hit_similarity_score(hit),
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

  # See `similar_tasks_for/1` for the rationale — rank-based confidence
  # in [0, 1]. `100` is the "not present in this channel" sentinel; both
  # ranks missing would already have been filtered upstream (a hit with
  # no channel rank cannot exist), so the max is a defensive floor.
  defp hit_similarity_score(%{semantic_rank: semantic_rank, lexical_rank: lexical_rank}) do
    ranks = Enum.reject([semantic_rank, lexical_rank], &is_nil/1)

    min_rank =
      case ranks do
        [] -> 100
        list -> Enum.min(list)
      end

    Float.round(1.0 / min_rank, 3)
  end

  defp hit_similarity_score(_), do: 0.0

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

  def execute("meeting_create", args, context) do
    attrs =
      %{
        project_id: Map.get(args, "project_id"),
        name: Map.get(args, "name"),
        slug: Map.get(args, "slug"),
        host_participant_id: Map.get(args, "host_participant_id")
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case Meetings.create_meeting(attrs) do
      {:ok, meeting} ->
        meeting = maybe_default_host_participant(meeting, args, context)
        {:ok, serialize_meeting(meeting)}

      {:error, {:missing, field}} ->
        {:error,
         %{
           error: "Missing required argument: #{field}",
           recoverable: true,
           suggestion: "meeting_create requires project_id and name"
         }}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{
           error: "Failed to create meeting: #{inspect_errors(changeset)}",
           recoverable: true,
           suggestion:
             "Check that project_id is valid; if you passed an explicit slug it must be unique within the project."
         }}

      {:error, reason} ->
        {:error, %{error: "Failed to create meeting: #{inspect(reason)}", recoverable: true}}
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

  def execute("task_complete", %{"task_id" => task_id}, _context) do
    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        case Tasks.transition_task_status(task, "done") do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})
            {:ok, %{task_id: updated.id, status: updated.status}}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Cannot transition task from '#{task.status}' to 'done'",
               recoverable: false,
               suggestion:
                 "Check the task's current status — only in_progress and deploying can move to done. " <>
                   "If you want to retire a non-started task instead, use task_update with status='cancelled' " <>
                   "(terminal, allowed from backlog/planning/in_progress/blocked/stack_pending)."
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

    tasks = Tasks.list_tasks(opts)

    {:ok, Enum.map(tasks, &serialize_task/1)}
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
  def execute("task_update", args, _context) do
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
        with {:ok, flat_attrs, phase_attrs} <-
               TaskAttrs.build_task_attrs(args, :update,
                 auto_route_flat_assignee_current_phase: true,
                 current_phase: Tasks.current_phase(task)
               ) do
          # Status transitions still route through
          # `Tasks.transition_task_status/2` (validates the edge), while
          # everything else flows through `Tasks.update_task/2`. Split
          # so the two writers don't step on each other.
          status_change = Map.get(flat_attrs, :status)
          non_status_flat = Map.delete(flat_attrs, :status)

          # If `auto_approve_plan` will be `true` after this update (in
          # this call or already-true on the task and not being changed),
          # resolve the effective assignee across THIS update's flat/phase
          # attrs merged over the existing task row, and reject if the
          # result is unassigned or non-agent. Silent auto-approve without
          # an assignee is the bug this guards against — the plan flips
          # to approved but no planner picks it up. See task 019f42fd
          # session note 2026-07-08. Gate lives inside the helper.
          current_phase = Tasks.current_phase(task)

          auto_check =
            check_auto_approve_requires_assignee(flat_attrs, phase_attrs, current_phase, task)

          # Order: flat_attrs → phase_attrs → status_change. Phase-attrs
          # writer (`Tasks.set_phase_assignees/2`) uses the task's
          # CURRENT status to derive the flat pointer, so we apply it
          # before any status transition — otherwise a same-call
          # phase-slot write for the target phase would still see the
          # old phase's derivation.
          with :ok <- auto_check,
               {:ok, updated} <- maybe_update_task(task, non_status_flat),
               {:ok, updated} <- maybe_apply_phase_assignees(updated, phase_attrs),
               {:ok, updated} <- maybe_transition_status(updated, status_change) do
            # `Tasks.update_task/2` and `Tasks.transition_task_status/2`
            # return the un-preloaded struct. Refresh sponsor so
            # `serialize_task` can emit the current shape — otherwise a
            # caller that just cleared the sponsor via `sponsor_user_id:
            # nil` would still see the pre-update Sponsor%User in the
            # response envelope.
            updated = Repo.preload(updated, :sponsor, force: true)
            Tasks.broadcast_board({:task_updated, updated})
            {:ok, serialize_task(updated)}
          else
            {:error, :invalid_transition} ->
              {:error,
               %{
                 error: "Invalid status transition from '#{task.status}' to '#{status_change}'",
                 recoverable: true,
                 suggestion:
                   "Check allowed transitions for the current status. " <>
                     "To retire a non-started task without walking it through in_progress, " <>
                     "transition to 'cancelled' (terminal, allowed from backlog/planning/" <>
                     "in_progress/blocked/stack_pending)."
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
                 suggestion: "Check that the provided values are valid"
               }}

            {:error, %{error: _} = err} ->
              # Passthrough for `validate_auto_approve_requires_assignee`
              # error envelopes (already-shaped for the tool caller).
              {:error, err}
          end
        else
          {:error, {:invalid_phase_keys, keys}} ->
            {:error,
             %{
               error: "Invalid phase_assignees keys: #{Enum.join(keys, ", ")}",
               recoverable: true,
               suggestion: "Use 'planning', 'execution', or 'review'"
             }}

          {:error, {:invalid_phase_assignees_shape, _}} ->
            {:error,
             %{
               error: "phase_assignees must be a map keyed by phase name",
               recoverable: true,
               suggestion:
                 "Pass %{\"planning\" => %{\"assignee_id\" => uuid, \"assignee_type\" => \"agent\"}}"
             }}
        end
    end
  end

  defp maybe_update_task(task, attrs) when map_size(attrs) == 0, do: {:ok, task}
  defp maybe_update_task(task, attrs), do: Tasks.update_task(task, attrs)

  defp maybe_transition_status(task, nil), do: {:ok, task}

  defp maybe_transition_status(task, new_status),
    do: Tasks.transition_task_status(task, new_status)

  # `auto_approve_plan: true` is meaningless without an agent-typed
  # assignee — the plan-engine has no one to dispatch to, so the plan
  # flips to approved but no planner picks it up (silent stall). Refuse
  # at the tool boundary so the caller notices. Enforced on both
  # `task_create` and `task_update`.
  #
  # Gate first: if the caller isn't asking for auto-approve, skip the
  # check entirely — this preserves the historical zero-friction path
  # where `task_create` with no assignee is fine.
  #
  # When the gate fires, resolve the RESOLVED assignee (merged with
  # `phase_assignees[current_phase]` and the existing task row on update)
  # so we validate what the row will actually look like post-write.
  defp check_auto_approve_requires_assignee(flat_attrs, phase_attrs, current_phase, task) do
    flat_flag = Map.get(flat_attrs, :auto_approve_plan, :missing)

    effective_flag =
      cond do
        flat_flag == true -> true
        flat_flag == false -> false
        # No flag in this update: fall through to the existing task row's
        # setting (create path passes task=nil so the fallback is false).
        task -> task.auto_approve_plan == true
        true -> false
      end

    if effective_flag do
      {resolved_id, resolved_type} =
        resolve_effective_assignee(flat_attrs, phase_attrs, current_phase, task)

      cond do
        is_nil(resolved_id) or resolved_id == "" ->
          {:error,
           %{
             error: "auto_approve_plan requires an assignee",
             recoverable: true,
             suggestion:
               "Set assignee_id + assignee_type in the same call (or a phase_assignees entry for the current phase), or omit auto_approve_plan (defaults to false) and set it later once an assignee is configured."
           }}

        resolved_type != "agent" ->
          {:error,
           %{
             error: "auto_approve_plan requires an agent assignee",
             recoverable: true,
             suggestion:
               "Auto-approve dispatches to the assigned agent's planner runtime. Set assignee_type to \"agent\" and pass an agent's id in assignee_id."
           }}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  # Resolve the effective (post-write) flat assignee for auto-approve
  # validation. Precedence: `phase_attrs[current_phase]` (canonical writer)
  # over `flat_attrs` (auto-route path leaves flat empty here) over the
  # existing task row (only meaningful for :update; pass `nil` on :create
  # so a missing assignee resolves to `nil` and the check fires).
  defp resolve_effective_assignee(flat_attrs, phase_attrs, current_phase, task) do
    phase_entry =
      case phase_attrs do
        %{} = m when is_binary(current_phase) -> Map.get(m, current_phase)
        _ -> nil
      end

    {phase_id, phase_type} =
      case phase_entry do
        %{"assignee_id" => id, "assignee_type" => type} -> {id, type}
        %{"assignee_id" => id} -> {id, nil}
        _ -> {nil, nil}
      end

    fallback_id = if task, do: task.assignee_id, else: nil
    fallback_type = if task, do: task.assignee_type, else: nil

    id = phase_id || Map.get(flat_attrs, :assignee_id, fallback_id)
    type = phase_type || Map.get(flat_attrs, :assignee_type, fallback_type)

    {id, type}
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

        case CanvasAttachments.attach_canvas(task_id, canvas_id,
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

          {:error, :canvas_not_found} ->
            {:error,
             %{
               error: "Canvas not found or soft-deleted: #{canvas_id}",
               recoverable: false,
               suggestion:
                 "Verify the canvas_id is correct and the canvas has not been soft-deleted upstream"
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

  def execute("task_detach_canvas", args, _context) do
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
        case CanvasAttachments.detach_canvas(task_id, canvas_id) do
          :ok ->
            {:ok, %{detached: true}}

          {:error, :not_found} ->
            {:error,
             %{
               error: "No attachment found for task #{task_id} and canvas #{canvas_id}",
               recoverable: false,
               suggestion: "Use task_list_canvases to see what is currently attached to the task."
             }}
        end
    end
  end

  def execute("task_list_canvases", args, _context) do
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
            {:error,
             %{
               error:
                 "Cannot start task from status #{task.status}. Must be backlog or planning (per ADR 0029, plan approval transitions to in_progress automatically).",
               recoverable: true,
               suggestion: "Check task status with task_get first"
             }}

          {:error, :no_approved_plan} ->
            {:error,
             %{
               error:
                 "Cannot start task: no approved plan exists for task #{task.id}. Per ADR 0029, plan approval is the start signal.",
               recoverable: false,
               suggestion:
                 "Create a plan with plan_create, submit it with plan_submit, and have it approved (plan_approve) before starting the task. Approval transitions the task into in_progress automatically."
             }}

          {:error, reason} ->
            {:error, %{error: "Failed to start task: #{inspect(reason)}", recoverable: true}}
        end
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
        rollup_branch: slug && Stacks.rollup_branch_name(slug)
      }
      |> maybe_put_base_branch(Map.get(args, "base_branch"))

    case Stacks.create_stack(attrs) do
      {:ok, %Stack{} = stack} ->
        # Eagerly ensure the rollup branch exists on origin at create-time
        # (fire-and-forget, idempotent against the stack_start trigger).
        StackDeployer.handle_stack_created(stack)
        {:ok, %{stack_id: stack.id, rollup_branch: stack.rollup_branch}}

      {:error, %Ecto.Changeset{} = changeset} ->
        if slug_taken?(changeset) do
          {:error,
           %{
             code: "slug_taken",
             error: "Slug '#{slug}' is already in use in this project",
             recoverable: true,
             suggestion: "Pick a different slug or reuse the existing stack"
           }}
        else
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
        executable_ids = stack |> Stacks.executable_members() |> Enum.map(& &1.id)
        merge_order_ids = stack |> Stacks.members_in_merge_order() |> Enum.map(& &1.id)
        {edges, cross_stack_deps} = classify_member_edges(members)

        {:ok,
         %{
           stack: serialize_stack(stack),
           members: Enum.map(members, &serialize_stack_member/1),
           edges: edges,
           executable_now: executable_ids,
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

    stacks = Stacks.list_stacks(filters)
    {:ok, Enum.map(stacks, &serialize_stack/1)}
  end

  def execute("stack_add", args, _context) do
    stack_id = Map.get(args, "stack_id")
    task_id = Map.get(args, "task_id")

    cond do
      is_nil(stack_id) ->
        {:error,
         %{error: "stack_id is required", recoverable: true, suggestion: "Provide a stack_id"}}

      is_nil(task_id) ->
        {:error,
         %{error: "task_id is required", recoverable: true, suggestion: "Provide a task_id"}}

      true ->
        case Stacks.add_task(stack_id, task_id) do
          {:ok, %Task{} = task} ->
            {:ok,
             %{
               task_id: task.id,
               stack_id: task.stack_id,
               stack_position: task.stack_position
             }}

          {:error, _} = err ->
            stack_add_error_envelope(err)

          {:error, _, _} = err ->
            stack_add_error_envelope(err)
        end
    end
  end

  def execute("stack_add_dependency", args, _context) do
    stack_id = Map.get(args, "stack_id")
    from_task_id = Map.get(args, "from_task_id")
    to_task_id = Map.get(args, "to_task_id")
    kind = Map.get(args, "kind", "blocks")

    cond do
      is_nil(stack_id) ->
        {:error,
         %{error: "stack_id is required", recoverable: true, suggestion: "Provide a stack_id"}}

      is_nil(from_task_id) ->
        {:error,
         %{
           error: "from_task_id is required",
           recoverable: true,
           suggestion: "Provide a from_task_id"
         }}

      is_nil(to_task_id) ->
        {:error,
         %{
           error: "to_task_id is required",
           recoverable: true,
           suggestion: "Provide a to_task_id"
         }}

      true ->
        case Stacks.add_dependency_edge(stack_id, from_task_id, to_task_id, kind: kind) do
          {:ok, %{} = result} ->
            {:ok,
             %{
               from_task_id: result.from_task_id,
               to_task_id: result.to_task_id,
               kind: result.kind,
               executable_now: result.executable_now
             }}

          {:error, _} = err ->
            stack_dependency_error_envelope(err)

          {:error, _, _} = err ->
            stack_dependency_error_envelope(err)
        end
    end
  end

  def execute("stack_remove_dependency", args, _context) do
    stack_id = Map.get(args, "stack_id")
    from_task_id = Map.get(args, "from_task_id")
    to_task_id = Map.get(args, "to_task_id")
    kind = Map.get(args, "kind", "blocks")

    cond do
      is_nil(stack_id) ->
        {:error,
         %{error: "stack_id is required", recoverable: true, suggestion: "Provide a stack_id"}}

      is_nil(from_task_id) ->
        {:error,
         %{
           error: "from_task_id is required",
           recoverable: true,
           suggestion: "Provide a from_task_id"
         }}

      is_nil(to_task_id) ->
        {:error,
         %{
           error: "to_task_id is required",
           recoverable: true,
           suggestion: "Provide a to_task_id"
         }}

      true ->
        case Stacks.remove_dependency_edge(stack_id, from_task_id, to_task_id, kind: kind) do
          {:ok, %{} = result} ->
            {:ok,
             %{
               from_task_id: result.from_task_id,
               to_task_id: result.to_task_id,
               executable_now: result.executable_now
             }}

          {:error, _} = err ->
            stack_dependency_error_envelope(err)

          {:error, _, _} = err ->
            stack_dependency_error_envelope(err)
        end
    end
  end

  def execute("stack_eject", args, _context) do
    stack_id = Map.get(args, "stack_id")
    task_id = Map.get(args, "task_id")

    cond do
      is_nil(stack_id) ->
        {:error,
         %{error: "stack_id is required", recoverable: true, suggestion: "Provide a stack_id"}}

      is_nil(task_id) ->
        {:error,
         %{error: "task_id is required", recoverable: true, suggestion: "Provide a task_id"}}

      true ->
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
               suggestion:
                 "Eject the dependent members first or remove the dep edge before retrying",
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
               error: "Stack is not at `forming`; only forming stacks can be started.",
               recoverable: false,
               suggestion: "Check the stack's current status via stack_get."
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
          {:ok, %{stack: updated, planning: planning}} ->
            {:ok, stack_start_planning_payload(updated, planning, [])}

          {:partial, %{stack: updated, planning: planning, errors: errors}} ->
            {:ok, stack_start_planning_payload(updated, planning, errors)}

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

  defp stack_start_planning_payload(%Stack{} = stack, planning, errors) do
    payload =
      stack
      |> serialize_stack()
      |> Map.put(:planning, Enum.map(planning, &serialize_stack_member/1))

    case errors do
      [] -> payload
      _ -> Map.put(payload, :cascade_errors, errors)
    end
  end

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
      # Stack-level agent assignment default (ADR 0041). `%{}` when unset.
      phase_assignees: Stacks.stack_phase_assignees(stack),
      inserted_at: format_datetime(stack.inserted_at),
      updated_at: format_datetime(stack.updated_at)
    }
  end

  defp serialize_stack_member(%Task{} = task) do
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
      assignee_type: task.assignee_type
    }
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

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp maybe_put_base_branch(attrs, nil), do: attrs
  defp maybe_put_base_branch(attrs, value), do: Map.put(attrs, :base_branch, value)

  # ── Plan / Stage / Validation tools ──────────────────────────────────────

  def execute("plan_create", args, _context) do
    task_id = Map.get(args, "task_id")
    raw_stages_input = Map.get(args, "stages", [])

    # Pre-persistence rewrites:
    # 1. Lift any e2e_behavior validations into a single task-level review stage.
    # 2. Log advisory warnings about manual_approval scoping (planner authority wins).
    stages_input =
      raw_stages_input
      |> Platform.Tasks.PlanEngine.route_e2e_behavior_validations()
      |> Platform.Tasks.PlanEngine.check_manual_approval_heuristic()

    if is_nil(task_id) do
      {:error,
       %{
         error: "task_id is required",
         recoverable: true,
         suggestion: "Provide a valid task_id"
       }}
    else
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
                  expected_artifacts: Map.get(stage_input, "expected_artifacts", [])
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
          {:ok, serialize_plan(plan)}

        {:error, :plan_pending_review} ->
          existing = Tasks.latest_plan(task_id)

          {:error,
           %{
             error:
               "A plan for this task is already #{existing.status}; create a new plan only after the existing one is rejected.",
             recoverable: false,
             suggestion:
               "Wait for human approval (or rejection) of plan v#{existing.version} (#{existing.id}). Use plan_get to read it; do not call plan_create again."
           }}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to create plan: #{inspect_errors_safe(reason)}",
             recoverable: true,
             suggestion: "Check that task_id is valid and stages have valid fields"
           }}
      end
    end
  end

  def execute("plan_get", args, _context) do
    task_id = Map.get(args, "task_id") || Map.get(args, "id")

    case Tasks.current_plan(task_id) do
      nil ->
        {:error,
         %{
           error: "No approved plan for task",
           recoverable: false,
           suggestion: "Create a plan with plan_create and approve it first"
         }}

      plan ->
        plan = Repo.preload(plan, stages: :validations)
        {:ok, serialize_plan(plan)}
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

    case Repo.get(Plan, plan_id) do
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

          {:error, reason} ->
            {:error, %{error: "Failed to approve plan: #{inspect(reason)}", recoverable: true}}
        end
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
    plan_id = Map.get(args, "plan_id")

    stages =
      Tasks.list_stages(plan_id)
      |> Repo.preload(:validations)

    {:ok, Enum.map(stages, &serialize_stage_with_validations/1)}
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

  def execute("stage_complete", args, _context) do
    stage_id = Map.get(args, "stage_id") || Map.get(args, "id")

    # NOTE: superseded-plan guard runs BEFORE :not_running / :pending_validations
    # so an executor whose task was returned-to-planning mid-flight gets a
    # decisive stop signal (recoverable: false) rather than a retry-friendly
    # "pending validations" hint. `&&` (not `||`) is the correct operator for
    # the negative-guard pattern here: a `false` helper result short-circuits
    # to `false`, which matches `false <-` and continues the chain; a `true`
    # result yields `{:error, :plan_superseded}` for the else branch.
    with %Stage{} = stage <- Repo.get(Stage, stage_id),
         %Plan{} = current_plan <- Repo.get(Plan, stage.plan_id),
         false <- plan_superseded?(current_plan) && {:error, :plan_superseded},
         true <- stage.status in ["running", "passed"] || {:error, :not_running},
         validations <- Tasks.list_validations(stage.id),
         true <-
           Enum.all?(validations, &(&1.status == "passed")) || validations == [] ||
             {:error, :pending_validations},
         {:ok, advanced_plan} <- PlanEngine.advance(stage.plan_id) do
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

  defp plan_superseded?(%Plan{status: "superseded"}), do: true
  defp plan_superseded?(_), do: false

  def execute("report_blocker", args, context) do
    task_id = Map.get(args, "task_id")
    stage_id = Map.get(args, "stage_id")
    description = Map.get(args, "description")
    needs_human = Map.get(args, "needs_human", false)

    cond do
      is_nil(task_id) or task_id == "" ->
        {:error,
         %{
           error: "task_id is required",
           recoverable: true,
           suggestion: "Provide the current task_id from the execution context"
         }}

      is_nil(stage_id) or stage_id == "" ->
        {:error,
         %{
           error: "stage_id is required",
           recoverable: true,
           suggestion: "Provide the current stage_id from the execution context"
         }}

      is_nil(description) or String.trim(description) == "" ->
        {:error,
         %{
           error: "description is required",
           recoverable: true,
           suggestion: "Describe what is blocked and what is needed to continue"
         }}

      true ->
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
            "reported_by" => Map.get(context, :agent_id) || "agent"
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

    cond do
      is_nil(slug) || slug == "" ->
        {:error,
         %{
           error: "slug is required",
           recoverable: true,
           suggestion: "Provide a valid template slug (e.g. dispatch.planning, heartbeat)"
         }}

      is_nil(content) ->
        {:error,
         %{
           error: "content is required",
           recoverable: true,
           suggestion: "Provide the new template content with {{variable_name}} placeholders"
         }}

      true ->
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
          online: r.online,
          connected_at: format_datetime(r.connected_at),
          last_seen_at: format_datetime(r.last_seen_at),
          last_connected_at: format_datetime(r.last_connected_at)
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

  def execute("memory_search", args, context) do
    with {:ok, query} <- require_string(args, "query", "memory_search") do
      agent = load_agent(context)

      with :ok <- authorize_org_filter(agent, Map.get(args, "org_id")),
           {:ok, opts} <- search_opts_from(args, agent) do
        Search.search(query, opts)
      end
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

  defp file_get_text_text(args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_get_text"),
         file when not is_nil(file) <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_get_text"),
         :ok <- authorize_file_access(context, project),
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
                 "The file may still be ingesting (ingest_status=\"pending\") or extraction may have failed. Re-check ingest_status via file_list before retrying, or pass `binary: true` to fetch the raw bytes instead."
             }}
        end

      {:error, _} = err ->
        err
    end
  end

  # `binary: true` branch — skip the extracted-text cache and stream the
  # bytes back base64-encoded. Capped at 25 MB to mirror
  # `attachment.get_inline`; bigger files will need a presigned download
  # path (deferred follow-up).
  defp file_get_text_binary(args, context) do
    with {:ok, file_id} <- require_string(args, "file_id", "file_get_text"),
         %Platform.Files.File{} = file <- Platform.Files.get_file(file_id),
         {:ok, project} <- fetch_project_for_files(file.project_id, "file_get_text"),
         :ok <- authorize_file_access(context, project),
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
      # Object first, row second. If the row delete fails we'd rather not
      # have orphaned a hard-to-find bytes-only object. Storage keys embed
      # the project_id so this can't blow away a sibling row's bytes in
      # another project.
      _ = Platform.Files.Storage.delete(file.storage_key)

      case Platform.Files.delete_file(file) do
        {:ok, _deleted} ->
          _ = Platform.Files.broadcast_deleted(project.id, file.id)
          {:ok, %{file_id: file.id, deleted: true}}

        {:error, changeset} ->
          {:error,
           %{
             error: "file_delete: row delete failed (#{inspect(changeset.errors)})",
             code: :delete_failed,
             recoverable: true,
             suggestion:
               "Underlying object may have been removed; re-issuing the call clears the row when the conflict resolves."
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

  # ── Memory tool helpers (ADR-0041 T5) ───────────────────────────────────

  defp load_agent(context) when is_map(context) do
    case Map.get(context, :agent) do
      %Agent{} = a ->
        a

      _ ->
        case Map.get(context, :agent_id) do
          id when is_binary(id) -> Repo.get(Agent, id)
          _ -> nil
        end
    end
  end

  defp load_agent(_), do: nil

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
        case Repo.get(Org, org_id) do
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
    case Repo.get(Org, org_id) do
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
    %{
      id: file.id,
      name: file.name || file.original_filename,
      original_filename: file.original_filename,
      content_type: file.content_type,
      byte_size: file.byte_size,
      ingest_status: file.ingest_status,
      inserted_at: format_datetime(file.inserted_at)
    }
  end

  # Richer single-row view returned by `file_get_metadata`. Intentionally
  # omits `storage_key` (internal handle into the object-store adapter) and
  # the extracted text body (use `file_get_text` for that).
  defp file_metadata(%Platform.Files.File{} = file) do
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

  defp serialize_stage_with_validations(stage) do
    validations =
      case stage.validations do
        %Ecto.Association.NotLoaded{} -> []
        validations -> Enum.map(validations, &serialize_validation/1)
      end

    stage
    |> serialize_stage()
    |> Map.put(:validations, validations)
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
      livekit_room_name: meeting.livekit_room_name,
      host_participant_id: meeting.host_participant_id,
      started_at: format_datetime(meeting.started_at),
      ended_at: format_datetime(meeting.ended_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

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
