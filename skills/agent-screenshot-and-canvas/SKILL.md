---
name: agent-screenshot-and-canvas
description: Capture a screenshot from the agent's CDP-attached Chrome, upload it as a Suite chat attachment, embed it in a Suite canvas, and submit a review request — the full four-tool chain (Page.captureScreenshot -> attachment.upload_start -> canvas.create -> review_request_create) currently used in dispatch prompts. Includes the tool-name underscore-vs-dot gotcha and the upload_inline corruption pitfall.
---

# Agent Screenshot + Canvas

This is the canonical evidence pipeline an agent uses to prove "I rendered the
feature in a real browser, here's the picture." It chains four operations:

1. **Capture** a PNG via the dedicated Chrome (`agent-chrome-cdp` skill).
2. **Upload** the bytes to Suite's attachment store.
3. **Embed** the resulting attachment in a Suite canvas.
4. **Submit** a `review_request` referencing that canvas.

There are two well-known footguns in the chain — read those first.

## Footguns to memorise

### 1. Tool-name underscore vs dot

The Suite MCP HTTP endpoint exposes tools with **dot-namespaced** names:

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
uses `cdp_navigate.py` from that skill to capture, then makes three Suite MCP
calls via `curl`.

```bash
SUITE_URL=http://localhost:4001 \
SUITE_TOKEN=<bearer> \
SUITE_SPACE_ID=<uuid> \
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

curl -sS "$SUITE_URL/mcp" \
  -H "Authorization: Bearer $SUITE_TOKEN" \
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
curl -sS "$SUITE_URL/mcp" \
  -H "Authorization: Bearer $SUITE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg space "$SUITE_SPACE_ID" \
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
curl -sS "$SUITE_URL/mcp" \
  -H "Authorization: Bearer $SUITE_TOKEN" \
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

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Canvas renders a broken image | Used `upload_inline` for a >2 KB payload, or `src` doesn't start with `/chat/attachments/`. | Switch to `upload_start` + `curl PUT`; verify the `src` path. |
| `attachment.upload_start` returns 413 | File exceeds Suite's max attachment size. | Compress/crop the screenshot before upload. |
| `review_request_create` returns "validation not found" | Wrong validation id, or the validation belongs to a different task. | Re-fetch the validation list for the current task. |
| MCP returns "tool not found" with the dotted name | Client uses underscore form. | Swap `attachment.upload_start` -> `attachment_upload_start` (or `mcp__startup-suite__attachment_upload_start`). |
