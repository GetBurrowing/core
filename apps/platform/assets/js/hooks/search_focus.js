// SearchFocus hook: search-forward entry for a search field that sits above
// a scrolling list. Renamed from DrawerSearchFocus (task 01a1557a-8562
// stage 3) when the phone Chat list's search sheet became its third user,
// after the mobile drawer and the external switcher.
//
// Attached to the search input. Two responsibilities:
//
// 1. Focus-on-search-entry: when the open was declared as a search, the
//    server mirrors it onto this element as data-search-intent="true" and the
//    field is focused on mount. Focus is done HERE, not via the HTML
//    `autofocus` attribute, because autofocus no-ops on iOS Safari when the
//    element renders after a LiveView round-trip, outside the original tap's
//    gesture chain. Accepted degradation on iOS: a visible focus ring without
//    the soft keyboard raising, still one tap from typing. preventScroll so
//    focusing never yanks the freshly opened surface.
//
// 2. Blur-on-list-scroll: a touchstart on the list under the field blurs the
//    input, so one swipe drops the soft keyboard and returns the full list.
//    The list is NAMED by the input itself, `data-blur-on-scroll="<id>"`:
//    each surface has its own scroller (`external-switcher-list`,
//    `chat-list-search-results`), and a hard-coded
//    id would leave every surface but one with a keyboard that never drops.
//    No attribute, or an id that is not in the document, means no blur: the
//    hook does nothing rather than throw.
const SearchFocus = {
  mounted() {
    if (this.el.dataset.searchIntent === "true") {
      this.el.focus({ preventScroll: true })
    }

    const listId = this.el.dataset.blurOnScroll
    this._list = listId ? document.getElementById(listId) : null
    this._onListTouchStart = () => this.el.blur()

    if (this._list) {
      // Passive: we never preventDefault, scrolling must stay native.
      this._list.addEventListener("touchstart", this._onListTouchStart, {
        passive: true,
      })
    }
  },

  destroyed() {
    if (this._list) {
      this._list.removeEventListener("touchstart", this._onListTouchStart)
    }
  },
}

export default SearchFocus
