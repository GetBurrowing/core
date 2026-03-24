// ExecutionLogScroll — auto-scrolls the execution log container to bottom
// on mount and on DOM updates (new messages via LiveView), but preserves
// the user's scroll position when they've scrolled up to read history.

const ExecutionLogScroll = {
  mounted() {
    this._atBottom = true;
    this.el.scrollTop = this.el.scrollHeight;

    this.el.addEventListener(
      "scroll",
      () => {
        const dist =
          this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight;
        this._atBottom = dist < 50;
      },
      { passive: true }
    );
  },

  updated() {
    if (this._atBottom) {
      this.el.scrollTop = this.el.scrollHeight;
    }
  },
};

export default ExecutionLogScroll;
