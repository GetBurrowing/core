// UploadButton hook — makes the + attach button work on mobile Safari (iOS).
//
// Problem: iOS Safari blocks programmatic .click() on file inputs unless
// it's in the synchronous call stack of a direct user gesture. Phoenix
// LiveView's phx-click sends an event to the server, which re-renders the
// DOM with the upload dialog — but by then the user gesture context is lost,
// so JS.dispatch("click", to: "#upload-file-trigger") inside the dialog
// no longer triggers the native file picker.
//
// Fix: On mobile (pointer: coarse), clicking the + button directly and
// synchronously clicks the hidden file input, opening the native picker
// within the user gesture. Once the user selects files, we push
// "show_upload_dialog" to open the staging dialog. On desktop, the
// existing phx-click="show_upload_dialog" flow is preserved unchanged.
const UploadButton = {
  mounted() {
    this._isMobile = window.matchMedia("(pointer: coarse)").matches;

    if (this._isMobile) {
      this._onClick = (e) => {
        // Look up the file input fresh each time (LiveView may re-render it)
        const fileInput = document.getElementById("upload-file-trigger");
        if (!fileInput) {
          console.warn("[UploadButton] #upload-file-trigger not found in DOM");
          return; // Let phx-click fire as fallback
        }
        // Guard: iOS won't open picker if the input is display:none or zero-size
        const style = window.getComputedStyle(fileInput);
        if (style.display === "none") {
          console.warn("[UploadButton] file input has display:none — iOS will ignore .click()");
        }
        if (fileInput) {
          // Synchronous .click() within the user tap gesture — iOS allows this
          fileInput.click();
          // Prevent the phx-click from also firing (it would open the empty
          // dialog before the user has selected files)
          e.stopPropagation();
        }
      };

      // Use capture phase so we run before LiveView's delegated phx-click
      this.el.addEventListener("click", this._onClick, { capture: true });

      // When the user finishes selecting files, open the staging dialog.
      // We listen directly on the file input. LiveView's auto_upload will
      // handle queuing the files; we just need to open the dialog UI.
      this._bindFileInput();
    }
  },

  updated() {
    // Re-bind if LiveView replaced the file input element
    if (this._isMobile) {
      this._bindFileInput();
    }
  },

  _bindFileInput() {
    const fileInput = document.getElementById("upload-file-trigger");
    // Only re-bind if the element changed
    if (fileInput && fileInput !== this._fileInput) {
      // Clean up old listener
      if (this._fileInput && this._onFileChange) {
        this._fileInput.removeEventListener("change", this._onFileChange);
      }
      this._fileInput = fileInput;
      this._onFileChange = () => {
        // Open the staging dialog after iOS native picker returns selected files.
        // Server handler name on this branch is `upload_dialog_open` (matches the
        // desktop phx-click on the + button).
        this.pushEvent("upload_dialog_open", {});
      };
      this._fileInput.addEventListener("change", this._onFileChange);
    }
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick, { capture: true });
    }
    if (this._fileInput && this._onFileChange) {
      this._fileInput.removeEventListener("change", this._onFileChange);
    }
  },
};

export default UploadButton;
