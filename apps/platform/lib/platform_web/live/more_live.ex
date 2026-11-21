defmodule PlatformWeb.MoreLive do
  @moduledoc """
  `/more`: the More destinations as a page in the content area (task 01a1fc7f
  stage 2), the open iPhone Duo's More tab.

  On the open (unfolded) Duo the More sheet, a fixed overlay outside the main
  pane, lingered over the next tab for a round trip plus its exit animation:
  a tab tap swaps only `main[data-scroll-container]` on the click frame
  (`assets/js/hooks/tab_switch_cache.js`). A page inside main is exited by
  that same swap, so on the open Duo `assets/js/lib/duo_more_page.js` routes
  More taps here instead of opening the sheet. The closed Duo and every other
  phone keep the sheet; nothing links here on them.

  The page is the sheet's own body, `PlatformWeb.Components.MoreSheet.more_entries/1`
  (same rows, order, row styling and current check), laid flat on the tab
  roots' ground (`bg-base-200`, as the Inbox phone root) under a tab-root
  header: an `<h1>` "More" in the Inbox root's treatment and no back control.
  None of the sheet's chrome: no handle, scrim, close button, drag to dismiss
  or scroll cue. Labels may wrap to two lines rather than truncate.

  `bottom_rail/1` marks More selected on this path (so the native strip does
  too, through `data-active-key`), and `TabSwitchCache.current_key/1` files a
  snapshot under "more" when it is left.

  Ungated like Settings (`PlatformWeb.ModuleGate`'s `@ungated` says why): each
  row is already filtered through the actor's access by the rows builder.
  At lg and up the same list renders; the desktop rail covers the same job.
  """
  use PlatformWeb, :live_view

  import PlatformWeb.Components.MoreSheet, only: [more_entries: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "More")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="more-page"
      data-role="more-page"
      class="more-page h-full overflow-y-auto overscroll-contain bg-base-200 text-base-content pb-4 clears-tab-bar"
    >
      <div class="mx-auto w-full max-w-lg">
        <header class="flex h-13 shrink-0 items-center gap-2.5 px-4">
          <h1 class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content">More</h1>
        </header>

        <div class="px-2">
          <.more_entries
            gaming={assigns[:gaming_experience?] == true}
            current_user={assigns[:current_user]}
            user={assigns[:current_user_record]}
            current_path={assigns[:current_path]}
            root_user={assigns[:root_user] == true}
            access_scope={assigns[:access_scope]}
          />
        </div>
      </div>
    </div>
    """
  end
end
