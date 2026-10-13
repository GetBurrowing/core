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
- **Embed:** `embed` renders a full HTML document in a sandboxed frame with no scripts, forms, popups or navigation. The HTML may not contain a script tag and is capped at 256 KB. Width and height are declared, and the frame scales down to fit narrow screens. Set `scripts: true` and the HTML may carry scripts: it then runs sealed, the same way a `prototype` does, with no network, no Suite cookies and no access to the page around it. Each edit of a scripted embed's HTML is kept as a version, so canvas history and restore show the HTML that was live then. Scripted embeds need prototypes turned on by an admin; while they are off, adding a scripted embed or changing its HTML is refused, and other edits to the canvas still work.
- **Prototype:** `prototype` frames a published, versioned prototype: a clickable bundle of HTML, CSS, JavaScript and images. Unlike `embed`, its scripts run, sealed in a sandboxed frame with no network and no Suite access. Props: `prototype_id` (required), `version` (pin one; absent follows the latest), and the same `width`, `height` and `min_scale` as `embed`. It only frames a prototype of the same org as the space. A bar above the frame shows the title and the version stamp, which opens the version list.
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

### Publishing a prototype

A prototype is published as a bundle: a zip, or a map of files, with an `index.html` entry. Publish with `prototype.publish`, or pick Prototype in the New canvas form and drop a zip there. Publishing has to be turned on by an install admin, who also sets who may publish, the size and file limits and how long old versions are kept. Agents need the `prototype` bundle granted.

- **Versions:** every publish creates the next version, and an older version never changes. `prototype.versions` lists them, and `prototype.rollback` points latest back at an earlier one without copying anything. In the canvas, pick a version from the version list and pin it. Versions older than the retention period are removed, except the latest.
- **What the sandbox blocks:** the bundle cannot read Suite cookies, reach the surrounding page or call any network address, Suite included, and forms cannot be submitted.
- **What it does not block:** a script can still navigate its own frame to an outside page, so never type a password or anything secret into a prototype. The Open button opens one version in a new tab through a short-lived bearer link: anyone holding that link can view that one version until it expires, so do not paste it outside the org.

### Shared by default

Every prototype is multiplayer with nothing to add: Suite puts a small script into each HTML page of the bundle, and it gives the page a global `window.suite`. Everyone viewing the same prototype node sees the same shared state, and every change is saved and attributed to the person who made it.

- **Shared state:** `state.get(key)` reads instantly; `state.set(key, value)` (a null value deletes) and `state.increment(key, by)` return a promise of the new value. Two people incrementing at once both count.
- **Lists:** `collection(name)` gives `list()`, `add(item)` (resolves with the new item's id), `update(id, patch)` and `remove(id)`.
- **Events:** `on("change", fn)` for every change, `on("presence", fn)` and the `presence` list for who is viewing, and `me` for the viewer. Wait for `ready` before the first read.
- **Cursors and drags:** `broadcast(channel, payload)` with `on("broadcast", fn)` reaches the other viewers, at most 30 a second, and is never saved.
- **Limits:** keys and list names up to 128 bytes, one value or item up to 16 KB, the whole state up to 512 KB, 50 lists of up to 1,000 items, and 20 writes a second per viewer. A write over a limit is rejected and nothing changes.
- **Where it is off:** opened full-size with Open, or on a surface that only displays canvases, `connected` is false and writes are rejected.

#### Handlers

A canvas can also store small server-side programs, called handlers, that a prototype runs with `suite.call(name, args)`. Set one with the `canvas.patch` operation `["set_binding", name, {"kind": "handler", "engine": "js", "source": "(event, ctx) => { ctx.increment('votes.' + event.args.option) }"}]`, and delete it with `["set_binding", name, null]`. A name is lower case, starts with a letter and is at most 64 characters (`^[a-z][a-z0-9_.-]{0,63}$`). The source is at most 64 KB, and a canvas holds at most 32 handlers. Setting a handler is a canvas edit, so only people who can edit the canvas can set one.

- **Handlers run as the person who clicked.** Every change a handler makes is saved and attributed to the viewer who called it, and its `ctx.patch` edits the canvas with that viewer's own permission. Someone who can only read the canvas can call a handler, but cannot edit the canvas through it.
- **The `ctx` API:** `ctx.state` is a read-only copy of the shared state, `ctx.now` is the room's time (and `Date.now()` returns it), and `ctx.actor` is the caller. `ctx.set`, `ctx.increment`, `ctx.add`, `ctx.update` and `ctx.remove` change shared state, `ctx.after(ms, handler, args)`, `ctx.every(ms, handler, args)` and `ctx.cancel(handler)` set timers, and `ctx.patch(operations)` edits this canvas. No other Suite call is available: anything else, such as `tasks.create`, is rejected with kind `forbidden` and code `binding_not_registered`.
- **Changes land together or not at all.** The handler's changes are applied when it finishes, on top of whatever other viewers changed meanwhile. If any one change is over a limit, none is applied.
- **Results:** `suite.call` resolves with `{ok: true, result}` and rejects with an error carrying `kind` and `code`.
- **Limits:** a handler run has 1 second, 16 MB of memory and 10 `ctx.patch` calls, and at most 50 changes and 16 timer requests. Each room runs up to 4 handlers at the same time, and each one's changes are applied, when it finishes, on top of the current shared state. Further calls queue, up to 16, then reject with `busy`; a node runs at most 8 handlers across all canvases. A call counts against the viewer's 20 writes a second.
- **Timers:** `after` waits 100 ms to 24 hours and fires once; `every` repeats at least 1 second apart. A room holds at most 16 named timers, and setting a timer with the same handler name replaces it. A timer fires as the person whose call set it. **Timers are not saved:** when the room stops, for example after everyone has left for a minute, its timers are gone.
- **Audit:** every run is recorded with the handler name, a hash of its source, the caller, how long it took and how it ended, but never its source, arguments or state.

## When to use it

- **Presenting structured or visual work:** status boards, comparisons, diagrams, screenshots.
- **Giving a reviewer evidence:** a canvas of screenshots with captions, attached to the task.
- **Showing a design mockup:** an `embed` of the HTML and CSS. Add `scripts: true` when one page needs a little JavaScript, such as a counter, a toggle or a tab switch.
- **Letting people click through a design:** a `prototype`, when the mockup needs scripts, several pages or a deep link.
- **Keeping one document current:** patch the same canvas instead of posting new messages.

## How agents use it

- `canvas.create` creates a canvas in a space from a full document and returns its `view_url`. `canvas.template` returns a starter document (empty, text, heading and text, checklist, table, form, code, dashboard) to adapt.
- `canvas.describe` reads the current document and revision. Call it before every patch.
- `canvas.patch` applies operations against a base revision. The operations are set props, replace children, append a child, delete a node, replace the whole document, and set a handler binding. A rejection names its reason: the target was deleted, the schema was violated, a child was not allowed there, or your revision was too stale. Describe again and retry.
- `canvas_list` lists a space's canvases, and `canvas_get` reads one by id.
- `canvas.versions` and `canvas.restore` read and roll back history.
- `task_attach_canvas` attaches a canvas to a task, so it rides along in every later dispatch for that task. `task_list_canvases` and `task_detach_canvas` read and remove those attachments.
- Images must point at an uploaded attachment, `/chat/attachments/<id>`. Upload the bytes first with `attachment.upload_inline` for small files or `attachment.upload_start` for large ones, then use the returned URL as the image's `src`.

## Common mistakes

- **Patching from memory.** A patch against an old revision is rebased or rejected. Read the canvas with `canvas.describe` first.
- **Pointing an image at an outside URL or a data URI.** Both are rejected. Upload the bytes and use the attachment URL.
- **Pasting a link the reader cannot open.** A canvas in an execution space opens only through its task. Attach it with `task_attach_canvas` before you share the link.
- **Putting a script in an embed without `scripts: true`.** The embed is refused. Set `scripts: true` for a single page with scripts, or publish a `prototype` when the design needs several files, several pages or a deep link.
- **Framing another org's prototype.** The canvas shows "This prototype is not available". A prototype opens only in a space of its own org.
- **Encoding a nested document as a JSON string.** Pass props, children and documents as objects and arrays.

_Last verified at 837fba6e._
