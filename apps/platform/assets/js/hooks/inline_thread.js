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
  },

  destroyed() {
    if (this._observer) this._observer.disconnect();
  },
};

export default InlineThread;
