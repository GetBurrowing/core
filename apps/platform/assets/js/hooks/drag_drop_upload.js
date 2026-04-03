// DragDropUpload hook — drag-and-drop + paste file upload for the chat area.
// Attaches to the chat column div; shows a styled drag-hint overlay on dragover,
// queues files into LiveView's upload system on drop/paste, and opens the
// staging dialog.
const DragDropUpload = {
  mounted() {
    this._dragCounter = 0;

    // Build drag-hint overlay (reference design)
    this._overlay = document.createElement("div");
    this._overlay.className = "drag-hint";
    this._overlay.innerHTML =
      '<div class="drag-hint-box">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>' +
      '<div class="drag-hint-title">Drop to upload images</div>' +
      '<div class="drag-hint-sub">Opens image share panel</div>' +
      "</div>";

    // Build paste toast
    this._pasteToast = document.createElement("div");
    this._pasteToast.className = "paste-toast";
    this._pasteToast.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 4h2a2 2 0 012 2v14a2 2 0 01-2 2H6a2 2 0 01-2-2V6a2 2 0 012-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/></svg>' +
      '<span class="paste-toast-text"><strong>Image pasted</strong> — opening upload panel</span>';

    // Ensure the hooked element is positioned so overlays anchor correctly
    const position = getComputedStyle(this.el).position;
    if (position === "static") {
      this.el.style.position = "relative";
    }
    this.el.appendChild(this._overlay);
    this.el.appendChild(this._pasteToast);

    this._onDragEnter = (e) => {
      e.preventDefault();
      this._dragCounter++;
      if (this._dragCounter === 1) {
        this._overlay.classList.add("visible");
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
        this._overlay.classList.remove("visible");
      }
    };

    this._onDrop = (e) => {
      e.preventDefault();
      this._dragCounter = 0;
      this._overlay.classList.remove("visible");

      const files = Array.from(e.dataTransfer.files);
      if (files.length === 0) return;

      // Queue files into LiveView's upload channel
      this.uploadTo(this.el, "attachments", files);

      // Tell the server to open the staging dialog
      this.pushEvent("show_upload_dialog", {});
    };

    this._onPaste = (e) => {
      const items = e.clipboardData && e.clipboardData.items;
      if (!items) return;

      const imageFiles = [];
      for (let i = 0; i < items.length; i++) {
        if (items[i].type.startsWith("image/")) {
          const file = items[i].getAsFile();
          if (file) imageFiles.push(file);
        }
      }

      if (imageFiles.length === 0) return;

      // Show paste toast briefly
      this._pasteToast.classList.add("visible");
      clearTimeout(this._pasteToastTimer);
      this._pasteToastTimer = setTimeout(() => {
        this._pasteToast.classList.remove("visible");
      }, 2500);

      // Queue pasted images and open dialog
      this.uploadTo(this.el, "attachments", imageFiles);
      this.pushEvent("show_upload_dialog", {});
    };

    this.el.addEventListener("dragenter", this._onDragEnter);
    this.el.addEventListener("dragover", this._onDragOver);
    this.el.addEventListener("dragleave", this._onDragLeave);
    this.el.addEventListener("drop", this._onDrop);
    this.el.addEventListener("paste", this._onPaste);
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this._onDragEnter);
    this.el.removeEventListener("dragover", this._onDragOver);
    this.el.removeEventListener("dragleave", this._onDragLeave);
    this.el.removeEventListener("drop", this._onDrop);
    this.el.removeEventListener("paste", this._onPaste);
    clearTimeout(this._pasteToastTimer);
    if (this._overlay && this._overlay.parentNode) {
      this._overlay.parentNode.removeChild(this._overlay);
    }
    if (this._pasteToast && this._pasteToast.parentNode) {
      this._pasteToast.parentNode.removeChild(this._pasteToast);
    }
  },
};

export default DragDropUpload;
