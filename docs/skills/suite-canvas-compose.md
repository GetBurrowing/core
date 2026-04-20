# Suite Canvas Compose

Compose, update, and inspect Startup Suite canvases — the shared, space-scoped, live collaboration surface. Use this skill any time you need to present structured, interactive, or visual content inside a Suite chat space instead of (or alongside) plain messages.

## When to use a canvas

- You're about to paste a long formatted blob into chat: use a canvas instead.
- You want the user to act on a list (checkboxes), fill a short form, or click action buttons: canvas kinds `checklist`, `form`, `action_row`.
- You're producing a diagram (`mermaid`), a data table (`table`), a code snippet (`code`), or a KPI readout (`dashboard` template).
- Content should persist, be patchable incrementally, and visible to every participant in the space in real time.

Do **not** use a canvas for ephemeral answers or a single sentence — a chat message is fine.

## The core tools

| Tool | When |
|---|---|
| `canvas.list_kinds` | First call if you're not sure what you can emit. Returns every kind with description, props, example node. |
| `canvas.template` | Returns a named starter document (`empty`, `text`, `heading_and_text`, `checklist`, `table`, `form`, `code`, `dashboard`). Pass straight to `canvas.create`. |
| `canvas.create` | Creates the canvas and a companion chat message. Takes `space_id`, `title`, `document`. |
| `canvas.describe` | Read current state by `canvas_id`: document, revision, presence. Cheap, call before patching. |
| `canvas.patch` | Apply operations against a canvas at a known `base_revision`. Rebase-or-reject; read rejections carefully. |

## Images, attachments, and the upload tools

Canvas `image` nodes require their `src` to be a path-relative URL under `/chat/attachments/<uuid>`. External URLs (https, http, data:, javascript:, file:, bare hosts) are rejected with a structured validation error. Upload bytes first via one of the attachment tools, then put the returned `url` into the node's `src` prop.

| Tool | When |
|---|---|
| `attachment.upload_inline` | Payload fits under ~25 MB. Pass bytes as a base64 string in `data_base64`. Returns `{id, url, byte_size, content_hash, content_type, deduplicated}` in a single round-trip. **Default choice for screenshots, diagrams, small documents.** |
| `attachment.upload_start` | Payload is large, or you'd rather POST raw bytes. Reserves a pending row, returns `{id, upload_url, expires_at, max_bytes, url}`. POST the bytes to `upload_url` within 15 minutes. Useful for big PDFs, videos, generated archives. |

Both paths deduplicate on `(space_id, content_hash)` — if the same bytes already exist in the space as a ready attachment, the canonical id comes back with `deduplicated: true`. That's a feature, not a failure: you can re-upload the same logo and always get the same `url`.

### End-to-end: put a screenshot into an image node

```
# 1. Upload the bytes.
attachment.upload_inline
  space_id: "<the space you're in>"
  filename: "screenshot.png"
  content_type: "image/png"
  data_base64: "<base64 of the PNG bytes>"

→ { "id": "019da...", "url": "/chat/attachments/019da...", "deduplicated": false, ... }

# 2. Reference the returned url in an image node.
{
  "id": "screenshot",
  "type": "image",
  "props": {
    "src": "/chat/attachments/019da...",
    "alt": "Login page after the redirect",
    "caption": "Figure 1: the new login flow"
  }
}

# 3. Put that node in a canvas (via canvas.create or canvas.patch append_child).
```

### When to reach for `upload_start` instead

- You're uploading something large — rule of thumb, over ~10 MB — and don't want to base64-inflate it in the tool-call envelope.
- You have the bytes on disk already and would rather stream them with a plain HTTP POST.
- You're building a pipeline that hands bytes to a separate process (e.g., a recorder or screenshot agent) after reservation.

The `upload_url` is HMAC-signed; no bearer / session needed on the POST. Content-Type of the POST must match the `content_type` you declared at reservation.

## Recommended workflow

1. **Decide the shape.** If the content is one of the named templates (`checklist`, `table`, `form`, `code`, `dashboard`), skip to step 2. Otherwise call `canvas.list_kinds` to see options.
2. **Get a starter document.** Call `canvas.template name=<template>`. Adjust the returned `document` to taste — change strings, add/remove children.
3. **Upload any images first.** If the canvas will contain `image` nodes, call `attachment.upload_inline` for each and collect the returned `url` values. Only then set them on the image node's `src`.
4. **Create.** Call `canvas.create` with `space_id`, `title`, and the adjusted `document`. Pass `document` as a nested JSON object, not a string.
5. **Iterate if needed.** `canvas.describe canvas_id=<id>` to read current state, then `canvas.patch` with `base_revision` from describe.

## Document shape

Every canvas document is:

```json
{
  "version": 1,
  "revision": 1,
  "root": {
    "id": "root",
    "type": "stack",
    "props": {"gap": 12},
    "children": [ /* node objects */ ]
  },
  "theme": {},
  "bindings": {},
  "meta": {}
}
```

- `version`, `revision`, `theme`, `bindings`, `meta` auto-fill if you omit them.
- `root` must be present. Typically a `stack` or `row` container.
- Every node has `id` (auto-filled if missing), `type` (required), `props` (object), and `children` (array, if the kind accepts children).

## Kinds at a glance

**Structural:** `stack` (vertical), `row` (horizontal), `card` (bordered with optional title).
**Content:** `text`, `markdown`, `heading`, `badge`, `image`, `code`, `mermaid`.
**Tabular:** `table` (columns + rows as props; no children).
**Interactive:** `form` (fields prop; emits `submitted`), `action_row` (actions prop; emits `action`), `checklist` + `checklist_item`.

Each kind's exact props, child rule, and an example node are returned by `canvas.list_kinds`. Don't guess — call it.

## Patch operations

`canvas.patch` operations are tuples (first element is the op name, remaining elements are args):

```json
[
  ["set_props", "node-id", {"value": "new"}],
  ["replace_children", "parent-id", [<child_node>, ...]],
  ["append_child", "parent-id", {<child_node>}],
  ["delete_node", "node-id"],
  ["replace_document", {<full_doc>}]
]
```

Always pass a `base_revision` from your most recent `canvas.describe`. If the server rejects with `{reason: :target_deleted | :illegal_child | :too_stale | :schema_violation}`, call `canvas.describe` again and retry against the new revision.

## Worked example — create a three-item checklist

```
canvas.template name=checklist
→ { "name": "checklist", "description": "...", "document": { ... } }

canvas.create
  space_id: "<the space you're in>"
  title: "Launch readiness"
  document: <the document you just got back, with adjusted labels>

→ { "canvas_id": "...", "kind": "stack", "revision": 1 }
```

Then if you want to flip one item to complete:

```
canvas.describe canvas_id=<id>        → revision: 1, find item's id in document
canvas.patch
  canvas_id: <id>
  base_revision: 1
  operations: [["set_props", "<item-id>", {"state": "complete"}]]
→ { "revision": 2 }
```

## Common pitfalls

- **External image URLs.** Canvas `image` nodes reject any `src` that isn't `/chat/attachments/<uuid>`. Upload first with `attachment.upload_inline`, then set `src` to the returned `url`. The validation error spells this out on first rejection.
- **Stringified payloads.** Some MCP clients serialize nested objects as JSON strings. Pass `document`, `props`, `children`, `child`, `doc` as nested objects. The server accepts strings as a fallback and decodes them, but objects are the contract.
- **Missing scaffolding.** You can omit `version`, `revision`, `id` on nodes — the server fills them in. You cannot omit `root` or `type`.
- **Wrong child kind.** Some kinds restrict children (e.g. `checklist` only accepts `checklist_item`). `canvas.list_kinds` tells you the child rule for each kind.
- **Stale patches.** Always patch against the `revision` you most recently saw. If you get a conflict, refresh with `canvas.describe` and retry.
- **Space membership.** You must already be a participant in the space before calling `canvas.create` or any `attachment.upload_*` there. The server returns a clear "not a participant in space" error if you aren't.

## Read the error

Validation errors on `canvas.create` / `canvas.patch` include:

- `reasons` — the raw list of what failed
- `suggestion` — points at `canvas.list_kinds` / `canvas.template`
- `minimal_valid_example` — a known-good document to copy and adjust
- `available_templates` — names you can request via `canvas.template`

`attachment.upload_inline` over-cap returns:

- `limit` — the byte ceiling
- `use: "attachment.upload_start"` — the tool to reach for instead

Use these. One failed turn should be enough to recover.
