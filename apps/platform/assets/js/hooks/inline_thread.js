const InlineThread = {
  mounted() {
    this.el.style.overflow = "hidden";
    this.el.style.maxHeight = "0px";
    this.el.style.transition = "max-height 0.3s ease-out, opacity 0.3s ease-out";
    this.el.style.opacity = "0";

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
