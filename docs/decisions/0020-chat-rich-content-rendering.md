# ADR 0020: Chat Rich Content Rendering

**Status:** Proposed  
**Date:** 2026-03-20  
**Deciders:** the product owner, Zip  
**Extends:** ADR 0008 (Chat Backend Architecture)  

---

## Context

The chat surface currently renders messages as plain text with minimal
formatting — only @-mention highlighting and HTML escaping. This creates
several problems:

1. **Code blocks render as backtick-wrapped text.** Agent responses frequently
   include code snippets, diffs, and configuration examples. These display as
   raw backtick characters in the message body with no syntax highlighting,
   no monospace font, and no visual distinction from prose.

2. **Images cannot be sent by agents.** When an agent generates a diagram,
   screenshot, or chart (e.g., a Mermaid-rendered PNG), there is no path to
   deliver it into the chat. The `message` tool on the OpenClaw side tried
   to send an image via `filePath`/`media` parameters, but the Burrow
   plugin has no image upload or inline media support. The only attachment
   path is user-initiated browser file uploads via LiveUpload.

3. **No markdown rendering.** Agent messages are often structured with
   headers, bullet lists, bold/italic text, and links. These arrive as raw
   markdown syntax characters, making messages harder to scan.

4. **No structured content for rich blocks.** The message schema has a
   `structured_content` JSONB field and `content_type` supports `text`,
   `system`, `agent_action`, and `canvas` — but there is no `rich` or
   `markdown` content type, and `structured_content` is unused for message
   rendering.

5. **Attachments are user-upload-only.** The `chat_attachments` table and
   `AttachmentStorage` module work for browser file uploads via LiveUpload,
   but agents have no programmatic attachment path (no API endpoint or
   runtime channel event for posting files).

---

## Decision

We will introduce rich content rendering in the chat surface through three
layers: markdown rendering, inline media blocks, and an agent attachment
channel.

---

## Decision Details

### 1. Markdown Rendering for Message Content

All message content will be parsed as markdown and rendered as sanitized HTML.

**Library choice:** MDEx (Rust-backed, fast, CommonMark + GFM compliant) or
Earmark (pure Elixir, well-established). MDEx is preferred for performance
if the NIF compilation is acceptable; Earmark as fallback.

**Rendering pipeline:**

```
raw content (string)
  → markdown parse (MDEx/Earmark)
  → sanitize HTML (strip dangerous tags/attributes)
  → syntax highlight code blocks (Makeup + lexers)
  → @-mention decoration (existing logic, applied post-render)
  → Phoenix.HTML.raw() for LiveView rendering
```

**What gets rendered:**

| Markdown feature | Rendered as |
|---|---|
| `# Header` | `<h3>` (cap at h3 — no h1/h2 in chat) |
| `**bold**` / `*italic*` | `<strong>` / `<em>` |
| `` `inline code` `` | `<code>` with monospace + subtle background |
| ` ```lang ... ``` ` | `<pre><code>` with syntax highlighting |
| `- bullet` | `<ul><li>` |
| `1. numbered` | `<ol><li>` |
| `[text](url)` | `<a>` with `target="_blank" rel="noopener"` |
| `> blockquote` | `<blockquote>` with left border accent |
| `---` | `<hr>` |
| Tables | `<table>` with DaisyUI table classes |
| Images `![alt](url)` | Inline `<img>` (see §2) |

**What gets stripped (sanitization):**

- `<script>`, `<iframe>`, `<object>`, `<embed>`, `<form>`
- `on*` event attributes (`onclick`, `onerror`, etc.)
- `javascript:` URLs
- `<style>` tags (CSS injection)

**Syntax highlighting:**

Use Makeup (Elixir ecosystem standard) with lexers for common languages:
- `makeup_elixir` — Elixir
- `makeup_js` — JavaScript/TypeScript
- `makeup_html` — HTML
- `makeup_json` — JSON
- `makeup_sql` — SQL
- `makeup_diff` — Diffs

Code blocks without a language tag get basic monospace styling without
highlighting.

**Performance consideration:** Markdown rendering happens once when the
message is displayed, not on every re-render. For long message histories,
consider caching rendered HTML in the message's `structured_content` field
or in a LiveView assign.

### 2. Inline Media Blocks

Messages can contain inline images and file references. These are rendered
as visual blocks within the message flow.

#### Image rendering

Images arrive via three paths:

| Source | Mechanism | Rendering |
|---|---|---|
| Markdown `![alt](url)` | Parsed from content | Inline `<img>` |
| Chat attachment (image/*) | `chat_attachments` record | Thumbnail + lightbox |
| Structured content block | `structured_content.blocks[]` | Inline `<img>` with caption |

**Inline image behavior:**

- Max width: constrained to message bubble width
- Click: opens lightbox / full-size view
- Loading: lazy load with placeholder skeleton
- Error: show alt text with broken image indicator
- External URLs: proxy through the platform to avoid mixed-content issues
  and provide caching (future — direct render is fine for v1)

#### Code block rendering

Code blocks larger than ~20 lines get a collapsed view:

```
┌─────────────────────────────────────────┐
│  elixir                        [Copy] ↗ │
│ ─────────────────────────────────────── │
│  defmodule Foo do                       │
│    def bar, do: :ok                     │
│  end                                    │
│                                         │
│  ... 47 more lines                      │
│  [Show all]                             │
└─────────────────────────────────────────┘
```

Features:
- Language label (top-left, from the fence info string)
- Copy button (top-right, copies raw code to clipboard)
- Expand/collapse for long blocks
- Line numbers (optional, off by default)
- Horizontal scroll for wide lines (no wrapping by default)

#### File attachment rendering

Non-image attachments render as a download card:

```
┌──────────────────────────────────┐
│  📎 architecture.mmd   (4.9 KB) │
│  [Download]                      │
└──────────────────────────────────┘
```

### 3. Agent Attachment Channel

Agents need a programmatic path to attach files (images, documents, code
files) to their messages without browser file uploads.

#### RuntimeChannel extension

Add a new event to the runtime channel protocol:

```elixir
# Agent sends a message with attachments
handle_in("reply_with_media", %{
  "space_id" => space_id,
  "content" => text_content,       # markdown text (optional)
  "attachments" => [
    %{
      "filename" => "architecture.png",
      "content_type" => "image/png",
      "data" => "<base64-encoded>"  # base64 for small files (< 5MB)
    }
  ]
}, socket)
```

**Flow:**
1. Agent runtime sends `reply_with_media` event via WebSocket
2. RuntimeChannel decodes base64 attachment data
3. For each attachment: persist via `AttachmentStorage.persist_upload/3`
4. Create `chat_attachments` records linked to the message
5. Post the message with `content_type: "text"` and linked attachments
6. PubSub broadcast includes attachment metadata for real-time rendering

**Size limits:**
- Per-attachment: 10 MB (configurable)
- Per-message: 25 MB total (configurable)
- Base64 encoding adds ~33% overhead, so effective upload limit is ~7.5 MB
  per file at the wire level

**For larger files:** A future iteration could add a pre-signed upload URL
flow (agent gets a URL, uploads directly to storage, references it in the
message). Out of scope for v1.

#### OpenClaw Plugin Update

The `startup-suite-channel` plugin needs a corresponding `sendReplyWithMedia`
method on `SuiteClient`:

```typescript
sendReplyWithMedia(spaceId: string, content: string, attachments: Array<{
  filename: string;
  contentType: string;
  data: string; // base64
}>): void {
  this.channel?.push("reply_with_media", {
    space_id: spaceId,
    content,
    attachments,
  });
}
```

And the `sendFinalReply` dispatcher should detect when the reply payload
includes file paths or media and route through `sendReplyWithMedia` instead
of plain `sendReply`.

### 4. Structured Content Blocks (Future-Ready)

The `structured_content` JSONB field on messages can store an array of typed
blocks for complex rendering:

```json
{
  "blocks": [
    {"type": "text", "content": "Here's the architecture:"},
    {"type": "image", "url": "/chat/attachments/abc-123", "alt": "Architecture diagram", "width": 800},
    {"type": "code", "language": "elixir", "content": "defmodule Foo do\n  ...\nend"},
    {"type": "file", "attachment_id": "def-456", "filename": "report.pdf"},
    {"type": "table", "headers": ["Name", "Status"], "rows": [["Task 1", "Done"]]}
  ]
}
```

For v1, this is **optional** — the markdown renderer handles most cases. But
when an agent needs to compose a message with interleaved text, images, and
code blocks in a specific layout, `structured_content` provides the escape
hatch.

When `structured_content.blocks` is non-empty, the renderer uses the block
array instead of parsing `content` as markdown. This gives agents full
control over message layout when needed.

### 5. Content Type Extension

Add a new content type to the message schema:

```elixir
@content_types ~w(text rich system agent_action canvas)
```

- `text` — legacy plain text (rendered with markdown for backward compat)
- `rich` — explicitly structured content (render from `structured_content.blocks`)
- `system` — system messages (join/leave/etc.)
- `agent_action` — agent action indicators
- `canvas` — canvas reference

**Backward compatibility:** Existing `text` messages are rendered through
the markdown pipeline. The renderer detects code blocks and images in the
markdown and renders them appropriately. No migration needed — just better
rendering of existing content.

---

## Implementation Phases

### Phase 1: Markdown Rendering
- Add MDEx (or Earmark) + Makeup dependencies
- Build `Platform.Chat.ContentRenderer` module
- Replace `format_message_content/1` in ChatLive with markdown pipeline
- Add syntax highlighting CSS to the asset pipeline
- Test with existing message content (backward compat)

### Phase 2: Code Block UX
- Collapsible long code blocks (> 20 lines)
- Copy-to-clipboard button
- Language label
- Horizontal scroll for wide content

### Phase 3: Agent Attachment Channel
- Add `reply_with_media` handler to RuntimeChannel
- Programmatic attachment persistence (base64 → disk)
- Image rendering inline in messages (thumbnail + lightbox)
- Update OpenClaw plugin with `sendReplyWithMedia`

### Phase 4: Inline Image Rendering
- Render attachment images inline in the message flow
- Lightbox for full-size viewing
- Lazy loading with skeleton placeholders
- Support markdown image syntax `![alt](url)`

### Phase 5: Structured Content Blocks (Optional)
- Implement `rich` content type
- Block renderer for structured_content array
- Agent API for composing block-structured messages

---

## Consequences

### Positive

- Agent responses become readable — code is highlighted, lists are formatted,
  headers provide structure
- Images and diagrams can be shared in chat — agents can show their work
- The chat surface matches expectations set by modern messaging apps
  (Slack, Discord, Teams all render markdown)
- Structured content blocks provide an extensibility path for future rich
  content types (embeds, interactive components, etc.)
- Backward compatible — existing messages look better, not different

### Negative / Trade-offs

- Markdown parsing adds processing cost per message render (mitigate: cache
  rendered HTML)
- Sanitization must be rigorous — markdown-to-HTML is an XSS vector if not
  done carefully
- NIF dependency (MDEx) adds compile-time complexity (mitigate: Earmark
  fallback)
- Base64 attachment encoding is inefficient for large files (mitigate: size
  limits, future pre-signed URL flow)
- Agent attachment channel adds surface area to the WebSocket protocol

### Risks

- Syntax highlighting for uncommon languages may produce poor results
  (mitigate: fall back to plain monospace)
- Image rendering in chat can be slow on mobile if images are large
  (mitigate: server-side thumbnail generation)
- Structured content blocks could lead to agents sending overly complex
  layouts that render poorly (mitigate: validate block types, cap block count)

---

## References

- ADR 0008: Chat Backend Architecture (message schema, content types)
- ADR 0014: Agent Federation and External Runtimes (RuntimeChannel protocol)
- `Platform.Chat.Message` — message schema with structured_content field
- `Platform.Chat.Attachment` / `AttachmentStorage` — existing attachment infra
- `PlatformWeb.RuntimeChannel` — existing agent communication channel
- `PlatformWeb.ChatLive.format_message_content/1` — current rendering function
- MDEx: <https://github.com/leandrocp/mdex>
- Makeup: <https://github.com/elixir-makeup/makeup>
