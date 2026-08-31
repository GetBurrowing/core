# Zero-hunt — root-cause rig for the drawer strand (task 01a05873)

Driver + instrumentation that caught the mechanism behind the gate-5
drawer defect: a `canvas_panel_toggle` patch leaves the bottom-parked
reader at `#chat-message-scroller.scrollTop = 0` with NO scroll event,
same DOM node, scrollHeight intact — and the top sentinel then fires
`load_older_messages` with `_preTop = 0`, throwing the reader to
`0 + Δ` (measured 3960) with the jump chip raised.

## The mechanism, as recorded by `diag.mjs` + `instrument.js`

* `results/zero-hunt-prefix-scroller-move-trace.json` — the smoking gun.
  At t=241.6, inside the drawer patch: `removed rel=SELF
  DIV#chat-message-scroller @SC` then `added rel=SELF … @SC` into the
  SAME parent `#chat-drop-zone`. Morphdom realigns a child list that
  grew ahead of the keyed siblings by relocating the keyed nodes;
  `Node.insertBefore` of an attached node removes it first, and a
  detached scroller forgets its scroll offset. `scrollTopWrite` events:
  NONE — the zeroing never went through a JS write, which is why no
  scroll event and no hook callback saw it (the patch does not touch
  `#message-list`, so `beforeUpdate`/`updated` don't run either; the
  #848 viewport observer reconstructs its pre-resize distance from the
  already-zeroed offset and declines).
* `results/zero-hunt-exp1b-drawer-id-still-moves.json` — control that
  killed the obvious alternative: giving the unkeyed drawer div a
  stable `id` does NOT avoid the move. The realign walk starts from the
  insertion point, not from the new node's key. Prevention therefore
  lives in the hooks, not in the template.
* `results/zero-hunt-postfix-repair-trace.json` — with the fix: the move
  still happens (2 records), the realign guard repairs `0 → 3273` in the
  observer microtask, the #848 height path snaps `3273 → 3500` (the
  drawer-shrunk bottom edge), the sentinel never triggers, rows stay 50,
  `d=0`, no chip.

## Files

* `instrument.js` — injected into the live page over CDP. Wraps the
  scroller's `scrollTop` accessor (a JS write logs a stack; a structural
  reset does not), MutationObservers the document for removals /
  additions / attribute changes involving the scroller or its ancestors,
  samples per frame with the ancestor identity chain (morphdom
  replacements show up as UNTAGGED), and traces the hook callbacks.
* `diag.mjs` — driver: login (reader), park at the bottom, inject, click
  the drawer toggle with real CDP mouse events, dump the event trace.
* `top-check.mjs` — the deliberate-top load-older contract: a reader who
  REALLY scrolls to the top must trigger exactly one `load_older` with
  `_preTop = 0` (the capture guard must not substitute for a genuine
  scroll — events delivered 0) and stay anchored on their row at
  `scrollTop = 0 + Δ`.
* `chip-click-check.mjs` — gate-3 semantics: reader 600px up, message
  arrives → chip; click → live edge, chip gone.

## Running

```bash
# headless chrome on moon (host network; CDP via an SSH tunnel if it
# binds 127.0.0.1):
#   ssh -f -N -L 9224:127.0.0.1:9224 dev@build-host.local
CDP_HOST=127.0.0.1:9224 APP_HOST=192.0.2.200 SPORT=4012 node diag.mjs
CDP_HOST=127.0.0.1:9224 APP_HOST=192.0.2.200 SPORT=4012 node top-check.mjs
CDP_HOST=127.0.0.1:9224 APP_HOST=192.0.2.200 SPORT=4012 node chip-click-check.mjs
```
