# ADR 0039: Agent-Uploadable Attachments

**Status:** Proposed
**Date:** 2026-04-19
**Deciders:** Rowan
**Related:** ADR 0008 (Chat Backend), ADR 0034 (MCP Endpoint & Capability Bundles), ADR 0036 (Canvases as First-Class Surfaces)

---

## Context

The attachment system today (`chat_attachments` + `Platform.Chat.AttachmentStorage` + `GET /chat/attachments/:id`) is well-built for one use case: a signed-in user dragging a file into a chat composer. It fails for three use cases we now need.

### What's broken

1. **Agents cannot upload bytes.** Canvases support an `image` kind whose `src` is an arbitrary URL. Agents have no MCP tool that converts bytes to a stable URL, so they paste external URLs (placekittens, third-party CDNs). These URLs break, expire, leak the space's traffic pattern to third parties, and cannot be treated as canonical content. The entire `image` kind is essentially unusable for agent-generated content.
2. **Attachments are message-subordinate.** `chat_attachments` has a non-nullable `message_id`. A canvas cannot own an attachment; a space-scoped canvas (ADR 0036) certainly cannot. The only workaround is to create a throwaway message to own the upload — a hack that pollutes the chat stream and couples two unrelated concerns.
3. **Serving is session-only.** `/chat/attachments/:id` gates on session auth. An agent runtime holding a bearer token for `/mcp` cannot read its own uploaded image back. This blocks any agent workflow that wants to verify a round-trip.

### Design constraint

The user's framing is explicit: **be generous.** People will want to hand their agent a long-form document, a multi-shot screenshot series, a short video clip. Arbitrary 5 MB caps will frustrate. The real limits are JSON-RPC message size for inline base64 and HTTP request timeouts — both are addressable.

### What scales

Disk-backed storage works for single-host deploys (hive prod, dev). It does not scale to multi-node without a shared volume, and it does not lend itself to CDN fronting. We should not rewrite storage in this ADR, but the abstraction must not paint us into a corner: a pluggable adapter that starts local-disk and can swap to S3/R2 later is the correct boundary.

## Decision

Attachments become a **first-class, space-scoped resource** with two MCP upload paths — inline for small files, presigned POST for everything else — served through a single controller that accepts both session and runtime-bearer auth.

Six commitments:

1. **Space-scoped attachments.** `chat_attachments` gains `space_id` (non-nullable going forward), and `message_id` becomes nullable. Add `canvas_id` for attachments directly owned by a canvas document. Add `uploaded_by_agent_id` (nullable) to distinguish agent uploads from user uploads.
2. **Content hashing for dedupe + verify.** Store `content_hash` (sha256) on every upload. Agents can round-trip-verify, and we get cheap dedupe inside a space if we want it later.
3. **Two MCP tools.** `attachment.upload_inline` for single-shot base64 (≤ 25 MB, tunable), `attachment.upload_start` that returns a one-shot signed POST URL for any size. Agents choose based on payload size; the tool schema explains the tradeoff.
4. **One controller, two auth shapes.** `GET /chat/attachments/:id` accepts either a session cookie (current behavior) or a runtime bearer token (same pipeline `/mcp` uses). Membership check runs against `chat_attachments.space_id`.
5. **Pluggable storage adapter.** Introduce `Platform.Chat.AttachmentStorage.Adapter` behaviour with a `LocalDisk` default. S3-compatible adapter is a future ADR; this ADR only ensures the code doesn't hard-code disk paths into call sites.
6. **Canvas `image` src sanitizer.** The `image` kind's `src` accepts `https://` URLs and path-relative `/chat/attachments/<uuid>` only. Everything else (`javascript:`, `file:`, `data:`, bare hosts) is rejected at patch-validation time. Grafts onto the existing `fix/canvas-url-sentinel-guard` work.

## Detailed design

### 1. Schema changes

```sql
ALTER TABLE chat_attachments
  ADD COLUMN space_id uuid REFERENCES chat_spaces(id) ON DELETE CASCADE,
  ADD COLUMN canvas_id uuid REFERENCES chat_canvases(id) ON DELETE SET NULL,
  ADD COLUMN uploaded_by_agent_id uuid REFERENCES agents_agents(id) ON DELETE SET NULL,
  ADD COLUMN content_hash varchar(64),
  ALTER COLUMN message_id DROP NOT NULL;

CREATE INDEX chat_attachments_space_id_idx ON chat_attachments (space_id);
CREATE INDEX chat_attachments_canvas_id_idx ON chat_attachments (canvas_id) WHERE canvas_id IS NOT NULL;
CREATE INDEX chat_attachments_content_hash_idx ON chat_attachments (space_id, content_hash);
```

Backfill `space_id` from the owning message. Rows whose messages were hard-deleted (none today; soft-delete only) drop out.

### 2. MCP tool contracts

**`attachment.upload_inline`** — small files, one round-trip.

```json
{
  "name": "attachment.upload_inline",
  "description": "Upload bytes as base64. Use this for files up to ~25 MB. For larger files, call attachment.upload_start to get a presigned POST URL.",
  "input_schema": {
    "space_id": "uuid",
    "filename": "string",
    "content_type": "string",
    "data_base64": "string",
    "canvas_id": "uuid (optional)"
  },
  "output": {
    "id": "uuid",
    "url": "/chat/attachments/<uuid>",
    "byte_size": "int",
    "content_hash": "sha256 hex",
    "content_type": "string"
  }
}
```

Hard limit: configurable `:inline_upload_max_bytes` (default 25 MB). Over the limit returns a structured error that tells the agent to use `upload_start` instead — self-correcting, same pattern as the canvas rebase-or-reject payloads.

**`attachment.upload_start`** — any size, two round-trips.

```json
{
  "name": "attachment.upload_start",
  "description": "Reserve an attachment and receive a one-shot upload URL. POST the raw bytes to that URL within 15 minutes. Use this for files over 25 MB or when you want a streaming upload.",
  "input_schema": {
    "space_id": "uuid",
    "filename": "string",
    "content_type": "string",
    "byte_size": "int",
    "canvas_id": "uuid (optional)"
  },
  "output": {
    "id": "uuid",
    "upload_url": "absolute URL including HMAC-signed query",
    "expires_at": "ISO-8601",
    "max_bytes": "int",
    "url": "/chat/attachments/<uuid>"
  }
}
```

Server reserves a `chat_attachments` row in `:pending` state. Agent `POST`s raw bytes (`Content-Type` supplied by `content_type`) to `upload_url`. Controller validates HMAC, writes via the storage adapter, finalizes the row with actual `byte_size` + `content_hash`, moves state `:pending → :ready`.

Absolute max per upload: configurable `:upload_max_bytes` (default 500 MB). Above that we'd need chunked multipart; defer.

Pending rows older than their `expires_at` are swept by a periodic task (add to `Platform.Chat.AttachmentReaper`, run every 5 min).

### 3. Controller auth

`PlatformWeb.ChatAttachmentController.show/2` grows a second auth mode:

```
pipeline :attachment_read do
  plug :fetch_session
  plug PlatformWeb.Plugs.MaybeSessionAuth
  plug PlatformWeb.Plugs.MaybeRuntimeBearerAuth
  plug PlatformWeb.Plugs.RequireAuthenticatedParticipant
end
```

`RequireAuthenticatedParticipant` checks: either `session_user` or `runtime` assigns are set, and the resolved identity has participant-in-space for `attachment.space_id`. Same authorization model as `/mcp` capability gating.

The existing session-only route stays; the new plug composition handles both.

### 4. Storage adapter behaviour

```elixir
defmodule Platform.Chat.AttachmentStorage.Adapter do
  @callback persist(key :: binary(), source :: {:path, Path.t()} | {:binary, binary()}) ::
              {:ok, map()} | {:error, term()}
  @callback read_stream(key :: binary()) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback delete(key :: binary()) :: :ok
  @callback presign_upload(key :: binary(), max_bytes :: pos_integer(), ttl_s :: pos_integer()) ::
              {:ok, %{url: binary(), expires_at: DateTime.t()}} | {:error, term()}
end
```

`LocalDisk` adapter: current behavior + an in-process HMAC-signed URL (signed by an app secret, verified by the `upload_finish` controller). S3Compatible adapter implements `presign_upload` via the native S3 presigning API; out of scope for this ADR.

The module `Platform.Chat.AttachmentStorage` becomes a thin dispatcher over the configured adapter.

### 5. Image src sanitizer

In `Platform.Chat.Canvas.Kinds.Image.validate_props/1`:

```elixir
defp valid_src?(src) when is_binary(src) do
  case URI.parse(src) do
    %URI{scheme: "https", host: host} when is_binary(host) -> true
    %URI{scheme: nil, path: "/chat/attachments/" <> rest} -> uuid_like?(rest)
    _ -> false
  end
end
```

Applies on `canvas.create` and on any `set_props` / `replace_children` that touches an `image` node. Reuse the `canvas_url` sentinel work already underway.

### 6. Limits and knobs

| Setting | Default | Notes |
|---|---|---|
| `:inline_upload_max_bytes` | 25 MB | Return structured "use upload_start" error above this |
| `:upload_max_bytes` | 500 MB | Enforced by presigned-POST body cap |
| `:pending_ttl_seconds` | 900 (15 min) | Window for `upload_start` → actual POST |
| `:upload_rate_limit_per_space` | 100/min | Simple token bucket at controller |
| `:total_storage_per_space` | unset | Optional; surface in space settings later |

We are explicitly **not** putting a per-upload ceiling lower than 500 MB. If a human would reasonably hand an agent a file of size N, the agent should be able to upload a file of size N.

## Consequences

**Enables.**

- Agents can ship screenshots, reports, diagrams, short videos, PDFs into a space without leaning on external hosts.
- Canvases get a real `image` kind; `fix/canvas-url-sentinel-guard` becomes load-bearing rather than guarding against a theoretical XSS vector.
- Attachments become addressable for non-chat surfaces — meetings transcripts, task evidence, agent-produced artifacts.

**Costs.**

- Migration is real: one migration, one backfill, one plug pipeline change, one controller, two MCP tools, one adapter behaviour. Not tiny, not risky.
- Storage accounting becomes a real concern. We don't add quotas in this ADR but we add the `space_id` index needed to compute them.
- The `/chat/attachments/:id` route now has two auth modes; both need tests. Mismatched authorization between session and runtime paths is the most likely bug class.

**Followups (out of scope).**

- S3-compatible adapter (multi-node prep).
- Image thumbnail generation / server-side resize.
- Virus scanning on upload (ClamAV sidecar or equivalent).
- Retention policies and per-space storage budgets.
- Chunked multipart for files above the 500 MB cap.
- Attachment GC for rows whose owning canvas/message/space was deleted.

## Open questions

1. **Should `content_hash` deduplicate inside a space?** Two agents uploading the same screenshot shouldn't double-bill storage. Proposal: on `upload_inline` and at `upload_finish`, if `(space_id, content_hash)` already exists, return the existing row and delete the new bytes. Cheap, agent-friendly, no downside.
2. **Presign-URL signing key rotation.** Use `Plug.Crypto.sign/3` with an app secret; rotate by changing the secret (invalidates in-flight uploads, which is fine at 15-min TTLs).
3. **Agent-uploaded attachment visibility.** An agent uploads into a space; should members see it only via a canvas/message that embeds it, or is there a separate "attachments library" view? Defer — this ADR makes it *possible* to exist without any particular UI.
