// While a composer field has focus the tab bar is hidden and the dock's
// clearance drops (app.css, `:root:has([phx-hook="ComposeInput"]:focus)`).
// A mousedown on the thread's collapse button would blur the field first:
// the dock grows back (52 -> 124px on a phone), the button moves 72px
// before the click lands, and the first tap is lost (redesign rung 9, task
// 01a1557a-9406). Keeping focus where it is until the click lands fixes
// that; collapsing then removes the field. Keyboard activation never sends
// a mousedown, so it is unaffected.
export function keepComposerFocus(event, doc = document) {
  const button = event.target?.closest?.('[data-role="thread-collapse"]')
  const active = doc.activeElement
  if (button && active?.matches?.('[phx-hook="ComposeInput"]')) event.preventDefault()
}

const InlineThread = {
  mounted() {
    this.el.style.overflow = "hidden";
    this.el.style.maxHeight = "0px";
    this.el.style.opacity = "0";
    this.el.style.transition =
      "max-height 0.4s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.3s ease";

    // Expand on next frame
    requestAnimationFrame(() => {
      this.el.style.maxHeight = this.el.scrollHeight + "px";
      this.el.style.opacity = "1";
    });

    // Watch for content changes (new messages, form resize)
    this._observer = new MutationObserver(() => {
      if (this.el.style.maxHeight !== "0px") {
        this.el.style.maxHeight = this.el.scrollHeight + "px";
      }
    });
    this._observer.observe(this.el, { childList: true, subtree: true });

    this._keepFocus = (event) => keepComposerFocus(event);
    this.el.addEventListener("mousedown", this._keepFocus);
  },

  destroyed() {
    if (this._observer) this._observer.disconnect();
    this.el.removeEventListener("mousedown", this._keepFocus);
  },
};

export default InlineThread;
