defmodule PlatformWeb.ChatLive.Partials.Rail do
  @moduledoc """
  The internal desktop channel rail — `<aside id="chat-sidebar">` and
  everything inside it.

  Same split as `ChatLive.Partials` and `ChatLive.Partials.ExternalRail`
  (ADR 0035): function components, no state, each taking a declared set of
  attrs. Extracted from `chat_live.html.heex` in task 01a0312e stage 3 as a
  PURE MOVE — every `id`, `phx-hook`, `phx-click`, `phx-value-*`, `data-*`
  and `aria-*` sits on the element it sat on before, and the rendered HTML
  was diffed across 22 fixture states (every branch of the rail) to prove it.

  The regions, in rail order:

    * `rail/1` — the `<aside>` shell, the `<nav id="chat-section-list">`
      scroll region, the edit-mode reset action and the brand-new-user empty
      state
    * `rail_header/1` — the header row (personal-edit / admin-edit / normal
      branches, the mask toggle, the overflow menu) and the mask mode strip
    * `pinned_block/1` — the Pinned block and its `#pinned-row-drag` scope
    * `dm_section/1` — the always-rendered Direct Messages section
    * `sub_org_sections/1` — the `#channel-membership-drag` wrapper and the
      per-org sections inside it
    * `archived_section/1` — the collapsed Archived group
    * `rail_footer/1` — undo toast, move toast, `+ New channel`, the global
      hidden-channels drawer and the resize handle

  ## WHY THE SPLIT STOPS WHERE IT DOES

  The `<nav>`'s children share the sidebar-edit-mode branching, so the split
  follows the rail's own section boundaries rather than cutting inside one.
  `rail/1` keeps the two one-shot children (the reset button and the empty
  state) inline: each is a single `:if`-gated element with no internal
  structure, and a named component per element would be a rename, not a
  decomposition.

  ## THE HOOK-IDENTITY RULE

  Three live JS hooks are bound BY ID in this region — `ResizableSidebar` on
  `#chat-sidebar`, `SectionReorder` on `#chat-section-list`, and TWO separate
  mounts of `ChannelMembershipDrag` (`#pinned-row-drag` and
  `#channel-membership-drag`). JS also reads `data-sidebar-edit`,
  `data-row-reorderable`, `data-section-slug`, `data-section-id` and
  `data-row-locked` off these elements. A binding left behind on a wrapper,
  or an id duplicated because the shell kept one and a component added
  another, renders a page that looks perfect and does nothing — and every
  markup assertion still passes. So: attrs are forwarded, elements are not
  re-parented, and no component introduces a wrapper element of its own.

  ## THE MASKING ATTRS ARE NOT OPTIONAL

  `ChatLive.masked_space_name/2` reads `:sidebar_sections`, `:mask_names?`
  and `:revealed_section_ids` out of the map it is handed, through TOLERANT
  `assigns[...]` access. It stays in `PlatformWeb.ChatLive` (stage 1 left it
  there for exactly that reason), so the components that call it declare
  those three as attrs and pass a `@mask_assigns` map built with
  `Map.take/2`.

  A component that FORGETS to declare them does not crash and does not
  render blank — it silently renders REAL WORKSPACE NAMES with the mask
  switched on. That is a privacy failure that passes every markup assertion,
  so the declaration is load-bearing wherever a space name is rendered:
  `archived_section/1` and `rail_footer/1` here, plus `sub_org_sections/1`,
  which builds its own `SidebarMask.context/3` from the same three values.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.Partials,
    only: [brand_new_user_empty_state: 1, row_actions_trigger: 1]

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [
      pinned_row_label: 3,
      section_channel_rows: 3,
      sidebar_row_label: 2,
      unread_label: 1
    ]

  import PlatformWeb.Components.LifecycleControls, only: [lifecycle_menu: 1]
  import PlatformWeb.Components.ScopePill, only: [scope_pill: 1]
  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias PlatformWeb.ChatLive

  # The exact keys `ChatLive.space_mask/1` reads. Named once so a component
  # that needs the mask takes the whole set or none of it — a partial take is
  # the silent-unmasking bug described in the moduledoc.
  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  attr(:sidebar_edit, :boolean, required: true)
  attr(:sidebar_admin_edit, :boolean, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:sidebar_menu_open, :boolean, required: true)
  attr(:root_admin?, :boolean, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:agents_block, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  attr(:scope_filter, :any, required: true)
  attr(:tenant_org_ids, :any, required: true)
  attr(:lifecycle_menu_key, :any, required: true)
  attr(:hidden_drawer_open, :boolean, required: true)
  attr(:undo_toast, :any, required: true)
  attr(:move_toast, :any, required: true)

  @doc """
  The internal desktop channel rail.

  The `:if={!@embedded and !@external?}` gate travelled INTO the component
  with the markup (same convention as `ExternalRail.external_rail/1`), so the
  call site states no render condition of its own — one gate, one place.
  """
  def rail(assigns) do
    ~H"""
    <aside
      :if={!@embedded and !@external?}
      id="chat-sidebar"
      phx-hook="ResizableSidebar"
      class="hidden lg:flex relative flex-shrink-0 flex-col border-r border-base-content/10 bg-base-200"
    >
      <.rail_header
        sidebar_edit={@sidebar_edit}
        sidebar_admin_edit={@sidebar_admin_edit}
        sidebar_menu_open={@sidebar_menu_open}
        root_admin?={@root_admin?}
        mask_names?={@mask_names?}
        revealed_section_ids={@revealed_section_ids}
      />
      <nav
        id="chat-section-list"
        phx-hook="SectionReorder"
        data-sidebar-edit={to_string(@sidebar_edit)}
        class="flex-1 overflow-y-auto py-2"
        aria-label="Channel sections"
      >
        <%!-- Agents block (task 01a0b491) — ABOVE Pinned. Renders nothing
             when the feature flag is off or no space carries a goal. --%>
        <.agents_block
          agents_block={@agents_block}
          active_space={@active_space}
          unread_counts={@unread_counts}
        />
        <.pinned_block
          channel_sections={@channel_sections}
          pinned_task_spaces={@pinned_task_spaces}
          sidebar_edit={@sidebar_edit}
          active_space={@active_space}
          unread_counts={@unread_counts}
          user_id={@user_id}
        />
        <.dm_section
          channel_sections={@channel_sections}
          active_space={@active_space}
          unread_counts={@unread_counts}
          user_id={@user_id}
        />
        <.sub_org_sections
          restricted_channel_ids={@restricted_channel_ids}
          sidebar_sections={@sidebar_sections}
          scope_filter={@scope_filter}
          mask_names?={@mask_names?}
          revealed_section_ids={@revealed_section_ids}
          sidebar_edit={@sidebar_edit}
          sidebar_admin_edit={@sidebar_admin_edit}
          active_space={@active_space}
          unread_counts={@unread_counts}
          root_admin?={@root_admin?}
          tenant_org_ids={@tenant_org_ids}
          lifecycle_menu_key={@lifecycle_menu_key}
        />
        <%!-- Reset to default layout (chat sidebar Stage 5, edit mode only).
           Clears all three per-user override keys (section order, channel
           placement, hidden sections) so the rail returns to the org default
           — the only way to un-hide a section hidden via the per-section
           control above. --%>
        <button
          :if={@sidebar_edit}
          type="button"
          phx-click="reset_sidebar"
          class="channel-reset-layout-button"
          aria-label="Reset to default layout"
        >
          <span class="hero-arrow-path size-4"></span>
          <span>Reset to default layout</span>
        </button>

        <%!-- Brand-new-user empty state — surfaces when the user has no
           channels AND no DMs at all. The sub-org headers above still
           render (with their own empty-state hints), but a separate
           top-level invite chip keeps the "Welcome to Suite" message
           from Stage 1 visible.

           `@archived_channels == []` is part of the test (task 019f4eaa):
           having archived channels is proof you are NOT a brand-new user, so
           "Welcome to Suite. To get started, create a space" is simply wrong
           — it rendered directly above the ARCHIVED section, telling an admin
           who had just archived her orgs that she had never used the product.
           Org-archive made this trivial to hit: it empties every channel in
           an org at once. Hidden channels deliberately do NOT count here —
           `@channels` still carries them (hiding is applied downstream in
           `channel_sections/4`), so hiding everything is not mistaken for
           being new either. --%>
        <%!-- The copy itself moved to `Partials.brand_new_user_empty_state/1`
           (stage 8) so the mobile content pane can render the SAME §5.1
           state without a second copy of the strings. The render condition
           stays here — it is the rail's, and the mobile caller's differs. --%>
        <.brand_new_user_empty_state :if={
          @channels == [] and @dm_conversations == [] and @archived_channels == []
        } />
        <.archived_section
          restricted_channel_ids={@restricted_channel_ids}
          archived_channels={@archived_channels}
          archived_open={@archived_open}
          active_space={@active_space}
          sidebar_sections={@sidebar_sections}
          mask_names?={@mask_names?}
          revealed_section_ids={@revealed_section_ids}
        />
      </nav>
      <.rail_footer
        undo_toast={@undo_toast}
        move_toast={@move_toast}
        channel_sections={@channel_sections}
        hidden_drawer_open={@hidden_drawer_open}
        sidebar_sections={@sidebar_sections}
        mask_names?={@mask_names?}
        revealed_section_ids={@revealed_section_ids}
      />
    </aside>
    """
  end

  attr(:sidebar_edit, :boolean, required: true)
  attr(:sidebar_admin_edit, :boolean, required: true)
  attr(:sidebar_menu_open, :boolean, required: true)
  attr(:root_admin?, :boolean, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)

  @doc """
  The rail's header row plus the masking mode strip below it.

  Two elements, one component, because the strip is the header's own state
  readout: it renders only while `@mask_names?` is on, which is the state the
  header's eye toggle sets. Splitting them would put a component boundary
  between a control and the banner that reports it.
  """
  def rail_header(assigns) do
    ~H"""
    <%!-- Sidebar header (chat sidebar Stage 5). Hosts the "Edit layout" /
         "Done" toggle. In edit mode the rail shows per-channel grab handles,
         per-section Hide/Show controls, keyboard move buttons, and a "Reset
         to default layout" action; in normal mode the rail navigates as
         before. Desktop only — the whole aside is `hidden lg:flex`. --%>
    <%!-- Sidebar header. The ~260px rail can't fit two text toggles, so the
         personal "Edit layout" and admin "Edit default" entry points collapse
         into ONE overflow ("More") menu (ui-ux-pro overflow-menu pattern: when
         actions exceed available space, use an overflow menu instead of
         cramming).

         Overflow contract — this row must NEVER push content past the ~260px
         rail in ANY mode. Containment comes from the flex children, NOT from
         clipping the row: the row is `min-w-0`, the text child truncates
         (`flex-1 min-w-0 truncate`), and the action button is pinned
         (`flex-shrink-0`). We deliberately do NOT put `overflow-hidden` on
         this row — the normal-mode "More" popover is anchored inside it and
         opens BELOW it (`top-full`), so an `overflow-hidden` row would clip
         the menu off (it did: the dropdown rendered hidden behind the rail).
           * in EITHER edit mode we do NOT also render the word "CHANNELS" —
             the mode label IS the row's text and takes the remaining space
             (`flex-1 min-w-0 truncate`), with only the "Done" button pinned
             (`flex-shrink-0`). The mode label + accent already say which mode
             is active, so "Done" needs no "(admin)" qualifier;
           * in normal mode the "CHANNELS" label is the flex-1 truncating child
             and the kebab "More" button is pinned (`flex-shrink-0`). --%>
    <div class="flex-shrink-0 flex items-center gap-2 px-3 py-2 border-b border-base-content/10 min-w-0">
      <%= cond do %>
        <% @sidebar_edit -> %>
          <%!-- In personal-edit mode: a single "Done" exit + a quiet mode
               label that absorbs the row's free space and truncates. No other
               control — and no "CHANNELS" word — occupies the row. --%>
          <span class="channel-edit-mode-label flex-1">Editing my layout</span>
          <button
            type="button"
            phx-click="toggle_sidebar_edit"
            class="channel-edit-toggle flex-shrink-0"
            aria-pressed="true"
            aria-label="Done editing layout"
          >
            Done
          </button>
        <% @sidebar_admin_edit -> %>
          <%!-- In admin-edit mode: a single "Done" exit + an admin-accented
               mode label so the admin always knows they are editing what
               everyone sees. The label absorbs free space and truncates; only
               "Done" is pinned. No "CHANNELS" word in the row. --%>
          <span class="channel-edit-mode-label channel-edit-mode-label--admin flex-1">
            Editing company default
          </span>
          <button
            type="button"
            phx-click="toggle_sidebar_admin_edit"
            class="channel-admin-edit-toggle flex-shrink-0"
            aria-pressed="true"
            aria-label="Done editing the company default"
          >
            Done
          </button>
        <% true -> %>
          <%!-- Normal mode: the "CHANNELS" label (flex-1, truncates) + ONE
               compact "More" (kebab) button (flex-shrink-0). Clicking the
               button opens an absolutely-positioned popover CONTAINED within
               the aside (the wrapper is position:relative so the menu anchors
               to the header, never floats over the chat pane). The menu closes
               on click-away and Escape; choosing an item enters the mode AND
               closes the menu (handled server-side). --%>
          <p class="min-w-0 flex-1 truncate text-xs font-semibold uppercase tracking-widest text-base-content/60">
            Channels
          </p>
          <%!-- Screen-share name masking (task 01a00c66). PERMANENTLY VISIBLE
               in the header row, a sibling of the kebab — never an item inside
               the kebab popover or any other dropdown. Harper's request offered
               "an eye symbol or some other dropdown"; the eye wins because a
               dropdown costs two clicks and a decision at the exact moment
               someone is fumbling with a share dialog.

               Posts the DESIRED next state rather than a flip, so a duplicated
               event from a render race is idempotent (same convention as
               `toggle_section_collapsed`). The icon swap is deliberately NOT
               the feature's signal — see the mode strip below. --%>
          <button
            type="button"
            phx-click="toggle_mask_names"
            phx-value-masked={to_string(!@mask_names?)}
            class="channel-mask-toggle flex-shrink-0"
            aria-pressed={to_string(@mask_names?)}
            aria-label="Hide workspace names for sharing"
          >
            <span
              class={[if(@mask_names?, do: "hero-eye-slash", else: "hero-eye"), "size-4"]}
              aria-hidden="true"
            >
            </span>
          </button>
          <div class="channel-sidebar-menu relative flex-shrink-0">
            <button
              type="button"
              phx-click="toggle_sidebar_menu"
              class="channel-sidebar-menu-button"
              aria-haspopup="menu"
              aria-expanded={to_string(@sidebar_menu_open)}
              aria-label="Sidebar options"
            >
              <span class="hero-ellipsis-vertical size-4"></span>
            </button>
            <div
              :if={@sidebar_menu_open}
              class="channel-sidebar-menu-popover"
              role="menu"
              aria-label="Sidebar options"
              phx-click-away="close_sidebar_menu"
              phx-window-keydown="close_sidebar_menu"
              phx-key="escape"
            >
              <%!-- FIRST, above the layout items: this one acts on the
                    conversations, the other two act on how the rail is
                    arranged. Ordinary menu-row styling on purpose — no
                    warning colour and no confirmation step, because reading
                    a conversation undoes it. --%>
              <button
                type="button"
                role="menuitem"
                phx-click="mark_all_read"
                class="channel-sidebar-menu-item"
              >
                Mark all as read
              </button>
              <button
                type="button"
                role="menuitem"
                phx-click="toggle_sidebar_edit"
                class="channel-sidebar-menu-item"
              >
                Edit my layout
              </button>
              <%!-- Admin-only entry point. Rendered ONLY for root-org admins; the
                   handler re-checks @root_admin? as the real gate. Admin accent
                   so it reads as a company-wide action, not a personal one. --%>
              <button
                :if={@root_admin?}
                type="button"
                role="menuitem"
                phx-click="toggle_sidebar_admin_edit"
                class="channel-sidebar-menu-item channel-sidebar-menu-item--admin"
              >
                Edit company default
              </button>
            </div>
          </div>
      <% end %>
    </div>
    <%!-- THE MODE STRIP IS THE SIGNAL, NOT THE ICON'S STATE (task 01a00c66).
         An eye and a crossed-out eye differ by a few pixels of stroke, and the
         only moment this feature exists for is a half-second glance under
         social pressure while starting a screen share. Both misreadings cost:
         believing it is on when it is off puts the client list on the call;
         believing it is off when it is on has someone hunting for a client
         that is sitting there as `Workspace C` while people watch. So the
         active mode gets a full-width band, not a glyph state.

         `--color-warning` because this is a deliberate TEMPORARY MODE, which
         is how warning already reads on the notification-state row — not
         `--color-error` (says something is wrong) and not `--color-primary`
         (the action colour; it would read as a button).

         Copy is about PRESENTING, never privacy: nothing here says privacy,
         secure, protected or encrypted, and there is no padlock or shield
         anywhere in this feature — an icon would make the same overclaim the
         forbidden words would. The eye is the only permitted metaphor. --%>
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
    """
  end

  attr(:agents_block, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)

  @doc """
  The Agents block — ONE row, above the Pinned block, for the space whose
  goal the federated agents are serving (task 01a0b491, stage 4).

  NOT a `channel_sections` row, and it cannot be one: that table carries
  `unique_index(:channel_sections, [:org_id])` — one row per org — and
  membership derives from `chat_spaces.org_id`. An "Agents" section would
  have to invent an org. So this is a bespoke block mirroring
  `pinned_block/1`'s structure and its `channel-section` classes.

  GROUPED BY SPACING, NOT BY A LINE (task 01a0ca8b stage 2). Once the space
  stopped also listing under its org heading, the block's separator became
  its only grouping cue, and it was not a visible one: `border-edge` painted
  in Chrome measures 1.2856:1 against the light rail (#D7D7D7 on #F2F2F2)
  and 1.4373:1 against the dark rail (#232A38 on #000306). The only existing
  tokens that clear 3:1 on both rails are `--color-secondary` (a near-black
  rule in light, heavier than the section below it) and the two cyans (a
  second chroma on a surface whose one chroma is the ring). So the line is
  dropped rather than raised: `border-b-0` cancels the `.channel-section`
  component border as well as the old utility, and `pb-2 mb-2` keep the
  block's geometry, so the row does not move and the Pinned heading below
  is the boundary. The drawer twin already had no line.

  NO CHROME, inherited deliberately from `pinned_block/1` three rows
  below: no surface fill, no border box, no badge, no second line, no
  collapse control. The original ticket asked for a row "visually heavier
  than a normal channel row"; that reverses a rule this file already
  states and which is load-bearing for the block underneath, so the
  ticket was corrected and the correction wins. Row height, left padding,
  unread pill and truncation are the pinned row's, unchanged.

  WEIGHT COMES FROM EXACTLY ONE THING: the leader's avatar at 20px, in
  the `w-5` glyph column the pinned rows already reserve for their flat
  glyphs, ringed in `ring-focus-ring`. That column has only ever held
  glyphs; a face in it says someone is accountable with no label and no
  added height, and the ring is the only chroma on this surface.

  The ring was `ring-primary` until task 01a0ca8b stage 2, and the
  pre-Burrow cyan painted 1.5956:1 against the light rail: the one device the
  block spends its boldness on was close to invisible in light. `--focus-ring`
  is the existing theme-split slot minted for exactly this job (a non-text
  indicator that must clear 3:1 on every ground). On the Burrow tokens (task
  01a120c5), computed from app.css against the rail's `bg-base-200`, it is
  #8b3b04 at 7.0195:1 in light and #f47721 (the dark primary) at 6.7002:1 in
  dark.
  `focus_ring_slot_test.exs` pins the slot's ratios, so a retune that
  breaks the floor reds there first. The avatar is not focusable, so the
  ring cannot be mistaken for a focus state on this element.

  Renders NOTHING when `@agents_block` is nil — flag off, or no space
  carries a goal. No label, no placeholder, no empty container. Same rule
  `pinned_block/1` applies to its own empty case and for the same reason.
  """
  def agents_block(assigns) do
    ~H"""
    <%= if @agents_block do %>
      <% space = @agents_block.space %>
      <% leader = @agents_block.leader %>
      <section
        class="channel-section group border-b-0 pb-2 mb-2"
        data-section-key="agents"
        data-role="agents-rail-block"
        aria-label="Agents"
      >
        <div
          class={[
            "channel-row-wrap group/row",
            @active_space && @active_space.id == space.id && "channel-row-wrap--active"
          ]}
          data-space-id={space.id}
        >
          <.link
            patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
            data-role="agents-rail-row"
            class={[
              "channel-row",
              @active_space && @active_space.id == space.id && "channel-row--active"
            ]}
          >
            <%!-- The glyph column, at the pinned rows' exact `w-5` width so
                   the names form one straight column with the block below.
                   The avatar is `xs` (size-5 = 20px), which is the box, not
                   an enlargement of the row.

                   Empty when no leader resolves, rather than a placeholder
                   face: a stand-in face would claim accountability nobody
                   holds, which is the one thing this row exists to say. --%>
            <span class="w-5 shrink-0 flex items-center justify-center" data-role="agents-row-glyph">
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
              <span class="channel-row-unread-pill">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>
        </div>
      </section>
    <% end %>
    """
  end

  attr(:channel_sections, :map, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:sidebar_edit, :boolean, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)

  @doc """
  The Pinned block — pinned channels, pinned DMs and pinned task
  conversations in one list, locked above every other section.

  `#pinned-row-drag` is the SECOND mount of `ChannelMembershipDrag` in the
  rail (`#channel-membership-drag` in `sub_org_sections/1` is the other). Two
  ids, two mounts, one hook — the component boundary must not merge them and
  must not let either id appear twice.
  """
  def pinned_block(assigns) do
    ~H"""
    <%!-- The Pinned block — ONE list holding pinned channels, pinned DMs
           and pinned task conversations, above every other section in the
           rail.

           It was two adjacent blocks ("Pinned Channels" and "Pinned Tasks")
           until 2026-08-10. Marlowe pinned a task from the Tasks page, went to
           Chat and found its execution log in her rail: pinning a task is the
           same act as pinning a channel, so it is one need and one block. The
           heading is the bare word "Pinned" because the block now holds
           everything that word covers.

           ONE ROW SHAPE, THREE GLYPHS, per Saru's design canvas for task
           019feec6-73d9. Row
           height, name treatment, hover, active state, unread pill and
           truncation are identical across the three kinds; the 20px glyph
           column is the only thing that varies. Deliberately NOT done: kind
           labels, dividers between kinds, per-kind tints, sub-headings. Each
           of those re-states the separation this block exists to remove, and
           in a 260px rail a kind chip is three characters of name.

           Ordering is newest-pinned first, with task rows ABOVE conversation
           rows — see `pinned_rail_entries/2` for why the two halves cannot be
           interleaved and why tasks lead.

           Renders only when non-empty. When empty it renders NOTHING: no
           label, no placeholder. The top of a 260px rail is too expensive to
           spend on instructions for a feature nobody has adopted.

           NO CHROME, per the design canvas: no icon beside the label, no
           surface fill, no border box, no collapse control. Every other
           grouping in the rail earns an affordance; this one earns none,
           and the absence is what makes it read as the user's own rather
           than as another client. A `base-300` rule separates it from what
           follows. NOT hideable, NOT reorderable.

           NO CLIENT COLOUR, and no space held for one. The rail carries
           client colour in section headers only. The row takes exactly the
           left padding of a row in any client section, so the block sits
           flush with the rest of the rail. (Task 019fd810 would have added
           a per-row colour marker and was cancelled; reserved space with
           nothing in it reads as a rendering bug.) --%>
    <%!-- Row-drag scope for the Pinned block (task 019fe987). A SECOND
           mount of the same ChannelMembershipDrag hook, not a second hook:
           the sub-org mount lives further down the rail and an element
           carries one phx-hook, so the block needs its own root. The rows
           below are the only draggables inside it, which is why a drag can
           never move a conversation INTO or OUT OF the block — pinning
           stays a click on the pin control.

           `data-admin-edit` is hard-coded false. There is no org default
           for "what this person pinned", so admin-edit must not turn a
           pinned drag into a global reassignment. --%>
    <% pinned_entries = ChatLive.pinned_rail_entries(@channel_sections.pinned, @pinned_task_spaces) %>
    <%= if pinned_entries != [] do %>
      <div
        id="pinned-row-drag"
        phx-hook="ChannelMembershipDrag"
        data-sidebar-edit={to_string(@sidebar_edit)}
        data-admin-edit="false"
      >
        <section
          class="channel-section group border-b border-edge pb-2 mb-2"
          data-section-key="pinned"
          data-section-reorderable="false"
          data-row-reorderable="true"
          data-row-scope="pinned"
          aria-label="Pinned"
        >
          <div class="channel-section-header">
            <p class="channel-section-label">Pinned</p>
          </div>
          <%= for %{kind: kind, space: space, move_index: move_index, move_count: move_count} <-
                  pinned_entries do %>
            <%!-- Bound once, used twice: as the row's visible label and as the
                   target inside the row control's accessible name. Resolving a
                   DM's label runs a participants query, so calling the helper
                   at each use would double the block's query count. --%>
            <% row_label = pinned_row_label(kind, space, @user_id) %>
            <%!-- Row wrapper: pairs the navigate-link with the row's own
                   overflow trigger as SIBLINGS, the same shape the sub-org
                   rows use. The wrapper carries the row's margin, rounding and
                   hover/active background (see `.channel-row-wrap` in app.css)
                   so the highlight spans the control too, and the `--active`
                   modifier must ride along or the scoped
                   `.channel-row-wrap > .channel-row--active` rule strips the
                   selected row's tint.

                   `data-role="pinned-task-rail-row-wrap"` survives the merge on
                   task rows only — it is what the task-pin tests address.

                   `data-row-locked` marks a row the drag must route AROUND
                   rather than through: the hook drops locked rows from the
                   order it computes and clamps a drop that lands on one. It is
                   the client half of the rule that `move_index: nil` states on
                   the server. Task rows are the only locked rows today. --%>
            <div
              class={[
                "channel-row-wrap group/row",
                @sidebar_edit && "channel-row-wrap--editing",
                @active_space && @active_space.id == space.id && "channel-row-wrap--active"
              ]}
              data-role={kind == :task && "pinned-task-rail-row-wrap"}
              data-space-id={space.id}
              data-row-locked={kind == :task && "true"}
            >
              <%!-- Grab handle (task 019fe987), borrowed verbatim from the
                     sub-org rows rather than invented here. Rendered ONLY in
                     personal-edit mode, never at rest: the row already carries
                     its overflow trigger on the right edge, and a second
                     permanent control on its left squeezes the name from both
                     sides, which the brand page's truncation rule forbids
                     because the name is the protected fragment.

                     CONVERSATION ROWS ONLY (Marlowe, 2026-08-12: "it's essentially
                     two separate lists so makes me think to not commingle the
                     interactions too much"). A task row is in the block but is
                     not hand-orderable, and the absence of a handle is what says
                     so. `move_index` is nil exactly on those rows.

                     NOT gated on `@sidebar_admin_edit` (unlike the sub-org rows,
                     which drag in either mode). Admin-edit rearranges the org
                     default; a pin list is one person's and has no org default,
                     so there is nothing for an admin to drag here.

                     This span, not the wrapper, carries `draggable` so it is the
                     HTML5 drag SOURCE and the hook's `.channel-row-grab` gate
                     matches. `tabindex` is untouched (a span is not focusable):
                     the keyboard path is the ▲▼ pair below, not this. --%>
              <span
                :if={@sidebar_edit and move_index != nil}
                class="channel-row-grab"
                aria-hidden="true"
                title="Drag to reorder"
                draggable="true"
              >
                ⠿
              </span>
              <%!-- The handle's slot, held open on the rows that do not get
                     one, so the names stay in one column when edit mode opens.
                     Same `w-5 ml-1` box `.channel-row-grab` occupies; no new
                     class and no new token for an empty box. --%>
              <span
                :if={@sidebar_edit and move_index == nil}
                class="w-5 ml-1 shrink-0"
                aria-hidden="true"
              >
              </span>
              <.link
                patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
                data-role={kind == :task && "pinned-task-rail-row"}
                data-space-id={kind == :task && space.id}
                class={[
                  "channel-row",
                  @active_space && @active_space.id == space.id && "channel-row--active"
                ]}
              >
                <%!-- The glyph column: 20px wide, and the ONLY thing that
                       varies between the three kinds.

                       `#` for a channel, an empty slot for a person, and
                       `hero-clipboard-document-list-mini` for a task
                       conversation. All three already existed before the merge;
                       no new marker was designed and none was added.

                       Both glyphs render at `--color-base-content` 60%. The `#`
                       was at 40% and the task glyph at 40% while they lived in
                       separate blocks; side by side in one column, two opacities
                       read as two levels of importance rather than two kinds of
                       thing.

                       The person slot stays EMPTY rather than taking an avatar:
                       `initials/1` takes the first two words of the label, so a
                       group DM named "Rowan Ellis, Alexandra ..." rendered
                       "RM" and was indistinguishable from a private DM with
                       Rowan. It is not the reserved gutter plan v3 rules out —
                       that was space held for a colour marker that is never
                       arriving, whereas a blank beside rows visibly carrying a
                       `#` reads as "no hash here". --%>
                <%= case kind do %>
                  <% :channel -> %>
                    <span
                      class="w-5 shrink-0 text-center text-base-content/60"
                      data-role="pinned-row-hash"
                    >
                      #
                    </span>
                  <% :dm -> %>
                    <span class="w-5 shrink-0" data-role="pinned-row-indent" aria-hidden="true">
                    </span>
                  <% :task -> %>
                    <%!-- Wrapped in the same `w-5` slot the `#` occupies so
                           the names form one straight column. The glyph itself
                           is 14px like the hash; the box around it is 20px. --%>
                    <span
                      class="w-5 shrink-0 text-center"
                      data-role="pinned-row-task-glyph"
                      aria-hidden="true"
                    >
                      <span class="hero-clipboard-document-list-mini size-3.5 text-base-content/60">
                      </span>
                    </span>
                <% end %>
                <span class="truncate flex-1">{row_label}</span>
                <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                  <span class="channel-row-unread-pill">
                    {unread_label(Map.get(@unread_counts, space.id, 0))}
                  </span>
                <% end %>
              </.link>
              <%!-- Keyboard and screen-reader reorder path (task 019fe987,
                     WCAG 2.1.1). NOT a touch fallback for the drag above: drag
                     alone is operable by one kind of user with one kind of
                     input, and this rail already carries a logged defect where a
                     hover-gated control was unreachable without a pointer. These
                     ship the same day the drag does.

                     The accessible name carries the VERB AND THE TARGET. A bare
                     "Move up" is meaningless in a list of identical controls, and
                     the block is exactly such a list. No "#" prefix, unlike the
                     sub-org rows: this block holds people too, and a hash on a
                     person names the wrong object type.

                     Boundary buttons are disabled rather than hidden, matching
                     the sub-org rows, so focus order stays stable as a row
                     travels to the top or the bottom. The boundaries are
                     `move_index` against `move_count` — the row's place among
                     the CONVERSATIONS, not among the block's rows. Counting the
                     task rows would leave the ▲ enabled on the top conversation
                     and point it at a destination it is not allowed to have. --%>
              <span :if={@sidebar_edit and move_index != nil} class="channel-row-move-controls">
                <button
                  type="button"
                  class="channel-row-move-button"
                  phx-click="move_pinned"
                  phx-value-space_id={space.id}
                  phx-value-direction="up"
                  disabled={move_index == 0}
                  data-role="pinned-move-up"
                  aria-label={"Move #{row_label} up"}
                  title="Move up"
                >
                  <span class="hero-chevron-up size-3"></span>
                </button>
                <button
                  type="button"
                  class="channel-row-move-button"
                  phx-click="move_pinned"
                  phx-value-space_id={space.id}
                  phx-value-direction="down"
                  disabled={move_index == move_count - 1}
                  data-role="pinned-move-down"
                  aria-label={"Move #{row_label} down"}
                  title="Move down"
                >
                  <span class="hero-chevron-down size-3"></span>
                </button>
              </span>
              <%!-- ONE trailing control on every row of the block, whatever
                     the row holds. Marlowe, 2026-08-13: "for pinned items, it's a
                     little weird to see an 'x' with 3-dots menu, so we should
                     keep the interaction more consistent and just have a 3-dot
                     menu where one of the actions for a pinned item is to unpin
                     it."

                     This replaces a pair of controls that differed by kind: the
                     conversation rows carried `pin_control/1` wearing an x, and
                     the task rows carried an x of their own, each of them beside
                     the trigger. The two unpins are still different operations
                     in different tables — a conversation unpins through
                     `toggle_pinned` (the user's preferences), a task conversation
                     through `unpin_task_from_chat` (`task_chat_pins`,
                     participant-scoped self-unpin) — and the menu keeps them
                     apart. What is gone is the second control on the row.

                     Marlowe's 2026-08-12 ask for a visible way out of the block is
                     reversed here, by her, with a reason: a row wearing two ways
                     to act on it reads as two different objects. The way out is
                     the menu's first item on every pinned row, task rows
                     included, and it is the only item a task row's menu holds
                     ("task - unpin since it gets pinned from a diff page").

                     A task row's trigger is why `row_actions_dialog/1` resolves
                     its subject through `rail_row_actions_target/6` rather than
                     the sheet's resolver: a task-exec space is in neither
                     `@channels` nor `@dm_conversations`. --%>
              <.row_actions_trigger space_id={space.id} name={row_label} />
            </div>
          <% end %>
        </section>
      </div>
    <% end %>
    """
  end

  attr(:channel_sections, :map, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)

  @doc """
  The Direct Messages section. Always rendered, empty state included — an
  empty section keeps its header so the rail's structure stays visible.
  """
  def dm_section(assigns) do
    ~H"""
    <%!-- DMs section — always rendered, even when empty (Marlowe: empty
           sections keep their header so the rail's structure is visible).
           Section key: "dms". NOT reorderable (Stage 3) — locked under Pinned. --%>
    <section
      class="channel-section group"
      data-section-key="dms"
      data-section-reorderable="false"
      aria-label="Direct Messages"
    >
      <div class="channel-section-header">
        <span class="hero-chat-bubble-left-right size-3.5 text-base-content/60"></span>
        <p class="channel-section-label">Direct Messages</p>
        <button
          type="button"
          phx-click="new_conversation_open"
          class="text-base-content/40 hover:text-primary ml-auto"
          title="New conversation"
        >
          <span class="hero-plus size-4"></span>
        </button>
      </div>
      <%= if @channel_sections.dms == [] do %>
        <p class="channel-section-empty">
          No conversations yet — direct messages will appear here once you start one.
        </p>
      <% else %>
        <%!-- Row wrapper (stage 3). A DM row was a bare link with a name and
               an unread pill and carried no hover affordance of any kind, so
               the pin control is new here rather than an adjustment. Wrapping
               it moves the row's margin/rounding/hover background onto the
               wrapper (the scoped `.channel-row-wrap > .channel-row` rules)
               and leaves the row's own visible content untouched: still a
               bare display name, no glyph, no avatar. --%>
        <%= for space <- @channel_sections.dms do %>
          <%!-- Bound once (a DM's label costs a participants query) and used
                 as both the visible name and the pin control's target. --%>
          <% row_label = sidebar_row_label(space, @user_id) %>
          <div
            class={[
              "channel-row-wrap",
              @active_space && @active_space.id == space.id && "channel-row-wrap--active"
            ]}
            data-space-id={space.id}
          >
            <.link
              patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
              class={[
                "channel-row",
                @active_space && @active_space.id == space.id && "channel-row--active"
              ]}
            >
              <span class="truncate flex-1">{row_label}</span>
              <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                <span class="channel-row-unread-pill">
                  {unread_label(Map.get(@unread_counts, space.id, 0))}
                </span>
              <% end %>
            </.link>
            <%!-- One trigger, no pin (task 019ff8ba stage 1). A DM's menu
                   holds Pin alone: `hide_channel` has no reverse for a DM and
                   a person row has no org filing to move. --%>
            <.row_actions_trigger space_id={space.id} name={row_label} />
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  attr(:sidebar_sections, :list, required: true)
  attr(:scope_filter, :any, required: true)
  attr(:sidebar_edit, :boolean, required: true)
  attr(:sidebar_admin_edit, :boolean, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:root_admin?, :boolean, required: true)
  attr(:tenant_org_ids, :any, required: true)
  attr(:lifecycle_menu_key, :any, required: true)

  # THE MASK ATTRS. `mask_ctx` below is built from these three by
  # `SidebarMask.context/3`, and every section header, `data-section-key`,
  # `data-section-slug`, `aria-label` and channel-row label in this component
  # is spelled through it. Drop one of these declarations and the component
  # keeps rendering — with the real org names in it. See the moduledoc.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)

  @doc """
  The per-org sections, inside the rail's `#channel-membership-drag` hook
  scope.
  """
  def sub_org_sections(assigns) do
    ~H"""
    <%!-- Sub-org sections (chat sidebar v3 Stage 4). Rendered from
           `@sidebar_sections` — the org-default sections (one per org,
           `channel_sections` table) merged with the user's personal
           arrangement by `Sidebar.resolve_for_user/2`. Each entry is a
           `%{section, channels}`: `section.name` is the header label,
           `section.color` is the scope token driving the org pill, and
           `channels` are the spaces placed under it by `chat_spaces.org_id`.
           ALWAYS rendered, even when empty — empty sections keep their
           header + an empty-state hint so the rail's structure stays visible.

           Filtered by @scope_filter when set (Stage 4): nil → all sections;
           an atom filter → only the section whose color matches that scope.
           The filter is toggled by clicking the chat-header scope-pill. --%>
    <% visible_sections =
      if is_nil(@scope_filter) do
        @sidebar_sections
      else
        Enum.filter(@sidebar_sections, fn %{section: section} ->
          PlatformWeb.ChatLive.section_scope_atom(section.color) == @scope_filter
        end)
      end %>
    <%!-- Screen-share masking (task 01a00c66). Placeholders are derived from
           the FULL `@sidebar_sections`, not from `visible_sections`, so a scope
           filter narrowing the rail cannot relabel the sections that remain —
           the letter is a fixed position in the rail for the session.

           The display name is merged into each entry ONCE here rather than
           recomputed at each render site, because the name reaches the header
           through several derived strings (`data-section-key`, the section's
           own `aria-label`, the collapse toggle's accessible name, the Hide and
           Reorder labels) and a single missed site leaves the real name in the
           accessibility tree while the visible text reads `Workspace B`. That
           is the failure this feature is most likely to ship with, and it
           passes any test that only inspects rendered text. --%>
    <% mask_ctx =
      Platform.Chat.SidebarMask.context(
        @sidebar_sections,
        @mask_names?,
        @revealed_section_ids
      )

    visible_sections =
      Enum.map(visible_sections, fn %{section: section} = entry ->
        entry
        |> Map.put(:display_name, Platform.Chat.SidebarMask.label(mask_ctx, section))
        |> Map.put(:revealed?, MapSet.member?(@revealed_section_ids, section.id))
      end) %>
    <%!-- ChannelMembershipDrag wrapper (chat sidebar Stage 5). A SEPARATE
           hook element from the <nav>'s SectionReorder hook: an element can
           only carry one phx-hook, and the two drag behaviors target
           different draggables (channel rows here vs. section headers there).
           Both hooks are bubble-phase listeners; each ignores the other's
           dragstart source, so they coexist on overlapping DOM. The hook is
           inert unless `data-sidebar-edit="true"`, which is the only mode it
           reads now: admin-edit used to hand it a second, cross-org meaning
           via `data-admin-edit`, and that path was retired in favour of the
           explicit "Move to organisation…" action (task 019fd76a). --%>
    <div
      id="channel-membership-drag"
      phx-hook="ChannelMembershipDrag"
      data-sidebar-edit={to_string(@sidebar_edit)}
    >
      <%!-- `data-row-reorderable` says rows inside this section may be
             reordered. Separate from `data-section-reorderable`, which answers
             whether the SECTION may be dragged elsewhere and is what the
             SectionReorder hook reads. The Pinned block (task 019fe987)
             reorders its rows while staying locked at the top of the rail, so
             the two answers genuinely differ and one flag cannot carry
             both. --%>
      <%!-- `data-section-slug` follows the LABEL, not the record, while the
             mask is on: the colour token IS the org slug ("wayne-tech"), so an
             unmasked attribute spells the real name in the page source beside a
             header reading `Workspace B` — a leak that any assertion written
             against visible text passes straight over. Nothing reads the
             attribute at runtime (SectionReorder keys off `data-section-id`;
             the dot colour comes from `section_dot_class/1`). --%>
      <section
        :for={
          %{
            section: section,
            channels: section_channels,
            collapsed?: collapsed?,
            display_name: display_name,
            revealed?: revealed?
          } <-
            visible_sections
        }
        id={"section-#{section.id}"}
        class={[
          "channel-section group",
          (@mask_names? and revealed?) && "channel-section--revealed"
        ]}
        data-section-key={display_name}
        data-section-slug={
          if(@mask_names? and not revealed?,
            do: Platform.Chat.SidebarMask.slug(display_name),
            else: section.color
          )
        }
        data-section-id={section.id}
        data-section-reorderable="true"
        data-row-reorderable="true"
        draggable="true"
        aria-label={"#{display_name} channels"}
      >
        <div class="channel-section-header">
          <%!-- Admin-edit (Stage 6): inline rename form per section header.
                 Submitting (Enter / blur via phx-change is intentionally NOT
                 used — we only persist on explicit submit so a mid-typing
                 re-render can't fire a half-typed name). The hidden section_id
                 rides along so the server knows which org-default row to
                 rename. In personal-edit and normal modes the label is static
                 text. --%>
          <%!-- Collapse toggle (019fd80f stage 2). The header is a FLEX ROW
                 whose first child is this button; it is deliberately NOT a
                 wrapper around the whole header, because the header already
                 contains the Hide control and the drag handle and a button
                 inside a button is invalid markup that assistive tech resolves
                 unpredictably. Those two stay siblings of this toggle.

                 Posts the DESIRED next state (`collapsed`) rather than a flip,
                 so a double-fire from a render race is idempotent. The chevron
                 is decorative; the accessible name carries the section so a
                 screen-reader user hearing a list of toggles can tell them
                 apart. In admin-edit the rename input owns the section name, so
                 the toggle carries the chevron alone and the aria-label is the
                 only naming it needs. --%>
          <button
            type="button"
            class="channel-section-collapse-toggle"
            phx-click="toggle_section_collapsed"
            phx-value-section_id={section.id}
            phx-value-collapsed={to_string(!collapsed?)}
            aria-expanded={to_string(!collapsed?)}
            aria-label={
              if collapsed?,
                do: "Expand #{display_name}",
                else: "Collapse #{display_name}"
            }
          >
            <span
              class={[
                "channel-section-chevron",
                if(collapsed?, do: "hero-chevron-right", else: "hero-chevron-down"),
                "size-3"
              ]}
              aria-hidden="true"
            >
            </span>
            <span
              :if={not @sidebar_admin_edit}
              class="channel-section-label"
            >
              {display_name}
            </span>
          </button>
          <%!-- Admin-edit (Stage 6): inline rename form per section header.
                 Submitting (Enter / blur via phx-change is intentionally NOT
                 used — we only persist on explicit submit so a mid-typing
                 re-render can't fire a half-typed name). The hidden section_id
                 rides along so the server knows which org-default row to
                 rename. In personal-edit and normal modes the label is static
                 text. --%>
          <form
            :if={@sidebar_admin_edit}
            phx-submit="rename_section_default"
            class="channel-section-rename-form"
          >
            <%!-- Task 01a08212 stage 2 (Saru's canvas 01a0dff3-bb77, option
                   2b): the input is an OPTIONAL sidebar-only label, not the
                   org's name. Empty = follow the org, and the placeholder
                   showing the live org name is the whole explanation of that
                   state. The hint below the header says which state it is
                   in; its reset reuses `rename_section_default` with a blank
                   name, which clears the label. --%>
            <input type="hidden" name="section_id" value={section.id} />
            <input
              type="text"
              name="name"
              value={section.name}
              placeholder={section.org_name}
              class="channel-section-rename-input placeholder:text-base-content/40"
              aria-label={"Sidebar label for #{section.org_name}"}
              maxlength="60"
            />
          </form>
          <%!-- Color-only swatch. The section's IDENTITY text is `section.name`
                 (rendered above / in the rename input); this dot communicates
                 the section's COLOR and nothing else. Previously this slot held
                 a `<.scope_pill>` whose VISIBLE TEXT was derived from the color
                 token via the scope enum, so recoloring a section (e.g. the
                 root org → yellow) silently relabeled the chip to "Paragon". Decoupling:
                 a recolor now changes ONLY this dot, never any name/label. The
                 dot is decorative (aria-hidden) — `section.name` beside it is
                 the text identity. --%>
          <%!-- The span ALWAYS renders (task 01a00910 stage 4). Since buckets
                 derive from the orgs table, a section can carry a colour token
                 the vocabulary has never heard of, and `section_dot_class/1`
                 returns nil for it BY DESIGN — that nil is the signal, not a
                 missing clause, which is why there is no seventh clause over
                 there. Rendering nothing would slide this header's text one
                 dot-width left and ragged-edge the column, making the newest
                 org the one that looks broken; so the slot is reserved and the
                 dot is drawn hollow instead. `aria-hidden` in BOTH branches —
                 the dot is decorative either way, `section.name` is the text
                 identity.

                 A section wearing its OWN org's colour with no compiled class
                 (the root org on every install, and any org created at
                 runtime) also carries `data-scope` = its org slug, so the
                 slug-agnostic var path fills the hollow ring from the org's
                 row (task 01a116de stage 3). An org with no `color_hue`
                 emits no rule and stays hollow. Suppressed while the section
                 is masked: the slug is a spelling of the org's name. --%>
          <span
            class={[
              "channel-section-color-dot",
              PlatformWeb.ChatLive.section_dot_class(section.color) ||
                "channel-section-color-dot--unassigned"
            ]}
            data-scope={
              if(@mask_names? and not revealed?,
                do: nil,
                else: PlatformWeb.ChatLive.section_dot_scope(section)
              )
            }
            aria-hidden="true"
          >
          </span>
          <%!-- Per-item reveal (task 01a00c66). ONE click, no menu: the case
                 this serves is walking one client through their own channel
                 with the rest of the rail still masked. A real focusable
                 button rather than a hover affordance, because
                 `@media (hover: hover)` never matches on a touch device and
                 the control would vanish there entirely. --%>
          <button
            :if={@mask_names? and not revealed?}
            type="button"
            class="channel-section-reveal-button"
            phx-click="reveal_section"
            phx-value-section_id={section.id}
            aria-label="Show this workspace name"
          >
            <span class="hero-eye size-3.5" aria-hidden="true"></span>
          </button>
          <%!-- Per-section Hide/Show control (Stage 5, edit mode only).
                 Posts the DESIRED next hidden state so the toggle is
                 idempotent. A hidden section drops out of @sidebar_sections
                 entirely (resolver behavior), so the only way to bring it
                 back is the "Reset to default layout" button below — which
                 is why we never render a Show control inline here. --%>
          <button
            :if={@sidebar_edit}
            type="button"
            class="channel-section-hide-button"
            phx-click="toggle_section_hidden"
            phx-value-section_id={section.id}
            phx-value-hidden="true"
            aria-label={"Hide #{display_name} section"}
            title="Hide section"
          >
            <span class="hero-eye-slash size-3.5"></span>
          </button>
          <button
            type="button"
            class="channel-section-drag-handle"
            aria-label={"Reorder #{display_name} section"}
            tabindex="-1"
            draggable="true"
          >
            ☰
          </button>
          <%!-- Org archive / schedule-deletion (task 019f4eaa stage 6).
                 root-admin only, and only for tenant orgs — the root org's
                 section is never offered (the lifecycle refuses it). --%>
          <.lifecycle_menu
            :if={@root_admin? and MapSet.member?(@tenant_org_ids, section.org_id)}
            key={"org:#{section.org_id}"}
            open={@lifecycle_menu_key == "org:#{section.org_id}"}
            type="org"
            id={section.org_id}
            name={display_name}
            class="relative ml-auto opacity-0 focus-within:opacity-100 group-hover:opacity-100"
          />
        </div>
        <%!-- Admin-edit label hint (task 01a08212 stage 2): which state the
               header is in, below the header row at the palette's inset so it
               reads at the rail's full width rather than wrapping inside the
               input's column. The reset is phx-click, not a submit, so it
               needs no form around it. --%>
        <p
          :if={@sidebar_admin_edit and not custom_label?(section)}
          data-role="section-label-hint"
          class="px-3 pb-1 text-xs text-base-content/60"
        >
          Uses the organisation name.
        </p>
        <p
          :if={@sidebar_admin_edit and custom_label?(section)}
          data-role="section-label-hint"
          class="px-3 pb-1 text-xs text-base-content/60"
        >
          Sidebar label only. The organisation is {section.org_name}.
          <button
            type="button"
            data-role="section-label-reset"
            phx-click="rename_section_default"
            phx-value-section_id={section.id}
            phx-value-name=""
            class="font-medium text-[var(--color-interactive)] hover:underline focus-visible-ring"
          >
            Use organisation name
          </button>
        </p>
        <%!-- Admin-edit (Stage 6): compact recolor palette — the five
               sibling scope tokens plus the section's OWN org token ARE the
               palette (no free-form color picker). The own-org swatch is
               coloured through `data-scope` from the org's row, which is how
               the root org gets a swatch with no compiled colour class (task
               01a116de stage 3); it is omitted while the section is masked. Each swatch
               posts `recolor_section_default` with the section id + token; the
               active token is marked so the admin sees the current color. The
               server whitelist-validates the token and re-checks root_admin?
               before writing `channel_sections.color`. --%>
        <div
          :if={@sidebar_admin_edit}
          class="channel-section-palette"
          role="group"
          aria-label={"Set color for #{display_name} section"}
        >
          <% own_token = PlatformWeb.ChatLive.section_own_token(section)

          own_swatch? =
            is_binary(own_token) and
              own_token not in PlatformWeb.ChatLive.sibling_scope_tokens() and
              not (@mask_names? and not revealed?) %>
          <button
            :if={own_swatch?}
            type="button"
            phx-click="recolor_section_default"
            phx-value-section_id={section.id}
            phx-value-color={own_token}
            data-scope={section.org_slug}
            class={[
              "channel-section-swatch",
              "channel-section-swatch--own",
              section.color == own_token && "channel-section-swatch--active"
            ]}
            aria-pressed={to_string(section.color == own_token)}
            aria-label={"Color: #{own_token}"}
            title={own_token}
          >
          </button>
          <button
            :for={token <- PlatformWeb.ChatLive.sibling_scope_tokens()}
            type="button"
            phx-click="recolor_section_default"
            phx-value-section_id={section.id}
            phx-value-color={token}
            class={[
              "channel-section-swatch",
              "channel-section-swatch--#{token}",
              section.color == token && "channel-section-swatch--active"
            ]}
            aria-pressed={to_string(section.color == token)}
            aria-label={"Color: #{token}"}
            title={token}
          >
          </button>
        </div>
        <%!-- Section body (019fd80f stages 2-3). Collapse is NOT hide — a
               hidden section leaves the rail entirely (the resolver drops it),
               whereas a collapsed one keeps its place, its header and its
               resolved channels. THREE states, not two:

                 * expanded                — every channel row.
                 * collapsed, with activity — header plus only the rows with
                   unread: the "ajar group" below. This is what lets someone
                   keep four clients closed and still see anything that moved.
                 * collapsed, quiet         — header only, an ordinary accordion.

               `section_channel_rows/3` picks the rows and keeps each one's index
               in the FULL channel list, so the keyboard move controls on a
               peeked row still reason about the whole section. --%>
        <% rows = section_channel_rows(section_channels, collapsed?, @unread_counts) %>
        <p :if={not collapsed? and section_channels == []} class="channel-section-empty">
          No channels yet — channels in this org appear here.
        </p>
        <%!-- The ajar group. Peeked rows hang off the collapsed header on a
               2px left rule so they read as one object left ajar rather than as
               loose rows that failed to hide, and the group closes with a quiet
               "Show all (N)" line. Peeked rows are ORDINARY rows — not shrunk,
               dimmed or italicised — because they are the ones a person wants to
               click. There is deliberately no unread rollup on the collapsed
               header: it would restate the pills already visible on the rows
               beneath it. One number, in one place, in the "Show all (N)" line.

               Rendered only when there is something to render: an expanded empty
               section takes the hint above, and a collapsed quiet one takes
               nothing at all. --%>
        <div :if={rows != []} class={collapsed? && "channel-ajar-group"}>
          <%= for {space, idx} <- rows do %>
            <%= if MapSet.member?(@restricted_channel_ids, space.id) do %>
              <div
                data-role="restricted-channel-row"
                data-space-id={space.id}
                aria-disabled="true"
                class="channel-row text-base-content/50"
              >
                <span class="hero-lock-closed-mini size-3.5"></span>
                <span class="truncate flex-1">
                  {Platform.Chat.SidebarMask.channel_label(mask_ctx, section, space.name)}
                </span>
                <span class="text-xs">Restricted, ask an admin</span>
              </div>
            <% else %>
              <div
                class={[
                  "channel-row-wrap",
                  (@sidebar_edit || @sidebar_admin_edit) && "channel-row-wrap--editing",
                  @active_space && @active_space.id == space.id && "channel-row-wrap--active"
                ]}
                data-channel-id={space.id}
                data-space-id={space.id}
                data-section-id={section.id}
              >
                <%!-- Grab handle — PERSONAL edit only (Stage 5).
                   This span — not the row-wrap — carries draggable so it is the
                   HTML5 drag SOURCE node: dragstart's e.target is then this span,
                   so the ChannelMembershipDrag hook's `.channel-row-grab` gate
                   matches (mirroring SectionReorder, whose handle is the source
                   too). A click on the row link still navigates because the link
                   isn't draggable. tabindex=-1 because the keyboard alternative
                   is the Up/Down buttons.

                   Admin-edit renders NO handle (task 019fd76a stage 2). The
                   gesture used to mean "refile this channel's org for
                   everyone", which is a company-wide act with an invisible
                   consequence — it re-points canvas read access — and it now
                   lives behind the "Move to organisation…" item on the row's
                   overflow menu, with a confirmation dialog. Dragging a row
                   means one thing in one mode: reorder it in my own rail. --%>
                <span
                  :if={@sidebar_edit}
                  class="channel-row-grab"
                  aria-hidden="true"
                  title="Drag to move"
                  draggable="true"
                >
                  ⠿
                </span>
                <.link
                  patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
                  class={[
                    "channel-row",
                    @active_space && @active_space.id == space.id && "channel-row--active"
                  ]}
                >
                  <span class="text-base-content/40">#</span>
                  <span class="truncate flex-1">
                    {Platform.Chat.SidebarMask.channel_label(mask_ctx, section, space.name)}
                  </span>
                  <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                    <span class="channel-row-unread-pill">
                      {unread_label(Map.get(@unread_counts, space.id, 0))}
                    </span>
                  <% end %>
                </.link>
                <%!-- Keyboard move controls (Stage 5, edit mode only — WCAG
                   2.1.1 keyboard alternative to drag). Each posts the same
                   `move_channel` event the keyboard path shares with drag's
                   `channel_moved` persistence. Up is disabled on the first
                   row, Down on the last, so focus can't trigger a no-op
                   that reads as broken. --%>
                <span :if={@sidebar_edit} class="channel-row-move-controls">
                  <button
                    type="button"
                    class="channel-row-move-button"
                    phx-click="move_channel"
                    phx-value-channel_id={space.id}
                    phx-value-section_id={section.id}
                    phx-value-direction="up"
                    disabled={idx == 0}
                    aria-label={
                    "Move ##{Platform.Chat.SidebarMask.channel_label(mask_ctx, section, space.name)} up"
                  }
                    title="Move up"
                  >
                    <span class="hero-chevron-up size-3"></span>
                  </button>
                  <button
                    type="button"
                    class="channel-row-move-button"
                    phx-click="move_channel"
                    phx-value-channel_id={space.id}
                    phx-value-section_id={section.id}
                    phx-value-direction="down"
                    disabled={idx == length(section_channels) - 1}
                    aria-label={
                    "Move ##{Platform.Chat.SidebarMask.channel_label(mask_ctx, section, space.name)} down"
                  }
                    title="Move down"
                  >
                    <span class="hero-chevron-down size-3"></span>
                  </button>
                </span>
                <%!-- The row's only trailing control (task 019ff8ba stage 1,
                   Option C). Pin, "Move to organisation…" and the eye-slash
                   hide button all stood here at rest, on every row of the
                   rail, all the time. Marlowe, 2026-08-13: the pin leaves the
                   row in EVERY mode, not only while arranging.

                   Available in NORMAL mode, for the reason the pin was:
                   pinning is how you use the rail, not an act of rearranging
                   it, and gating it behind "Edit my layout" would put a
                   two-step preamble in front of it.

                   Rows in this section are unpinned by definition — a pinned
                   channel is lifted into the Pinned block above — so the
                   menu's first item is always the Pin direction here. --%>
                <.row_actions_trigger
                  space_id={space.id}
                  name={Platform.Chat.SidebarMask.channel_label(mask_ctx, section, space.name)}
                />
              </div>
            <% end %>
          <% end %>
          <%!-- "Show all (N)": the line that stops a partial list reading as a
                 rendering bug. N is the section's TOTAL channel count, so it
                 answers "where did the rest go" at the moment a person asks it.
                 It is a real focusable control and it doubles as the expand
                 target, posting the same DESIRED-state event as the header
                 toggle. Its accessible name carries the count AND the section
                 because the left rule that groups these rows communicates
                 nothing to a screen reader: without it, someone hearing two
                 channels under a heading has no way to know seven are
                 withheld. --%>
          <button
            :if={collapsed?}
            type="button"
            class="channel-ajar-show-all"
            phx-click="toggle_section_collapsed"
            phx-value-section_id={section.id}
            phx-value-collapsed="false"
            aria-label={"Show all #{length(section_channels)} channels in #{display_name}"}
          >
            Show all ({length(section_channels)})
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr(:archived_channels, :list, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:active_space, :any, required: true)

  # THE MASK ATTRS — see the moduledoc. The archived rows render a space name
  # through `ChatLive.masked_space_name/2`, whose lookup is tolerant, so
  # omitting these three unmasks the Archived group while the rest of the
  # rail stays masked.
  attr(:sidebar_sections, :list, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)

  @doc """
  The Archived group. Renders only when at least one archived channel exists;
  collapsed by default.
  """
  def archived_section(assigns) do
    assigns = assign(assigns, :mask_assigns, Map.take(assigns, @mask_keys))

    ~H"""
    <%!-- Archived channels (task 019e95ea stage 2). Renders only when at
           least one archived channel exists; collapsed by default with a
           phx-click toggle (same idea as the hidden-channels drawer below —
           quiet until asked for). Rows stay OUT of @channel_sections /
           @sidebar_sections: archived channels never mix into the active
           buckets, they only live here. Muted treatment mirrors the
           hidden-channels rows; the row still navigates so the read-only
           snapshot stays reachable. --%>
    <section
      :if={@archived_channels != []}
      class="channel-section"
      data-section-key="archived"
      data-section-reorderable="false"
      aria-label="Archived channels"
    >
      <button
        type="button"
        class="channel-section-header w-full text-left"
        phx-click="toggle_archived_section"
        aria-expanded={if @archived_open, do: "true", else: "false"}
        aria-controls="archived-channel-list"
      >
        <span class="hero-archive-box size-3.5 text-base-content/40"></span>
        <p class="channel-section-label">Archived</p>
        <span class="ml-auto text-base-content/40 text-xs">
          {if @archived_open, do: "▾", else: "▸"}
        </span>
      </button>
      <div :if={@archived_open} id="archived-channel-list">
        <%= for space <- @archived_channels do %>
          <%= if MapSet.member?(@restricted_channel_ids, space.id) do %>
            <div
              data-role="restricted-channel-row"
              data-space-id={space.id}
              aria-disabled="true"
              class="channel-row text-base-content/50"
            >
              <span class="hero-lock-closed-mini size-3.5"></span>
              <span class="truncate flex-1">{mask_name(@mask_assigns, space.name)}</span>
              <span class="text-xs">Restricted, ask an admin</span>
            </div>
          <% else %>
            <.link
              patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
              class={[
                "channel-row text-base-content/50",
                @active_space && @active_space.id == space.id && "channel-row--active"
              ]}
            >
              <span class="hero-archive-box size-3.5 text-base-content/30"></span>
              <span class="truncate flex-1">{mask_name(@mask_assigns, space.name)}</span>
            </.link>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  attr(:undo_toast, :any, required: true)
  attr(:move_toast, :any, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:hidden_drawer_open, :boolean, required: true)

  # THE MASK ATTRS — see the moduledoc. The hidden-channels drawer renders
  # both org names (via `SidebarMask.label_for_bucket/3`) and channel names
  # (via `ChatLive.masked_space_name/2`), so a drawer that lost these three
  # would spell the real names underneath a masked rail.
  attr(:sidebar_sections, :list, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)

  @doc """
  Everything below the scrolling `<nav>`: the undo toast, the move-confirmation
  toast, `+ New channel`, the global hidden-channels drawer and the resize
  drag handle.

  These are ONE component because their vertical order is the contract: the
  toasts are in-flow `flex-shrink-0` siblings so `+ New channel` and the
  drawer trigger never move when a toast appears.
  """
  def rail_footer(assigns) do
    assigns = assign(assigns, :mask_assigns, Map.take(assigns, @mask_keys))

    ~H"""
    <%!-- Undo toast — ephemeral 4-second affordance shown after a hide
         (Stage 3 v3 follow-up per Marlowe's 2026-05-29 review). Lives as
         an IN-FLOW `flex-shrink-0` sibling between the scrolling `<nav>`
         (`flex-1`) above and the pinned "+ New channel" button below.
         When the toast appears, the `flex-1` scroll nav absorbs its
         height by shrinking — so "+ New channel" stays exactly where it
         is, the drawer stays exactly where it is, and the toast doesn't
         overlap any content. Trades a soft scroll-area compression for
         stable pinned chrome (the right exchange — overlap with content
         is the actual user complaint; transient scroll compression is
         the standard chat-rail behavior, same way Slack/Discord handle
         compose-area system notes).

         role=status + aria-live=polite (NOT assertive) — hiding a
         channel is non-destructive (nothing deleted, only user-filtered)
         so a polite announcement is the right WCAG choice. The Undo
         button shares its handler with the drawer's Show buttons via
         do_unhide/2 in the LiveView, so the round-trip is identical
         regardless of which way the user reverses the hide. Auto-clears
         via a Process.send_after → handle_info({:clear_undo_toast,
         space_id}) pair scheduled by the hide_channel handler.

         HIDE ONLY. Task 019ffc5f stage 2 gave this toast a second variant
         for the DM Close action, and stage 3 gave that variant a second
         line teaching the rule that brings the row back. Marlowe rejected it
         at the stage-3 gate: "We don't need a acknowledgement / affirmation
         for a close action on a DM. A User can simply search for a person
         or agent to DM again if they want to bring back the window." So a
         close now passes silently and this element is back to the single
         verb it shipped with. Hide keeps it because Hide's reverse is a
         drawer, and the toast is the only thing that says the drawer now
         has something in it. --%>
    <div
      :if={@undo_toast}
      role="status"
      aria-live="polite"
      class="channel-undo-toast"
    >
      <span class="channel-undo-toast-message">
        Hidden <span class="font-medium">#{@undo_toast.name}</span>
      </span>
      <button
        type="button"
        class="channel-undo-toast-button"
        phx-click="undo_hide"
        phx-value-id={@undo_toast.space_id}
      >
        Undo
      </button>
    </div>

    <%!-- Move confirmation (task 019ffcad stage 4, from the design canvas).
         Says what just happened after a root-org admin files a channel into
         another organisation. Stages 1 to 3 put the row in its new section
         and make it visible there; the admin is looking at the section it
         LEFT, where the only observable event is a row disappearing.

         The hide toast's component, its position, and its 4s dismissal, with
         the copy and the handler changed and no action button. Undo is out of
         scope for this stage: the move already carries a two-step confirmation
         and the row's own menu moves the channel back in one click. Marlowe's
         separate decision to offer an Undo here is task
         01a01052-3155-7c15-8c48-9ff8955b9b70.

         A SEPARATE assign from `@undo_toast`. Hide and Move are two verbs a
         person can perform seconds apart, and sharing one assign would have
         whichever came second silently blank the first, which is invisible to
         any test that fires only one of them.

         Both names in one sentence. "Moved #gen-migration." leaves the reader
         checking where it went, which is the work this line exists to save.
         The destination is the SECTION's name, so the sentence echoes the word
         the admin just clicked in the chooser (an admin can rename a section
         away from its org's name).

         `channel-move-toast-message` instead of `channel-undo-toast-message`:
         the same flex slot WITHOUT `truncate`. The rail is ~224px wide, and a
         two-name sentence under `truncate` ellipsises from the right, which
         eats the destination: the exact half the copy rule exists to keep. It
         wraps to two lines instead, as the canvas wireframe draws it. The
         toast SURFACE is untouched, so Hide's toast is unchanged.

         Desktop only, like the hide toast: there is no mobile-drawer copy of
         either. --%>
    <div
      :if={@move_toast}
      data-role="channel-move-toast"
      role="status"
      aria-live="polite"
      class="channel-undo-toast"
    >
      <span class="channel-move-toast-message">
        Moved #{@move_toast.channel_name} to {@move_toast.section_name}.
      </span>
    </div>

    <%!-- "+ New channel" — pinned rail chrome (Stage 3 v3 follow-up per
         Marlowe's review). Lives as an UNCONDITIONAL `flex-shrink-0` sibling
         of `<nav>` and the conditional bottom-region wrapper, so its
         visual position never drifts based on channel count OR on whether
         the undo toast / hidden drawer happens to be showing. The wrapper
         was deliberately NOT merged into the bottom-region's `:if` block —
         doing so would yank the button out of view whenever both toast
         and drawer are absent, reintroducing the "position depends on
         state" bug. Visual divider above is a top border using the same
         `border-base-content/10` token the aside itself uses, so the
         rail's separator language stays consistent. Reuses the
         channel-row hover/text vocabulary so the button rhymes visually
         with the section rows above. --%>
    <button
      type="button"
      phx-click="new_channel_open"
      aria-label="New channel"
      class="flex-shrink-0 flex items-center gap-2 w-full border-t border-base-content/10 px-3 py-2 text-sm text-base-content/70 hover:text-primary hover:bg-base-300 transition-colors"
    >
      <span class="hero-plus size-4"></span>
      <span>New channel</span>
    </button>

    <%!-- Bottom region (Stage 3 v3): hosts the global "N hidden channels"
         drawer ONLY. Silent at N=0 — the wrapper is :if-gated to
         `hidden_count > 0` so it disappears entirely when the user has
         no hidden channels, keeping the sidebar foot empty in the clean
         state. The undo toast used to live here too but moved up to its
         own in-flow position above "+ New channel" — keeps pinned chrome
         (+ New channel, drawer trigger) stable when a hide fires, since
         the scroll-nav (flex-1) absorbs the toast's height instead. --%>
    <% hidden_count =
      @channel_sections.hidden_sub_orgs
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum() %>
    <div
      :if={hidden_count > 0}
      class="flex-shrink-0 border-t border-base-content/10 px-2 py-2"
    >
      <%!-- Global "N hidden channels" drawer (Option B per Marlowe's v3
           review). One quiet row at the rail's foot — silent at N=0 —
           expanding upward into a scrollable grouped list. The panel
           ALWAYS renders so the max-height CSS transition animates in
           and out smoothly; the `--open` modifier on the wrapper drives
           the transition. Internal scroll caps the panel at min(50vh,
           360px) so it can't claim more than half the sidebar at very
           high hidden counts. Each Show button shares the unhide_channel
           handler with the (now-removed) v2 inline list, so behavior is
           identical to v2 — only the trigger surface changed. --%>
      <div
        :if={hidden_count > 0}
        class={[
          "channel-hidden-drawer",
          @hidden_drawer_open && "channel-hidden-drawer--open"
        ]}
      >
        <div
          id="hidden-drawer-panel"
          class="channel-hidden-drawer-panel"
          aria-hidden={if @hidden_drawer_open, do: "false", else: "true"}
        >
          <%= for {bucket, hidden_channels} <- @channel_sections.hidden_sub_orgs,
                  hidden_channels != [] do %>
            <div class="channel-hidden-drawer-group">
              <div class="channel-hidden-drawer-group-label">
                <%!-- Each bucket is an org NAME, and `bucket_orgs` (task 01a0938b)
                     maps it to that org's row: its slug, its name and the
                     value `scope_pill`'s `scope` attr takes (one of the six
                     compiled atoms, or the slug binary as stored for any org
                     created at runtime). Every org row therefore renders a
                     pill, whatever its slug. `scope_pill` is total since
                     01a09287 stage 2: `scope_label/1` title-cases any slug,
                     the var-path colour classes are slug-agnostic, and a
                     colour arrives only through `ScopeColorStyles`' rule for
                     the chip's `data-scope`, so an org with no `color_hue`
                     gets an uncoloured pill rather than a crash.

                     The plain-name `<span>` is reached only by a bucket with
                     no org row behind it: the default bucket, on an install
                     that has no org of that name.

                     Call-site contract, shared with both chat header pills:
                     `label` is the placeholder when masked and the org's NAME
                     otherwise (the slug title-cased is not always the name:
                     `new_client` would read "New Client" for Newclient), and
                     `value` is the org's SLUG unmasked and nil masked.
                     `value` is load-bearing: `scope_pill` emits no
                     `data-scope` for a binary `label` without one, and every
                     colour rule is keyed on `data-scope`. --%>
                <% bucket_org = @channel_sections.bucket_orgs[bucket]

                hidden_mask_ctx =
                  Platform.Chat.SidebarMask.context(
                    @sidebar_sections,
                    @mask_names?,
                    @revealed_section_ids
                  )

                bucket_label =
                  Platform.Chat.SidebarMask.label_for_bucket(
                    hidden_mask_ctx,
                    @sidebar_sections,
                    bucket
                  ) %>
                <%!-- Screen-share masking (task 01a00c66 stage 3). This heading
                     is an ORG NAME, so it masks like every other one — a rail
                     reading `Workspace B` above a hidden-channels group reading
                     the real name has leaked exactly what the mode hides. The
                     placeholder is passed IN; `scope_pill` holds no mask table
                     of its own, because a second copy drifts and the copy that
                     drifts is the one nobody is looking at. --%>
                <%!-- `surface` is declared, not inherited (task 01a09333-d374):
                     this drawer sets no fill, so the chip sits on the rail
                     `<aside>`'s `bg-base-200`. --%>
                <.scope_pill
                  :if={bucket_org}
                  scope={bucket_org.scope}
                  surface={:base_200}
                  clickable={false}
                  label={if @mask_names?, do: bucket_label, else: bucket_org.name}
                  value={if @mask_names?, do: nil, else: bucket_org.slug}
                />
                <span
                  :if={is_nil(bucket_org)}
                  class="text-xs font-semibold uppercase tracking-wide text-base-content/50"
                >
                  {bucket_label}
                </span>
              </div>
              <ul class="channel-hidden-drawer-group-list">
                <li
                  :for={space <- hidden_channels}
                  class="channel-hidden-drawer-item"
                >
                  <span class="text-base-content/40">#</span>
                  <span class="truncate flex-1">{mask_name(@mask_assigns, space.name)}</span>
                  <button
                    type="button"
                    class="channel-hidden-drawer-show"
                    phx-click="unhide_channel"
                    phx-value-id={space.id}
                    aria-label={"Show ##{mask_name(@mask_assigns, space.name)}"}
                  >
                    Show
                  </button>
                </li>
              </ul>
            </div>
          <% end %>
        </div>
        <button
          type="button"
          class="channel-hidden-drawer-trigger"
          phx-click="toggle_hidden_drawer"
          aria-expanded={if @hidden_drawer_open, do: "true", else: "false"}
          aria-controls="hidden-drawer-panel"
          aria-label={
            if @hidden_drawer_open,
              do: "Collapse hidden channels",
              else: "Show #{hidden_count} hidden channels"
          }
        >
          <span class="flex-1 text-left">
            {hidden_count} hidden {if hidden_count == 1, do: "channel", else: "channels"}
          </span>
          <span class="channel-hidden-drawer-caret">
            {if @hidden_drawer_open, do: "▾", else: "▴"}
          </span>
        </button>
      </div>
    </div>
    <%!-- Drag handle for sidebar resize --%>
    <div
      class="absolute right-0 inset-y-0 w-1 cursor-col-resize hover:bg-primary/40 active:bg-primary/60 transition-colors z-10"
      aria-hidden="true"
    />
    """
  end

  # `ChatLive.masked_space_name/2` under a shorter name, called only from this
  # module's own markup.
  #
  # It exists for one reason and it is not aesthetic. Inside
  # `chat_live.html.heex` the call was the unqualified `masked_space_name(...)`;
  # here it has to be qualified (ChatLive imports this module, so this module
  # cannot import ChatLive), and the qualified form is long enough to push
  # `<span class="truncate flex-1">{...}</span>` past the formatter's line
  # width. The formatter then reflows the span onto three lines, which puts
  # WHITESPACE INSIDE the span — a real change in the rendered HTML of a stage
  # whose whole claim is that the rendered HTML does not change. Shortening the
  # name keeps the line intact and the render byte-identical; the render-diff
  # harness caught this on the drawer rows and nowhere else.
  defp mask_name(mask_assigns, name), do: ChatLive.masked_space_name(mask_assigns, name)

  # Task 01a08212: whether the admin set a sidebar-only label on this section,
  # i.e. whether `Section.display_name/1` reads the stored `name` rather than
  # the org's. Keyed on the same non-blank test so the hint can never disagree
  # with the header it describes.
  defp custom_label?(%{name: name}) when is_binary(name), do: String.trim(name) != ""
  defp custom_label?(_section), do: false
end
