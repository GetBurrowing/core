const ResizableSidebar = {
  mounted() {
    const saved = localStorage.getItem("suite:sidebar_width");
    const initialWidth = saved ? parseInt(saved, 10) : 208;
    this.el.style.width = initialWidth + "px";

    this._handle = this.el.querySelector("[data-drag-handle]");
    if (!this._handle) return;

    this._onMouseDown = (e) => {
      e.preventDefault();
      this._startX = e.clientX;
      this._startWidth = this.el.offsetWidth;
      document.body.classList.add("sidebar-resizing");
      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    };

    this._onMouseMove = (e) => {
      const delta = e.clientX - this._startX;
      const newWidth = Math.min(480, Math.max(160, this._startWidth + delta));
      this.el.style.width = newWidth + "px";
    };

    this._onMouseUp = () => {
      document.body.classList.remove("sidebar-resizing");
      document.removeEventListener("mousemove", this._onMouseMove);
      document.removeEventListener("mouseup", this._onMouseUp);
      localStorage.setItem("suite:sidebar_width", parseInt(this.el.style.width, 10));
    };

    this._handle.addEventListener("mousedown", this._onMouseDown);
  },

  destroyed() {
    if (this._handle) {
      this._handle.removeEventListener("mousedown", this._onMouseDown);
    }
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    document.body.classList.remove("sidebar-resizing");
  },
};

export default ResizableSidebar;
