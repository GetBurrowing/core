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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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
if (typeof navigator.modelContext !== "undefined") {
  navigator.modelContext.registerTool({
    name: "send_message",
    description: "Send a chat message in the currently active Suite chat space. The message will appear from the authenticated user.",
    input: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "The message content to send"
        }
      },
      required: ["text"]
    },
    async execute({ text }) {
      const input = document.querySelector("#compose-form input[type='text'], #compose-form textarea");
      const form = document.getElementById("compose-form");
      if (!input || !form) {
        return { content: [{ type: "text", text: "Error: chat compose form not found on this page" }] };
      }
      // Set value and dispatch input event so LiveView picks it up
      const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
      nativeInputValueSetter.call(input, text);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      // Submit the form
      await new Promise(r => setTimeout(r, 50));
      form.dispatchEvent(new Event("submit", { bubbles: true }));
      return { content: [{ type: "text", text: `Message sent: "${text}"` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "navigate_space",
    description: "Navigate to a different chat space/channel by clicking its link in the sidebar",
    input: { type: "object", properties: { slug: { type: "string", description: "The space slug to navigate to (e.g. 'general')" } }, required: ["slug"] },
    async execute({ slug }) {
      const link = document.querySelector(`a[href="/chat/${slug}"]`);
      if (!link) return { content: [{ type: "text", text: `Space "${slug}" not found in sidebar` }] };
      link.click();
      return { content: [{ type: "text", text: `Navigated to #${slug}` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "get_page_state",
    description: "Get the current page state: active space, message count, participant info",
    input: { type: "object", properties: {} },
    async execute() {
      const space = document.querySelector("header .truncate.font-semibold")?.textContent?.trim() || "unknown";
      const messages = document.querySelectorAll("[id^='messages-']").length;
      const compose = !!document.getElementById("compose-form");
      return { content: [{ type: "text", text: JSON.stringify({ space, messageCount: messages, composeAvailable: compose, url: window.location.href }) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "search_messages",
    description: "Search chat messages using the search bar",
    input: { type: "object", properties: { query: { type: "string", description: "Search query" } }, required: ["query"] },
    async execute({ query }) {
      const input = document.querySelector("#chat-search-form input[type='text']");
      if (!input) return { content: [{ type: "text", text: "Search input not found" }] };
      const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
      nativeSet.call(input, query);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      await new Promise(r => setTimeout(r, 500));
      const results = document.querySelectorAll("[phx-click='search_open_result']").length;
      return { content: [{ type: "text", text: JSON.stringify({ query, resultCount: results }) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "create_canvas",
    description: "Create a new live canvas in the current chat space",
    input: { type: "object", properties: { title: { type: "string", description: "Canvas title" }, type: { type: "string", description: "Canvas type: table, form, code, diagram, dashboard, custom", enum: ["table", "form", "code", "diagram", "dashboard", "custom"] } }, required: ["title", "type"] },
    async execute({ title, type }) {
      const titleInput = document.querySelector("input[name='canvas[title]']");
      const typeSelect = document.querySelector("select[name='canvas[canvas_type]']");
      const form = titleInput?.closest("form");
      if (!titleInput || !typeSelect || !form) return { content: [{ type: "text", text: "Canvas creation form not found. Open the canvases panel first." }] };
      const nativeSet = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
      nativeSet.call(titleInput, title);
      titleInput.dispatchEvent(new Event("input", { bubbles: true }));
      typeSelect.value = type;
      typeSelect.dispatchEvent(new Event("change", { bubbles: true }));
      await new Promise(r => setTimeout(r, 100));
      form.dispatchEvent(new Event("submit", { bubbles: true }));
      return { content: [{ type: "text", text: `Canvas "${title}" (${type}) creation submitted` }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "list_spaces",
    description: "List all available chat spaces/channels visible in the sidebar",
    input: { type: "object", properties: {} },
    async execute() {
      const links = document.querySelectorAll("nav a[href^='/chat/']");
      const spaces = Array.from(links).map(a => {
        const slug = a.getAttribute("href").replace("/chat/", "");
        const name = a.textContent.trim().replace(/^#\s*/, "");
        return { slug, name };
      });
      return { content: [{ type: "text", text: JSON.stringify(spaces) }] };
    }
  });

  navigator.modelContext.registerTool({
    name: "toggle_thread",
    description: "Open a thread panel for a specific message by clicking its thread button",
    input: { type: "object", properties: { messageId: { type: "string", description: "The message ID to open the thread for" } }, required: ["messageId"] },
    async execute({ messageId }) {
      const btn = document.querySelector(`[phx-click="open_thread"][phx-value-message-id="${messageId}"]`);
      if (!btn) return { content: [{ type: "text", text: `Thread button not found for message ${messageId}` }] };
      btn.click();
      return { content: [{ type: "text", text: `Thread opened for message ${messageId}` }] };
    }
  });

  console.log("[WebMCP] Suite tools registered:", ["send_message", "navigate_space", "get_page_state", "search_messages", "create_canvas", "list_spaces", "toggle_thread"].join(", "));
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

