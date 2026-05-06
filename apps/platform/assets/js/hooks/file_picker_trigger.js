// FilePickerTrigger hook — makes browse/dropzone/add-more buttons open the
// native file picker on mobile Safari (iOS).
//
// On desktop, JS.dispatch("click", to: "#upload-file-trigger") works fine.
// On mobile Safari, the dispatched click loses the user gesture context,
// so the file picker never opens. This hook intercepts the click in the
// capture phase and synchronously calls .click() on the file input,
// preserving the gesture chain.
const FilePickerTrigger = {
  mounted() {
    this._isMobile = window.matchMedia("(pointer: coarse)").matches;

    if (this._isMobile) {
      this._onClick = (e) => {
        const fileInput = document.getElementById("upload-file-trigger");
        if (!fileInput) {
          console.warn("[FilePickerTrigger] #upload-file-trigger not found");
          return;
        }
        // Synchronous .click() within user gesture — iOS requires this
        fileInput.click();
        // Prevent JS.dispatch from also firing (would be a no-op but avoids
        // double-triggering on browsers that do honour the dispatch)
        e.stopPropagation();
        e.preventDefault();
      };

      this.el.addEventListener("click", this._onClick, { capture: true });
    }
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick, { capture: true });
    }
  },
};

export default FilePickerTrigger;
