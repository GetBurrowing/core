defmodule PlatformWeb.ChatLive.Partials.MobileBrowser do
  @moduledoc """
  The internal mobile channel-browser drawer — `<div id="mobile-channel-browser">`
  and everything inside it.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail` and
  `ChatLive.Partials.Rail` (ADR 0035): function components, no state, each
  taking a declared set of attrs. Extracted from `chat_live.html.heex` in task
  01a0312e stage 4 as a PURE MOVE — every `id`, `phx-hook`, `phx-click`,
  `phx-change`, `phx-value-*`, `data-*` and `aria-*` sits on the element it sat
  on before, and the rendered HTML was diffed across 19 fixture states (every
  branch this drawer has) to prove it.

  It is deliberately NOT part of `Rail`. The drawer is parity-with-the-rail in
  copy and behaviour but a genuinely independent DOM tree: its own hooks
  (`SectionReorderTouch`, `RowReorderTouch`, `DrawerSearchFocus`), its own
  search state, and its own entry into personal-edit mode. One module per
  navigation surface means a mobile regression is revertable without touching
  desktop.

  The regions, in drawer order:

    * `mobile_browser/1` — the overlay shell and its gate, the header (mask
      toggle, mobile Edit entry, close), the mask mode strip, the
      `#mobile-section-list` nav and `#mobile-row-reorder-scope` hook element,
      the edit-mode explainer and reorder announcer, the Archived group, the
      no-matches state, the account-empty state and the `+ New channel` foot
    * `drawer_search/1` — the search row and its `#drawer-search-input`
    * `drawer_pinned/1` — the Pinned block (browse rows and edit rows)
    * `drawer_dms/1` — the Direct Messages section
    * `drawer_sections/1` — the sub-org sections, their reorder chrome and
      their channel rows

  ## WHY THE SPLIT STOPS WHERE IT DOES

  The four one-shot children left in `mobile_browser/1` — the explainer, the
  announcer, Archived, no-matches, the empty state and the foot button — are
  each a single `:if`-gated element with no internal structure. A named
  component per element would be a rename, not a decomposition. The three
  extracted lists are the ones with a `:for`, a filter and a mode branch.

  ## THE HOOK-IDENTITY RULE

  Three live JS hooks are bound BY ID in this region — `SectionReorderTouch`
  on `#mobile-section-list`, `RowReorderTouch` on `#mobile-row-reorder-scope`,
  and `DrawerSearchFocus` on `#drawer-search-input`. The search form is
  `phx-change` (NOT `phx-keyup`), `#drawer-search-input` carries
  `data-search-intent`, and both hook roots carry `data-search-active`. A
  binding left behind on a wrapper, or an id duplicated because the shell kept
  one and a component added another, renders a drawer that looks perfect and
  does nothing — and every markup assertion still passes. So: attrs are
  forwarded, elements are not re-parented, and no component introduces a
  wrapper element of its own.

  The drawer also deliberately sets NO html `id` on its sub-org sections: the
  desktop rail is in the same DOM (hidden via `lg:flex`) and already owns
  `id="section-<section-id>"`.

  ## THE MASKING ATTRS ARE NOT OPTIONAL

  `ChatLive.masked_space_name/2` reads `:sidebar_sections`, `:mask_names?` and
  `:revealed_section_ids` out of the map it is handed, through TOLERANT
  `assigns[...]` access. It stays in `PlatformWeb.ChatLive`, so the components
  that call it declare those three as attrs and pass a `@mask_assigns` map
  built with `Map.take/2` — the same pattern `Rail` and `ExternalRail` use.

  A component that FORGETS to declare them does not crash and does not render
  blank — it silently renders REAL WORKSPACE NAMES with the mask switched on.
  That is a privacy failure that passes every markup assertion. Here the
  declaration is load-bearing in `mobile_browser/1` (the Archived rows, and
  the `SidebarMask.context/3` the no-matches gate is computed against) and in
  `drawer_sections/1`, which builds the same context for its headings, both
  move buttons, the drag handle and the channel rows.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.Partials, only: [row_actions_control: 1]

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [
      drawer_filter_dms: 3,
      drawer_filter_pinned: 3,
      drawer_filter_sections: 3,
      drawer_agents_visible?: 2,
      drawer_no_matches?: 7,
      pinned_row_label: 3,
      sidebar_row_label: 2,
      unread_label: 1
    ]

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]
  import PlatformWeb.Components.EmptyState, only: [empty_state: 1]

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive

  # The exact keys `ChatLive.masked_space_name/2` reads. Named once so a
  # component that needs the mask takes the whole set or none of it — a
  # partial take is the silent-unmasking bug described in the moduledoc.
  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  attr(:mobile_browser_open, :boolean, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  attr(:sidebar_edit, :boolean, required: true)
  # The three masking attrs. Declared here because the Archived rows call
  # `ChatLive.masked_space_name/2` and the no-matches gate builds a
  # `SidebarMask.context/3` — both read these through tolerant access, so a
  # missing declaration unmasks silently rather than failing.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:agents_block, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:drawer_search_intent, :any, required: true)
  attr(:drawer_reorder_announcement, :string, required: true)

  @doc """
  The mobile channel browser overlay.

  The `@mobile_browser_open and !@embedded and !@external?` gate travelled
  INTO the component with the markup (same convention as `Rail.rail/1` and
  `ExternalRail.external_rail/1`), so the call site states no render condition
  of its own — one gate, one place. It is suppressed when embedded, and for
  external users (rbac-external-users M5): its sectioned org-tree browser,
  new-channel affordance and scope pills are all internal-discovery chrome,
  and `ExternalRail.external_mobile_switcher/1` is the single flat surface
  those users get instead.
  """
  def mobile_browser(assigns) do
    assigns = assign(assigns, :mask_assigns, Map.take(assigns, @mask_keys))

    ~H"""
    <div
      :if={@mobile_browser_open and !@embedded and !@external?}
      id="mobile-channel-browser"
      class="fixed inset-0 z-40 flex flex-col bg-base-100 lg:hidden safe-area-x"
    >
      <%!-- Masking context for the drawer (task 01a00c66 stage 3). Derived
           from the FULL `@sidebar_sections` exactly as the rail's is, so a
           section carries the SAME letter on both breakpoints and an active
           search cannot relabel what remains. Built once and threaded to
           every derived string below — the header text, the section's own
           aria-label, both move buttons, the touch drag handle and the
           channel rows — because the way this ships broken is one missed
           site leaving the real name in the accessibility tree under a
           heading that reads `Workspace B`. --%>
      <% drawer_mask_ctx =
        Platform.Chat.SidebarMask.context(
          @sidebar_sections,
          @mask_names?,
          @revealed_section_ids
        ) %>
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4 safe-area-top">
        <p class="text-sm font-semibold">Conversations</p>
        <div class="flex items-center gap-1">
          <%!-- Screen-share name masking on the DRAWER (task 01a00c66 stage 3).
               The SAME control and the SAME event as the desktop rail, not a
               reduced variant: the rail renders at two breakpoints and they
               have diverged before, and a phone that can only reveal — or only
               mask — is the failure this stage exists to prevent. Sized to the
               drawer's 44px touch floor rather than the rail's 16px glyph. --%>
          <button
            type="button"
            phx-click="toggle_mask_names"
            phx-value-masked={to_string(!@mask_names?)}
            class="channel-mask-toggle flex items-center justify-center min-h-11 min-w-11 rounded-lg text-base-content/70 hover:bg-base-300 hover:text-base-content"
            aria-pressed={to_string(@mask_names?)}
            aria-label="Hide workspace names for sharing"
          >
            <span
              class={[if(@mask_names?, do: "hero-eye-slash", else: "hero-eye"), "size-5"]}
              aria-hidden="true"
            >
            </span>
          </button>
          <%!-- Mobile entry into personal-edit mode (chat sidebar mobile
               Stage 3). Stage 2's report flagged that `@sidebar_edit` — which
               gates the lock affordances AND this stage's drag handles — was
               only reachable via the desktop rail's kebab menu, hidden on
               phones. This button closes that gap using the SAME
               `toggle_sidebar_edit` event (one edit mode, two entry points).
               Admin-edit stays desktop-only chrome. --%>
          <button
            type="button"
            phx-click="toggle_sidebar_edit"
            class="flex items-center justify-center min-h-11 min-w-11 px-3 rounded-lg text-sm font-medium text-base-content/70 hover:bg-base-300 hover:text-base-content"
            aria-pressed={to_string(@sidebar_edit)}
            aria-label={if @sidebar_edit, do: "Done editing layout", else: "Edit layout"}
          >
            {if @sidebar_edit, do: "Done", else: "Edit"}
          </button>
          <button
            phx-click="close_mobile_browser"
            class="flex items-center justify-center size-10 rounded-lg text-base-content/60 hover:bg-base-300 hover:text-base-content"
            aria-label="Close"
          >
            <span class="hero-x-mark size-5"></span>
          </button>
        </div>
      </header>

      <.drawer_search drawer_query={@drawer_query} drawer_search_intent={@drawer_search_intent} />

      <%!-- The mode strip, identical in copy and colour to the rail's (task
           01a00c66 stage 3). It is the signal on this breakpoint too: the icon
           swap is a few pixels of stroke either way, and the phone is the
           likelier device to be mirrored into a call. --%>
      <div :if={@mask_names?} class="channel-mask-strip">
        <span class="hero-eye-slash size-3.5 flex-shrink-0" aria-hidden="true"></span>
        <span class="min-w-0 flex-1">
          {if MapSet.size(@revealed_section_ids) > 0,
            do: "Names hidden · #{MapSet.size(@revealed_section_ids)} showing",
            else: "Names hidden for sharing"}
        </span>
        <button type="button" phx-click="remask_all" class="channel-mask-strip-action">
          Show all
        </button>
      </div>

      <%!-- Sectioned mobile channel browser — parity with the desktop rail
           (chat sidebar mobile Stage 1). Renders the SAME already-computed
           data desktop consumes — `@channel_sections.pinned` / `.dms` and the
           resolver-driven `@sidebar_sections` sub-org list — in the same
           top-to-bottom order: Pinned (locked at top, only when non-empty),
           Direct Messages (locked directly under Pinned), then the sub-org
           sections alphabetically. No new server assign or query — the overlay
           just re-renders the existing assigns with the overlay's touch-sized
           rows. Sub-org sections carry `data-section-id` + reorderable markers
           for the later touch-reorder stage; Pinned + DMs are locked
           (`data-section-reorderable="false"`). We deliberately DON'T set an
           HTML `id` on the sub-org sections: the desktop rail (present in the
           same DOM, hidden via `lg:flex`) already owns `id="section-#{id}"`, so
           a duplicate id here would break LiveView DOM patching. The drawer
           still closes only via the explicit close control + backdrop tap —
           no swipe-to-dismiss.

           SectionReorderTouch (Stage 3) owns long-press + drag reorder for
           the sub-org sections via Pointer Events — the desktop
           SectionReorder hook is HTML5 DnD and never fires on touch. The id
           is required for the hook and must differ from the desktop nav's
           `chat-section-list` (both are in the DOM at once). --%>
      <nav
        id="mobile-section-list"
        phx-hook="SectionReorderTouch"
        data-search-active={to_string(@drawer_query != "")}
        class="flex-1 overflow-y-auto py-2"
        aria-label="Channel sections"
      >
        <%!-- RowReorderTouch (channel-row reorder Stage 2) needs its own
             hook element — one element = one phx-hook, and the nav above is
             owned by SectionReorderTouch. This wrapper is that element; it
             deliberately spans the same subtree so both hooks see every
             pointerdown, each arming only on its own handle class
             (.channel-section-drag-handle vs .channel-row-drag-handle).
             data-search-active mirrors the nav's — same guard rail, read by
             the shared engine on its own root. --%>
        <div
          id="mobile-row-reorder-scope"
          phx-hook="RowReorderTouch"
          data-search-active={to_string(@drawer_query != "")}
        >
          <%!-- Edit-mode explainer (2026-07-09): the ▲▼ buttons are visible
             and self-explanatory, but the hold-to-drag gesture has no visual
             affordance beyond the ☰ glyph — one muted line teaches it. --%>
          <p
            :if={@sidebar_edit && @drawer_query == ""}
            class="px-4 pb-2 text-xs text-base-content/40"
          >
            Reorder with the arrows, or press and hold ☰ to drag.
          </p>
          <%!-- Reorder announcements for screen readers (Stage 3). The
             region renders (empty) as soon as edit mode opens — aria-live
             only announces CHANGES to an existing region, so it must be in
             the DOM before the first move updates it. --%>
          <div :if={@sidebar_edit} class="sr-only" aria-live="polite">
            {@drawer_reorder_announcement}
          </div>
          <%!-- Agents block FIRST, so drawer order matches rail order
               (Agents, Pinned, DMs, sub-orgs). Mirrored from
               `Rail.agents_block/1` rather than called into it: the drawer is
               a deliberately independent DOM tree (see this module's
               moduledoc), and its rows carry the drawer's touch-target
               geometry, not the rail's 32px row. --%>
          <.drawer_agents
            agents_block={@agents_block}
            active_space={@active_space}
            unread_counts={@unread_counts}
            drawer_query={@drawer_query}
          />

          <.drawer_pinned
            sidebar_edit={@sidebar_edit}
            drawer_query={@drawer_query}
            channel_sections={@channel_sections}
            pinned_task_spaces={@pinned_task_spaces}
            active_space={@active_space}
            unread_counts={@unread_counts}
            user_id={@user_id}
          />

          <.drawer_dms
            sidebar_edit={@sidebar_edit}
            drawer_query={@drawer_query}
            channel_sections={@channel_sections}
            active_space={@active_space}
            unread_counts={@unread_counts}
            user_id={@user_id}
          />

          <.drawer_sections
            restricted_channel_ids={@restricted_channel_ids}
            sidebar_edit={@sidebar_edit}
            drawer_query={@drawer_query}
            sidebar_sections={@sidebar_sections}
            mask_names?={@mask_names?}
            revealed_section_ids={@revealed_section_ids}
            active_space={@active_space}
            unread_counts={@unread_counts}
          />

          <%!-- Archived channels (task 019e95ea stage 2) — same collapsed
             group as the desktop rail, driven by the same @archived_channels
             / @archived_open assigns. Hidden while a search is active: the
             drawer_filter_* helpers only know the active sections, and
             archived rows shouldn't surface as phantom search results. --%>
          <section
            :if={@archived_channels != [] and @drawer_query == ""}
            data-section-reorderable="false"
            aria-label="Archived channels"
          >
            <button
              type="button"
              class="flex w-full items-center gap-1.5 px-4 py-1 mt-2 text-left"
              phx-click="toggle_archived_section"
              aria-expanded={if @archived_open, do: "true", else: "false"}
              aria-controls="archived-channel-list-mobile"
            >
              <span class="hero-archive-box size-3.5 text-base-content/40"></span>
              <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                Archived
              </p>
              <span class="ml-auto text-base-content/40 text-xs">
                {if @archived_open, do: "▾", else: "▸"}
              </span>
            </button>
            <div :if={@archived_open} id="archived-channel-list-mobile">
              <%= for space <- @archived_channels do %>
                <%= if MapSet.member?(@restricted_channel_ids, space.id) do %>
                  <div
                    data-role="restricted-channel-row"
                    data-space-id={space.id}
                    aria-disabled="true"
                    class="flex items-center gap-3 px-4 py-3 text-sm text-base-content/50"
                  >
                    <span class="hero-lock-closed-mini size-4"></span>
                    <span class="truncate flex-1">{mask_name(@mask_assigns, space.name)}</span>
                    <span class="text-xs">Restricted, ask an admin</span>
                  </div>
                <% else %>
                  <.link
                    patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
                    phx-click="close_mobile_browser"
                    class={[
                      "flex items-center gap-3 px-4 py-3 text-sm transition-colors",
                      "text-base-content/50 hover:bg-base-200",
                      @active_space && @active_space.id == space.id &&
                        "bg-base-200 font-semibold"
                    ]}
                  >
                    <span class="hero-archive-box size-4 text-base-content/30"></span>
                    <span class="truncate flex-1">{mask_name(@mask_assigns, space.name)}</span>
                  </.link>
                <% end %>
              <% end %>
            </div>
          </section>

          <%!-- No-matches state (Stage 1) — ONLY for an active search that
             matched nothing; the account-empty state below stays reserved
             for a genuinely conversation-less account. The likeliest miss is
             searching a PERSON's name (that's the other search), so the dead
             end hands off to the new-conversation people picker rather than
             apologizing. --%>
          <div
            :if={
              @drawer_query != "" and
                drawer_no_matches?(
                  ChatLive.pinned_rail_entries(@channel_sections.pinned, @pinned_task_spaces),
                  @channel_sections,
                  @sidebar_sections,
                  @drawer_query,
                  @user_id,
                  drawer_mask_ctx,
                  @agents_block
                )
            }
            class="flex flex-col items-center gap-3 px-6 py-10 text-center"
          >
            <span class="hero-magnifying-glass size-8 text-base-content/30" aria-hidden="true"></span>
            <p class="text-sm font-medium">No matches for “{@drawer_query}”</p>
            <p class="text-sm text-base-content/50">
              Check the spelling, or start a new conversation.
            </p>
            <div class="flex items-center gap-2 mt-1">
              <button
                type="button"
                phx-click={JS.push("new_conversation_open") |> JS.push("close_mobile_browser")}
                class="flex items-center justify-center min-h-11 px-4 rounded-lg bg-base-200 border border-base-content/10 text-sm font-medium hover:bg-base-300"
              >
                New conversation
              </button>
              <button
                type="button"
                phx-click="drawer_search_clear"
                class="flex items-center justify-center min-h-11 px-4 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-200"
              >
                Clear search
              </button>
            </div>
          </div>

          <%!-- Empty state per docs/design-system/03-voice.md §5.1 — mobile
             combined view (no channels AND no DMs). Chip event is a JS
             chain so opening the new-conversation flow also closes the
             mobile browser overlay. Suppressed while a search is active —
             the no-matches state above owns that case. --%>
          <.empty_state
            :if={@channels == [] and @dm_conversations == [] and @drawer_query == ""}
            variant={:conversational}
          >
            <:system_message>— no conversations yet —</:system_message>
            <:body>
              Start your first conversation. Pick a channel or DM someone in your space.
            </:body>
            <:chips
              label="+ Start your first conversation"
              event={JS.push("new_conversation_open") |> JS.push("close_mobile_browser")}
            />
          </.empty_state>
        </div>
      </nav>

      <%!-- "+ New channel" — pinned overlay chrome, mirroring the desktop
           rail's foot button. Preserves the new-channel entry point that the
           old flat "Channels" header used to host; the JS chain closes the
           overlay as the create flow opens. --%>
      <%!-- pt-3 + .mobile-drawer-footer-safe (NOT py-3 + .safe-area-bottom):
           the safe-area utility REPLACES padding-bottom with the device
           inset, which is 0 on desktop — in a desktop PWA the window's
           rounded corners then clip the label (Marlowe, 2026-07-05). The
           footer class adds the inset ON TOP of the normal padding. --%>
      <button
        phx-click={JS.push("new_channel_open") |> JS.push("close_mobile_browser")}
        aria-label="New channel"
        class="flex-shrink-0 flex items-center gap-2 w-full border-t border-edge px-4 pt-3 text-sm text-base-content/70 hover:text-primary hover:bg-base-200 transition-colors mobile-drawer-footer-safe"
      >
        <span class="hero-plus size-5"></span>
        <span>New channel</span>
      </button>
    </div>
    """
  end

  attr(:drawer_query, :string, required: true)
  attr(:drawer_search_intent, :any, required: true)

  @doc """
  The drawer's search row.

  `phx-change` on the form and `phx-hook="DrawerSearchFocus"` +
  `data-search-intent` on `#drawer-search-input` are the whole contract here;
  see the inline comments for why each is what it is.
  """
  def drawer_search(assigns) do
    ~H"""
    <%!-- Drawer search (mobile channel search Stage 1). Pinned row BETWEEN
         the header and the scrolling list — the h-12 header is already full
         (title + Edit/Done + X) and touch targets need breathing room.
         Filters the rendered list as you type via the drawer_filter_*
         helpers; find-verbs ("Find a channel or DM") to stay verbally
         distinct from the DM "+" people-picker, which STARTS conversations.
         text-base is load-bearing: anything under 16px makes iOS auto-zoom
         the viewport on focus. Stable id so LiveView patches preserve
         focus/cursor while the list under it re-renders. --%>
    <div class="flex-shrink-0 px-4 py-2 border-b border-edge" role="search">
      <%!-- phx-change (NOT phx-keyup): change fires for every way text can
           enter the field — typing, paste, iOS dictation, the native
           type=search clear — where keyup only sees physical keys.
           phx-submit reuses the same handler so the iOS "go" key doesn't
           fall through to a full-page form POST. --%>
      <form class="relative" phx-change="drawer_search" phx-submit="drawer_search">
        <span
          class="hero-magnifying-glass absolute left-3 top-1/2 -translate-y-1/2 size-4 text-base-content/40"
          aria-hidden="true"
        >
        </span>
        <%!-- DrawerSearchFocus (Stage 2): focuses this field on mount when
             the open carried search intent (data attr below), and blurs it
             when the user starts scrolling the list so one swipe drops the
             keyboard. Focus is hook-driven, NOT the HTML autofocus attr —
             autofocus no-ops on iOS when the render lands after a LiveView
             round-trip, outside the tap's gesture chain. --%>
        <input
          id="drawer-search-input"
          type="search"
          name="value"
          value={@drawer_query}
          phx-hook="DrawerSearchFocus"
          data-search-intent={to_string(@drawer_search_intent)}
          phx-debounce="150"
          placeholder="Find a channel or DM"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="none"
          spellcheck="false"
          enterkeyhint="go"
          aria-label="Find a channel or direct message"
          class="w-full h-11 rounded-lg bg-base-200 border border-base-content/10 pl-9 pr-11 text-base placeholder:text-base-content/40 focus:border-primary focus:outline-none"
        />
        <button
          :if={@drawer_query != ""}
          type="button"
          phx-click="drawer_search_clear"
          class="absolute right-0 top-1/2 -translate-y-1/2 flex items-center justify-center min-h-11 min-w-11 text-base-content/50 hover:text-base-content"
          aria-label="Clear search"
        >
          <span class="hero-x-mark size-4"></span>
        </button>
      </form>
    </div>
    """
  end

  attr(:agents_block, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:drawer_query, :string, required: true)

  @doc """
  The Agents block, mirrored into the drawer (task 01a0b491 v2 stage 1).

  Renders NOTHING when `@agents_block` is nil — flag off, or no space carries
  a goal. No label, no placeholder, no empty container, no empty `<section>`;
  the same rule `drawer_pinned/1` applies to its own empty case.

  ROW SHAPE IS THE DRAWER'S, NOT THE DESKTOP RAIL'S. Geometry is copied from
  the pinned BROWSE row below (`px-4 py-3`, the drawer's unread pill), because
  the difference between the two surfaces is a touch-target decision and that
  is the one honest reason a mobile row may differ from its desktop twin.

  NO CHROME otherwise, inherited from `Rail.agents_block/1`: no icon beside
  the label, no surface fill, no border box, no badge, no second line, no
  collapse control. Weight comes from exactly one thing — the leader's avatar
  at 20px in the `w-5` glyph column the pinned rows already reserve, ringed in
  `ring-focus-ring` (the same ring as the desktop row, and for the same
  measured reason; see `Rail.agents_block/1`). Empty column when no leader
  resolves, never a stand-in face: it would claim accountability nobody holds.

  TAP TARGET. The link, not the ring, is the hit area: the whole row is the
  `<.link>`, and `py-3` around a 20px line holds it at 44px tall (measured in
  Chrome at 375px, task 01a0ca8b stage 2). The name truncates and the unread
  pill never does (`min-w-0 flex-1 truncate` / `shrink-0 whitespace-nowrap`).

  NO `row_actions_control`. The neighbouring pinned channel rows carry one and
  this row does not: parity with the DESKTOP AGENTS ROW wins over parity with
  the adjacent drawer row, because the sheet's verbs (pin/mute/leave) are all
  wrong for a block whose membership is derived, not chosen.

  SEARCH. Suppressed when `@drawer_query` matches neither nothing nor this
  space's name, via the same predicate `drawer_no_matches?/7` consults — a row
  rendering beside the "No matches" copy is the defect already shipped once on
  this surface for pinned tasks.
  """
  def drawer_agents(assigns) do
    ~H"""
    <%= if drawer_agents_visible?(@agents_block, @drawer_query) do %>
      <% space = @agents_block.space %>
      <% leader = @agents_block.leader %>
      <section data-role="agents-drawer-block" aria-label="Agents" class="mb-2">
        <div class="flex items-center" data-role="drawer-row-wrap" data-space-id={space.id}>
          <.link
            patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
            phx-click="close_mobile_browser"
            data-role="agents-drawer-row"
            class={[
              "flex items-center gap-3 flex-1 min-w-0 px-4 py-3 text-sm transition-colors",
              "hover:bg-base-200",
              @active_space && @active_space.id == space.id &&
                "bg-base-200 text-primary font-semibold"
            ]}
          >
            <span
              class="w-5 shrink-0 flex items-center justify-center"
              data-role="agents-drawer-row-glyph"
            >
              <.agent_avatar
                :if={leader}
                name={leader.name}
                avatar_url={leader.avatar_url}
                size="xs"
                class="ring-2 ring-focus-ring"
                title={"#{leader.name} leads"}
              />
            </span>
            <span class="min-w-0 flex-1 truncate">{space.name}</span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="ml-1 shrink-0 whitespace-nowrap min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>
        </div>
      </section>
    <% end %>
    """
  end

  attr(:sidebar_edit, :boolean, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)

  @doc """
  The Pinned block — locked at the top, rendered only when non-empty.

  Renders no space `name` through the mask (pinned rows resolve their label
  through `pinned_row_label/3`), so it declares no masking attrs. If a masked
  string is ever added here, the three `@mask_keys` come with it.
  """
  def drawer_pinned(assigns) do
    ~H"""
    <%!-- Pinned — locked at the top, rendered only when non-empty
       (and, while searching, only when it has a match).

       ONE section, matching the desktop rail: pinned channels, pinned
       DMs and pinned task conversations in one list with one heading.
       It was two adjacent sections until 2026-08-10. A rename or a
       merge on one surface only is a change a phone user never sees. --%>
    <% pinned_rows =
      drawer_filter_pinned(
        ChatLive.pinned_rail_entries(@channel_sections.pinned, @pinned_task_spaces),
        @drawer_query,
        @user_id
      ) %>
    <section :if={pinned_rows != []} data-section-reorderable="false" aria-label="Pinned">
      <div class="flex items-center px-4 py-1">
        <%!-- Same label as the desktop block. Holds all three kinds. --%>
        <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Pinned
        </p>
        <%!-- Lock affordance (chat sidebar mobile Stage 2, Decision #5).
           Touch has no hover state to reveal that Pinned is locked to the
           top, so we surface an explicit hero-lock-closed icon in edit
           mode (`@sidebar_edit`, the same personal-edit mode that gates
           desktop section reorder). The SECTION drag handle stays omitted
           — mirroring desktop's data-section-reorderable="false" branch,
           which renders no .channel-section-drag-handle on locked
           sections.

           Copy revised (task 019fe987): this used to read "and can't be
           reordered", which is now false at row level. The block stays
           pinned to the top of the drawer; the rows inside it reorder. --%>
        <span
          :if={@sidebar_edit}
          class="channel-section-lock hero-lock-closed ml-auto size-3.5 text-base-content/40"
          aria-hidden="true"
          title="Pinned stays at the top of the list"
        >
        </span>
      </div>
      <%!-- EDIT-MODE pinned rows (task 019fe987). Both surfaces or
           neither: the parent task shipped a stage that wired the desktop
           rail and left the drawer rendering rows that could not do the
           thing, and it reached a human approval gate before anyone
           noticed.

           Shape copied from the sub-org edit rows directly below, so the
           drawer teaches ONE arranging convention. That means: the row
           stops being a link (a mis-tap would navigate and close the
           drawer, ejecting the user from the mode), the ▲▼ pair is
           persistent rather than revealed, boundary buttons are disabled
           rather than hidden, and the unread badge yields its right-edge
           slot to the reorder chrome because edit mode is a mode and
           counts are browse chrome.

           TASK ROWS STAY, and stay unarranged (Marlowe, 2026-08-12: "it's
           essentially two separate lists so makes me think to not
           commingle the interactions too much"). They render in the same
           list with the same glyph column and NO ▲▼ pair, so edit mode
           shows the block a phone user actually has rather than a
           filtered version of it. `move_index` is nil on exactly those
           rows.

           No ☰ drag handle here, unlike the sub-org rows. Touch drag is
           the desktop drag's twin and the arrows are the accessible path;
           the block is three to eight rows, where two taps does the job.
           If phone users reach for the gesture, adding it is a second
           mount of RowReorderTouch, not a new pattern.

           Search suppresses the mode: reordering a filtered view writes
           an order the user cannot see. Same guard the sub-org rows and
           the section handles use, and it is what keeps `move_index`
           contiguous — the indices describe the unfiltered block. --%>
      <%= if @sidebar_edit && @drawer_query == "" do %>
        <div
          :for={
            %{kind: kind, space: space, move_index: move_index, move_count: move_count} <-
              pinned_rows
          }
          class="flex items-center gap-3 px-4 py-3 text-sm"
          data-role={
            if kind == :task,
              do: "drawer-pinned-task-edit-row",
              else: "drawer-pinned-edit-row"
          }
          data-space-id={space.id}
        >
          <% row_label = pinned_row_label(kind, space, @user_id) %>
          <%!-- Same three-glyph column as the browse rows below and as the
               desktop rail, so a row does not change kind when the mode
               changes. --%>
          <%= case kind do %>
            <% :channel -> %>
              <span
                class="w-5 shrink-0 text-center text-base-content/60 text-lg"
                data-role="pinned-row-hash"
              >
                #
              </span>
            <% :dm -> %>
              <span class="w-5 shrink-0" data-role="pinned-row-indent" aria-hidden="true"></span>
            <% :task -> %>
              <span
                class="w-5 shrink-0 text-center"
                data-role="pinned-row-task-glyph"
                aria-hidden="true"
              >
                <span class="hero-clipboard-document-list-mini size-4 text-base-content/60"></span>
              </span>
          <% end %>
          <span class="truncate flex-1">{row_label}</span>
          <%!-- Boundaries are the row's place among the CONVERSATIONS
               (`move_index` against `move_count`), not among the block's
               rows. Counting the task rows above would leave the ▲
               enabled on the top conversation and point it at a
               destination it is not allowed to have. --%>
          <span :if={move_index != nil} class="channel-row-move-controls--touch">
            <button
              type="button"
              class="channel-row-move-button--touch"
              phx-click="move_pinned"
              phx-value-space_id={space.id}
              phx-value-direction="up"
              disabled={move_index == 0}
              data-role="pinned-move-up"
              aria-label={"Move #{row_label} up"}
              title="Move up"
            >
              <span class="hero-chevron-up size-4"></span>
            </button>
            <button
              type="button"
              class="channel-row-move-button--touch"
              phx-click="move_pinned"
              phx-value-space_id={space.id}
              phx-value-direction="down"
              disabled={move_index == move_count - 1}
              data-role="pinned-move-down"
              aria-label={"Move #{row_label} down"}
              title="Move down"
            >
              <span class="hero-chevron-down size-4"></span>
            </button>
          </span>
        </div>
      <% else %>
        <%!-- Row wrapper: SIBLING link + trailing control, so a tap on
           the control never bubbles into the anchor's navigation. A
           `<button>` nested in an `<a>` is invalid HTML, and LiveView
           binds click on `window` in the bubble phase, so a nested
           control would need a `stopPropagation` guard that swallows
           the navigation too.

           WHICH control depends on the kind, and this is where the two
           pin models met. A conversation row carries the overflow
           control from task 019fe998, which opens the pin/unpin/hide
           sheet. That control is the only touch path to any of those
           three: all of them are `group-hover/row:` gated on desktop,
           and Tailwind compiles `hover:` inside `@media (hover: hover)`,
           so none of them match on a touch device.

           A task row keeps its own unpin button instead.
           `row_actions_target/5` resolves the sheet's subject against
           `@channels ++ @dm_conversations`, and a task-exec space is in
           neither list, so the sheet would open on a nil target: empty
           header, dead actions. The verbs are wrong for it besides. A
           task pin lives in `task_chat_pins` and comes off through
           `unpin_task_from_chat`, not through the user's
           `toggle_pinned` preferences.

           Neither control carries `phx-click="close_mobile_browser"`,
           on purpose: opening the sheet must not collapse the drawer
           out from under it, and unpinning must not collapse it
           mid-tap. --%>
        <div
          :for={%{kind: kind, space: space} <- pinned_rows}
          class="flex items-center"
          data-role={if kind == :task, do: "pinned-task-drawer-row-wrap", else: "drawer-row-wrap"}
          data-space-id={space.id}
        >
          <% row_label = pinned_row_label(kind, space, @user_id) %>
          <.link
            patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
            phx-click="close_mobile_browser"
            data-role={kind == :task && "pinned-task-drawer-row"}
            data-space-id={kind == :task && space.id}
            class={[
              "flex items-center gap-3 flex-1 min-w-0 px-4 py-3 text-sm transition-colors",
              "hover:bg-base-200",
              @active_space && @active_space.id == space.id &&
                "bg-base-200 text-primary font-semibold"
            ]}
          >
            <%!-- The glyph column, same three glyphs as the desktop rail
               and the only thing that varies between the kinds. Before
               the kind branch existed the row rendered `{space.name}`
               for everything, and a DM has no `name`, so a pinned person
               appeared as a `#` with no label: an unnamed CHANNEL, the
               wrong object type rather than a missing string. --%>
            <%= case kind do %>
              <% :channel -> %>
                <span
                  class="w-5 shrink-0 text-center text-base-content/60 text-lg"
                  data-role="pinned-row-hash"
                >
                  #
                </span>
              <% :dm -> %>
                <span class="w-5 shrink-0" data-role="pinned-row-indent" aria-hidden="true"></span>
              <% :task -> %>
                <span
                  class="w-5 shrink-0 text-center"
                  data-role="pinned-row-task-glyph"
                  aria-hidden="true"
                >
                  <span class="hero-clipboard-document-list-mini size-4 text-base-content/60"></span>
                </span>
            <% end %>
            <span class="truncate flex-1">{row_label}</span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>
          <%= if kind == :task do %>
            <button
              type="button"
              class="flex-shrink-0 inline-flex items-center justify-center w-10 h-10 mr-2 rounded text-base-content/40 hover:text-primary hover:bg-base-200 transition-colors"
              phx-click="unpin_task_from_chat"
              phx-value-task-id={space.metadata["task_id"]}
              data-role="pinned-task-drawer-unpin"
              data-space-id={space.id}
              aria-label={"Unpin #{row_label} from Chat"}
              title="Unpin from Chat"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          <% else %>
            <.row_actions_control space_id={space.id} name={row_label} />
          <% end %>
        </div>
      <% end %>
    </section>
    """
  end

  attr(:sidebar_edit, :boolean, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)

  @doc """
  The Direct Messages section — locked directly under Pinned.

  DM labels come from `sidebar_row_label/2` (a participant display name), not
  from a space name, so nothing here goes through the workspace-name mask and
  the three `@mask_keys` are correctly absent.
  """
  def drawer_dms(assigns) do
    ~H"""
    <%!-- Direct Messages — locked directly under Pinned. While a search
       is active the whole section hides when no DM display-name
       matches; the "No conversations yet" copy below is ONLY for a
       genuinely DM-less account, never for a no-match search. --%>
    <section
      :if={
        @drawer_query == "" or
          drawer_filter_dms(@channel_sections.dms, @drawer_query, @user_id) != []
      }
      data-section-reorderable="false"
      aria-label="Direct Messages"
    >
      <div class="flex items-center justify-between px-4 py-1 mt-2">
        <div class="flex items-center gap-1.5">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Direct Messages
          </p>
          <%!-- Lock affordance (chat sidebar mobile Stage 2, Decision #5) —
             Direct Messages is locked directly under Pinned and can't be
             reordered; surfaced explicitly for touch (no hover) in edit
             mode. Drag handle stays omitted, mirroring desktop's
             data-section-reorderable="false" branch. --%>
          <span
            :if={@sidebar_edit}
            class="channel-section-lock hero-lock-closed size-3.5 text-base-content/40"
            aria-hidden="true"
            title="Direct Messages is locked and can't be reordered"
          >
          </span>
        </div>
        <button
          phx-click={JS.push("new_conversation_open") |> JS.push("close_mobile_browser")}
          class="flex items-center justify-center size-11 rounded-lg text-base-content/60 hover:bg-base-300 hover:text-primary"
          aria-label="New conversation"
          title="New conversation"
        >
          <span class="hero-plus size-5"></span>
        </button>
      </div>
      <%!-- Edit-mode caption (channel-row reorder Stage 1): DM rows are
         deliberately NOT reorderable — recency ordering is automatic
         and self-healing, and a manual order would be silently wiped
         by the next incoming message. One line of copy explains the
         absent affordance instead of per-row lock icons. --%>
      <p :if={@sidebar_edit} class="px-4 pb-1 text-xs text-base-content/40">
        Sorted by recent activity
      </p>
      <%= if @channel_sections.dms == [] do %>
        <p class="px-4 py-2 text-sm text-base-content/50">
          No conversations yet — direct messages will appear here once you start one.
        </p>
      <% else %>
        <%!-- Row wrapper (task 019fe998) — see the Pinned block above for
             why the control is a sibling of the link, never a child. --%>
        <div
          :for={space <- drawer_filter_dms(@channel_sections.dms, @drawer_query, @user_id)}
          class="flex items-center"
          data-role="drawer-row-wrap"
          data-space-id={space.id}
        >
          <% row_label = sidebar_row_label(space, @user_id) %>
          <.link
            patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
            phx-click="close_mobile_browser"
            class={[
              "flex flex-1 min-w-0 items-center gap-3 px-4 py-3 text-sm transition-colors",
              "hover:bg-base-200",
              @active_space && @active_space.id == space.id &&
                "bg-base-200 text-primary font-semibold"
            ]}
          >
            <span class="truncate flex-1">{row_label}</span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>
          <.row_actions_control space_id={space.id} name={row_label} />
        </div>
      <% end %>
    </section>
    """
  end

  attr(:sidebar_edit, :boolean, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  # The three masking attrs again — this component builds its OWN
  # `SidebarMask.context/3` from them, and every heading, aria-label, move
  # button, drag handle and channel row below is derived through it. Drop one
  # and the drawer renders real org names with the mask on.
  attr(:sidebar_sections, :list, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)

  @doc """
  The sub-org sections — the resolver output, in resolver order.

  Its `drawer_mask_ctx` is derived from the FULL `@sidebar_sections`, exactly
  as `mobile_browser/1`'s and the rail's are, so a section carries the SAME
  letter on both breakpoints and an active search cannot relabel what remains.
  """
  def drawer_sections(assigns) do
    ~H"""
    <%!-- Masking context for the drawer (task 01a00c66 stage 3). Derived
         from the FULL `@sidebar_sections` exactly as the rail's is, so a
         section carries the SAME letter on both breakpoints and an active
         search cannot relabel what remains. Built once and threaded to
         every derived string below — the header text, the section's own
         aria-label, both move buttons, the touch drag handle and the
         channel rows — because the way this ships broken is one missed
         site leaving the real name in the accessibility tree under a
         heading that reads `Workspace B`. --%>
    <% drawer_mask_ctx =
      Platform.Chat.SidebarMask.context(
        @sidebar_sections,
        @mask_names?,
        @revealed_section_ids
      ) %>
    <%!-- Sub-org sections — the resolver output (`@sidebar_sections`, the
       same list desktop iterates), rendered in the SAME resolver order as
       desktop (the user's saved drag-order via chat_section_order, then
       admin default). Deliberately NOT re-sorted alphabetically: a hard
       alphabetical sort would override the per-user order that Stage 3's
       touch drag-reorder persists, making that reorder look broken on
       mobile. Keyed by `data-section-id` for the later touch-reorder stage. --%>
    <%!-- While searching, sections render their MATCHING channels only and
       zero-match sections drop out entirely (drawer_filter_sections).
       The neighbor-index math for the move buttons stays valid because
       the edit controls are hidden whenever a search is active — the
       filtered list and @sidebar_sections are identical when the
       controls can actually render. --%>
    <section
      :for={
        {%{section: section, channels: section_channels}, section_index} <-
          Enum.with_index(drawer_filter_sections(@sidebar_sections, @drawer_query, drawer_mask_ctx))
      }
      data-section-id={section.id}
      data-section-reorderable="true"
      aria-label={"#{Platform.Chat.SidebarMask.label(drawer_mask_ctx, section)} channels"}
    >
      <div class="flex items-center px-4 py-1 mt-2">
        <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
          {Platform.Chat.SidebarMask.label(drawer_mask_ctx, section)}
        </p>
        <%!-- Per-item reveal, the SAME affordance the rail has. A real
             focusable button, never a hover treatment: `@media (hover:
             hover)` never matches on a touch device, so a hover-only
             reveal would leave the drawer with no way to show one org at
             all. Sized to the 44px touch floor. --%>
        <button
          :if={
            @mask_names? and
              not Platform.Chat.SidebarMask.revealed?(drawer_mask_ctx, section)
          }
          type="button"
          class="channel-section-reveal-button channel-section-reveal-button--touch"
          phx-click="reveal_section"
          phx-value-section_id={section.id}
          aria-label="Show this workspace name"
        >
          <span class="hero-eye size-4" aria-hidden="true"></span>
        </button>
        <%!-- Up/down move buttons (Stage 4 — WCAG 2.5.7 Dragging
           Movements): the REQUIRED single-pointer alternative to the
           long-press drag, not an optional nicety. They fire the SAME
           `section_reordered {from, to}` event the drag sends — one
           server path, two triggers. The event's semantics are "insert
           `from` ABOVE `to`" (mirroring the drop indicator), which has
           no direct "move below" form — so Down on section A is
           expressed as "insert my NEXT sibling above me"
           (from=next.id, to=this.id), which is the same swap. Boundary
           buttons are disabled, not hidden, mirroring the desktop row
           controls: focus can't land on a no-op that reads as broken.
           Pinned/DMs render none of this (locked).

           Stage 1 search guard rail: ALL reorder affordances vanish
           while a search filter is active — a reorder computed against
           a filtered subset would persist a wrong order. This gate is
           also what keeps the neighbor-index math above safe. --%>
        <span
          :if={@sidebar_edit && @drawer_query == ""}
          class="channel-section-move-controls"
        >
          <button
            type="button"
            class="channel-section-move-button--touch"
            phx-click="section_reordered"
            phx-value-from={section.id}
            phx-value-to={
              section_index > 0 &&
                Enum.at(@sidebar_sections, section_index - 1).section.id
            }
            disabled={section_index == 0}
            aria-label={
              "Move #{Platform.Chat.SidebarMask.label(drawer_mask_ctx, section)} section up"
            }
            title="Move section up"
          >
            <span class="hero-chevron-up size-4"></span>
          </button>
          <button
            type="button"
            class="channel-section-move-button--touch"
            phx-click="section_reordered"
            phx-value-from={
              section_index < length(@sidebar_sections) - 1 &&
                Enum.at(@sidebar_sections, section_index + 1).section.id
            }
            phx-value-to={section.id}
            disabled={section_index == length(@sidebar_sections) - 1}
            aria-label={
              "Move #{Platform.Chat.SidebarMask.label(drawer_mask_ctx, section)} section down"
            }
            title="Move section down"
          >
            <span class="hero-chevron-down size-4"></span>
          </button>
        </span>
        <%!-- Touch drag handle (Stage 3) — the ONLY drag origin: a touch
           starting outside it scrolls the rail, never drags (Stage 4
           checklist #6 verifies this). Edit-gated like the Stage 2 lock
           affordances; locked sections render no handle at all.
           `tabindex="-1"` because the keyboard/a11y reorder path is the
           Stage 4 up/down buttons beside it, not this gesture
           affordance. --%>
        <button
          :if={@sidebar_edit && @drawer_query == ""}
          type="button"
          class="channel-section-drag-handle channel-section-drag-handle--touch"
          aria-label={
            "Reorder #{Platform.Chat.SidebarMask.label(drawer_mask_ctx, section)} section — touch and hold, then drag"
          }
          tabindex="-1"
        >
          ☰
        </button>
      </div>
      <%= cond do %>
        <% section_channels == [] -> %>
          <p class="px-4 py-2 text-sm text-base-content/50">
            No channels yet — channels in this org appear here.
          </p>
        <% @sidebar_edit && @drawer_query == "" -> %>
          <%= for {space, row_index} <- Enum.with_index(section_channels) do %>
            <%= if MapSet.member?(@restricted_channel_ids, space.id) do %>
              <div
                data-role="restricted-channel-row"
                data-space-id={space.id}
                aria-disabled="true"
                class="flex items-center gap-3 px-4 py-3 text-sm text-base-content/50"
              >
                <span class="hero-lock-closed-mini size-4"></span>
                <span class="truncate flex-1">
                  {Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)}
                </span>
                <span class="text-xs">Restricted, ask an admin</span>
              </div>
            <% else %>
              <%!-- EDIT-MODE rows (channel-row reorder Stage 1; revised in
             Stage 2). Rows stop being navigation links — a mis-tap
             would navigate + close the drawer, ejecting the user from
             the mode. Every row shows its ▲▼ pair persistently, the
             same convention as the section headers directly above them
             (Marlowe a11y request 2026-07-09, reversing the July 6
             select-to-reveal decision: controls that hide until touched
             read as broken, and were reported as a bug twice in one
             review). The unread badge yields its right-edge slot to the
             reorder chrome (edit mode is a mode; counts are browse
             chrome). Boundary ▲▼ are disabled, not hidden, matching
             the section buttons. Reorder reuses the EXISTING
             move_channel pipeline (per-user chat_channel_order pref) —
             the same one desktop's row controls persist through. --%>
              <div
                data-channel-id={space.id}
                data-section-id={section.id}
                class="flex items-center gap-3 px-4 py-3 text-sm"
              >
                <span class="text-base-content/40 text-lg">#</span>
                <span class="truncate flex-1">
                  {Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)}
                </span>
                <span class="channel-row-move-controls--touch">
                  <button
                    type="button"
                    class="channel-row-move-button--touch"
                    phx-click="move_channel"
                    phx-value-channel_id={space.id}
                    phx-value-section_id={section.id}
                    phx-value-direction="up"
                    disabled={row_index == 0}
                    aria-label={
                  "Move ##{Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)} up"
                }
                    title="Move up"
                  >
                    <span class="hero-chevron-up size-4"></span>
                  </button>
                  <button
                    type="button"
                    class="channel-row-move-button--touch"
                    phx-click="move_channel"
                    phx-value-channel_id={space.id}
                    phx-value-section_id={section.id}
                    phx-value-direction="down"
                    disabled={row_index == length(section_channels) - 1}
                    aria-label={
                  "Move ##{Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)} down"
                }
                    title="Move down"
                  >
                    <span class="hero-chevron-down size-4"></span>
                  </button>
                  <%!-- Touch drag handle (Stage 2) — the ONLY row-drag
                 origin; activates the slot Stage 1 held with an inert
                 placeholder. Lives INSIDE the controls cluster so the
                 row's gap-3 can't wedge 12px between ▼ and ☰ — that
                 offset broke column alignment with the section header
                 (design QA, 2026-07-09). `tabindex="-1"` because the
                 keyboard/a11y reorder path is the always-visible ▲▼
                 buttons beside it, not this gesture affordance
                 (WCAG 2.5.7 coupling, same as sections). --%>
                  <button
                    type="button"
                    class="channel-row-drag-handle"
                    aria-label={
                  "Reorder ##{Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)} — touch and hold, then drag"
                }
                    tabindex="-1"
                  >
                    ☰
                  </button>
                </span>
              </div>
            <% end %>
          <% end %>
        <% true -> %>
          <%= for space <- section_channels do %>
            <%= if MapSet.member?(@restricted_channel_ids, space.id) do %>
              <div
                data-role="restricted-channel-row"
                data-space-id={space.id}
                aria-disabled="true"
                class="flex items-center gap-3 px-4 py-3 text-sm text-base-content/50"
              >
                <span class="hero-lock-closed-mini size-4"></span>
                <span class="truncate flex-1">
                  {Platform.Chat.SidebarMask.channel_label(drawer_mask_ctx, section, space.name)}
                </span>
                <span class="text-xs">Restricted, ask an admin</span>
              </div>
            <% else %>
              <%!-- Row wrapper (task 019fe998). NORMAL mode only: the
               edit-mode branch above already carries its own persistent
               ▲▼ + drag cluster, and the sheet deliberately offers no
               Move — arrows are for repeated nudging inside an explicit
               arranging mode, and reordering a list by opening a sheet
               per step would be miserable. --%>
              <div
                class="flex items-center"
                data-role="drawer-row-wrap"
                data-space-id={space.id}
              >
                <.link
                  patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
                  phx-click="close_mobile_browser"
                  class={[
                    "flex flex-1 min-w-0 items-center gap-3 px-4 py-3 text-sm transition-colors",
                    "hover:bg-base-200",
                    @active_space && @active_space.id == space.id &&
                      "bg-base-200 text-primary font-semibold"
                  ]}
                >
                  <span class="text-base-content/40 text-lg">#</span>
                  <span class="truncate flex-1">
                    {Platform.Chat.SidebarMask.channel_label(
                      drawer_mask_ctx,
                      section,
                      space.name
                    )}
                  </span>
                  <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                    <span class="ml-1 flex-shrink-0 min-w-[1.125rem] h-[1.125rem] rounded-full bg-primary text-primary-content text-[0.6rem] font-bold flex items-center justify-center px-1 leading-none">
                      {unread_label(Map.get(@unread_counts, space.id, 0))}
                    </span>
                  <% end %>
                </.link>
                <.row_actions_control
                  space_id={space.id}
                  name={
                    Platform.Chat.SidebarMask.channel_label(
                      drawer_mask_ctx,
                      section,
                      space.name
                    )
                  }
                />
              </div>
            <% end %>
          <% end %>
      <% end %>
    </section>
    """
  end

  # `ChatLive.masked_space_name/2` under a shorter name, called only from the
  # Archived rows above. The alias keeps the `<span class="truncate flex-1">`
  # line inside the formatter's width — a reflow there puts WHITESPACE INSIDE
  # the span, which is a rendered-output change in a pure move.
  defp mask_name(mask_assigns, name), do: ChatLive.masked_space_name(mask_assigns, name)
end
