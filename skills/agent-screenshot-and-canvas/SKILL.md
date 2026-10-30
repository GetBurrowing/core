---
name: agent-screenshot-and-canvas
description: Capture a screenshot from the agent's CDP-attached Chrome, upload it as a Burrow chat attachment, embed it in a Burrow canvas, and submit a review request — the full four-tool chain (Page.captureScreenshot -> attachment.upload_start -> canvas.create -> review_request_create) currently used in dispatch prompts. Includes the tool-name underscore-vs-dot gotcha and the upload_inline corruption pitfall.
---

# Agent Screenshot + Canvas

This is the canonical evidence pipeline an agent uses to prove "I rendered the
feature in a real browser, here's the picture." It chains four operations:

1. **Capture** a PNG via the dedicated Chrome (`agent-chrome-cdp` skill).
2. **Upload** the bytes to Burrow's attachment store.
3. **Embed** the resulting attachment in a Burrow canvas.
4. **Submit** a `review_request` referencing that canvas.

There are two well-known footguns in the chain — read those first.

## Footguns to memorise

### 1. Tool-name underscore vs dot

The Burrow MCP HTTP endpoint exposes tools with **dot-namespaced** names:

```
attachment.upload_start
attachment.upload_inline
canvas.create
canvas.patch
review_request_create
```

The Claude Code MCP wrapper and OpenClaw's tool surface convert dots to
**double underscore** when registering Claude/OpenClaw-side tool names:

```
mcp__startup-suite__attachment_upload_start
mcp__startup-suite__attachment_upload_inline
mcp__startup-suite__canvas_create
mcp__startup-suite__canvas_patch
mcp__startup-suite__review_request_create
```

Same tool, two names. Use whichever your MCP client expects. The HTTP examples
in this skill use the dotted form.

### 2. `attachment.upload_inline` silently corrupts large base64

`attachment.upload_inline` is convenient — you pass the bytes inline, base64-
encoded, and get back an attachment URL. It works for tiny payloads (think
small icons, well under 2 KB). For anything bigger, it silently corrupts:
the upload appears to succeed, the canvas embed appears to succeed, and the
rendered image is broken bytes.

**Always use `attachment.upload_start` + `curl PUT` for screenshots.** Even a
small empty page screenshot is ~30 KB.

## Worked example

`scripts/screenshot-to-review.sh` is the end-to-end recipe in <30 lines. It
expects the agent's CDP Chrome to be running (`agent-chrome-cdp` skill). It
uses `cdp_navigate.py` from that skill to capture, then makes three Burrow MCP
calls via `curl`.

```bash
BURROW_URL=http://localhost:4001 \
BURROW_TOKEN=<bearer> \
BURROW_SPACE_ID=<uuid> \
VALIDATION_ID=<uuid> \
TARGET_URL=http://localhost:4001/tasks \
LABEL="Tasks page renders without error" \
skills/agent-screenshot-and-canvas/scripts/screenshot-to-review.sh
```

What the script does, end to end:

```
+- 1. cdp_navigate.py TARGET_URL --screenshot /tmp/shot.png       (capture)
+- 2. attachment.upload_start { filename, byte_size, content_type } -> upload_url
+- 3. curl --upload-file /tmp/shot.png "<upload_url>"              (upload)
+-    response: { url: "/chat/attachments/<uuid>", attachment_id: ... }
+- 4. canvas.create with one image node whose src = "/chat/attachments/<uuid>"
+- 5. review_request_create with validation_id + items: [{label, canvas_id}]
```

Output: the canvas id and review-request id printed to stdout.

## Step-by-step (for when you need to do it by hand)

### Step 1: capture

Through the CDP-attached Chrome (see `agent-chrome-cdp`):

```bash
python3 skills/agent-chrome-cdp/scripts/cdp_navigate.py \
  "$TARGET_URL" --screenshot /tmp/shot.png
ls -l /tmp/shot.png   # size in bytes — pass to upload_start
```

Or, in Python with Playwright if you've installed it:

```python
page.screenshot(path="/tmp/shot.png", full_page=True)
```

### Step 2: request an upload slot

```bash
SIZE=$(wc -c < /tmp/shot.png | tr -d ' ')

curl -sS "$BURROW_URL/mcp" \
  -H "Authorization: Bearer $BURROW_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg size "$SIZE" '
    { jsonrpc: "2.0", id: 1, method: "tools/call",
      params: {
        name: "attachment.upload_start",
        arguments: {
          filename: "shot.png",
          content_type: "image/png",
          byte_size: ($size | tonumber)
        } } }')" \
  | jq -r '.result.content[0].text' \
  | jq .   # { upload_url, upload_method, upload_headers, attachment_id, url }
```

The response gives you a presigned-style `upload_url`, the HTTP method to use
(usually `PUT`), required headers, the eventual attachment URL (looks like
`/chat/attachments/<uuid>`), and the attachment id.

### Step 3: upload the bytes

```bash
curl -sS -X PUT "$UPLOAD_URL" \
  -H 'Content-Type: image/png' \
  --data-binary @/tmp/shot.png
```

Add any `upload_headers` from step 2 verbatim. Confirm 200/204.

### Step 4: create the canvas

```bash
curl -sS "$BURROW_URL/mcp" \
  -H "Authorization: Bearer $BURROW_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg space "$BURROW_SPACE_ID" \
        --arg src "$ATTACHMENT_URL" \
        --arg alt "$LABEL" '
    { jsonrpc: "2.0", id: 2, method: "tools/call",
      params: {
        name: "canvas.create",
        arguments: {
          space_id: $space,
          kind: "evidence",
          title: "Screenshot evidence",
          content: {
            children: [
              { type: "image", src: $src, alt: $alt }
            ] } } } }')" \
  | jq -r '.result.content[0].text' \
  | jq .
```

The `src` MUST match `^/chat/attachments/<uuid>$` — that's how the canvas
renderer dereferences the attachment.

If you'd rather extend an existing canvas, use `canvas.patch` with the
`append_child` op instead:

```json
{
  "name": "canvas.patch",
  "arguments": {
    "canvas_id": "<existing>",
    "ops": [
      ["append_child", "<parent-node-id>",
       { "type": "image", "src": "/chat/attachments/<uuid>", "alt": "..." }]
    ]
  }
}
```

### Step 5: file the review request

```bash
curl -sS "$BURROW_URL/mcp" \
  -H "Authorization: Bearer $BURROW_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg vid "$VALIDATION_ID" \
        --arg cid "$CANVAS_ID" \
        --arg label "$LABEL" '
    { jsonrpc: "2.0", id: 3, method: "tools/call",
      params: {
        name: "review_request_create",
        arguments: {
          validation_id: $vid,
          items: [ { label: $label, canvas_id: $cid } ]
        } } }')" \
  | jq -r '.result.content[0].text' \
  | jq .
```

Done. Reviewers see the canvas with the screenshot embedded; the review
request flips the validation gate into "awaiting human review".

## Meetings surfaces: run the layout gate BEFORE the capture

**If the screenshot you are about to take is of a meetings call surface
(`/meetings` or the in-chat quickmeet), a screenshot on its own is not
evidence.** Presence checks pass on a screen wired into the wrong parents, and
three rounds of this surface were rejected on sight by the sponsor — every
element the approved canvas called for was present and every colour token was
right, but the ring, the controls, the grid and the card's reading order had
been assembled into different parents.

Immediately before the capture, from the repo root:

```bash
e2e/scripts/measure-meeting-layout.sh \
  --base-url "$TARGET_URL" \
  --surface meetings|quickmeet \
  --viewport 1280x800|390x844
```

It prints a verdict block: one line per assertion with the assertion name, the
**measured numbers**, the tolerance, and PASS or FAIL. Numbers are printed on
PASS as well as FAIL, because a bare PASS is indistinguishable from an assertion
that could not fail.

**Paste that verdict block into the evidence canvas alongside the screenshot** —
a `markdown` or `code` node next to the `image` node. A `manual_approval`
submitted with a screenshot and no verdict block is an **incomplete review** and
should be sent back rather than approved.

Its exit codes are distinct on purpose: `0` all pass, `1` a real layout FAIL,
`3` **rig fault — `/assets/js/app.js` did not return 200**, `4` rig fault —
the spec produced no measurements. Exit `3` is never a layout regression: a
tile-less page reads exactly like the feature being missing, and filing that as
a design defect is the specific mistake the distinct code exists to prevent. It
also supersedes the generic asset precheck above for these surfaces — the curl
is built into the runner, so there is nothing separate to remember.

The runner also encodes the quickmeet prelude (`meeting_join` must be clicked
before any rail exists; below `lg` the `[data-role="quickmeet-rail-toggle"]`
must be pressed too) and prints a `prelude` line proving it ran. A capture taken
before both is a false "feature missing" and has already cost review cycles.

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Canvas renders a broken image | Used `upload_inline` for a >2 KB payload, or `src` doesn't start with `/chat/attachments/`. | Switch to `upload_start` + `curl PUT`; verify the `src` path. |
| `attachment.upload_start` returns 413 | File exceeds Burrow's max attachment size. | Compress/crop the screenshot before upload. |
| `review_request_create` returns "validation not found" | Wrong validation id, or the validation belongs to a different task. | Re-fetch the validation list for the current task. |
| MCP returns "tool not found" with the dotted name | Client uses underscore form. | Swap `attachment.upload_start` -> `attachment_upload_start` (or `mcp__startup-suite__attachment_upload_start`). |
