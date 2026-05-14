# Finding — 3-dot menu "Edit message" deadclick (Marlowe user report 2026-05-12)

**Reported by:** Marlowe Quill, in #marlowe-playspace, 2026-05-12 ~22:55 UTC.
**Symptom:** "When I click three-dots on a message and click 'edit message,' it looks like a deadclick."
**Marlowe's testable hypothesis:** "There may be a significant delay between when a User requests to edit a message, and the message becomes editable."

This finding is part of Task 6 Stage 1 recon — verifying the **render contract (Section d)**. The 3-dot path is documented in the contract as the **PWA pattern** (Task 5's surface); the hover-pencil is the web pattern (Task 4's surface). Both should converge on the same inline editor.

---

## Code path I traced (static analysis only — see "Open: live measurement" below)

1. **3-dot button** at `lib/platform_web/components/chat_message.ex:223–232` fires `phx-click="open_message_actions"` with `phx-value-id={@msg.id}`.
2. **LV handler** at `lib/platform_web/live/chat_live.ex:221`: `def handle_event("open_message_actions", %{"id" => msg_id}, ...)` — assigns `:open_message_actions_id` to the message id.
3. **Sheet** at `lib/platform_web/live/chat_live.html.heex:1134–1204` renders via `:if={@open_message_actions_id}` (full-mount, not just `data-open` toggle).
4. **"Edit message" item** at `lib/platform_web/live/chat_live.html.heex:1190–1202` fires a chained `Phoenix.LiveView.JS.push`:
   ```elixir
   phx-click={
     Phoenix.LiveView.JS.push("edit_message_clicked",
       value: %{"message-id" => @open_message_actions_id}
     )
     |> Phoenix.LiveView.JS.push("close_message_actions")
   }
   ```
5. **LV handler** at `chat_live.ex:241–244`:
   ```elixir
   def handle_event("edit_message_clicked", params, socket) do
     msg_id = params["message-id"] || params["message_id"]
     {:noreply, assign(socket, :editing_message_id, msg_id)}
   end
   ```
   No DB query, no slow work — instant assign.
6. **`close_message_actions`** at `chat_live.ex:226`: sets `:open_message_actions_id` to nil → sheet `:if`-unmounts.
7. **Editor mount** at `chat_message.ex:266–269`:
   ```heex
   <PlatformWeb.Components.ChatMessageEditor.chat_message_editor
     :if={@editing_message_id == @msg.id}
     msg={@msg}
   />
   ```
8. **`MessageEditor` JS hook** (`assets/js/hooks/message_editor.js`) mounts on the form, calls `this.textarea.focus()`, sets cursor at end.

**On paper this path is correct.** Sheet's `Sheet` JS hook (`assets/js/hooks/sheet.js`) has a focus-restore in `updated()` (lines 43–54) that fires `requestAnimationFrame(() => previousFocus.focus())` on `data-open="false"` — but because the sheet is `:if`-unmounted (not `data-open` toggled), the `updated()` callback never sees the close transition. Only `destroyed()` fires, which just removes the keydown listener.

So the static path predicts: instant edit + instant sheet unmount + instant editor render + instant textarea focus.

---

## Ranked runtime hypotheses (most likely first)

### H1 — Full chat stream re-render on every `editing_message_id` change (LIKELY)

`editing_message_id` is a top-level LV assign, not part of any stream. Phoenix LiveView's diff algorithm will detect that `editing_message_id` changed and re-evaluate every stream item whose template references it. For a channel with 50+ messages, that diff is large and the wire payload + DOM patch take perceptible time.

**Why it'd look like a deadclick on mobile:** the diff might take 200–600 ms over a typical mobile WS link. Marlowe clicks, nothing visibly happens for a beat, then the editor swaps in. If she's tapped Edit a second time mid-delay, the second tap may land on a different control or the now-closed sheet, looking like nothing happened.

**Fix shape (if confirmed):** move `editing_message_id` into the stream's per-item assign by passing it through `chat_message.ex`'s attr more efficiently — or use `JS.toggle_class` / `JS.set_attribute` to flip a CSS state client-side instead of a server-roundtrip diff.

### H2 — Editor renders below the fold (LIKELY on mobile)

The 3-dot sheet covers the bottom of the viewport. When it closes, the user's eye is on the sheet's last position, but the editor appeared above (in the message row that was below the sheet before the open). On a phone, the editor can be entirely off-screen when the sheet closes — Marlowe sees the sheet close and "nothing happens" because she'd need to scroll to find the new editor.

**Fix shape:** `scrollIntoView({block: 'center'})` on the editor's textarea inside the `MessageEditor` `mounted()` hook. Trivial.

### H3 — JS.push chain timing: `close_message_actions` wins (UNLIKELY but possible)

Both pushes are dispatched. If `close_message_actions` arrives at the server first (network-frame ordering), then `editing_message_id` would be set AFTER `open_message_actions_id` was cleared, meaning the sheet unmount and the editor mount happen in the same diff. Visually this should still work, but if there's a stream-key mismatch (`editing_message_id` is a UUID string, `@msg.id` is also a UUID string — should match), the editor wouldn't render and Marlowe would see the sheet close and nothing else.

**Fix shape (if confirmed):** explicitly serialize: have the sheet's Edit button push only `edit_message_clicked` (no chain), and have the LV handler set BOTH `editing_message_id` and clear `open_message_actions_id` in the same `assign` call. One round-trip instead of two.

### H4 — `Sheet` JS hook focus race (UNLIKELY, ruled mostly out)

The Sheet `updated()` focus-restore code (sheet.js:43–54) would only fire if the sheet's element persisted across the `data-open` flip. Since `chat_live.html.heex:1135` uses `:if={@open_message_actions_id}`, the sheet element is REMOVED, not toggled. `updated()` never fires on a removed element; only `destroyed()` does, which has no focus logic. So focus shouldn't race.

However: if someone refactored the sheet to `data-open`-toggle later, this WOULD become a real race. Watch for it.

---

## What I tried for live measurement (and why I stopped)

Goal: time `editClickedAt → editorVisibleAt` on Marlowe's live dev server.

1. Attempted `chromium.connectOverCDP("http://127.0.0.1:9222")` to attach to Marlowe's existing Chrome — **timed out** at the browser-level WS handshake.
2. Pivoted to fresh `chromium.launch()` headless — hit Playwright-version-vs-installed-chromium mismatch (cache had 1217, code wanted 1223). Fixed by moving the script into `~/saru-tools/` to resolve the local `playwright@1.59` install. Then:
3. Hit `net::ERR_CONNECTION_REFUSED` on `127.0.0.1:4008` — dev server on 4008 had died between earlier-observed-Chrome-tab and my test. Port 4004 was alive but returned 500 on `/dev/login`; couldn't get a clean login.

Rather than burn another 20+ minutes restarting a fresh server, I'm filing this static-analysis finding and recommending a one-liner Marlowe can paste into her DevTools console (next section) to capture the actual click-to-editor-visible latency in her live environment. Stage 5's Playwright spec will codify the measurement properly once a known-good dev server is running.

---

## Diagnostic snippet Marlowe can paste

Open DevTools console on the chat page, paste this, then click 3-dot → Edit message:

```js
(() => {
  const probe = (window.__probe = { log: [], clickAt: null, editorAt: null });
  const mark = (e, d) => probe.log.push({ at: performance.now(), event: e, detail: d });
  const obs = new MutationObserver(() => {
    const ed = document.querySelector("form[id^='msg-editor-'] textarea[name='body']");
    if (ed && probe.editorAt === null) {
      probe.editorAt = performance.now();
      mark("editor_visible");
      console.log("⏱  edit-click → editor:",
        probe.clickAt ? (probe.editorAt - probe.clickAt).toFixed(1) + " ms" : "no click captured");
    }
  });
  obs.observe(document.body, { childList: true, subtree: true });
  document.addEventListener("click", (e) => {
    const btn = e.target.closest && e.target.closest("button");
    if (btn && btn.textContent && btn.textContent.trim().toLowerCase().includes("edit message")) {
      probe.clickAt = performance.now();
      mark("edit_clicked");
      console.log("⏱  Edit click captured at", probe.clickAt.toFixed(1));
    }
  }, true);
  console.log("⏱  Probe installed. Now click 3-dot → Edit message. Check `window.__probe` afterward.");
})();
```

The console logs will show:
- `Edit click captured at <ms>` immediately on the click
- `edit-click → editor: <N> ms` once the editor's textarea appears

If `N > 500ms` consistently, H1 (full-stream re-render) is confirmed. If `N` is small but Marlowe still says "deadclick," H2 (editor below the fold) is the cause.

---

## Recommended call

This finding is **Stage 1 output** — it documents the gap, doesn't fix it. The fix belongs in either:
- A new Suite Task (if Marlowe wants to address it before announcing editable messages), or
- The Stage 4 manual_approval gate of Task 11 (Chat reimagining), which already owns the editable-messages UI.

I lean toward filing a new task — keeps Task 6's scope as verification, not bug-fixing. **Stage 2 onward should proceed regardless**; the bug doesn't block the API/realtime/permission tests from running.

---

## UPDATE 2026-05-12 (post Marlowe desktop repro)

**Marlowe tested on desktop and reports:**
- Pencil → nothing happens
- 3-dot → Edit message → sheet auto-closes, message stays uneditable
- No other message becomes editable either

This rules out H2 (off-screen) and H4 (focus race), and instead promotes a **definitive cause from static trace:**

### Definitive cause — LiveView streams attribute-propagation gotcha

`chat_message` is rendered inside `phx-update="stream"` (chat_live.html.heex:690 wrapping :693–714). Phoenix LiveView's stream pattern preserves child DOM nodes by ID and **only re-renders entries via explicit `stream_insert` / `stream_delete` operations**. Top-level assign changes (like `@editing_message_id`) on the parent LV do NOT cause the stream rows to receive updated attrs.

**So when the user clicks Edit:**
1. `edit_message_clicked` handler at `chat_live.ex:241–244` correctly sets `:editing_message_id` to the message id on the LV socket.
2. The parent template re-evaluates the `:for` block.
3. **But the DOM patcher with `phx-update="stream"` ignores the re-evaluation — the existing rows are preserved with their original attrs.**
4. The chat_message components on the client keep their original `editing_message_id={nil}` from when they were stream-inserted.
5. The editor's `:if={@editing_message_id == @msg.id}` always evaluates false.
6. The editor never renders. Click feels dead.

The reason the SAVE path works while the OPEN path doesn't: `apply_save_edit` at `chat_live.ex:285–320` calls `MessagesHooks.stream_insert_message(updated)` to push the message back through the stream — that forces the row to re-render with the new content. The `edit_message_clicked` handler does NOT call `stream_insert_message`, so the row never re-renders.

### Fix shape (5-line change)

In `chat_live.ex:241–244`:

```elixir
# Before:
def handle_event("edit_message_clicked", params, socket) do
  msg_id = params["message-id"] || params["message_id"]
  {:noreply, assign(socket, :editing_message_id, msg_id)}
end

# After:
def handle_event("edit_message_clicked", params, socket) do
  msg_id = params["message-id"] || params["message_id"]
  socket = assign(socket, :editing_message_id, msg_id)
  case Platform.Repo.get(Platform.Chat.Message, msg_id) do
    nil -> {:noreply, socket}
    msg -> {:noreply, MessagesHooks.stream_insert_message(socket, msg)}
  end
end
```

The `cancel_edit` handler at `chat_live.ex:246–251` needs the same treatment — when closing the editor, we also need to re-insert the message so the row reverts to bubble. Today it sets `editing_message_id` to nil but doesn't stream-insert, so the row stays "stuck" in editor mode visually.

### Why this wasn't caught before

The `apply_save_edit` path (used by save) always calls `stream_insert_message` because the message content itself changed and needed broadcasting. The `edit_message_clicked` path doesn't change the message — it just opens the UI — so the implementer didn't think to stream-insert. But the stream pattern requires re-insert ANY time we want a row's parent assigns to propagate.

This is a one-line miss in the implementation. Production impact: **the feature is invisible to users on the canonical edit path.** Stage 2-5 verification would catch it (cross-client sync test in Stage 5 would fail loudly), but Stage 1's grep + Marlowe's manual report caught it sooner.
