// ComposeInput hook — auto-expanding textarea, Enter to send (desktop),
// Shift+Enter for newline, @mention autocomplete, and per-space draft persistence
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

      const currentValue = this.el.value || "";
      const storedValue = localStorage.getItem(this._draftKey) || "";

      if (keyChanged) {
        if (currentValue !== "") {
          if (currentValue !== storedValue) {
            localStorage.setItem(this._draftKey, currentValue);
          }
        } else if (storedValue !== "") {
          this.el.value = storedValue;
          this.el.dispatchEvent(new Event("input", { bubbles: true }));
        }

        return;
      }

      if (currentValue === "") {
        localStorage.removeItem(this._draftKey);
      } else if (currentValue !== storedValue) {
        localStorage.setItem(this._draftKey, currentValue);
      }
    };

    // Only resize if field-sizing:content isn't supported
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    this._syncDraftState();

    // Reset viewport after iOS keyboard dismisses
    this.el.addEventListener("blur", () => {
      setTimeout(() => {
        window.scrollTo({ top: 0, behavior: "instant" });
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

          this.pushEvent("mention_clear", {});
          this._lastMentionQuery = null;

          const form = this.el.closest("form");
          if (form) form.requestSubmit();
          return;
        }
      }

      if (e.key === "Escape") {
        this.pushEvent("mention_clear", {});
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
          localStorage.removeItem(this._draftKey);
        } else {
          localStorage.setItem(this._draftKey, this.el.value);
        }
      }

      this._detectMention();
    });

    // Reset height and clear persisted draft after a successful submission
    this.handleEvent && this.handleEvent("compose_reset", () => {
      this.el.value = "";

      if (this._draftKey) {
        localStorage.removeItem(this._draftKey);
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
        localStorage.setItem(this._draftKey, this.el.value);
      }

      this.pushEvent("mention_clear", {});
      this._lastMentionQuery = null;
      this.el.focus();
    });
  },

  updated() {
    // Re-apply auto-resize when LiveView patches the textarea (e.g., after send clears it)
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    this._syncDraftState();
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
        this.pushEvent("mention_query", { query, source });
      }
    } else {
      if (this._lastMentionQuery !== null) {
        this._lastMentionQuery = null;
        this.pushEvent("mention_clear", {});
      }
    }
  },
};

export default ComposeInput;
