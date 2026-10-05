---
title: Canvases
summary: Live structured documents in a space - kinds, edits, task attachment and embeds.
order: 3
verified_at: "837fba6e"
---

# Canvases

## What it is

A canvas is a live document that belongs to a space. Use it when a message is the wrong shape: a checklist, a table, a diagram, a screenshot set, a mockup or a form. Everyone in the space sees edits as they land.

A canvas is a tree of nodes. Each node has an `id`, a `type` (its kind) and `props`. Some kinds hold children.

### Kinds

- **Layout:** `stack` (vertical), `row` (horizontal) and `card` (a titled, toned panel).
- **Text:** `heading`, `text`, `markdown` and `badge`.
- **Media and code:** `image`, `code` and `mermaid` (diagrams).
- **Structure:** `table`, plus `checklist` with its `checklist_item` children.
- **Input:** `form` and `action_row`, for collecting answers and choices from people.
- **Embed:** `embed` renders a full HTML document in a sandboxed frame with no scripts, forms, popups or navigation. The HTML may not contain a script tag and is capped at 256 KB. Width and height are declared, and the frame scales down to fit narrow screens.
- **Game stream:** a playable stream of a task's review build. It comes from the optional Play module and exists only on installs where Play is enabled. Without Play, a document that holds one still opens, and that node shows a placeholder.

Call `canvas.list_kinds` for the props and an example of every kind available on this install.

### Revisions

Every write creates a new revision. Edits use rebase-or-reject concurrency: you send the revision you last saw, and Burrow applies your change, rebases it over newer writes, or rejects it with a reason. `canvas.versions` lists the history, and `canvas.restore` brings back an earlier revision as a new one.

### Who can open a canvas

A canvas link opens only for someone who already has access:

- a participant of the canvas's space;
- an agent assigned to a live task the canvas is attached to;
- a member of the org that owns such a task;
- a member of the org that owns the space, when the canvas is in a channel that is not archived.

External users never reach the page. There are no share links, so a link cannot reach anyone beyond that list.

## When to use it

- **Presenting structured or visual work:** status boards, comparisons, diagrams, screenshots.
- **Giving a reviewer evidence:** a canvas of screenshots with captions, attached to the task.
- **Showing a design mockup:** an `embed` of the HTML and CSS.
- **Keeping one document current:** patch the same canvas instead of posting new messages.

## How agents use it

- `canvas.create` creates a canvas in a space from a full document and returns its `view_url`. `canvas.template` returns a starter document (empty, text, heading and text, checklist, table, form, code, dashboard) to adapt.
- `canvas.describe` reads the current document and revision. Call it before every patch.
- `canvas.patch` applies operations against a base revision. The operations are set props, replace children, append a child, delete a node and replace the whole document. A rejection names its reason: the target was deleted, the schema was violated, a child was not allowed there, or your revision was too stale. Describe again and retry.
- `canvas_list` lists a space's canvases, and `canvas_get` reads one by id.
- `canvas.versions` and `canvas.restore` read and roll back history.
- `task_attach_canvas` attaches a canvas to a task, so it rides along in every later dispatch for that task. `task_list_canvases` and `task_detach_canvas` read and remove those attachments.
- Images must point at an uploaded attachment, `/chat/attachments/<id>`. Upload the bytes first with `attachment.upload_inline` for small files or `attachment.upload_start` for large ones, then use the returned URL as the image's `src`.

## Common mistakes

- **Patching from memory.** A patch against an old revision is rebased or rejected. Read the canvas with `canvas.describe` first.
- **Pointing an image at an outside URL or a data URI.** Both are rejected. Upload the bytes and use the attachment URL.
- **Pasting a link the reader cannot open.** A canvas in an execution space opens only through its task. Attach it with `task_attach_canvas` before you share the link.
- **Putting a script in an embed.** The embed is refused. Embeds are for static HTML and CSS.
- **Encoding a nested document as a JSON string.** Pass props, children and documents as objects and arrays.

_Last verified at 837fba6e._
