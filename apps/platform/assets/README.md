# platform / assets

Front-end asset tree for the Suite Phoenix app. Vitest suites live under
`test/`, node-native tests under `test/**/*_test.mjs`, hooks under `js/hooks/`,
and CSS under `css/`. `esbuild` + Tailwind are wired via `mix assets.build`
(see the parent Elixir project); this README covers the JS-side conventions
that don't have a natural home in the Elixir tree.

## Client state persistence

Every hook that persists per-tab preferences goes through
[`js/client_state.js`](js/client_state.js) — the single wrapper around
`window.localStorage` that centralises quota / private-mode error handling
and enforces a shared key scheme. Direct `localStorage.*` calls outside
this module are gated by a repo-local lint check (see below).

Keys are stored as `suite:<namespace>:<key>`. The `suite:` prefix mirrors
the historical `suite:tasks-last-project-id` naming already baked into
older hooks. Values JSON-serialize on write and JSON-parse on read; a
legacy raw string that fails `JSON.parse` (e.g. `localStorage.setItem(k,
"blocked")`) round-trips as its raw string, so migration from an older
call site is byte-identical for the value.

Public API:

```js
import ClientState from "./client_state";

ClientState.get(namespace, key, defaultValue = null);   // → value | default
ClientState.set(namespace, key, value, { ttlMs } = {}); // → void
ClientState.remove(namespace, key);                     // → void
ClientState.clear(namespace);                           // → void
ClientState.clearAll();                                 // → void
ClientState.available();                                // → boolean (in-mem fallback active?)
```

`ttlMs` writes an envelope `{v: value, e: expiryEpoch}`; reads treat
expired entries as missing and clean them up transparently.

On `QuotaExceededError` or `SecurityError` (private-mode Safari, aggressive
tracking-prevention settings) the module flips an internal disabled flag
and switches to an in-memory `Map` for the tab's lifetime. Callers do not
need to catch — every method survives, values just don't persist across
reloads. `ClientState.available()` reports the current mode.

### Adding a new namespace

Pick a short, lowercase, underscore-separated namespace unique to your
subsystem (e.g. `chat_ui`, `meeting_prefs`, `soundboard`). Import and go —
no registration step:

```js
import ClientState from "../client_state";

const NAMESPACE = "my_feature";
const value = ClientState.get(NAMESPACE, "collapsed", false);
ClientState.set(NAMESPACE, "collapsed", true);
```

If you're migrating an existing hook off a raw `localStorage` key, use
the one-shot read-then-delete pattern — see any of `resizable_sidebar.js`,
`last_project.js`, `tasks_status_filter.js`, or `sidebar_collapse.js` for
the template. Mark the legacy calls with a `// client-state:allow (legacy
migration)` comment so the lint gate lets them through.

### Carve-outs

- **`burrow-theme-v1` (theme cache)** — the `data-role="theme-boot"`
  inline script in `root.html.heex` owns this key: it holds the last
  applied `{preset, mode}` so the first frame paints the right theme before
  any bundle loads. JS changes the theme through `window.burrowTheme`
  (`get()` / `apply({preset, mode})`) and follows it through the
  `burrow:theme` event; it never touches the key directly. The
  `hooks/theme_picker.js` hook stays on the lint script's allowlist.

Any other subsystem that needs to bypass the wrapper — new interop with
Phoenix core, third-party integrations that dictate a raw key — should
either extend the ClientState API surface or add itself to the explicit
allowlist in `scripts/check_no_direct_localstorage.mjs` with a comment
explaining why.

## Lint gate

[`scripts/check_no_direct_localstorage.mjs`](scripts/check_no_direct_localstorage.mjs)
walks `js/` recursively and rejects any `localStorage.*` call that isn't
covered by one of these escape hatches:

1. **Allowlisted file** — `js/client_state.js` (the API itself) and
   `js/hooks/theme_picker.js` (theme carve-out).
2. **Same-line `"burrow-theme-v1"` marker** — belt-and-braces for any code
   that has to read the theme cache directly.
3. **Same-line `client-state:allow` comment marker** — the documented
   escape hatch for one-shot legacy-key migration paths. Add a trailing
   comment such as `// client-state:allow (legacy migration)` on the
   exact line that touches raw `localStorage`.

The check runs automatically as part of `npm test` (after `vitest run` and
`node --test`). Run it in isolation with:

```sh
cd apps/platform/assets
node scripts/check_no_direct_localstorage.mjs
```

Exit codes: `0` clean, `1` one or more offenders (path + line printed to
stderr), `2` internal error. A self-test at
[`test/no_direct_localstorage_test.mjs`](test/no_direct_localstorage_test.mjs)
exercises the script against synthetic fixture trees so a broken
gate can't silently green-light regressions.

## Test suites

- `test/*.test.js` and `test/hooks/*.test.js` — vitest, run via `vitest run`.
- `test/**/*_test.mjs` — node native test runner, hand-rolled DOM shims
  where possible so the toolchain stays zero-dependency.
- Both suites plus the lint gate are wired into `npm test`.

## Meetings: synthesising captions

The call rail's Transcript pane (`js/hooks/meeting_transcript.js`) and the
caption overlay (`js/hooks/meeting_captions.js`) both consume one client-side
DOM event, `meeting:caption`, which `js/hooks/meeting_room.js`
(`_onTranscription()`) dispatches on `document` for every LiveKit
`TranscriptionSegment` it receives. Nothing server-side ever sees the payload.

```js
// detail shape, as meeting_room.js builds it:
//   id        seg.id || crypto.randomUUID()      interim/final pairing key
//   speaker   participant.name || identity || "Unknown"
//   identity  participant.identity || ""         "user:…" | "agent:…" | "guest:…"
//   text      seg.text || ""
//   final     seg.final !== false                defaults to TRUE when absent
//   timestamp seg.startTime || Date.now()        epoch ms
document.dispatchEvent(
  new CustomEvent("meeting:caption", {
    detail: { id: "u1", speaker: "Ada", identity: "", text: "first line", final: true, timestamp: Date.now() },
  })
)
```

So a transcript can be driven with no LiveKit room at all — from the browser
console, a CDP `Runtime.evaluate`, or a jsdom test — on either surface that
mounts the rail (`/meetings/:slug`, or the in-chat quickmeet panel once
`in_meeting` is set). An interim (`final: false`) followed by a final replaces
it in place, whether or not the two share an `id`; a redelivered final with the
same `id` updates in place rather than duplicating.
