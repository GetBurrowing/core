// DrawerSearchFocus hook — search-forward entry for the mobile
// Conversations drawer (mobile channel search Stage 2).
//
// Attached to the drawer's search input. Two responsibilities:
//
// 1. Focus-on-search-entry: when the drawer open was declared as a search
//    (the pills-strip magnifying glass sets phx-value-intent="search";
//    the server mirrors it onto this element as data-search-intent), focus
//    the field on mount. Focus is done HERE, not via the HTML `autofocus`
//    attribute, because autofocus no-ops on iOS Safari when the element
//    renders after a LiveView round-trip — outside the original tap's
//    gesture chain. Accepted graceful degradation on iOS: a visible focus
//    ring without the soft keyboard raising — still one tap from typing.
//    preventScroll so focusing never yanks the freshly-opened drawer.
//
// 2. Blur-on-list-scroll: a touchstart on the section list blurs the input
//    so one swipe drops the soft keyboard and returns the full browse list.
//    This is what makes focus-on-entry safe on a surface that doubles as
//    the browse view — the keyboard never traps the user.
const DrawerSearchFocus = {
  mounted() {
    if (this.el.dataset.searchIntent === "true") {
      this.el.focus({ preventScroll: true });
    }

    this._list = document.getElementById("mobile-section-list");
    this._onListTouchStart = () => this.el.blur();
    if (this._list) {
      // Passive: we never preventDefault — scrolling must stay native.
      this._list.addEventListener("touchstart", this._onListTouchStart, {
        passive: true,
      });
    }
  },

  destroyed() {
    if (this._list) {
      this._list.removeEventListener("touchstart", this._onListTouchStart);
    }
  },
};

export default DrawerSearchFocus;
