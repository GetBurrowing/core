import ClientState from "../client_state.js";

/**
 * RouteResume — per-module last-URL tracking so a click on the Chat / Tasks /
 * Meetings (etc.) top-nav tile returns the user to their last URL within that
 * module rather than the module's root (task 019f3e9a stage 2).
 *
 * Contract:
 *   - On every LiveView navigation completion (`phx:page-loading-stop` on
 *     window), extract `window.location.pathname + window.location.search`,
 *     derive a `moduleId` from the pathname's first segment (allowlist
 *     below), and persist the path-plus-query string via
 *     `ClientState.set("route_resume", moduleId, pathAndSearch)`. Paths
 *     outside the allowlist are ignored. Query strings are preserved so
 *     deep-link state (e.g. `/tasks?sponsor=mine`) survives a top-nav
 *     roundtrip through a different module (task 019f487e Case 5 fix).
 *   - A delegated `click` listener on `document` intercepts clicks on any
 *     `<a data-module-id=…>` element. If a saved URL exists for that module,
 *     differs from the anchor's `href` (path + search compared together, not
 *     path alone — otherwise a bare `/tasks` anchor would silently match a
 *     saved `/tasks?sponsor=mine` and drop the query), and lives under the
 *     same module prefix (search-stripped), we `preventDefault()` and use
 *     `liveSocket.historyRedirect/5` to route to the saved URL. This is
 *     Phoenix LiveView's public imperative-navigation API and correctly
 *     handles cross-LV transitions (patch is a no-op when the target LV
 *     differs) — using the canonical LV path rather than `history.pushState`
 *     keeps SPA behavior intact and avoids a hard reload.
 *   - When a LiveView discovers its resumed URL is stale (deleted task,
 *     unreachable space) it pushes a `route_resume_stale` event; the
 *     window-level listener here calls `ClientState.remove("route_resume",
 *     module)` so the next click falls back to the module root.
 *
 * Mount instance is expected to be singleton per shell (see
 * `shell.html.heex`); the hook wires its listeners against `window` /
 * `document` and cleans them up in `destroyed()`.
 */

// Longest-prefix-first path→module map. Order matters: `/admin/prompts` MUST
// resolve to `prompts` before `/admin` matches as `admin`, otherwise a
// prompts-scoped save would collide with admin. `context` maps to
// `/org_memory` because the tile carries `data-module-id="context"`
// (see icon_rail.ex `dest.key` for the org-memory destination) while the URL
// segment is `org_memory` — the map bridges the mismatch so click intercept
// and save/read agree on a single moduleId.
const PATH_MODULE_MAP = [
  ["/admin/prompts", "prompts"],
  ["/org_memory", "context"],
  ["/chat", "chat"],
  ["/tasks", "tasks"],
  ["/meetings", "meetings"],
  ["/inbox", "inbox"],
  ["/activity", "activity"],
  ["/skills", "skills"],
  ["/files", "files"],
  ["/canvases", "canvases"],
  ["/control", "control"],
  ["/admin", "admin"],
];

// Reverse map: given a `moduleId` (from a tile's `data-module-id`), which
// URL prefix does it own? Used by the click intercept to gate the "same
// module prefix" check on the saved URL — a stray saved value in the wrong
// namespace can't hijack a click.
const MODULE_TO_PATH = Object.fromEntries(
  PATH_MODULE_MAP.map(([path, mod]) => [mod, path])
);

// Resume entries expire after 3 hours (task 019f62c8). Without a TTL the
// saved subpage lived in localStorage indefinitely — across hours and across
// a fresh deploy — so clicking a module tile (e.g. the Admin gear) kept
// resuming a long-dead subpage like `/admin/users` instead of the module
// root. A fresh return within the window still resumes your last spot; a
// stale read is treated as missing by ClientState.get (expire-on-read +
// self-clean), the click intercept bails, and normal LiveView navigation to
// the module root proceeds. 3h per Rowan: long enough to feel like "take me
// back to where I was" within a work session, short enough that a next-day
// or post-deploy visit lands on root.
const RESUME_TTL_MS = 3 * 60 * 60 * 1000;

// Extract a moduleId from a URL pathname. Returns null when nothing in the
// allowlist matches — those routes silently skip both save and resume.
// Callers may pass a full path+search (e.g. `/tasks?sponsor=mine`); the
// query and fragment are stripped before matching so a `?sponsor=mine` on
// `/tasks` still resolves to the `tasks` module.
function moduleFromPath(pathname) {
  if (typeof pathname !== "string" || !pathname.startsWith("/")) return null;
  const pathOnly = stripQueryAndFragment(pathname);
  for (const [prefix, mod] of PATH_MODULE_MAP) {
    if (pathOnly === prefix || pathOnly.startsWith(prefix + "/")) return mod;
  }
  return null;
}

// The saved URL is a valid resume target for `moduleId` iff it still lives
// under the module's canonical prefix. Guards against a namespace pollution
// where a `route_resume:chat` entry accidentally holds `/tasks/…` — clicking
// Chat wouldn't route to Tasks. Saved values may include a query string
// (task 019f487e Case 5) so we compare against the pathname component only.
function sameModulePrefix(moduleId, saved) {
  const prefix = MODULE_TO_PATH[moduleId];
  if (!prefix || typeof saved !== "string") return false;
  const pathOnly = stripQueryAndFragment(saved);
  return pathOnly === prefix || pathOnly.startsWith(prefix + "/");
}

// Strip anything after the first `?` or `#`. We only need this for prefix
// matching — the actual saved value keeps the query so we can restore it on
// intercept. Returns the input unchanged when neither char is present.
function stripQueryAndFragment(pathAndSearch) {
  if (typeof pathAndSearch !== "string") return "";
  const qIdx = pathAndSearch.indexOf("?");
  const hIdx = pathAndSearch.indexOf("#");
  let cut = -1;
  if (qIdx >= 0 && hIdx >= 0) cut = Math.min(qIdx, hIdx);
  else if (qIdx >= 0) cut = qIdx;
  else if (hIdx >= 0) cut = hIdx;
  return cut >= 0 ? pathAndSearch.slice(0, cut) : pathAndSearch;
}

const RouteResume = {
  mounted() {
    // `phx:page-loading-stop` fires after every LV nav (patch or redirect)
    // and after the initial page load, which is the right moment to snapshot
    // the current URL for future resume. Using the window event rather than
    // the hook's `updated()` avoids double-writes when unrelated assigns
    // change on the shell.
    this._onPageLoadingStop = () => this._persistCurrentPath();
    window.addEventListener("phx:page-loading-stop", this._onPageLoadingStop);

    // Delegated click intercept. Attached to `document` so a tile added or
    // re-rendered after mount is still caught without per-anchor wiring.
    this._onClick = (event) => this._maybeInterceptClick(event);
    document.addEventListener("click", this._onClick, true);

    // Server-initiated stale signal: a LiveView pushed `route_resume_stale`
    // because it resolved a saved URL to a 404-equivalent state (task
    // deleted, space missing). Bubble up on window so any LV in the tree
    // can broadcast without knowing where this hook lives.
    this._onStale = (event) => {
      const mod = event?.detail?.module;
      if (typeof mod === "string" && mod.length > 0) {
        ClientState.remove("route_resume", mod);
      }
    };
    window.addEventListener("phx:route_resume_stale", this._onStale);

    // Persist the URL we mounted on — covers the case where the shell was
    // rendered by a full-page load and no LV nav has fired yet.
    this._persistCurrentPath();
  },

  destroyed() {
    window.removeEventListener("phx:page-loading-stop", this._onPageLoadingStop);
    document.removeEventListener("click", this._onClick, true);
    window.removeEventListener("phx:route_resume_stale", this._onStale);
  },

  _persistCurrentPath() {
    const path = window.location.pathname || "";
    const search = window.location.search || "";
    const mod = moduleFromPath(path);
    if (!mod) return;
    // Persist path + query so deep-link filter state (e.g. `?sponsor=mine`
    // on Tasks) round-trips through a top-nav click that leaves and returns
    // to the module. Fragment intentionally excluded — LV navigations don't
    // preserve hashes and re-emitting them would confuse the browser scroll
    // anchor. See task 019f487e Case 5.
    // Pass a TTL so the entry ages out (see RESUME_TTL_MS). ClientState wraps
    // the value in a `{v, e}` envelope; a read after `e` returns the default
    // (null) and cleans the stale key, so the click intercept falls back to
    // the module root instead of resuming a dead subpage.
    ClientState.set("route_resume", mod, path + search, { ttlMs: RESUME_TTL_MS });
  },

  _maybeInterceptClick(event) {
    // Bail on modifier / non-primary clicks — the user asked for a new tab
    // or a middle-click, which we must not hijack into a same-tab patch.
    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;

    const anchor = event.target && event.target.closest
      ? event.target.closest("a[data-module-id]")
      : null;
    if (!anchor) return;

    const moduleId = anchor.dataset.moduleId;
    if (!moduleId) return;

    const saved = ClientState.get("route_resume", moduleId);
    if (typeof saved !== "string" || saved.length === 0) return;

    // The anchor's `href` includes the scheme+host in `getAttribute("href")`
    // if authored as absolute; the DOM `.pathname` / `.search` normalize
    // back to just the path and query. We compare the whole path+search
    // (not path alone) so a bare `/tasks` anchor does NOT no-op when the
    // saved value is `/tasks?sponsor=mine` — that mismatch is exactly the
    // signal that we need to redirect to preserve the query state. See
    // task 019f487e Case 5.
    const anchorPath = anchor.pathname || anchor.getAttribute("href") || "";
    const anchorSearch = anchor.search || "";
    const currentHrefFull = anchorPath + anchorSearch;
    if (saved === currentHrefFull) return;

    if (!sameModulePrefix(moduleId, saved)) return;

    event.preventDefault();
    // Stop bubble-phase propagation to `window`. LiveView.js registers its
    // OWN document-wide click handler at `window` in bubble phase (see
    // `live_socket.js` — `window.addEventListener("click", …, false)`) and
    // does NOT check `event.defaultPrevented` before running its own
    // `historyRedirect(event, anchor.href, "push", null, anchor)`. Without
    // this call, our capture-phase navigation to the saved URL is
    // immediately clobbered by LV's bubble-phase navigation to the
    // anchor's raw href — the user lands on `/tasks` root or `/chat/general`
    // instead of the resumed URL. `stopPropagation()` (not
    // `stopImmediatePropagation()`) is sufficient because the clobbering
    // listener is on `window`, not other listeners on `document`.
    event.stopPropagation();

    // Phoenix LV public API for imperative SPA navigation. Signature is
    // `historyRedirect(e, href, linkState, flash, targetEl)` (see
    // live_socket.js) — `event` is the click we intercepted (LV inspects
    // it for its own bookkeeping); `linkState` "push" tells the socket to
    // append a history entry (same as clicking a `phx-link="redirect"`
    // anchor); `flash` is `null` because we have nothing to carry; and
    // `targetEl` gives LV the originating anchor for focus-restoration.
    // We use `historyRedirect` (not `pushHistoryPatch`) because saved URLs
    // routinely cross LiveView boundaries — e.g. resuming
    // `/tasks/<id>/…` from a click on the Tasks tile mounted under the
    // shell LV requires a full redirect, not a patch. Prior revision
    // called `pushHistoryPatch(saved, "push", anchor)` — that method's
    // real signature is `pushHistoryPatch(e, href, linkState, targetEl)`
    // so the 3-arg form silently mapped `href="push"` and no-op'd every
    // cross-LV navigation.
    const socket = window.liveSocket;
    if (socket && typeof socket.historyRedirect === "function") {
      socket.historyRedirect(event, saved, "push", null, anchor);
    } else {
      // Fallback (should not fire in practice — liveSocket is set globally
      // by app.js). A full-page assign is worse than a patch but at least
      // gets the user to the right URL.
      window.location.assign(saved);
    }
  },
};

// Named exports for the vitest suite. `moduleFromPath` + `sameModulePrefix`
// + `stripQueryAndFragment` are pure and cheap to test in isolation; the
// object export is the hook itself.
export {
  moduleFromPath,
  sameModulePrefix,
  stripQueryAndFragment,
  PATH_MODULE_MAP,
  RESUME_TTL_MS,
};
export default RouteResume;
