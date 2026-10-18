# ADR 0057: Prototypes on Burrow: Sealed Hosting, Multiplayer Canvas Rooms, Pluggable Script Engine

- **Status:** Proposed
- **Date:** 2026-10-12
- **Owners:** the product owner, Dalton
- **Task:** 01a1316b-1376-7001-ad5e-0d9628ccfb2f (stack `prototype-runtime`)
- **Extends:** [ADR 0036](0036-canvases-first-class-collaboration-surfaces.md). 0036 already
  anticipated sandboxed `ui_preview` / `iframe` kinds (its Specialized kinds list and Follow-ups)
  and a document-level `bindings` map. This ADR is the first concrete design for both. 0036 is
  not edited.
- **Related:** [ADR 0036](0036-canvases-first-class-collaboration-surfaces.md), canvas
  `01a130e8-7a8b-7001-a8db-62fb81fb30ed` ("Prototypes on Suite - design record"), build tasks
  01a1316b-4e46 (hosting), 01a1316b-677a (scripted embed), 01a1316b-84fa (canvas rooms),
  01a1316b-aab0 (room scripts)

## Context

Agents and people want to publish full clickable prototypes inside Burrow, not on a public
`*.trycloudflare.com` tunnel, and later to let those prototypes hold data and run logic. It has
to be a standard Burrow feature that works on a fresh single-host install.

The thesis, from the product owner, 2026-10-12: **"multiplayer by default. That's our differentiator."**
Every prototype and every scripted canvas is shared and live for all viewers, with no opt-in.

This revives a 2026-05-08/09 thread. The product owner asked about exposing IEx over MCP so agents could
create backend capability behind a canvas. Raw IEx was rejected: it is remote code execution,
it can mint auth, and it can call `:erlang.halt`. The alternative proposed then was canvas-bound
Luerl scripts stored in the canvas's unused `bindings` field, calling only curated bindings, run
as the clicking participant. No ADR was written and none of it was built.

Premises, measured on origin/main `ea0137bee`, 2026-10-12:

- **No ADR covers this.** `grep -rliE 'luerl|prototype host|canvas room' docs/` returns nothing.
- **Code mode exists.** `Platform.CodeMode` (`apps/platform/lib/platform/code_mode/`) runs
  QuickJS-ng compiled to wasm (`priv/code_mode/quickjs_cm.wasm`) under wasmtime via
  `{:wasmex, "== 0.15.1"}`, with wall, fuel and memory limits in `limits.ex`. It is agent-only
  today: one hard-named `Platform.CodeMode.Slots` pool and an `%AgentRuntime{}` principal.
- **Uploaded HTML is single-file only.** `file_blob_controller.ex` `@interactive_frame_csp`
  is `sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src
  'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src
  'none'; form-action 'none'`. That allows inline script and style only, so no second file loads.
- **Embed is script-free.** `kinds/embed.ex` renders `<iframe srcdoc=... sandbox="">` and
  rejects any `<script` (line 98).
- **The session cookie is on the parent domain in both live installs.** It is host-only in code
  (`endpoint.ex` `@session_options`), but `plugs/session_cookie_domain.ex` adds `domain:` from
  `SESSION_COOKIE_DOMAIN`. Measured with `curl -D - https://<host>/auth/login`: `domain=.example.com` and
  `domain=.example.com`, both `HttpOnly; Secure; SameSite=Lax`. It is load-bearing: cross-host
  OIDC state (#587) and the meet-host return (`login_origin.ex`, #738) depend on it.

## Decision

### 1. Hosting: sealed, on the install's own host, per-request grants

- Bundles (multi-file, versioned, immutable per version) are served from
  `/proto/:id/:version/*path` on the install's own host. Every response carries a sandbox CSP
  that extends `@interactive_frame_csp` to bundles: `sandbox allow-scripts` with no
  `allow-same-origin`, so the document gets an opaque origin; the bundle's own files allowed as
  script/style/img/font sources (`'self'` or a path-scoped source, settled by a spike in the
  build); `connect-src 'none'`; `form-action 'none'`. The CSP is appended to the existing
  header, so `frame-ancestors 'self'` stays. The same sandbox applies to top-level opens.
- **Per-request auth is a signed grant, not the cookie.** Requests from an opaque-origin frame
  are cross-site for `SameSite=Lax` and carry no session. The entry request is a navigation the
  Burrow page starts, so it does carry the session. After an org-membership check, it 302s to
  `/proto/:id/:version/g/<grant>/...`. The grant is a short-lived `Phoenix.Token` bound to user,
  prototype and version. Every grant request re-checks that user's membership. Non-members,
  unknown ids and unknown paths get 404.
- **Honest limit: a grant URL is a bearer capability.** Anyone holding a live grant URL can
  read that one version until `max_age`, or until the minting user leaves the org. The server
  cannot tell who holds it.
- **Honest limit: this is not exfiltration-proof.** CSP3 has no `navigate-to`, so script in a
  bundle can navigate its own frame to an outside URL carrying whatever the bundle can see. The
  guarantee is **no Burrow cookies, no Burrow DOM and no Burrow API reachable from the bundle**,
  NOT "no exfiltration". The comment at `file_blob_controller.ex:123-125` ("has no exfiltration
  path") overstates this for the single-file frame too, and should be corrected when that file
  is next touched.
- **`PROTOTYPE_HOST` is deferred.** The intended shape stays as the design record had it:
  optional, one DNS name, a cert through the installer's ACME flow, and no wildcard or
  per-prototype subdomains. But it needs the session cookie to be host-only, and that is false
  on both live installs. A proto subdomain under the parent domain would receive the session.
  Making the cookie host-only would break #587 and #738, and a separate host with no session
  has nothing to org-check against. Both need a design this ADR does not give. v1 serves on the
  install's own host only. Isolation there does not depend on the cookie domain: the document is
  opaque-origin and the cookie is `HttpOnly`.

### 2. Scripted embed: `scripts: true`, loaded through `/proto`, never srcdoc

- An opt-in `scripts: true` prop on the `embed` kind (default false). With it false or absent,
  validation and render stay unchanged, including the `<script` rejection.
- A scripted embed's HTML is stored as a **canvas-owned single-file prototype** (keyed by
  canvas_id and node_id, with a version per distinct HTML) and loaded from `/proto` under the
  same CSP and grant as Decision 1. The server stamps a `prototype_ref` at write time, so render
  stays pure. A client-sent ref is overwritten or stripped.
- **A scripted embed carries no srcdoc anywhere.** `embed_canvas_scale.js` copies the wrapper's
  `data-srcdoc` into the iframe (`updated()` and the expand view), and srcdoc takes precedence
  over src. A scripted node with `data-srcdoc` would run its script under the Burrow page's own
  CSP, with network, and bypass the seal entirely. No `data-srcdoc`, no srcdoc attribute, and no
  fallback to srcdoc when the ref is missing.

### 3. Canvas rooms: the multiplayer core

- `Platform.Chat.CanvasRoom` is a **separate process type**, one per (canvas_id, node_id). It
  reuses `Platform.Chat.Registry` and `Platform.Chat.CanvasSupervisor`, and sits beside
  `Platform.Chat.Canvas.Server`, which stays the single writer of the canvas document. It is
  separate because the key differs, the lifecycle differs (idle stop, flush on terminate), and
  cursor traffic must not queue behind patch rebases.
- The room holds authoritative state, applies ops one at a time through a fixed op set with size
  caps, owns timers and presence, and broadcasts diffs. It persists a snapshot and keeps an
  append-only event log (actor per op, the write audit, and the source for replay or fork later).
- **Own PubSub topic** (`chat:canvas_room:<canvas_id>:<node_id>`), not the canvas topic, because
  every LiveView in a space subscribes to every canvas topic and cursors would fan out to all.
- **Bridge.** `suite.js` is injected inline into every HTML response `/proto` serves, so authors
  add nothing. The frame talks to its parent only by `postMessage`. The parent hook drops any
  message whose `event.source` is not its iframe's `contentWindow` (an identity check, since the
  origin is `"null"`), and drops anything outside the fixed message schema. The room is reached
  **only through the parent LiveView**: canvas and node ids come from the iframe element's data
  attributes, the actor comes from session assigns, and the frame never names a room.
- **Ephemeral events** (cursors, drag) are broadcast only: no persistence, no event log, no
  scripts.
- **Persistence is debounced.** A graceful stop flushes synchronously. A brutal kill or node
  crash loses the unflushed buffer. That is normally one debounce window, and more if earlier
  flushes failed, since a failed flush keeps its buffer.
- Task-page canvas surfaces (stacks, gate panel, steering components) get **no room in v1**.
  Frames there see `suite.connected === false`.

### 4. Script engine: pluggable, JS on code mode first

- `Platform.Canvas.ScriptEngine` is a behaviour the room calls. A run returns **a list of room
  ops** (plus timer effects), not a new state. Handlers run off the room process, so ops from
  other viewers can land during a run. Returned ops are applied all-or-nothing to the current
  state, which stops concurrent ops being clobbered. They pass the same `Ops` caps and event
  log as frame ops, so a handler can write nothing a frame op could not.
- **Engine one is JS on the existing code mode sandbox** (`Platform.CodeMode.Runtime`, no wasm
  change). Reasons: it is already built and mutation-tested, agents write JS well, and it leaves
  one sandbox to secure.
- **Crash risk, corrected.** The design record's "QuickJS could segfault the whole BEAM" is true
  of raw native QuickJS, but not of what Burrow ships. Burrow runs QuickJS-ng compiled to wasm
  under wasmtime, so a guest bug traps in the sandbox. A small residual risk remains in wasmtime
  itself, which is a Rust NIF.
- **Luerl is kept open behind the behaviour**, for what it uniquely gives: state as an Erlang
  value (saved with versions, forked, rolled back), deterministic replay, no native code, and
  preemptive scheduling. It is not built in v1.
- Handlers run in a supervised task (`Task.Supervisor.async_nolink`), so the room keeps serving
  ops, presence and joins during a run. They draw from a **canvas-specific slot pool**: a second
  named `Platform.CodeMode.Slots` instance (`Slots` gains a `:name` option), separate from agent
  code mode runs.
- Handlers run **as the invoking participant**, with the principal bound host-side. The only v1
  host binding is `canvas.patch` on the owning canvas, through `Chat.patch_canvas/3` and the same
  `CanvasAccess.fetch_for_writer/2` gate the MCP tool uses. That means no second authz path and
  never raw `Repo`. Every run is audited (`[:platform, :canvas, :script_run]`, with handler,
  script hash, caller and result kind; no source, args or state). Time comes from the room
  (`ctx.now`), not the host clock.
- **No write bindings in v1** (`tasks.create`, `chat.post_message`). Unregistered names are
  refused.
- **Confused-deputy risk, gated before any write binding exists.** Any canvas writer can author
  a handler, but it runs with the clicker's authority. v1 is safe only because its sole binding
  is one every writer already holds. Any write binding must first bound the author's authority
  too, for example to the intersection of author and clicker.

### 5. Standard-feature requirements

- **Admin-panel settings per install** (`/admin/prototypes`, a singleton settings table, never
  the orgs table): on/off (default off), who may publish, bundle size and file caps, retention
  days. Read at call time. Publish fails closed.
- **Installer option for the prototype host:** deferred with `PROTOTYPE_HOST` (Decision 1).
  Until then there is nothing for the installer to prompt for.
- **A Burrow docs page** (`docs/burrow/canvases.md`) covering how to publish, what the sandbox
  blocks, and the honest limits: navigation away is possible, grant links are bearer links, and
  room scripts run as the clicker.
- **A security review stage** in the build plans. The room-scripts task carries one: every
  containment test must be shown to fail with its limit removed.

### 6. Later / out of scope

- `PROTOTYPE_HOST` and the installer prompt for it.
- Room wiring on task-page canvas surfaces.
- Live Burrow read views (approved `data.query` views).
- The Luerl engine.
- Luerl or JS as a general policy engine (router rules, triage filters).
- Write bindings, behind the confused-deputy gate in Decision 4.

## Consequences

- Prototypes and scripted embeds run on-platform behind org login, with no extra setup on a
  bare-IP install. The cost is the bearer-grant and navigation limits above, which the docs and
  moduledocs state instead of hiding.
- Every prototype is shared live by default, so room state, and not only the document, becomes
  user data with its own retention questions. The event log has no compaction in v1.
- Open items for the build, not settled here:
  - Room ops are gated only by canvas visibility, so any viewer can write room state. Whether
    "multiplayer by default" deliberately means that is a product call, flagged to the product owner. It
    applies to handler-emitted ops too.
  - A timer runs as the actor who scheduled it. Its access should be re-checked at fire time.
  - `Platform.Canvas` is a new namespace beside `Platform.Chat.Canvas.*`. The room-scripts build
    either moves `ScriptEngine` under `Platform.Chat.Canvas` or states that `Platform.Canvas` is
    deliberate. One module must not sit there by accident.
  - Rooms are node-local (Registry), like `Canvas.Server`. A multi-node install would need a
    distributed registry for both.

## Alternatives considered

- **IEx over MCP for agent-built backends.** Rejected: remote code execution, auth minting,
  `:erlang.halt`.
- **Scripts in srcdoc.** Rejected: the frame inherits the Burrow page's CSP and network.
- **Wildcard or per-prototype subdomains.** Rejected: they need DNS-provider API keys for
  wildcard certs.
- **A separate prototype host as the default.** Rejected: one more DNS record rules out bare-IP
  installs. Deferred even as an option, on the cookie-domain measurement.
- **Luerl as engine one.** Not chosen: agents are more fluent in JS, and code mode is already
  built and hardened. Kept open behind the behaviour.
- **Room state inside `Canvas.Server`.** Rejected: different key, lifecycle and traffic profile.
- **The engine returning a new state.** Rejected: a handler running off-process would clobber
  concurrent ops.
