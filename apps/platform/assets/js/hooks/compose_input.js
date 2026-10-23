// ComposeInput hook — auto-expanding textarea, Enter to send (desktop),
// Shift+Enter for newline, @mention autocomplete, and per-space draft
// persistence via Suite.ClientState.
//
// Task 019f3e9a stage 3: draft-persistence calls migrated off ad-hoc
// direct-store calls onto `Suite.ClientState` under the `compose` namespace.
// The per-space `_draftKey` is used as the sub-key. If a `data-draft-key`
// ever arrives already-prefixed with `"suite:"`, we strip it before passing
// through so ClientState's own `suite:compose:` prefix isn't doubled.
import ClientState from "../client_state.js";
import {
  attachedToastText,
  dropBufferedProgress,
  forgetTrackedFiles,
  imageFilesFromClipboard,
  installRetry,
  leaveUploadChannels,
  markInterrupted,
  releaseRetry,
  restage,
  snapshotTray,
  stageFiles,
  toast,
} from "../attach_stage.js";

const NAMESPACE = "compose";

// Strip a legacy `suite:` prefix from the draft key so ClientState doesn't
// end up storing under `suite:compose:suite:...`. Today's callers emit
// `chat-draft:<space_id>` (see chat_live.html.heex), so this is defensive
// against any future call site that reflexively adds the app prefix.
function normalizeDraftKey(key) {
  if (typeof key !== "string" || key.length === 0) return key;
  return key.startsWith("suite:") ? key.slice("suite:".length) : key;
}

function readDraft(key) {
  return ClientState.get(NAMESPACE, normalizeDraftKey(key), "");
}

function writeDraft(key, value) {
  ClientState.set(NAMESPACE, normalizeDraftKey(key), value);
}

function removeDraft(key) {
  ClientState.remove(NAMESPACE, normalizeDraftKey(key));
}

// Decides whether the delayed post-blur viewport reset should run. It runs
// whenever focus has really left the composer (the iOS keyboard closed), and
// is skipped when focus is back on it by the time the timer fires.
export function shouldResetViewportAfterBlur(activeElement, el) {
  return activeElement !== el;
}

// True when a mousedown is on the form's Send button while the caption has
// focus: that mousedown must not move focus (see `_onSendMousedown`).
export function shouldHoldFocusOnSend(target, activeElement, el) {
  if (activeElement !== el || !target || typeof target.closest !== "function") return false;
  return target.closest('button[type="submit"]') !== null;
}

const ComposeInput = {
  mounted() {
    this._lastMentionQuery = null;
    this._draftKey = null;

    // Mobile detection: touch-primary devices keep Enter as newline,
    // send button is the primary send method on mobile.
    this._isMobile = window.matchMedia("(pointer: coarse)").matches;

    // Auto-resize: collapse to 0 then expand to exact content height (capped at 200px)
    this._autoResize = () => {
      this.el.style.height = "0";
      const contentHeight = this.el.scrollHeight;
      this.el.style.height = Math.min(contentHeight, 200) + "px";
      // Toggle internal scroll when content exceeds max
      this.el.style.overflowY = contentHeight > 200 ? "auto" : "hidden";
    };

    this._syncDraftState = () => {
      const nextDraftKey = this.el.dataset.draftKey || null;
      const keyChanged = nextDraftKey !== this._draftKey;
      this._draftKey = nextDraftKey;

      if (!this._draftKey) return;

      if (keyChanged) {
        // Textareas don't auto-sync `.value` with new child text after a
        // morphdom patch, so on space change `el.value` still holds the
        // previous space's typed content even though LiveView rendered
        // the new space's server-side draft into the textarea's
        // defaultValue. Re-sync explicitly — otherwise the stale value
        // below would be written into the new key's draft store and
        // poison the next restore.
        this.el.value = this.el.defaultValue || "";

        const currentValue = this.el.value;
        const storedValue = readDraft(this._draftKey) || "";

        // If the server had no stored draft but ClientState does (e.g.
        // after a page refresh where the in-memory :drafts map was
        // reinitialized), restore from ClientState.
        if (currentValue === "" && storedValue !== "") {
          this.el.value = storedValue;
          this.el.dispatchEvent(new Event("input", { bubbles: true }));
        }

        return;
      }

      // Same-key update: keep the persisted draft mirrored to textarea content.
      const currentValue = this.el.value || "";
      const storedValue = readDraft(this._draftKey) || "";
      if (currentValue === "") {
        removeDraft(this._draftKey);
      } else if (currentValue !== storedValue) {
        writeDraft(this._draftKey, currentValue);
      }
    };

    // Only resize if field-sizing:content isn't supported
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    this._syncDraftState();

    // Reset viewport after iOS keyboard dismisses. Skipped when focus has
    // come back to the composer before the timer fires: picking an @mention
    // suggestion blurs the textarea and `chat:insert-mention` refocuses it,
    // so an unconditional reset jumped the page to the top mid-compose.
    this.el.addEventListener("blur", () => {
      setTimeout(() => {
        if (shouldResetViewportAfterBlur(document.activeElement, this.el)) {
          window.scrollTo({ top: 0, behavior: "instant" });
        }
      }, 100);
    });

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        // Shift+Enter always inserts a newline (default textarea behavior)
        if (e.shiftKey) return;

        // On desktop: Enter (or Cmd/Ctrl+Enter) sends the message
        // On mobile: Enter inserts a newline (send via button)
        if (!this._isMobile || e.metaKey || e.ctrlKey) {
          e.preventDefault();

          // Don't send empty/whitespace-only messages
          if (this.el.value.trim().length === 0) return;

          this._pushMention("clear", {});
          this._lastMentionQuery = null;

          const form = this.el.closest("form");
          if (form) form.requestSubmit();
          return;
        }
      }

      if (e.key === "Escape") {
        this._pushMention("clear", {});
        this._lastMentionQuery = null;
      }

      if (e.key === "Tab" && this._lastMentionQuery !== null) {
        const dropdown = this.el.closest("form")?.querySelector("[data-mention-suggestion]");
        if (dropdown) {
          e.preventDefault();
          dropdown.click();
        }
      }
    });

    this.el.addEventListener("input", () => {
      if (!CSS.supports("field-sizing", "content")) {
        this._autoResize();
      }

      if (this._draftKey) {
        if (this.el.value === "") {
          removeDraft(this._draftKey);
        } else {
          writeDraft(this._draftKey, this.el.value);
        }
      }

      this._detectMention();
    });

    // Reset height and clear persisted draft after a successful submission
    this.handleEvent && this.handleEvent("compose_reset", () => {
      this.el.value = "";

      if (this._draftKey) {
        removeDraft(this._draftKey);
      }

      if (!CSS.supports("field-sizing", "content")) {
        this.el.style.height = "33px";
        this.el.style.overflowY = "hidden";
      }
    });

    // Handle insert-mention events dispatched by suggestion buttons
    this.el.addEventListener("chat:insert-mention", (e) => {
      const name = e.detail && e.detail.name;
      if (!name) return;

      const value = this.el.value;
      const cursor = this.el.selectionStart;

      // Find the @ that triggered the suggestion
      const before = value.slice(0, cursor);
      const atIndex = before.lastIndexOf("@");

      if (atIndex !== -1) {
        const after = value.slice(cursor);
        this.el.value = before.slice(0, atIndex) + "@[" + name + "] " + after;

        // Cursor lands after "@[" + name + "] " (4 extra chars)
        const newPos = atIndex + name.length + 4;
        this.el.setSelectionRange(newPos, newPos);
      }

      if (this._draftKey) {
        writeDraft(this._draftKey, this.el.value);
      }

      this._pushMention("clear", {});
      this._lastMentionQuery = null;
      this.el.focus();
    });

    // Paste an image into the chat composer (rung 11, task 01a1557a-9de3):
    // it stages as a thumbnail in the composer's tray and the caret stays
    // here. Only the chat composer (`#compose-form`) has the tray; a text
    // paste is left entirely to the browser.
    this._onPaste = (e) => {
      if (!this.el.closest("#compose-form")) return;
      const files = imageFilesFromClipboard(e.clipboardData);
      if (files.length === 0) return;
      e.preventDefault();
      stageFiles(this, files);
      toast(attachedToastText(files.length));
    };
    this.el.addEventListener("paste", this._onPaste);
    if (this.el.closest("#compose-form")) installRetry(this);

    // Keep the caption focused through a tap on Send. On a phone the
    // mousedown would blur it, app.css then brings the tab bar back
    // (`:has([phx-hook="ComposeInput"]:focus)`), the composer jumps up, and
    // the click lands on whatever moved under the finger: the send was lost.
    this._form = this.el.closest("form");
    this._onSendMousedown = (e) => {
      if (shouldHoldFocusOnSend(e.target, document.activeElement, this.el)) e.preventDefault();
    };
    if (this._form) this._form.addEventListener("mousedown", this._onSendMousedown);

    this._applyTouchPlaceholder();
  },

  updated() {
    // Re-apply auto-resize when LiveView patches the textarea (e.g., after send clears it)
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    this._syncDraftState();
    this._applyTouchPlaceholder();
  },

  destroyed() {
    releaseRetry(this);
    if (this._form) this._form.removeEventListener("mousedown", this._onSendMousedown);
  },

  // Keep what was staged across a socket drop (see attach_stage.js).
  disconnected() {
    if (!this.el.closest("#compose-form")) return;
    this._trayAtDrop = snapshotTray();
    markInterrupted(this._trayAtDrop);
    const view = typeof this.__view === "function" ? this.__view() : null;
    const socket = this.liveSocket;
    const settle = () => {
      dropBufferedProgress(view && view.channel);
      leaveUploadChannels(socket && socket.socket);
      forgetTrackedFiles(this.el.closest("#compose-form"));
    };
    settle();
    // LiveView issues a push `getLatencySim()` ms after it is made (0 unless
    // latency simulation is on), so one can still land in the buffer just
    // after this callback: settle again once those have been issued.
    const latency = (socket && typeof socket.getLatencySim === "function" && socket.getLatencySim()) || 0;
    setTimeout(settle, latency + 50);
  },

  reconnected() {
    const snapshot = this._trayAtDrop;
    this._trayAtDrop = null;
    // After the rejoin's first render, which has an empty tray.
    if (snapshot && (snapshot.restage.length > 0 || snapshot.failed.length > 0)) {
      setTimeout(() => restage(this, snapshot), 300);
    }
  },

  // With files staged the server renders the desktop placeholder ("... —
  // Enter to send") and the touch one in `data-placeholder-touch`; on a
  // touch device Enter is a newline, so the touch copy drops the hint.
  _applyTouchPlaceholder() {
    const touch = this.el.dataset && this.el.dataset.placeholderTouch;
    if (touch && this._isMobile) this.el.setAttribute("placeholder", touch);
  },

  // A hook's `pushEvent` ignores `phx-target` — `View.pushHookEvent/4`
  // passes a nil target context — so an untargeted push from markup that
  // lives inside a LiveComponent silently lands on the PARENT LiveView.
  // TasksLive's steering composer moved into `SteeringComponent` (task
  // 01a008f6 stage 5), so it declares `data-mention-target` and gets
  // `pushEventTo`. ChatLive declares none of these attributes and keeps
  // today's untargeted `mention_query` / `mention_clear`.
  _mentionEvent(kind) {
    const custom =
      kind === "query"
        ? this.el.dataset.mentionQueryEvent
        : this.el.dataset.mentionClearEvent;
    return custom || (kind === "query" ? "mention_query" : "mention_clear");
  },

  _pushMention(kind, payload) {
    const event = this._mentionEvent(kind);
    const target = this.el.dataset.mentionTarget;

    if (target) {
      this.pushEventTo(target, event, payload);
    } else {
      this.pushEvent(event, payload);
    }
  },

  _detectMention() {
    const value = this.el.value;
    const cursor = this.el.selectionStart;
    const before = value.slice(0, cursor);

    // Match `@` that starts a mention-in-progress:
    //   - preceded by start-of-line or whitespace (so `foo@bar.com` doesn't trigger)
    //   - followed by query chars: anything except brackets, another @, or newline
    //   - `[` in exclusion class means a committed `@[Name]` stops matching once
    //     the user types past the closing `]`
    const match = before.match(/(?:^|\s)@([^\[\]@\n]*)$/);

    // Identify which compose area triggered the mention by form ID
    const form = this.el.closest("form");
    const source = form ? form.id : "compose-form";

    if (match) {
      const query = match[1];
      if (query !== this._lastMentionQuery) {
        this._lastMentionQuery = query;
        this._pushMention("query", { query, source });
      }
    } else {
      if (this._lastMentionQuery !== null) {
        this._lastMentionQuery = null;
        this._pushMention("clear", {});
      }
    }
  },
};

export default ComposeInput;
