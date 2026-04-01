const InlineFocus = {
  mounted() {
    this.handleEvent("focus_inline_thread_compose", ({ message_id }) => {
      const el = document.getElementById(`inline-thread-compose-${message_id}`);
      if (el) {
        requestAnimationFrame(() => el.focus());
      }
    });
  },
};

export default InlineFocus;
