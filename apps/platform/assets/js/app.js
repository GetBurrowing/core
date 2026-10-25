// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import Hooks from "./hooks"
import {installNativeDonations} from "./native_donations"
import {uploadManager} from "./hooks/large_upload"
import {installReloadGuard} from "./lib/reload_guard"
import {createReconnectEscalation, parseThresholds} from "./lib/reconnect_escalation"
import {createConnectionStatusView, fingerprint} from "./lib/connection_status_view"
import {installNavPending} from "./lib/nav_pending"
import {installTopBar} from "./lib/top_bar"
import {installPressHold} from "./hooks/button_loading"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // `timezone` is the viewer's IANA zone, read in `mount/3` via
  // `get_connect_params/1` and validated server-side by
  // `PlatformWeb.MeetingLive.CalendarWindow.resolve_time_zone/1`. Not
  // persisted — `users` has no timezone column and this needs no migration.
  //
  // Every other local time in this app is formatted in the browser by the
  // LocalTime hook, and deliberately so. The calendar cannot use that path:
  // WHICH DAY COLUMN a meeting lands in is a bucketing decision the server
  // makes before any HTML exists, so the zone has to arrive with the
  // connect rather than after the render.
  //
  // `viewport_lg` (task 01a166be stage 3) is read per join, hence the
  // function: /tasks skips the rows of its phone-only list when the join
  // comes from an `lg`-or-wider window (`PlatformWeb.Tasks.FilterHooks`).
  params: () => ({
    _csrf_token: csrfToken,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    viewport_lg: window.matchMedia("(min-width: 64rem)").matches,
  }),
  hooks: Hooks,
})

// LiveView recovers from some failures by reloading the page
// (`reloadWithJitter`), which destroys the File of a large upload that is
// paused offline. Hold that reload while an upload is running; Phoenix keeps
// retrying the connection, and a reload still needed once the uploads are
// done goes ahead (task 01a120be, ./lib/reload_guard.js).
const reloadGuard = installReloadGuard(liveSocket, {isBusy: () => uploadManager.isBusy()})
uploadManager.onIdle(() => reloadGuard.kick())

// Top progress bar (./lib/top_bar.js, task 01a166be-b5b9 stage 3, canvas
// 01a167b0 rule 6): primary token, 3px, below the safe area, after 100ms,
// and only for navigations no control owns (deep links, back/forward). A
// dropped connection is not a page load: LiveView dispatches
// page-loading-start with kind "error" on every drop and kind "initial" for
// the rejoin, and the window-wide bar would make a quiet reconnect look like
// an unrequested navigation (task 01a12b10), so topBarDelay returns no bar
// for "error" and for "initial" while `reconnecting()` (defined below).
installTopBar({topbar, reconnecting: () => reconnecting()})

// Press-hold buttons (./hooks/button_loading.js): aria-busy after 100ms on
// a `.press-hold` button still in its phx-click round trip.
installPressHold()

// iOS Safari (and the Capacitor WKWebView shell) only applies CSS :active
// while a touchstart listener exists somewhere on the page. Press feedback on
// tabs, rail tiles, sheet rows and menu items is pure CSS :active (task
// 01a166be-b5b9), so register ONE empty, passive document-level listener.
// Passive: it never delays scrolling.
document.addEventListener("touchstart", () => {}, {passive: true})

// Optimistic navigation (task 01a166be-b5b9 stage 2, ./lib/nav_pending.js):
// a tapped tab, rail tile, More row or chat row looks current at once and
// rolls back with a toast if the navigation fails or times out (8s). On
// rollback, release LiveView's pending link so tapping again really retries:
// LiveView ignores a click on the href it still believes is loading.
installNavPending({
  onRollback: () => {
    liveSocket.pendingLink = null
  },
})

// Burrow app only: forward `native_donate` (ids only) to SuiteNative.donate.
// A no-op in a browser (task 01a111bb).
installNativeDonations()

// Diagnostic: surface LiveView socket close codes + errors in the console
// so the cause of an "Attempting to reconnect" toast can be identified
// without inspecting the DOM. Close-code map:
//   1000  normal — ignored
//   1001  going away (server shutting down — deploy/restart)
//   1006  abnormal close (network blip, proxy idle timeout)
//   1011  server-side internal error (LV process crashed)
// When a telemetry beacon endpoint exists this can be forwarded server-side.
// Today the console is enough to correlate toasts with root cause.
// `e.reason` is server-controlled and must be treated as potentially sensitive
// before any future server-side forwarding — redact/allowlist it then.
liveSocket.socket.onClose(e => {
  if (e.code !== 1000) {
    console.warn("[lv-socket] close", {code: e.code, reason: e.reason, wasClean: e.wasClean})
  }
})
liveSocket.socket.onError(e => {
  console.warn("[lv-socket] error", e)
})

// ── Quiet reconnect (task 01a12b10) ──────────────────────────────────────
//
// The stock phx-disconnected binding showed the red toast 500 ms into ANY
// drop. The toasts now carry data-escalate / data-clear JS commands instead
// (layouts.ex flash_group), and this controller decides when to run them:
// ./lib/reconnect_escalation.js turns socket events into states, and
// ./lib/connection_status_view.js renders them into #connection-status.
// It lives here, not in a hook, because hooks are destroyed on remount.
//
// FAILURE COUNTING. A failed attempt always ends in a socket close, on both
// transports (longpoll.js closeAndRetry calls onclose), so failures are
// counted on onClose only, through escalation.socketClosed(). The first close
// after a loss is the drop itself and is not counted; each later close is one
// failed retry. onError marks the loss but does not count, so a websocket
// error + close pair, or the websocket-to-longpoll switch under
// longPollFallbackMs, is one failure and never resets the counter.
const escalationMeta = document.querySelector('meta[name="reconnect-escalation"]')
const thresholds = parseThresholds(
  escalationMeta ? {attempts: escalationMeta.dataset.attempts, seconds: escalationMeta.dataset.seconds} : {}
)
const connectionView = createConnectionStatusView({
  doc: document,
  execJS: (el, cmd) => liveSocket.execJS(el, cmd),
})
let lossFingerprint = null
const escalation = createReconnectEscalation({
  ...thresholds,
  isOnline: () => navigator.onLine,
  isHidden: () => document.visibilityState === "hidden",
  onState: ({state, kind}) => {
    connectionView.render({state, kind})
    if (state === "escalated") {
      console.warn("[lv-socket] escalated", {kind, ...escalation.getState(), thresholds})
    }
  },
})
const LOST_STATES = new Set(["pending", "reconnecting", "escalated"])
function reconnecting() {
  return LOST_STATES.has(escalation.getState().state)
}
function lose(kind) {
  if (!reconnecting()) lossFingerprint = fingerprint(document)
  escalation.socketLost(kind)
}

liveSocket.socket.onClose(_e => {
  if (liveSocket.isUnloaded()) return
  if (liveSocket.isConnected()) {
    lose("client")
    return
  }
  if (!reconnecting()) lossFingerprint = fingerprint(document)
  escalation.socketClosed("client")
})
liveSocket.socket.onError(_e => {
  if (liveSocket.isUnloaded()) return
  lose("client")
})
window.addEventListener("phx:page-loading-start", info => {
  const detail = info.detail || {}
  if (detail.kind !== "error" || liveSocket.isUnloaded()) return
  if (detail.errorKind === "server") {
    lose("server")
    escalation.attemptFailed("server")
  } else {
    lose("client")
  }
})
window.addEventListener("phx:page-loading-stop", _info => {
  if (!reconnecting() || !liveSocket.isConnected()) return
  const changed = lossFingerprint !== fingerprint(document)
  const {state} = escalation.getState()
  console.info("[lv-socket] reconnect", {from: state, changed})
  escalation.recovered({changed})
  lossFingerprint = null
  if (changed) connectionView.settle()
})
window.addEventListener("offline", () => escalation.offline())
// Background and freeze time does not count toward the red limits (see
// reconnect_escalation.js BACKGROUND AND FREEZE).
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") escalation.resumed()
})
document.addEventListener("resume", () => escalation.resumed())
window.addEventListener("pageshow", () => escalation.resumed())
// An offline blip often never closes the websocket, so no rejoin follows.
// If the LiveView is still live when the network returns, clear the red here.
window.addEventListener("online", () => {
  const connected = liveSocket.isConnected() && document.querySelector("[data-phx-main].phx-connected") !== null
  escalation.online({connected})
})

// #connection-status is phx-update="ignore", but LiveView still merges data-*
// attributes from the server render onto it, which would reset data-state to
// "idle" on any patch. Put the controller's state back when that happens.
new MutationObserver(() => connectionView.reassert()).observe(document.body, {
  subtree: true,
  attributes: true,
  attributeFilter: ["data-state"],
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Register service worker for PWA support
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js")
    .then(reg => { window.__swReg = reg; })
    .catch(err => console.warn("SW registration failed", err));
}

// ── WebMCP tool registration (Chrome 146+ with flag enabled) ──────────────
//
// Gated by `config :platform, :webmcp_enabled` (rendered as <meta name="webmcp-enabled">).
// Default: on in dev, off everywhere else. Override with WEBMCP_ENABLED=true|false.
//
// Security: tools drive the UI as the authenticated user and ride the LV
// socket's already-authenticated channel. Inputs interpolated into CSS
// selectors are regex-validated to prevent attribute-selector injection;
// string args are length-capped to bound LV-socket DOS / runaway payloads.
// Origin allowlist is not feasible — modelContext does not expose caller
// origin to the execute() callback. See BACKLOG #14.
const webmcpEnabled =
  document.querySelector('meta[name="webmcp-enabled"]')?.content === "true";

if (webmcpEnabled && typeof navigator.modelContext !== "undefined") {
  // Single source of truth for DOM selectors so a UI refactor fails loudly here,
  // not silently for tool callers.
  const SEL = {
    composeInput: "#compose-form input[type='text'], #compose-form textarea",
    composeForm: "#compose-form",
    canvasTitleInput: "input[name='canvas[title]']",
    // The Search pages' inputs (Burrow redesign 22 stage 4 deleted the desktop
    // header's #chat-search-form): the details panel's, else the phone sheet's.
    chatSearchInput: "#details-search-input, #space-sheet-search-input",
    spaceHeader: "header .truncate.font-semibold",
    sidebarSpaceLinks: "nav a[href^='/chat/']",
  };

  const MAX_TEXT = 10000;
  const MAX_QUERY = 500;
  const MAX_TITLE = 200;

  // Charset allowlists for values interpolated into querySelector strings.
  // Not strict format validators — the goal is to reject any character that
  // could break out of an attribute-selector context (quotes, brackets,
  // whitespace, etc.) before it reaches the selector.
  //
  // `NAV_TARGET_RE` covers BOTH slug-form (`general`, `my-channel`) and
  // UUID-form (`0190abcd-...`) nav targets. After ADR 0042 the sidebar
  // emits UUIDs for org-scoped channels (see
  // `PlatformWeb.ChatLive.space_nav_target/1`), so the navigate_space MCP
  // tool needs to accept both shapes.
  const SLUG_RE = /^[a-z0-9_-]{1,64}$/;
  const NAV_TARGET_RE = /^[a-z0-9_-]{1,64}$/i;
  const SAFE_ID_RE = /^[a-z0-9-]{1,36}$/i;

  const errorResult = (msg) => ({ content: [{ type: "text", text: msg }] });

  // Use the right prototype's setter so LV picks up changes for both <input>
  // and <textarea>; using the input-only prototype on a textarea silently no-ops.
  const setNativeValue = (el, value) => {
    const proto = el.tagName === "TEXTAREA"
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };

  navigator.modelContext.registerTool({
    name: "send_message",
    description: "Send a chat message in the currently active Burrow chat space. The message will appear from the authenticated user.",
    input: { type: "object", properties: { text: { type: "string", description: "The message content to send" } }, required: ["text"] },
    async execute({ text }) {
      if (typeof text !== "string") return errorResult("Error: text must be a string");
      if (text.length > MAX_TEXT) return errorResult(`Error: text exceeds ${MAX_TEXT} character limit`);
      const input = document.querySelector(SEL.composeInput);
      const form = document.querySelector(SEL.composeForm);
      if (!input || !form) return errorResult("Error: chat compose form not found on this page");
      setNativeValue(input, text);
      await new Promise(r => setTimeout(r, 50));
      form.dispatchEvent(new Event("submit", { bubbles: true }));
      return { content: [{ type: "text", text: `Message sent: "${text}"` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "navigate_space",
    description: "Navigate to a different chat space/channel by clicking its link in the sidebar. The `slug` parameter is treated as an opaque navigation target — pass through whatever `list_spaces` returns (may be a slug like 'general' OR a UUID for org-scoped channels after ADR 0042).",
    input: { type: "object", properties: { slug: { type: "string", description: "The space nav target — pass through what `list_spaces` returns. Slug or UUID accepted." } }, required: ["slug"] },
    async execute({ slug }) {
      if (typeof slug !== "string" || !NAV_TARGET_RE.test(slug)) {
        return errorResult("Error: slug must match [a-z0-9_-]{1,64} (slug or UUID)");
      }
      // Suffix-match (`$=`) so this works for both `/chat/<slug>` (org-less
      // channels and DMs) and `/chat/<uuid>` (org-scoped channels after
      // ADR 0042). Equality match would miss the latter.
      const link = document.querySelector(`a[href$="/chat/${slug}"]`);
      if (!link) return errorResult(`Space "${slug}" not found in sidebar`);
      link.click();
      return { content: [{ type: "text", text: `Navigated to ${slug}` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "get_page_state",
    description: "Get the current page state: active space, message count, participant info",
    input: { type: "object", properties: {} },
    async execute() {
      const space = document.querySelector(SEL.spaceHeader)?.textContent?.trim() || "unknown";
      const messages = document.querySelectorAll("[id^='messages-']").length;
      const compose = !!document.querySelector(SEL.composeForm);
      return { content: [{ type: "text", text: JSON.stringify({ space, messageCount: messages, composeAvailable: compose, url: window.location.href }) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "search_messages",
    description: "Search chat messages using the search bar",
    input: { type: "object", properties: { query: { type: "string", description: "Search query" } }, required: ["query"] },
    async execute({ query }) {
      if (typeof query !== "string") return errorResult("Error: query must be a string");
      if (query.length > MAX_QUERY) return errorResult(`Error: query exceeds ${MAX_QUERY} character limit`);
      const input = document.querySelector(SEL.chatSearchInput);
      if (!input) return errorResult("Search input not found");
      setNativeValue(input, query);
      await new Promise(r => setTimeout(r, 500));
      const results = document.querySelectorAll("[data-role$='-search-result']").length;
      return { content: [{ type: "text", text: JSON.stringify({ query, resultCount: results }) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "create_canvas",
    description: "Create a new live canvas in the current chat space",
    // Note: the prior `type` parameter targeted a `select[name='canvas[canvas_type]']`
    // that does not exist in the canvas form (only `canvas[title]` is rendered, and
    // the server-side `canvas_create` handler only reads `["title"]`). Dropped to
    // match reality.
    input: { type: "object", properties: { title: { type: "string", description: "Canvas title" } }, required: ["title"] },
    async execute({ title }) {
      if (typeof title !== "string") return errorResult("Error: title must be a string");
      if (title.length > MAX_TITLE) return errorResult(`Error: title exceeds ${MAX_TITLE} character limit`);
      const titleInput = document.querySelector(SEL.canvasTitleInput);
      const form = titleInput?.closest("form");
      if (!titleInput || !form) return errorResult("Canvas creation form not found. Open the canvases panel first.");
      setNativeValue(titleInput, title);
      await new Promise(r => setTimeout(r, 100));
      form.dispatchEvent(new Event("submit", { bubbles: true }));
      return { content: [{ type: "text", text: `Canvas "${title}" creation submitted` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "list_spaces",
    description: "List all available chat spaces/channels visible in the sidebar. Each entry's `slug` is an opaque navigation target (may be a slug or UUID per ADR 0042) — pass it through to `navigate_space` as-is.",
    input: { type: "object", properties: {} },
    async execute() {
      const links = document.querySelectorAll(SEL.sidebarSpaceLinks);
      const spaces = Array.from(links).map(a => {
        // Keyed as `slug` for parameter-name compat with `navigate_space`,
        // but actually an opaque nav target (slug OR UUID). See
        // `PlatformWeb.ChatLive.space_nav_target/1`.
        const slug = a.getAttribute("href").replace("/chat/", "");
        const name = a.textContent.trim().replace(/^#\s*/, "");
        return { slug, name };
      });
      return { content: [{ type: "text", text: JSON.stringify(spaces) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "toggle_thread",
    description: "Open the inline thread under a specific message by clicking its Reply in thread button",
    input: { type: "object", properties: { messageId: { type: "string", description: "The message ID to open the thread for" } }, required: ["messageId"] },
    async execute({ messageId }) {
      if (typeof messageId !== "string" || !SAFE_ID_RE.test(messageId)) {
        return errorResult("Error: messageId must match [a-z0-9-]{1,36}");
      }
      const btn = document.querySelector(`[phx-click="open_inline_thread"][phx-value-message-id="${messageId}"]`);
      if (!btn) return errorResult(`Thread button not found for message ${messageId}`);
      btn.click();
      return { content: [{ type: "text", text: `Thread opened for message ${messageId}` }] };
    }
  });

  // Dev-only debug aid; esbuild substitutes process.env.NODE_ENV at build time
  // so this drops out of prod bundles even if WEBMCP_ENABLED=true is set.
  if (process.env.NODE_ENV === "development") {
    console.log(
      "[WebMCP] Burrow tools registered:",
      ["send_message", "navigate_space", "get_page_state", "search_messages", "create_canvas", "list_spaces", "toggle_thread"].join(", ")
    );
  }
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

