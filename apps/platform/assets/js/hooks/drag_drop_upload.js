// DragDropUpload hook — drag-and-drop file upload for the chat area.
// Attaches to the chat column div; shows an overlay on dragover,
// queues files into LiveView's upload system on drop, and opens the
// staging dialog.
const DragDropUpload = {
  mounted() {
    this._dragCounter = 0;

    // Build overlay element (hidden by default)
    this._overlay = document.createElement("div");
    this._overlay.className =
      "drag-drop-overlay hidden absolute inset-0 z-50 flex items-center justify-center " +
      "bg-base-100/80 backdrop-blur-sm border-2 border-dashed border-primary rounded-lg " +
      "pointer-events-none transition-opacity duration-150";
    this._overlay.innerHTML =
      '<div class="flex flex-col items-center gap-2 text-base-content/70">' +
      '<svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">' +
      '<path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />' +
      "</svg>" +
      '<span class="text-lg font-medium">Drop files to upload</span>' +
      "</div>";

    // Ensure the hooked element is positioned so the overlay anchors correctly
    const position = getComputedStyle(this.el).position;
    if (position === "static") {
      this.el.style.position = "relative";
    }
    this.el.appendChild(this._overlay);

    this._onDragEnter = (e) => {
      e.preventDefault();
      this._dragCounter++;
      if (this._dragCounter === 1) {
        this._overlay.classList.remove("hidden", "opacity-0");
        this._overlay.classList.add("opacity-100");
      }
    };

    this._onDragOver = (e) => {
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    };

    this._onDragLeave = (e) => {
      e.preventDefault();
      this._dragCounter--;
      if (this._dragCounter <= 0) {
        this._dragCounter = 0;
        this._hideOverlay();
      }
    };

    this._onDrop = (e) => {
      e.preventDefault();
      this._dragCounter = 0;
      this._hideOverlay();

      const files = Array.from(e.dataTransfer.files);
      if (files.length === 0) return;

      // Queue files into LiveView's upload channel
      this.uploadTo(this.el, "attachments", files);

      // Tell the server to open the staging dialog
      this.pushEvent("show_upload_dialog", {});
    };

    this.el.addEventListener("dragenter", this._onDragEnter);
    this.el.addEventListener("dragover", this._onDragOver);
    this.el.addEventListener("dragleave", this._onDragLeave);
    this.el.addEventListener("drop", this._onDrop);
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this._onDragEnter);
    this.el.removeEventListener("dragover", this._onDragOver);
    this.el.removeEventListener("dragleave", this._onDragLeave);
    this.el.removeEventListener("drop", this._onDrop);
    if (this._overlay && this._overlay.parentNode) {
      this._overlay.parentNode.removeChild(this._overlay);
    }
  },

  _hideOverlay() {
    this._overlay.classList.add("opacity-0");
    // Wait for transition then fully hide
    setTimeout(() => {
      this._overlay.classList.add("hidden");
      this._overlay.classList.remove("opacity-100");
    }, 150);
  },
};

export default DragDropUpload;
