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
//
// Large files (task 01a120be): a picked file over the composer's inline cap
// is taken out of this input by the LargeUpload hook's capture-phase
// listener (./large_upload.js) before LiveView sees it, and staged for the
// chunked path. Staging opens the dialog server-side too; opening it twice
// is harmless.
//
// OPENING THE DIALOG AFTER THE PICK (Android + iOS "pick an image, nothing
// happens"). Two rules, each of which broke it once:
//
//   1. Do not read `input.files` in the change handler to decide whether
//      anything was picked. Browsers fire `input` before `change`, and
//      LiveView's window `input` listener (LiveUploader.trackFiles) copies
//      the files into its own registry and sets `input.value = null` for a
//      `multiple` input. By `change`, `input.files` is ALWAYS empty, so a
//      "files.length > 0" guard never opens the dialog. A `change` event
//      itself means the user picked something (cancel fires `cancel`).
//
//   2. Do not hold a reference to the input element. `live_file_input`
//      renders `id={@upload.ref}`, and the ref is random per LiveView mount,
//      so every socket rejoin (the tab was backgrounded, the phone slept, the
//      network blipped: routine on a phone) re-renders the input with a new
//      id and morphdom replaces the element. A listener bound to the old
//      element never fires again. The listener is delegated on `document`
//      and matches the input by selector at event time.

export const FILE_INPUT_SELECTOR = "#upload-send-form input[type=\"file\"]";

function findFileInput() {
  return document.querySelector(FILE_INPUT_SELECTOR);
}

function isUploadFileInput(el) {
  return !!(el && typeof el.matches === "function" && el.matches(FILE_INPUT_SELECTOR));
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
      // Delegated (rule 2 above) and unconditional (rule 1 above).
      this._onFileChange = (e) => {
        if (!isUploadFileInput(e.target)) return;
        this.pushEvent("upload_dialog_open", {});
      };
      document.addEventListener("change", this._onFileChange);
    }
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick, { capture: true });
    }
    if (this._onFileChange) {
      document.removeEventListener("change", this._onFileChange);
    }
  },
};

export default UploadButton;
