// UploadButton hook — makes the + attach button work on mobile Safari (iOS).
//
// Problem: iOS Safari blocks programmatic .click() on file inputs unless
// it's in the synchronous call stack of a direct user gesture. Phoenix
// LiveView's phx-click sends an event to the server, which re-renders the
// DOM with the upload dialog — but by then the user gesture context is lost,
// so dispatching a click into the dialog no longer triggers the native
// file picker.
//
// Fix: On mobile (pointer: coarse), clicking the + button directly and
// synchronously clicks the hidden file input, opening the native picker
// within the user gesture. Once the user selects files, we push
// "upload_dialog_open" to open the staging dialog. On desktop, the
// existing phx-click="upload_dialog_open" flow is preserved unchanged.
//
// We locate the file input via `#upload-send-form input[type="file"]` —
// `live_file_input` hardcodes `id={@upload.ref}` (which Phoenix randomises
// across renders), so a fixed id selector is unreliable. The
// always-present `#upload-send-form` is stable and contains exactly one
// file input: the one for `:attachments`.
function findFileInput() {
  return document.querySelector("#upload-send-form input[type=\"file\"]");
}

const UploadButton = {
  mounted() {
    this._isMobile = window.matchMedia("(pointer: coarse)").matches;

    if (this._isMobile) {
      this._onClick = (e) => {
        // Look up the file input fresh each time (LiveView may re-render it)
        const fileInput = findFileInput();
        if (!fileInput) {
          console.warn("[UploadButton] file input not found in #upload-send-form");
          return; // Let phx-click fire as fallback
        }
        // Synchronous .click() within the user tap gesture — iOS allows this
        fileInput.click();
        // Prevent the phx-click from also firing (it would open the empty
        // dialog before the user has selected files)
        e.stopPropagation();
      };

      // Use capture phase so we run before LiveView's delegated phx-click
      this.el.addEventListener("click", this._onClick, { capture: true });

      // When the user finishes selecting files, open the staging dialog.
      // We listen directly on the file input.
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
    const fileInput = findFileInput();
    // Only re-bind if the element changed
    if (fileInput && fileInput !== this._fileInput) {
      // Clean up old listener
      if (this._fileInput && this._onFileChange) {
        this._fileInput.removeEventListener("change", this._onFileChange);
      }
      this._fileInput = fileInput;
      this._onFileChange = () => {
        // Open the staging dialog after iOS native picker returns selected files.
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
