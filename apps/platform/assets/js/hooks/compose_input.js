// ComposeInput hook — auto-expanding textarea, Enter to send (desktop),
// Shift+Enter for newline, @mention autocomplete, and per-space draft
// persistence via Suite.ClientState.
//
// Two shapes. The chat composer and the inline thread reply are a
// contenteditable chip field (redesign rung 10, `_mountRich` below; the chip
// DOM lives in lib/mention_field.js) where Enter sends on every pointer type.
// The task steering composer is a textarea and keeps the original path
// unchanged.
//
// Task 019f3e9a stage 3: draft-persistence calls migrated off ad-hoc
// direct-store calls onto `Suite.ClientState` under the `compose` namespace.
// The per-space `_draftKey` is used as the sub-key. If a `data-draft-key`
// ever arrives already-prefixed with `"suite:"`, we strip it before passing
// through so ClientState's own `suite:compose:` prefix isn't doubled.
import ClientState from "../client_state.js";
import { attachSendFeel, SEND_SELECTOR } from "../lib/send_feel.js";
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
import {
  deleteChipBeforeCaret,
  hydrate,
  insertChip,
  isSendable,
  mentionQueryAtCaret,
  needsSpaceBefore,
  serialize,
} from "../lib/mention_field.js";

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

// A LiveView patch that inserts something BEFORE the field (the @mention
// list above the pill, the staged tray inside it) moves the field's subtree:
// morphdom re-appends every keyed sibling after the insertion point, and a
// moved element loses focus. LiveView restores focus only for textual inputs
// (`DOM.restoreFocus`), never a contenteditable, so the chip field restores
// its own. True when `records` moved `el` (it or an ancestor was removed and
// re-added) and focus fell to nothing rather than to another control.
export function shouldRestoreFocusAfterMove(records, el, activeElement, body) {
  if (activeElement && activeElement !== body) return false;
  return records.some((r) =>
    Array.from(r.removedNodes || []).some(
      (n) => n === el || (typeof n.contains === "function" && n.contains(el)),
    ),
  );
}

// The thread reply's clear after a send runs on the next task, not in the
// field's own submit listener: LiveView serializes the form in its
// window-level submit listener, which runs AFTER the form's own, so a
// synchronous clear would send an empty reply. Exported for the tests.
export const CLEAR_AFTER_SUBMIT_MS = 0;

// True when a mousedown is on the form's Send button while the caption has
// focus: that mousedown must not move focus (see `_onSendMousedown`).
export function shouldHoldFocusOnSend(target, activeElement, el) {
  if (activeElement !== el || !target || typeof target.closest !== "function") return false;
  return target.closest('button[type="submit"]') !== null;
}

const ComposeInput = {
  mounted() {
    // The chat composer and the inline thread reply are a contenteditable
    // chip field (rung 10, see `_mountRich`); the steering composer is still
    // a textarea and takes the path below unchanged.
    if (this.el.isContentEditable) {
      this._mountRich();
      return;
    }

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
    if (this._rich) {
      this._syncDraftState();
      this._applyRichPlaceholder();
      this._updateSend(serialize(this.el));
      this._syncList();
      return;
    }

    // Re-apply auto-resize when LiveView patches the textarea (e.g., after send clears it)
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    this._syncDraftState();
    this._applyTouchPlaceholder();
  },

  destroyed() {
    releaseRetry(this);
    if (this._sendFeel) {
      this._sendFeel.detach();
      this._sendFeel = null;
    }
    if (this._form) this._form.removeEventListener("mousedown", this._onSendMousedown);
    if (this._form && this._onListPress) {
      this._form.removeEventListener("pointerdown", this._onListPress);
      this._form.removeEventListener("mousedown", this._onListPress);
      this._form.removeEventListener("pointerover", this._onListHover);
    }
    if (this._richObserver) this._richObserver.disconnect();
    if (this._moveObserver) this._moveObserver.disconnect();
    if (this._onSelectionChange) document.removeEventListener("selectionchange", this._onSelectionChange);
    if (this._onWindowSubmit && typeof window.removeEventListener === "function") {
      window.removeEventListener("submit", this._onWindowSubmit);
    }
    if (this._atButton) {
      this._atButton.removeEventListener("pointerdown", this._onAtPress);
      this._atButton.removeEventListener("mousedown", this._onAtPress);
      this._atButton.removeEventListener("click", this._onAtClick);
    }
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

  // ── The chat composer's chip field (redesign rung 10) ────────────────
  //
  // `this.el` is a contenteditable (`phx-update="ignore"`, so LiveView
  // never rewrites what the writer is typing) and the form value lives in
  // the hidden `compose[text]` input named by `data-value-input`. Every edit
  // serializes the field into that input and fires a bubbling `input` on it,
  // which is what drives the form's `phx-change="compose_changed"`. The
  // wire format is unchanged: chips serialize to ADR 0037 `@[Name]`.
  _mountRich() {
    const el = this.el;
    this._rich = true;
    this._lastMentionQuery = null;
    this._mentionRange = null;
    // The @mention list (stage 3): the highlighted row's index, kept here
    // and re-applied after every server patch, and the "@token" Esc closed
    // the list on, which stays plain text and does not reopen it until the
    // caret leaves that token.
    this._highlight = 0;
    this._suppress = null;
    this._draftKey = null;
    this._form = el.closest("form");
    // Only the touch placeholder reads this now: Enter sends on every
    // pointer type (coverage row 115), so nothing else branches on it.
    this._isMobile = window.matchMedia("(pointer: coarse)").matches;

    this._syncDraftState = () => {
      const nextDraftKey = el.dataset.draftKey || null;
      const keyChanged = nextDraftKey !== this._draftKey;
      this._draftKey = nextDraftKey;

      if (!this._draftKey) return;

      if (keyChanged) {
        // The textarea path's `el.defaultValue`: the server's draft for this
        // space, rendered into the hidden input.
        const input = this._valueInput();
        const serverValue = (input && input.value) || "";
        const storedValue = readDraft(this._draftKey) || "";

        if (serverValue === "" && storedValue !== "") {
          hydrate(el, storedValue);
          this._emit();
        } else {
          hydrate(el, serverValue);
          this._updateSend(serverValue);
        }

        return;
      }

      const currentValue = serialize(el);
      const storedValue = readDraft(this._draftKey) || "";
      if (currentValue === "") {
        removeDraft(this._draftKey);
      } else if (currentValue !== storedValue) {
        writeDraft(this._draftKey, currentValue);
      }
    };

    this._syncDraftState();
    this._updateSend(serialize(el));

    el.addEventListener("blur", () => {
      setTimeout(() => {
        if (shouldResetViewportAfterBlur(document.activeElement, el)) {
          window.scrollTo({ top: 0, behavior: "instant" });
        }
      }, 100);
    });

    el.addEventListener("keydown", (e) => {
      if (e.isComposing) return;

      if (e.key === "Enter") {
        // Shift+Enter is the browser's own line break (a <br>).
        if (e.shiftKey && !e.metaKey && !e.ctrlKey) return;

        // With the list open, Enter picks the highlighted row and never
        // sends; Enter sends only when the list is closed.
        if (this._listOpen()) {
          e.preventDefault();
          this._pickHighlighted();
          return;
        }

        // Enter and Cmd/Ctrl+Enter send, on every pointer type.
        e.preventDefault();
        this._sendRich();
        return;
      }

      if (this._listOpen() && !e.altKey && !e.metaKey && !e.ctrlKey) {
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          this._moveHighlight(e.key === "ArrowDown" ? 1 : -1);
          return;
        }
        if (e.key === "Tab" && !e.shiftKey) {
          e.preventDefault();
          this._pickHighlighted();
          return;
        }
      }

      if (e.key === "Backspace" && !e.metaKey && !e.ctrlKey && !e.altKey) {
        const pos = deleteChipBeforeCaret(window.getSelection());
        if (pos) {
          e.preventDefault();
          this._placeCaret(pos);
          this._emit();
          this._detectMentionRich();
        }
        return;
      }

      // Esc closes the list and leaves the typed "@text" as plain text.
      if (e.key === "Escape" && this._lastMentionQuery !== null) {
        e.preventDefault();
        this._dismissMention();
      }
    });

    el.addEventListener("input", () => {
      this._emit();
      this._detectMentionRich();
    });

    // `compose_reset` is the space composer's: the server pushes it after a
    // space send, and a pushed event reaches every hook that handles it, so
    // a thread reply box (`data-clear-on-submit`, which clears itself) must
    // not take it, or a space send would wipe a half-written thread reply.
    this.handleEvent &&
      this.handleEvent("compose_reset", () => {
        if (this._clearsOnSubmit()) return;
        while (el.firstChild) el.removeChild(el.firstChild);
        const input = this._valueInput();
        if (input) input.value = "";
        if (this._draftKey) removeDraft(this._draftKey);
        this._lastMentionQuery = null;
        this._mentionRange = null;
        this._suppress = null;
        this._closeList();
        this._updateSend("");
      });

    // A suggestion row was picked (its click dispatches this; the event
    // name is the insertion API): the typed "@query" becomes a chip. A row
    // press never takes focus (see `_onListPress`), so the field is still
    // focused here; it is focused only if something else really took it.
    el.addEventListener("chat:insert-mention", (e) => {
      const name = e.detail && e.detail.name;
      if (!name) return;

      const range = this._mentionInsertRange();
      if (document.activeElement !== el) el.focus({ preventScroll: true });
      const pos = insertChip(el, range, name);
      this._placeCaret(pos);
      this._emit();

      this._pushMention("clear", {});
      this._lastMentionQuery = null;
      this._mentionRange = null;
      this._suppress = null;
      this._closeList();
    });

    // A press on a list row must not move focus: the phone keyboard stays
    // up and the caret stays where it is. preventDefault on pointerdown
    // (and on mousedown, for browsers that still focus on it); the click
    // that follows does the insert. Pointer hover moves the highlight, so
    // the keys continue from the row the pointer is on.
    this._onListPress = (e) => {
      const t = e.target;
      if (t && typeof t.closest === "function" && t.closest('[data-role="mention-list"]')) {
        e.preventDefault();
      }
    };
    this._onListHover = (e) => {
      const t = e.target;
      const row = t && typeof t.closest === "function" ? t.closest('[role="option"]') : null;
      if (!row || !this._listOpen()) return;
      const i = this._options().indexOf(row);
      if (i !== -1 && i !== this._highlight) {
        this._highlight = i;
        this._syncList();
      }
    };
    if (this._form) {
      this._form.addEventListener("pointerdown", this._onListPress);
      this._form.addEventListener("mousedown", this._onListPress);
      this._form.addEventListener("pointerover", this._onListHover);
    }

    // Paste: an image stages as a thumbnail (rung 11, unchanged); text goes
    // in as plain text only, so no markup from the clipboard reaches the field.
    this._onPaste = (e) => {
      const files = el.closest("#compose-form") ? imageFilesFromClipboard(e.clipboardData) : [];
      if (files.length > 0) {
        e.preventDefault();
        stageFiles(this, files);
        toast(attachedToastText(files.length));
        return;
      }

      const data = e.clipboardData;
      const text = data && typeof data.getData === "function" ? data.getData("text/plain") : "";
      e.preventDefault();
      if (text) document.execCommand("insertText", false, text);
    };
    el.addEventListener("paste", this._onPaste);
    if (el.closest("#compose-form")) installRetry(this);

    this._onSendMousedown = (e) => {
      if (shouldHoldFocusOnSend(e.target, document.activeElement, el)) e.preventDefault();
    };
    if (this._form) this._form.addEventListener("mousedown", this._onSendMousedown);

    // Belt and braces: the hidden input holds exactly what the field shows
    // at the moment the form submits (LiveView reads it on `submit`).
    //
    // After a send, focus stays in the field (direction canvas 01a16233,
    // "Focus never leaves the field"). LiveView's submitForm blurs the
    // active element in its window-level submit listener, so the field
    // takes focus back in a window-level listener of its own, registered
    // after LiveView's (hooks mount after the socket binds its events): in
    // the same task as the blur, so nothing paints in between and a phone
    // keeps its keyboard. The caret goes to the end. Only when the field had
    // focus as the submit began: a tap on Send with the keyboard down must
    // not raise it.
    //
    // The thread reply (`data-clear-on-submit`) then clears itself: no
    // `compose_reset` comes back for it. On the next task, so LiveView has
    // serialized the value first (see CLEAR_AFTER_SUBMIT_MS).
    // Send's press and send feedback (lib/send_feel.js): only on the chat
    // composer, the one form with `.compose-pill-send`. Decoration only; it
    // runs after the value is in place and never holds the submit.
    if (this._form && this._form.querySelector(SEND_SELECTOR)) {
      this._sendFeel = attachSendFeel(this._form);
    }

    if (this._form) {
      this._form.addEventListener("submit", () => {
        const input = this._valueInput();
        if (input) input.value = serialize(el);
        this._focusAtSubmit = document.activeElement === el;
        if (this._sendFeel) this._sendFeel.go();
        if (this._clearsOnSubmit()) {
          const refocus = this._focusAtSubmit;
          setTimeout(() => {
            this._clearField();
            if (refocus) this._refocusAfterSend();
          }, CLEAR_AFTER_SUBMIT_MS);
        }
      });

      this._onWindowSubmit = (e) => {
        if (e.target !== this._form || !this._focusAtSubmit) return;
        this._refocusAfterSend();
      };
      if (typeof window.addEventListener === "function") {
        window.addEventListener("submit", this._onWindowSubmit);
      }
    }

    // The @ toolbar button: inserts "@" at the caret, which opens the list
    // through the ordinary mention detection. Pressing it must not take
    // focus from the field, or the phone keyboard drops and the caret is lost.
    this._atButton = this._form && this._form.querySelector('[data-role="compose-mention-button"]');
    this._onAtPress = (e) => e.preventDefault();
    this._onAtClick = (e) => {
      e.preventDefault();
      if (document.activeElement !== el) {
        el.focus({ preventScroll: true });
        this._placeCaret({ node: el, offset: el.childNodes.length });
      }
      const prefix = needsSpaceBefore(window.getSelection()) ? " " : "";
      document.execCommand("insertText", false, prefix + "@");
    };
    if (this._atButton) {
      this._atButton.addEventListener("pointerdown", this._onAtPress);
      this._atButton.addEventListener("mousedown", this._onAtPress);
      this._atButton.addEventListener("click", this._onAtClick);
    }

    // Keep focus and the caret through a patch that moves the field (see
    // `shouldRestoreFocusAfterMove`). The caret is kept as plain (node,
    // offset) pairs: a live Range inside a removed subtree collapses to the
    // removed node's parent, so by the time the field blurs the selection
    // already points outside it. The patch blurs the field synchronously and
    // the observer's callback, queued by the same removal, runs before the
    // microtask queued in the blur handler, so `_blurPending` is set only for
    // a blur the patch itself caused in this task.
    this._onSelectionChange = () => {
      const sel = window.getSelection();
      if (!sel || sel.rangeCount === 0 || !el.contains(sel.anchorNode)) return;
      if (this._suppress && !this._inSuppressed(mentionQueryAtCaret(sel))) this._suppress = null;
      const r = sel.getRangeAt(0);
      this._lastCaret = {
        startContainer: r.startContainer,
        startOffset: r.startOffset,
        endContainer: r.endContainer,
        endOffset: r.endOffset,
      };
    };
    document.addEventListener("selectionchange", this._onSelectionChange);

    el.addEventListener("blur", () => {
      this._blurPending = { caret: this._lastCaret || null };
      queueMicrotask(() => {
        this._blurPending = null;
      });
    });

    if (typeof MutationObserver !== "undefined" && this._form) {
      this._moveObserver = new MutationObserver((records) => {
        this._syncList();
        // A patch re-renders Send with the server's `disabled`. The server
        // cannot see a thread reply's text (it renders Send disabled), so
        // the field's own rule is re-applied after every patch.
        this._updateSend(serialize(el));
        const pending = this._blurPending;
        if (!pending || !el.isConnected) return;
        if (!shouldRestoreFocusAfterMove(records, el, document.activeElement, document.body)) return;
        this._blurPending = null;
        el.focus({ preventScroll: true });
        const c = pending.caret;
        const sel = window.getSelection();
        if (c && sel && el.contains(c.startContainer) && el.contains(c.endContainer)) {
          const range = document.createRange();
          range.setStart(c.startContainer, c.startOffset);
          range.setEnd(c.endContainer, c.endOffset);
          sel.removeAllRanges();
          sel.addRange(range);
        }
      });
      this._moveObserver.observe(this._form, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["disabled", "data-send-blocked", "data-staged"],
      });
    }

    // `phx-update="ignore"` still merges `data-*` attributes from the
    // server; a space change arrives as a new `data-draft-key`.
    if (typeof MutationObserver !== "undefined") {
      this._richObserver = new MutationObserver(() => {
        this._syncDraftState();
        this._applyRichPlaceholder();
      });
      this._richObserver.observe(el, {
        attributes: true,
        attributeFilter: ["data-draft-key", "data-placeholder", "data-placeholder-touch"],
      });
    }

    this._applyRichPlaceholder();
  },

  _valueInput() {
    const id = this.el.dataset.valueInput;
    return id ? document.getElementById(id) : null;
  },

  // The thread reply box: it clears itself after a send and ignores the
  // space composer's `compose_reset`.
  _clearsOnSubmit() {
    return this.el.hasAttribute("data-clear-on-submit");
  },

  // Empty the field, its value input and its draft, and close the list.
  _clearField() {
    const el = this.el;
    while (el.firstChild) el.removeChild(el.firstChild);
    const input = this._valueInput();
    if (input) input.value = "";
    if (this._draftKey) removeDraft(this._draftKey);
    if (this._lastMentionQuery !== null) this._pushMention("clear", {});
    this._lastMentionQuery = null;
    this._mentionRange = null;
    this._suppress = null;
    this._closeList();
    this._updateSend("");
  },

  // Focus back in the field with the caret at the end, unless it is already
  // there or the field has left the page.
  _refocusAfterSend() {
    const el = this.el;
    if (el.isConnected === false || document.activeElement === el) return;
    el.focus({ preventScroll: true });
    this._placeCaret({ node: el, offset: el.childNodes.length });
  },

  _sendButton() {
    return this._form ? this._form.querySelector('button[type="submit"]') : null;
  },

  // ── The in-flow @mention list (stage 3, Partials.MentionList) ─────────
  //
  // The server renders the list inside the form while a query is active;
  // the field's `aria-controls` names its listbox. The hook owns the
  // highlight and the field's `aria-expanded` / `aria-activedescendant`
  // (LiveView merges only `data-*` into this ignored element, so the server
  // never overwrites them).

  _list() {
    const id = this.el.getAttribute("aria-controls");
    return id && this._form ? this._form.querySelector("#" + id) : null;
  },

  // The pickable rows, in order (the empty row is aria-disabled).
  _options(list = this._list()) {
    if (!list) return [];
    return Array.from(list.querySelectorAll('[role="option"]')).filter(
      (o) => o.getAttribute("aria-disabled") !== "true",
    );
  },

  _listOpen() {
    return this._lastMentionQuery !== null && this._list() !== null;
  },

  _moveHighlight(step) {
    const n = this._options().length;
    if (n === 0) return;
    this._highlight = (((this._highlight + step) % n) + n) % n;
    this._syncList();
  },

  _pickHighlighted() {
    const row = this._options()[this._highlight];
    if (row) row.click();
  },

  // Apply the highlight (clamped to the rows there are now) and the field's
  // ARIA state to whatever the last patch rendered.
  _syncList() {
    const el = this.el;
    const list = this._list();
    const open = this._lastMentionQuery !== null && list !== null;
    el.setAttribute("aria-expanded", String(open));
    const opts = open ? this._options(list) : [];

    if (opts.length === 0) {
      if (!open) this._highlight = 0;
      el.removeAttribute("aria-activedescendant");
      return;
    }

    this._highlight = Math.min(Math.max(this._highlight, 0), opts.length - 1);
    opts.forEach((o, i) => {
      const selected = String(i === this._highlight);
      if (o.getAttribute("aria-selected") !== selected) o.setAttribute("aria-selected", selected);
    });
    const active = opts[this._highlight];
    if (el.getAttribute("aria-activedescendant") !== active.id) {
      el.setAttribute("aria-activedescendant", active.id);
    }
    this._revealInList(list, active);
  },

  // Keep the highlighted row inside the list's own scroll box. Only the
  // list's scrollTop is written; the page and the conversation never move.
  _revealInList(list, row) {
    if (typeof row.offsetTop !== "number" || typeof list.clientHeight !== "number") return;
    if (row.offsetTop < list.scrollTop) list.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > list.scrollTop + list.clientHeight) {
      list.scrollTop = row.offsetTop + row.offsetHeight - list.clientHeight;
    }
  },

  _closeList() {
    this._highlight = 0;
    this.el.setAttribute("aria-expanded", "false");
    this.el.removeAttribute("aria-activedescendant");
  },

  // Esc, or a typed space with nothing matching: close the list, keep the
  // "@text" as typed, and do not reopen it on this token.
  _dismissMention() {
    const q = this._mentionRange;
    if (q) this._suppress = { node: q.node, start: q.start };
    this._pushMention("clear", {});
    this._lastMentionQuery = null;
    this._mentionRange = null;
    this._closeList();
  },

  _inSuppressed(q) {
    const s = this._suppress;
    return !!(s && q && q.node === s.node && q.start === s.start);
  },

  // Serialize into the hidden input, fire `input` on it for phx-change,
  // mirror the draft and the Send state. Returns the serialized text.
  _emit() {
    const text = serialize(this.el);

    // A field emptied by deletion can keep a placeholder <br>; clear it so
    // `:empty` (the placeholder rule) applies again.
    if (text === "") while (this.el.firstChild) this.el.removeChild(this.el.firstChild);

    const input = this._valueInput();
    if (input) {
      input.value = text;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    }

    if (this._draftKey) {
      if (text === "") removeDraft(this._draftKey);
      else writeDraft(this._draftKey, text);
    }

    this._updateSend(text);
    return text;
  },

  // Send is disabled for real while there is nothing to send. The server
  // renders the same rule (`disabled` on the button); the button's
  // `data-send-blocked` carries the parts JS cannot see (no participant,
  // an upload in flight or failed) and `data-staged` the staged tray.
  _updateSend(text) {
    const button = this._sendButton();
    if (!button) return;
    // While a submit is in flight LiveView holds Send disabled and restores
    // it when the reply lands (`data-phx-disabled`); that restore is itself
    // a patch the form observer sees, and the rule is applied then.
    if (button.hasAttribute("data-phx-disabled")) return;
    const blocked = button.dataset.sendBlocked === "true";
    const staged = button.dataset.staged === "true";
    const disabled = blocked || !isSendable(text, staged);
    // Written only on a change: the form observer below watches `disabled`,
    // and an unchanged write would still queue a record.
    if (button.disabled !== disabled) button.disabled = disabled;
  },

  _sendRich() {
    const text = serialize(this.el);
    const button = this._sendButton();
    const staged = !!button && button.dataset.staged === "true";
    if (!isSendable(text, staged)) return;
    if (button && button.disabled) return;

    this._pushMention("clear", {});
    this._lastMentionQuery = null;
    this._mentionRange = null;

    const input = this._valueInput();
    if (input) input.value = text;
    if (this._form) this._form.requestSubmit();
  },

  _placeCaret(pos) {
    if (!pos || typeof document.createRange !== "function") return;
    const sel = window.getSelection();
    if (!sel) return;
    const range = document.createRange();
    range.setStart(pos.node, pos.offset);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
  },

  // Where a picked name goes: over the typed "@query" when it is still in
  // the field, else at the caret, else at the end.
  _mentionInsertRange() {
    const el = this.el;
    const q = this._mentionRange;
    if (q && el.contains(q.node)) {
      const end = Math.min(q.end, q.node.data.length);
      return { startContainer: q.node, startOffset: q.start, endContainer: q.node, endOffset: end };
    }
    const sel = window.getSelection();
    if (sel && sel.rangeCount > 0 && el.contains(sel.anchorNode)) return sel.getRangeAt(0);
    const n = el.childNodes.length;
    return { startContainer: el, startOffset: n, endContainer: el, endOffset: n };
  },

  _detectMentionRich() {
    const sel = window.getSelection();
    let q = sel && this.el.contains(sel.anchorNode) ? mentionQueryAtCaret(sel) : null;
    const source = this._form ? this._form.id : "compose-form";

    if (this._suppress && !this._inSuppressed(q)) this._suppress = null;
    if (this._suppress) q = null;

    // A typed space closes the list only when nothing matched the query so
    // far (names have spaces, so with matches the space filters on).
    if (
      q &&
      this._lastMentionQuery !== null &&
      q.query !== this._lastMentionQuery &&
      /\s$/.test(q.query) &&
      this._options().length === 0
    ) {
      this._mentionRange = q;
      this._dismissMention();
      return;
    }

    if (q) {
      this._mentionRange = q;
      if (q.query !== this._lastMentionQuery) {
        this._lastMentionQuery = q.query;
        this._pushMention("query", { query: q.query, source });
      }
    } else {
      this._mentionRange = null;
      if (this._lastMentionQuery !== null) {
        this._lastMentionQuery = null;
        this._pushMention("clear", {});
      }
    }
  },

  // The placeholder is CSS (`:empty::before`, `attr(data-placeholder)`). With
  // files staged on a touch device, swap in the shorter touch copy.
  _applyRichPlaceholder() {
    const touch = this.el.dataset && this.el.dataset.placeholderTouch;
    if (touch && this._isMobile && this.el.getAttribute("data-placeholder") !== touch) {
      this.el.setAttribute("data-placeholder", touch);
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
