// ComposeInput hook — Enter to send, Shift+Enter for newline, @mention autocomplete
const ComposeInput = {
  mounted() {
    this._lastMentionQuery = null;

    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        // Clear mention suggestions first
        this.pushEvent("clear_mention_suggestions", {});
        this._lastMentionQuery = null;

        const form = this.el.closest("form");
        if (form) form.requestSubmit();
      }

      if (e.key === "Escape") {
        this.pushEvent("clear_mention_suggestions", {});
        this._lastMentionQuery = null;
      }

      if (e.key === "Tab" && this._lastMentionQuery !== null) {
        // Tab-complete: select the first suggestion if available
        const dropdown = this.el.closest("form")?.querySelector("[data-mention-suggestion]");
        if (dropdown) {
          e.preventDefault();
          dropdown.click();
        }
      }
    });

    this.el.addEventListener("input", () => {
      this._detectMention();
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
        this.el.value = before.slice(0, atIndex) + "@" + name + " " + after;

        // Move cursor after the inserted mention
        const newPos = atIndex + name.length + 2;
        this.el.setSelectionRange(newPos, newPos);
      }

      this.pushEvent("clear_mention_suggestions", {});
      this._lastMentionQuery = null;
      this.el.focus();
    });
  },

  _detectMention() {
    const value = this.el.value;
    const cursor = this.el.selectionStart;
    const before = value.slice(0, cursor);

    // Look for @ followed by word chars (no spaces) since last whitespace
    const match = before.match(/@(\w*)$/);

    if (match) {
      const query = match[1];
      if (query !== this._lastMentionQuery) {
        this._lastMentionQuery = query;
        this.pushEvent("mention_query", { query });
      }
    } else {
      if (this._lastMentionQuery !== null) {
        this._lastMentionQuery = null;
        this.pushEvent("clear_mention_suggestions", {});
      }
    }
  },
};

export default ComposeInput;
