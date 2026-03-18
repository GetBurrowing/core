// ComposeInput hook — Enter to send, Shift+Enter for newline
const ComposeInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        const form = this.el.closest("form");
        if (form) form.requestSubmit();
      }
      // Shift+Enter: allow default behaviour (inserts a newline)
    });
  },
};

export default ComposeInput;
