defmodule PlatformWeb.ChatLive.Partials.ChatList do
  @moduledoc """
  The Chat list: `<section id="chat-list">`. The phone Chat tab at `/chat`
  (task 01a1557a-8562, Burrow redesign rung 6, stage 2), and since Burrow
  redesign 22 stage 2 also the desktop list pane (see `## Desktop list pane`).

  Same split as `ChatLive.Partials` and `Partials.ExternalRail` (ADR 0035):
  function components, no state, each taking a declared set of attrs. The
  render gate lives INSIDE `chat_list/1` (`:index` or `:show`, not
  embedded), so the call site in `chat_live.html.heex` states no condition
  of its own.

  ## Desktop list pane (Burrow redesign 22 stage 2)

  master-desktop.html `#list` (L594, CSS L46-52, L563). At lg the list sits
  beside the conversation on `/chat` and `/chat/:slug`: 280px, 240px at or
  below 1100px, base-200 with a right `border-edge` (`pane_class/2`). It
  replaced the desktop channel rail (`Partials.Rail`) and the external rail,
  both deleted. Below lg nothing changed: `/chat` is the full-width list and
  `/chat/:slug` hides it (`hidden lg:flex`), so the phone sees only the
  conversation. A desktop `/chat` still patches into a channel once
  `ViewportBreakpoint` reports the side of `lg` it is on.

    * The open conversation's row carries `aria-current="page"` and the
      base-300 fill; rows fill base-300 on hover, at lg only.
    * The header grows to 52px with a bottom edge; under "Chat" the line
      reads "{n} spaces · {m} direct" (the rows under Spaces and Direct), or
      "names masked" while masked.
    * The three header buttons open `Partials.ListPopover` at lg (the bottom
      sheets keep `lg:hidden`), from the same `@list_sheet`.
    * Right-clicking a row opens `row_actions_dialog/1` (`RowContextMenu` on
      the root pushes `open_row_actions`), on the rows that offer the phone's
      long-press sheet.
    * An external user gets the list at lg only, holding just their own
      channels and conversations: no Agents row, no pinned tasks, no
      Archived, no New channel, no Options. Their identity and Log out sit at
      its foot, because the external layout has no sidebar.

  Rows keep the phone's metrics on desktop (one rendering model).

  ## Order

  Sections: PINNED (the Agents row, then `ChatLive.pinned_rail_entries/2`),
  SPACES (every sub-org section of `@sidebar_sections` flattened into ONE
  list: the phone shows Spaces as one section), DIRECT
  (`@channel_sections.dms`, the rail's Direct list: pinned and closed
  conversations already removed, so no row appears twice) and ARCHIVED (only
  while `@archived_open`).

  Inside Spaces, Direct and Archived rows sort by recency
  (`ChatListData.sort_by_recency/3`, task 01a166bf stage 1): newest top-level
  message first, rows with no message last by name. The sort runs here, in
  the component, over `@list_excerpts`, which `ChatListData.put_message/2`
  patches live, so an arriving message moves its row on the next render.

  Pinned is the exception (task 01a1557b): the Agents row stays FIRST (it is
  a derived entry, not a pin), then the pinned TASK conversations by recency,
  then the pinned conversations in the user's SAVED order
  (`chat_pinned_spaces`, exactly as `ChatLive.pinned_rail_entries/2` returns
  it). A message in a pinned conversation never moves it, and the hold does
  not re-order that run. A new pin appends at its end.

  The only manual order is that saved Pinned order, written by
  `PlatformWeb.ChatLive.PinnedReorderHooks` on desktop. Everything else is
  recency. The desktop rail's curated order and edit mode went with the rail
  in Burrow redesign 22 stage 2, and the phone shows the saved order with no
  reorder control.

  ## Holding the order (task 01a166bf stage 4)

  No row moves while the reader is touching or scrolling the list. The
  `ChatListSettle` hook on `#chat-list-scroller` pushes `chat_list_hold` on
  pointerdown, touchstart or scroll, and `chat_list_release` once no pointer
  is down and no scroll has fired for 600ms. `ChatListHooks` keeps
  `@list_order_hold`, `%{section => [space ids as displayed]}` snapshotted
  from `section_order/1` when the hold began, and auto-releases it 10s
  after the latest hold (a ref-checked timer, so a stale one is ignored);
  leaving the list clears it.

  While held each section renders in snapshot order with unknown ids last
  (`ChatListData.order_rows/4`); excerpt, time, weight and dot keep reading
  the live assigns, so ONLY order freezes. On release the list re-sorts once
  and the hook slides moved rows over 200ms (FLIP), or jumps them under
  `prefers-reduced-motion`.

  ## Folding (task 01a166bf stage 3)

  Every section header (Pinned, Spaces, Direct, Archived) is a `<button>`
  inside its `<h2>`, carrying `aria-expanded` and `aria-controls`. A tap
  pushes the EXISTING `toggle_section_collapsed` event with the DESIRED next
  state, so the fold persists through `Sidebar.set_section_collapsed/3` in
  the user's `chat_collapsed_sections` preference and its broadcast converges
  the user's other sessions. No new event, preference key or store.

  The keys are `"chat-list:pinned"`, `"chat-list:spaces"`,
  `"chat-list:direct"` and `"chat-list:archived"`. Spaces folds as ONE (the
  list has one Spaces header). `ChatLive` reads the set into
  `@list_collapsed` at mount and in every `recompute_sidebar/1`.

  A folded section renders no rows (nor its empty state). Its header always
  shows how many rows the fold hides beside the label ("SPACES · 41", the
  label's own `text-subtle`, `aria-hidden` with an sr-only "41
  conversations"), counted from the same rows the section renders when
  expanded, Pinned counting the Agents row. A folded section with 0 rows
  keeps its bare header, so "· 0" never appears. Separately, on the right,
  it shows the unread dot plus the number of unread CONVERSATIONS (not
  messages) when any row in it has unread. An expanded header shows neither.
  Archived never shows a count or a marker. Archived is still shown only behind
  the "Show archived" switch; once shown it folds like the rest.

  Accepted side effect: `Sidebar.reset_to_default/1` clears the whole
  `chat_collapsed_sections` key, so the desktop layout reset also unfolds the
  phone list.

  ## Every row is a plain patch link

  No `phx-click` on any link in this list. A bare-string `phx-click` on a
  `patch`/`navigate` link throws in the client, and a `JS.push` on one never
  reaches the server (rung 5 measured 0 of 45 taps). State that must reset
  when the reader leaves the list resets in `handle_params/3` for `:show`.
  `chat_live_chat_list_test.exs` refutes a `phx-click` on any link here.

  ## Paint (Saru's ruling, canvas 01a15d7c `ground`)

  The list ground is base-200. A pressed row paints base-100 (`active:`).
  Hover exists only at lg (`lg:hover:`), on the desktop list pane. The notification banner lifts off the list on base-100 with
  `border-edge`, as a sheet does. Text is body or `text-subtle`, nothing else.
  The pairs are measured in all ten variants by
  `test/platform/design/chat_list_contrast_guard_test.exs`.

  Weight, not colour, marks unread: a row's name is `font-semibold` when it
  has unread and `font-normal` when read, always `text-base-content`. The
  excerpt and time follow the same flag, `text-base-content` unread and
  `text-subtle` read. Two weights only (400, 600).

  ## Channel rows (dense, Slack # / lock)

  The product owner's pick from canvas 01a16e53 (options 5 "No icon (dense)"
  and 2 "Slack # / lock"). A row is DENSE when the row is a channel row and
  the space is `kind: "channel"` (`dense_row?/2`): one line, at least 44px
  from `min-h-11`, indented `pl-7` under the section header as option 5 is,
  an 18px glyph, the name, and on unread a count pill in neutral tokens
  (base-content on base-300, never primary). No disc, no time, no excerpt;
  the excerpt is still loaded, because recency order reads it.

    * `#` (`hero-hashtag`) for a channel anyone can open.
    * a lock (`hero-lock-closed`) for a PRIVATE channel: one carrying a role
      restriction (`Platform.Access.Restrictions`) that the reader passes,
      `@list_private_ids` (`ChatListData.load_private_ids/1`).
    * `hero-no-symbol` for a RESTRICTED channel the reader cannot open,
      unlinked, so it never shares the lock with "private".

  Unread draws the glyph solid and base-content, as the name goes semibold;
  read is the outline glyph in `text-subtle`.

  Everything else keeps the 42px avatar, time and excerpt: DMs, agent DMs
  (accent ring), the Agents row (a derived entry led by its agent), pinned
  task conversations (check disc), and any non-channel space in a channel
  row (an execution or system space keeps its initial disc: `#` claims
  "channel"). A group (`kind: "group"`) draws `hero-user-group` in the disc,
  so "Sam, Alex" stops reading as a DM.

  ## Pinned reorder (Burrow redesign 25 stage 2, canvas 01a17470)

  Only a pinned CONVERSATION row with a link reorders (`reorder`): it
  carries `data-reorder="true"`, `data-pinned-position` (its 0-based
  `move_index` in the server's conversation run) and `data-pinned-count`.
  A restricted pinned row carries `data-pinned-position` alone. Task rows,
  the Agents row and every unpinned row get none of it, and a folded Pinned
  renders no rows, so no grips.

  The grip lives in the time column: `hidden` at rest and below lg, shown
  only by `lg:group-hover/row` and `lg:group-focus-visible/row` on the row
  link (every row link is `group/row relative`). The time (or, on a dense
  row, the unread pill) goes `invisible` and keeps its box, so the name's
  box is the same at rest and on hover. The row menu's Move up / Move down
  push `move_pinned_step` (`Partials.row_actions_dialog/1`).

  The drag and the Alt+arrow keys belong to the `PinnedReorder` hook
  (`assets/js/hooks/pinned_reorder.js`), mounted on `#chat-list-rows-pinned`
  and on no other section's rows. Desktop (lg) mouse and pen only. It draws
  the lifted row, the origin-slot outline and the drop line into
  `#pinned-reorder-overlay` (`phx-update="ignore"`), so a patch mid-drag
  cannot strip them, and it pushes `move_pinned_row` or `move_pinned_step`.

  `#pinned-reorder-announcer` is always rendered and speaks
  `@pinned_announcement`. `#pinned-undo-toast` renders once while
  `@pinned_undo` is set, desktop only, on the base-100 surface with no
  primary.

  ## THE MASKING ATTRS ARE NOT OPTIONAL

  `ChatLive.masked_space_name/2` reads `:sidebar_sections`, `:mask_names?` and
  `:revealed_section_ids` through TOLERANT access, so a component that forgets
  to declare them renders REAL names with the mask on and passes every markup
  assertion. `chat_list/1` declares all three and hands `Map.take(assigns,
  @mask_keys)` down, as `Partials.ExternalRail` does.

  What the mask covers here is EXACTLY the existing org-derived rule
  (`SidebarMask.space_label/3`), the same toggle every chat surface obeys:
  an org-derived channel name masks, a project-code channel (`#atlas`) and a
  person's name do not. On top of that, while masked:

    * every excerpt renders as one fixed-length placeholder, so neither its
      text nor its length leaks, and the row does not change height;
    * a row whose name the rule masked draws a neutral base-300 disc with no
      initial and no agent accent, because the initial would spell the start
      of the name (Saru, canvas 01a15d7c rev 4).

  There is no per-section reveal and no mask strip on the list (coverage row
  20 is DROP).
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.RenderHelpers, only: [unread_label: 1, search_headline: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS

  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.ChatListData

  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  # The masked excerpt. Fixed length on purpose: a placeholder whose length
  # tracked the hidden text would publish it.
  @masked_excerpt "••••••••••••••••••••"

  attr(:live_action, :atom, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  # The three masking attrs (see the moduledoc).
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
  attr(:restricted_channel_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  # Private channels the reader can open: the lock glyph (`## Channel rows`).
  attr(:list_private_ids, :any, required: true)
  # The phone fold keys from `chat_collapsed_sections` (stage 3, `## Folding`).
  attr(:list_collapsed, :any, required: true)
  # The held order, or nil (stage 4, `## Holding the order`).
  attr(:list_order_hold, :any, default: nil)
  attr(:push_permission, :any, required: true)
  attr(:notification_banner_dismissed, :boolean, required: true)
  # The sheets (stage 3): `ChatListHooks` owns all three.
  attr(:list_sheet, :any, required: true)
  attr(:list_search_query, :string, required: true)
  attr(:list_search_results, :map, required: true)
  # The desktop list pane (Burrow redesign 22 stage 2, `## Desktop list pane`).
  attr(:active_space, :any, default: nil)
  attr(:external_user, :any, default: nil)
  attr(:hidden_drawer_open, :boolean, default: false)
  attr(:resolved_mode, :string, default: "dark")
  # Pinned reorder (Burrow redesign 25 stage 2, `## Pinned reorder`): the
  # live-region text and the burst's undo state, both owned by
  # `PinnedReorderHooks`.
  attr(:pinned_announcement, :any, default: nil)
  attr(:pinned_undo, :any, default: nil)

  @doc "The list. Renders nothing unless the gate in the moduledoc holds."
  def chat_list(assigns) do
    assigns =
      assigns
      |> assign(:mask_assigns, Map.take(assigns, @mask_keys))
      |> external_scrub()
      |> assign(:active_id, active_id(assigns.active_space))
      |> assign_sorted_rows()
      |> assign_folds()

    ~H"""
    <section
      :if={@live_action in [:index, :show] and !@embedded}
      id="chat-list"
      data-role="chat-list"
      phx-hook="RowContextMenu"
      data-context-event="open_row_actions"
      class={pane_class(@live_action, @external?)}
      aria-label="Chat"
    >
      <header class="relative flex h-12 flex-shrink-0 items-center gap-1 pl-4 pr-2 lg:h-[52px] lg:border-b lg:border-edge lg:px-3">
        <div class="contents lg:flex lg:min-w-0 lg:flex-1 lg:flex-col">
          <h1 class="text-lg font-semibold">Chat</h1>
          <span
            data-role="chat-list-subtitle"
            class="min-w-0 flex-1 truncate text-xs text-subtle lg:hidden"
          >
            {if @mask_names?, do: "names masked"}
          </span>
          <%!-- master-desktop.html L712: "{n} spaces · {m} direct", or
               "names masked" while masked. Desktop only. --%>
          <span
            data-role="chat-list-counts"
            class="hidden truncate text-xs text-subtle lg:block"
          >
            {counts_line(@mask_names?, @space_rows, @dm_rows)}
          </span>
        </div>
        <%!-- Prototype master-mobile.html v3 :542-544, aria-labels verbatim.
             Buttons, never links: a bare event is fine on them. One button
             serves both widths: the phone opens the bottom sheet, desktop
             the anchored popover (`Partials.ListPopover`), from the one
             `@list_sheet`. --%>
        <.header_button
          id="list-search"
          role="chat-list-search"
          sheet="search"
          open={@list_sheet == :search}
          icon="hero-magnifying-glass"
          label="Search channels and DMs"
        />
        <.header_button
          id="list-new"
          role="chat-list-new"
          sheet="new"
          open={@list_sheet == :new}
          icon="hero-plus"
          label="New channel or conversation"
        />
        <.header_button
          :if={!@external?}
          id="list-more"
          role="chat-list-options"
          sheet="options"
          open={@list_sheet == :options}
          icon="hero-ellipsis-horizontal"
          label="List options: mask names, archived"
        />
        <PlatformWeb.ChatLive.Partials.ListPopover.list_popover
          sheet={@list_sheet}
          external?={@external?}
          query={@list_search_query}
          results={@list_search_results}
          channels={@channels}
          dm_conversations={@dm_conversations}
          archived_channels={@archived_channels}
          restricted_channel_ids={@restricted_channel_ids}
          list_private_ids={@list_private_ids}
          unread_counts={@unread_counts}
          list_excerpts={@list_excerpts}
          list_identities={@list_identities}
          mask_assigns={@mask_assigns}
          mask_names?={@mask_names?}
          archived_open={@archived_open}
          hidden_drawer_open={@hidden_drawer_open}
          hidden_channels={hidden_channels(@channel_sections)}
          resolved_mode={@resolved_mode}
        />
      </header>

      <div
        id="chat-list-scroller"
        phx-hook="ChatListSettle"
        class="clears-tab-bar min-h-0 flex-1 overflow-y-auto"
      >
        <.list_banner
          push_permission={@push_permission}
          dismissed={@notification_banner_dismissed}
        />

        <%= if @channels == [] and @dm_conversations == [] and @pinned_task_spaces == [] and is_nil(@agents_block) and not (@archived_open and @archived_channels != []) do %>
          <div data-role="chat-list-empty" class="px-8 py-16 text-center">
            <p class="text-sm text-subtle">No channels yet.</p>
            <p class="text-sm text-subtle">Create one or ask someone to add you.</p>
            <button
              :if={!@external?}
              type="button"
              phx-click="new_channel_open"
              class="btn btn-primary btn-sm mt-4"
              data-role="chat-list-empty-new-channel"
            >
              <span class="hero-plus size-4" aria-hidden="true"></span> New channel
            </button>
          </div>
        <% else %>
          <section
            :if={@agents_block || @pinned_rows != []}
            data-role="chat-list-pinned"
            aria-labelledby="chat-list-label-pinned"
          >
            <.section_label id="chat-list-label-pinned" fold={@folds.pinned}>
              Pinned
            </.section_label>
            <%!-- The drag and Alt+arrow keys (`## Pinned reorder`): the hook
                 draws into its own ignored overlay, never into the rows. --%>
            <div
              id={@folds.pinned.controls}
              data-role="chat-list-section-rows"
              phx-hook="PinnedReorder"
              class="relative"
            >
              <div
                id="pinned-reorder-overlay"
                data-role="pinned-reorder-overlay"
                phx-update="ignore"
                aria-hidden="true"
                class="pointer-events-none absolute inset-x-0 top-0 z-10 h-0"
              >
              </div>
              <%= if !@folds.pinned.collapsed? do %>
                <.agents_row
                  :if={@agents_block}
                  active_id={@active_id}
                  agents_block={@agents_block}
                  unread_counts={@unread_counts}
                  list_excerpts={@list_excerpts}
                  mask_assigns={@mask_assigns}
                />
                <%= for %{kind: kind, space: space} = entry <- @pinned_rows do %>
                  <.row
                    space={space}
                    kind={kind}
                    name={row_name(kind, space, @list_identities)}
                    agent={row_agent(space, @list_identities)}
                    human={row_human(space, @list_identities)}
                    unread={Map.get(@unread_counts, space.id, 0)}
                    excerpt={Map.get(@list_excerpts, space.id)}
                    mask_assigns={@mask_assigns}
                    restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                    private?={MapSet.member?(@list_private_ids, space.id)}
                    long_press={kind != :task}
                    current={space.id == @active_id}
                    reorder={kind != :task and not MapSet.member?(@restricted_channel_ids, space.id)}
                    pinned_position={entry.move_index}
                    pinned_count={entry.move_count}
                  />
                <% end %>
              <% end %>
            </div>
          </section>

          <section data-role="chat-list-spaces" aria-labelledby="chat-list-label-spaces">
            <.section_label id="chat-list-label-spaces" fold={@folds.spaces}>
              Spaces
            </.section_label>
            <div id={@folds.spaces.controls} data-role="chat-list-section-rows">
              <%= if @folds.spaces.collapsed? do %>
              <% else %>
                <%= if @space_rows == [] and !@external? do %>
                  <.section_empty
                    role="chat-list-spaces-empty"
                    copy="You're not in any channels yet."
                    label="New channel"
                    event="new_channel_open"
                  />
                <% else %>
                  <%= for space <- @space_rows do %>
                    <.row
                      space={space}
                      kind={:channel}
                      name={space.name}
                      agent={nil}
                      unread={Map.get(@unread_counts, space.id, 0)}
                      excerpt={Map.get(@list_excerpts, space.id)}
                      mask_assigns={@mask_assigns}
                      restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                      private?={MapSet.member?(@list_private_ids, space.id)}
                      long_press
                      current={space.id == @active_id}
                    />
                  <% end %>
                <% end %>
              <% end %>
            </div>
          </section>

          <section data-role="chat-list-direct" aria-labelledby="chat-list-label-direct">
            <.section_label id="chat-list-label-direct" fold={@folds.direct}>
              Direct
            </.section_label>
            <div id={@folds.direct.controls} data-role="chat-list-section-rows">
              <%= if @folds.direct.collapsed? do %>
              <% else %>
                <%= if @dm_rows == [] do %>
                  <.section_empty
                    role="chat-list-direct-empty"
                    copy="No conversations yet."
                    label="New conversation"
                    event="new_conversation_open"
                  />
                <% else %>
                  <%= for space <- @dm_rows do %>
                    <.row
                      space={space}
                      kind={:dm}
                      name={row_name(:dm, space, @list_identities)}
                      agent={row_agent(space, @list_identities)}
                      human={row_human(space, @list_identities)}
                      unread={Map.get(@unread_counts, space.id, 0)}
                      excerpt={Map.get(@list_excerpts, space.id)}
                      mask_assigns={@mask_assigns}
                      restricted?={false}
                      long_press
                      current={space.id == @active_id}
                    />
                  <% end %>
                <% end %>
              <% end %>
            </div>
          </section>

          <section
            :if={@archived_open and @archived_channels != []}
            data-role="chat-list-archived"
            aria-labelledby="chat-list-label-archived"
          >
            <.section_label id="chat-list-label-archived" fold={@folds.archived}>
              Archived
            </.section_label>
            <div id={@folds.archived.controls} data-role="chat-list-section-rows">
              <%= for space <- @archived_rows, !@folds.archived.collapsed? do %>
                <.row
                  space={space}
                  kind={:channel}
                  name={space.name}
                  agent={nil}
                  unread={Map.get(@unread_counts, space.id, 0)}
                  excerpt={Map.get(@list_excerpts, space.id)}
                  mask_assigns={@mask_assigns}
                  restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                  private?={MapSet.member?(@list_private_ids, space.id)}
                  long_press={false}
                  current={space.id == @active_id}
                />
              <% end %>
            </div>
          </section>
        <% end %>
      </div>

      <.external_footer :if={@external?} external_user={@external_user} />

      <%!-- Pinned reorder (`## Pinned reorder`): the live region every move
           speaks through, always in the DOM so a screen reader is already
           listening when the first move lands. --%>
      <div id="pinned-reorder-announcer" role="status" aria-live="polite" class="sr-only">
        {@pinned_announcement}
      </div>
      <.pinned_undo_toast :if={@pinned_undo} />

      <.search_sheet
        open={@list_sheet == :search}
        query={@list_search_query}
        results={@list_search_results}
        channels={@channels}
        dm_conversations={@dm_conversations}
        archived_channels={@archived_channels}
        restricted_channel_ids={@restricted_channel_ids}
        list_private_ids={@list_private_ids}
        unread_counts={@unread_counts}
        list_excerpts={@list_excerpts}
        list_identities={@list_identities}
        mask_assigns={@mask_assigns}
      />
      <.new_sheet open={@list_sheet == :new} />
      <.options_sheet
        open={@list_sheet == :options}
        mask_names?={@mask_names?}
        archived_open={@archived_open}
      />
    </section>
    """
  end

  # ONE toast per burst (`## Pinned reorder`): it renders while
  # `@pinned_undo` is set, and a later move in the burst only re-arms the
  # timer. Desktop only, since only desktop reorders. The base-100 surface
  # and base-content ink, never primary or neutral (the direction's "no
  # primary anywhere in this interaction"); 14px, the existing toast size.
  defp pinned_undo_toast(assigns) do
    ~H"""
    <div
      id="pinned-undo-toast"
      data-role="pinned-undo-toast"
      role="status"
      class="fixed bottom-6 left-1/2 z-50 hidden -translate-x-1/2 items-center gap-3 rounded-box border border-edge bg-base-100 py-1 pl-4 pr-1 text-sm text-base-content shadow-md lg:flex"
    >
      <p class="whitespace-nowrap">Pinned order changed</p>
      <button
        type="button"
        phx-click="undo_pinned_order"
        data-role="pinned-undo-button"
        class="min-h-11 shrink-0 rounded-box px-3 font-semibold text-base-content lg:hover:bg-base-300 focus-visible-ring"
      >
        Undo
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:role, :string, required: true)
  attr(:sheet, :string, required: true)
  attr(:open, :boolean, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)

  # 44px on the phone; 34px at lg, `text-subtle` at rest (master-desktop.html
  # L65-66), base-300 on hover. `aria-expanded` tracks the sheet or popover.
  defp header_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="open_list_sheet"
      phx-value-sheet={@sheet}
      data-role={@role}
      aria-label={@label}
      aria-haspopup="dialog"
      aria-expanded={to_string(@open)}
      class="flex size-11 shrink-0 items-center justify-center rounded-full text-base-content active:bg-base-100 focus-visible-ring lg:size-[34px] lg:text-subtle lg:hover:bg-base-300 lg:hover:text-base-content"
    >
      <span class={[@icon, "size-6 lg:size-5"]} aria-hidden="true"></span>
    </button>
    """
  end

  # ── sheets (stage 3) ──────────────────────────────────────────────────
  #
  # Every sheet: `<.sheet placement={:bottom} class="... lg:hidden">` with
  # rung 5's `handle_close` (the handle is the Close button) and
  # `swipe_dismiss`. base-100 surface, base-content labels, subtle meta, rows
  # at least 44px, pressed rows on base-200 as the More sheet's are. No hover
  # anywhere.

  attr(:open, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:results, :map, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:list_private_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)

  defp search_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-list-search-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet chat-list-search-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Search</:title>
      <%!-- Rendered only while open, so `SearchFocus` mounts with the sheet
           and focuses the field then (data-search-intent), not once at page
           load while the sheet is shut. --%>
      <.search_body
        :if={@open}
        query={@query}
        results={@results}
        channels={@channels}
        dm_conversations={@dm_conversations}
        archived_channels={@archived_channels}
        restricted_channel_ids={@restricted_channel_ids}
        list_private_ids={@list_private_ids}
        unread_counts={@unread_counts}
        list_excerpts={@list_excerpts}
        list_identities={@list_identities}
        mask_assigns={@mask_assigns}
      />
    </.sheet>
    """
  end

  attr(:query, :string, required: true)
  attr(:results, :map, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:list_private_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  # Every id and data-role in the body derives from this, so the phone sheet
  # ("chat-list-search") and the desktop popover ("chat-list-pop-search") can
  # both be in the DOM without a collision.
  attr(:prefix, :string, default: "chat-list-search")
  # The search field's frame: base-200 inside the base-100 sheet and popover.
  attr(:form_class, :string, default: "relative px-4 pb-2")

  attr(:input_class, :string,
    default:
      "h-11 w-full rounded-lg border border-edge bg-base-200 pl-9 pr-3 text-base placeholder:text-subtle focus:border-primary focus:outline-none"
  )

  attr(:icon_class, :string,
    default:
      "hero-magnifying-glass pointer-events-none absolute left-7 top-1/2 size-4 -translate-y-1/2 text-subtle"
  )

  attr(:pressed, :string, default: "active:bg-base-200")
  attr(:results_class, :string, default: nil)

  @doc """
  The search field and its result groups: the phone search sheet's body and
  the desktop list popover's (`Partials.ListPopover`). Fires `list_search`.
  """
  def search_body(assigns) do
    assigns =
      assign(
        assigns,
        :spaces_by_id,
        Map.new(
          assigns.channels ++ assigns.dm_conversations ++ assigns.archived_channels,
          &{&1.id, &1}
        )
      )

    ~H"""
    <div class="flex min-h-0 flex-col">
      <form
        class={@form_class}
        role="search"
        phx-change="list_search"
        phx-submit="list_search"
      >
        <span class={@icon_class} aria-hidden="true"></span>
        <input
          id={"#{@prefix}-input"}
          type="search"
          name="value"
          value={@query}
          phx-hook="SearchFocus"
          data-search-intent="true"
          data-blur-on-scroll={"#{@prefix}-results"}
          phx-debounce="200"
          maxlength="100"
          placeholder="Find channel, DM or message"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="none"
          spellcheck="false"
          enterkeyhint="go"
          aria-label="Find channel, DM or message"
          class={@input_class}
        />
      </form>

      <div id={"#{@prefix}-results"} data-role={"#{@prefix}-results"} class={@results_class}>
        <%= if @query == "" do %>
          <section :if={@results.recent != []} data-role={"#{@prefix}-recent"}>
            <.section_label id={"#{@prefix}-label-recent"}>Recent</.section_label>
            <.search_space_row
              :for={space <- @results.recent}
              space={space}
              prefix={@prefix}
              pressed={@pressed}
              unread_counts={@unread_counts}
              list_excerpts={@list_excerpts}
              list_identities={@list_identities}
              mask_assigns={@mask_assigns}
              restricted_channel_ids={@restricted_channel_ids}
              list_private_ids={@list_private_ids}
            />
          </section>
        <% else %>
          <section :if={@results.channels != []} data-role={"#{@prefix}-channels"}>
            <.section_label id={"#{@prefix}-label-channels"}>Channels</.section_label>
            <.search_space_row
              :for={space <- @results.channels}
              space={space}
              prefix={@prefix}
              pressed={@pressed}
              unread_counts={@unread_counts}
              list_excerpts={@list_excerpts}
              list_identities={@list_identities}
              mask_assigns={@mask_assigns}
              restricted_channel_ids={@restricted_channel_ids}
              list_private_ids={@list_private_ids}
            />
          </section>
          <section :if={@results.dms != []} data-role={"#{@prefix}-direct"}>
            <.section_label id={"#{@prefix}-label-direct"}>Direct</.section_label>
            <.search_space_row
              :for={space <- @results.dms}
              space={space}
              prefix={@prefix}
              pressed={@pressed}
              unread_counts={@unread_counts}
              list_excerpts={@list_excerpts}
              list_identities={@list_identities}
              mask_assigns={@mask_assigns}
              restricted_channel_ids={@restricted_channel_ids}
              list_private_ids={@list_private_ids}
            />
          </section>
          <section :if={@results.messages != []} data-role={"#{@prefix}-messages"}>
            <.section_label id={"#{@prefix}-label-messages"}>Messages</.section_label>
            <.message_hit
              :for={msg <- @results.messages}
              :if={Map.has_key?(@spaces_by_id, msg.space_id)}
              msg={msg}
              role={
                if @prefix == "chat-list-search",
                  do: "chat-list-message-hit",
                  else: "#{@prefix}-message-hit"
              }
              pressed={@pressed}
              space={Map.fetch!(@spaces_by_id, msg.space_id)}
              list_identities={@list_identities}
              mask_assigns={@mask_assigns}
            />
          </section>
          <p
            :if={@results.channels == [] and @results.dms == [] and @results.messages == []}
            data-role={"#{@prefix}-no-matches"}
            class="px-4 py-6 text-sm text-subtle"
          >
            No matches for “{@query}”
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:space, :map, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:list_private_ids, :any, required: true)
  attr(:prefix, :string, default: "chat-list-search")
  attr(:pressed, :string, default: "active:bg-base-200")

  # A channel or conversation result: the list's own row, with the sheet's
  # pressed paint and its own DOM ids.
  defp search_space_row(assigns) do
    kind = if assigns.space.kind in ["dm", "group"], do: :dm, else: :channel
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <.row
      space={@space}
      kind={@kind}
      name={row_name(@kind, @space, @list_identities)}
      agent={row_agent(@space, @list_identities)}
      human={row_human(@space, @list_identities)}
      unread={Map.get(@unread_counts, @space.id, 0)}
      excerpt={Map.get(@list_excerpts, @space.id)}
      mask_assigns={@mask_assigns}
      restricted?={MapSet.member?(@restricted_channel_ids, @space.id)}
      private?={MapSet.member?(@list_private_ids, @space.id)}
      pressed={@pressed}
      hover={nil}
      id_prefix={@prefix}
    />
    """
  end

  attr(:msg, :map, required: true)
  attr(:space, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:role, :string, default: "chat-list-message-hit")
  attr(:pressed, :string, default: "active:bg-base-200")

  # A message hit: a plain patch link to the existing `?message=` deep link,
  # no phx-click. The snippet goes through `RenderHelpers.search_headline/1`,
  # the one sanitising path for `ts_headline` markup. While masked it renders
  # the fixed placeholder and no snippet text. The author is a PERSON's name
  # (the message's author snapshot), which the org rule does not mask, so it
  # is shown as the rail and the drawer show people's names.
  defp message_hit(assigns) do
    kind = if assigns.space.kind in ["dm", "group"], do: :dm, else: :channel
    name = row_name(kind, assigns.space, assigns.list_identities)

    assigns =
      assigns
      |> assign(:space_name, ChatLive.masked_space_name(assigns.mask_assigns, name))
      |> assign(:masked?, assigns.mask_assigns[:mask_names?] == true)
      |> assign(:author, PlatformWeb.ChatLive.PresenceHooks.sender_name(%{}, assigns.msg))

    ~H"""
    <.link
      patch={~p"/chat/#{ChatLive.space_nav_target(@space)}?message=#{@msg.id}"}
      data-role={@role}
      data-space-id={@space.id}
      data-message-id={@msg.id}
      class={[
        "flex min-h-11 flex-col justify-center gap-0.5 px-4 py-2",
        @pressed,
        "focus-visible-ring"
      ]}
    >
      <span class="flex min-w-0 items-baseline gap-2">
        <span class="min-w-0 truncate text-[15px] font-semibold text-base-content">
          {@space_name}
        </span>
        <span class="shrink-0 truncate text-xs text-subtle">{@author}</span>
      </span>
      <span data-role="chat-list-snippet" class="block truncate text-[13px] text-subtle">
        <%= if @masked? do %>
          <span aria-hidden="true">{masked_excerpt()}</span>
          <span class="sr-only">Message hidden</span>
        <% else %>
          {search_headline(@msg)}
        <% end %>
      </span>
    </.link>
    """
  end

  attr(:open, :boolean, required: true)

  defp new_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-list-new-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>New</:title>
      <div class="flex flex-col pb-2">
        <.sheet_action
          role="chat-list-new-channel"
          click={JS.push("close_list_sheet") |> JS.push("new_channel_open")}
          icon="hero-hashtag"
          label="New channel"
          meta="name, people, your agent"
        />
        <.sheet_action
          role="chat-list-new-conversation"
          click={JS.push("close_list_sheet") |> JS.push("new_conversation_open")}
          icon="hero-chat-bubble-left-right"
          label="New conversation"
          meta="DM a person or agent"
        />
      </div>
    </.sheet>
    """
  end

  attr(:role, :string, required: true)
  attr(:click, :any, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :string, required: true)

  defp sheet_action(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      data-role={@role}
      class="flex min-h-13 w-full items-center gap-3 rounded-field px-4 py-2 text-left active:bg-base-200 focus-visible-ring"
    >
      <span class={[@icon, "size-5 shrink-0 text-base-content"]} aria-hidden="true"></span>
      <span class="min-w-0 flex-1">
        <span class="block text-[15px] text-base-content">{@label}</span>
        <span class="block text-[13px] text-subtle">{@meta}</span>
      </span>
    </button>
    """
  end

  attr(:open, :boolean, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:archived_open, :boolean, required: true)

  defp options_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-list-options-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Chat list</:title>
      <div class="flex flex-col pb-2">
        <.switch_row
          role="chat-list-option-mask"
          js={JS.push("toggle_mask_names", value: %{masked: to_string(!@mask_names?)})}
          on?={@mask_names?}
          label="Mask names"
          meta="for screen sharing"
        />
        <.switch_row
          role="chat-list-option-archived"
          js={JS.push("toggle_archived_section")}
          on?={@archived_open}
          label="Show archived"
          meta={nil}
        />
      </div>
    </.sheet>
    """
  end

  attr(:role, :string, required: true)
  attr(:js, :any, required: true)
  attr(:on?, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :any, required: true)

  # A toggle row: `role="switch"` with `aria-checked`, the whole row the
  # control. It fires the existing events (`toggle_mask_names`,
  # `toggle_archived_section`) through `JS.push`. Track primary when on (measured >= 3:1 on base-100), base-300
  # when off, with the knob carrying the boundary.
  defp switch_row(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@on?)}
      phx-click={@js}
      data-role={@role}
      class="flex min-h-13 w-full items-center gap-3 rounded-field px-4 py-2 text-left active:bg-base-200 focus-visible-ring"
    >
      <span class="min-w-0 flex-1">
        <span class="block text-[15px] text-base-content">{@label}</span>
        <span :if={@meta} class="block text-[13px] text-subtle">{@meta}</span>
      </span>
      <span
        data-role="chat-list-switch-track"
        class={[
          "relative inline-flex h-6 w-10 shrink-0 items-center rounded-full",
          if(@on?, do: "bg-primary", else: "bg-base-300")
        ]}
        aria-hidden="true"
      >
        <span class={[
          "absolute size-5 rounded-full border border-edge bg-base-100",
          if(@on?, do: "left-[1.125rem]", else: "left-0.5")
        ]}>
        </span>
      </span>
    </button>
    """
  end

  # Uppercase via CSS, at the 12px floor (the prototype's 11px raised), in the
  # shell sidebar labels' tracking.
  attr(:id, :string, required: true)
  # nil: a plain label (the search sheet's groups). A map from `assign_folds/1`:
  # the list's foldable header.
  attr(:fold, :map, default: nil)
  slot(:inner_block, required: true)

  defp section_label(%{fold: nil} = assigns) do
    ~H"""
    <h2 id={@id} class="px-4 pt-4 pb-1 text-xs font-medium uppercase tracking-widest text-subtle">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  # A foldable list header (stage 3, `## Folding`). The whole 44px row is the
  # button; the h2 keeps the id the section's `aria-labelledby` names. A
  # button, never a link, so the event on it is fine.
  defp section_label(assigns) do
    ~H"""
    <h2 id={@id} class="pt-2">
      <button
        type="button"
        data-role="chat-list-section-toggle"
        data-section={@fold.key}
        aria-expanded={to_string(!@fold.collapsed?)}
        aria-controls={@fold.controls}
        phx-click={
          JS.push("toggle_section_collapsed",
            value: %{section_id: @fold.key, collapsed: to_string(!@fold.collapsed?)}
          )
        }
        class="flex min-h-11 w-full items-center gap-2 px-4 text-left text-xs font-medium uppercase tracking-widest text-subtle active:bg-base-100 focus-visible-ring"
      >
        <span class="flex min-w-0 flex-1 items-center gap-1">
          <span class="min-w-0 truncate">{render_slot(@inner_block)}</span>
          <span
            :if={@fold.total}
            data-role="chat-list-section-count"
            aria-hidden="true"
            class="shrink-0 tabular-nums"
          >
            · {@fold.total}
          </span>
          <span :if={@fold.total} class="sr-only">, {@fold.total} conversations</span>
        </span>
        <span
          :if={@fold.marker}
          data-role="chat-list-section-unread"
          class="flex shrink-0 items-center gap-1.5 normal-case tracking-normal text-base-content"
        >
          <span class="size-2 shrink-0 rounded-full bg-primary" aria-hidden="true"></span>
          <span data-role="chat-list-section-unread-count" class="tabular-nums">
            {@fold.marker}
          </span>
          <span class="sr-only">unread conversations</span>
        </span>
        <span
          data-role="chat-list-section-chevron"
          class={[
            "hero-chevron-down size-4 shrink-0 text-subtle transition-transform duration-150 motion-reduce:transition-none",
            @fold.collapsed? && "-rotate-90"
          ]}
          aria-hidden="true"
        >
        </span>
      </button>
    </h2>
    """
  end

  attr(:role, :string, required: true)
  attr(:copy, :string, required: true)
  attr(:label, :string, required: true)
  attr(:event, :string, required: true)

  defp section_empty(assigns) do
    ~H"""
    <div data-role={@role} class="flex items-center gap-3 px-4 py-3">
      <p class="min-w-0 flex-1 text-sm text-subtle">{@copy}</p>
      <button
        type="button"
        phx-click={@event}
        class="btn btn-primary btn-sm shrink-0"
        data-role={@role <> "-action"}
      >
        {@label}
      </button>
    </div>
    """
  end

  attr(:push_permission, :any, required: true)
  attr(:dismissed, :boolean, required: true)

  # Coverage row 40. Shown while the browser permission is still `prompt` and
  # the viewer has not dismissed it. Both controls are buttons, never links,
  # so a bare event is fine on them.
  defp list_banner(assigns) do
    ~H"""
    <div
      :if={@push_permission == "prompt" and not @dismissed}
      data-role="chat-list-notification-banner"
      class="mx-4 mt-2 flex items-center gap-3 rounded-xl border border-edge bg-base-100 px-3 py-2.5"
    >
      <span class="hero-bell size-5 shrink-0 text-subtle" aria-hidden="true"></span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold text-base-content">Enable notifications</p>
        <p class="text-xs text-subtle">mentions and DMs, nothing else</p>
      </div>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-primary btn-sm shrink-0"
        data-role="chat-list-notification-enable"
      >
        Enable
      </button>
      <button
        type="button"
        phx-click="dismiss_notification_banner"
        class="flex size-11 shrink-0 items-center justify-center rounded-lg text-subtle"
        aria-label="Dismiss"
        data-role="chat-list-notification-dismiss"
      >
        <span class="hero-x-mark size-5" aria-hidden="true"></span>
      </button>
    </div>
    """
  end

  attr(:agents_block, :map, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:active_id, :any, default: nil)

  # The Agents row: the agents space, with its leader's avatar in the leader's
  # rung-3 slot. It patches to the agents space exactly as the drawer's
  # `drawer_agents/1` does (rung 8 owns the Agents sheet).
  defp agents_row(assigns) do
    leader = assigns.agents_block.leader

    assigns =
      assign(
        assigns,
        :agent,
        leader &&
          %{
            name: leader.name,
            avatar_url: leader.avatar_url,
            slot: Platform.Agents.ColorPalette.slot_for(Map.get(leader, :color))
          }
      )

    ~H"""
    <.row
      space={@agents_block.space}
      kind={:agents}
      name={@agents_block.space.name}
      agent={@agent}
      unread={Map.get(@unread_counts, @agents_block.space.id, 0)}
      excerpt={Map.get(@list_excerpts, @agents_block.space.id)}
      mask_assigns={@mask_assigns}
      restricted?={false}
      current={@agents_block.space.id == @active_id}
    />
    """
  end

  attr(:space, :map, required: true)
  attr(:kind, :atom, required: true)
  attr(:name, :string, required: true)
  attr(:agent, :any, required: true)
  # The other person of a one-to-one DM, when they have an image
  # (`ChatListData.load_identities/1`): `%{avatar_url: url}` or nil.
  attr(:human, :any, default: nil)
  attr(:unread, :integer, required: true)
  attr(:excerpt, :any, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:restricted?, :boolean, required: true)
  # A role-gated channel the reader can open (`ChatListData.load_private_ids/1`):
  # the lock glyph instead of `#`. Only read on a dense channel row.
  attr(:private?, :boolean, default: false)
  # The pressed ground: base-100 on the base-200 list, base-200 inside a
  # base-100 sheet (the More sheet's paint).
  attr(:pressed, :string, default: "active:bg-base-100")
  # DOM ids must stay unique when one space renders in the list AND in a sheet.
  attr(:id_prefix, :string, default: "chat-list")
  # The row link carries the generic `RowLongPress` hook, opening the row
  # sheet. Off for the Agents row (its membership is derived, so pin, hide
  # and order are all wrong for it), pinned tasks, Archived and search rows.
  attr(:long_press, :boolean, default: false)
  # The open conversation, on the desktop list pane (`## Desktop list pane`):
  # `aria-current="page"` and the base-300 fill. Never true on the phone,
  # where the list renders only at `/chat`, with no space open.
  attr(:current, :boolean, default: false)
  # The desktop hover fill; nil on search results, whose `pressed` carries it.
  attr(:hover, :any, default: "lg:hover:bg-base-300")
  # A pinned CONVERSATION row the user can reorder (`## Pinned reorder`): the
  # grip and `data-reorder`. Never a task, Agents, restricted or unpinned row.
  attr(:reorder, :boolean, default: false)
  # Its `move_index` and `move_count` in the server's conversation run. A
  # restricted pinned row carries the position too, so the stage 3 hook can
  # index around it.
  attr(:pinned_position, :any, default: nil)
  attr(:pinned_count, :any, default: nil)

  # One row. The whole row is the link (at least 44px tall), with no
  # phx-click. Name `min-w-0 truncate`; time, dot and count never shrink.
  #
  # Two shapes (`## Channel rows` in the moduledoc): a channel-kind space is
  # DENSE (glyph, name, unread count, one line); everything else keeps the
  # 42px avatar, the time and the excerpt.
  defp row(assigns) do
    shown = ChatLive.masked_space_name(assigns.mask_assigns, assigns.name)
    masked? = assigns.mask_assigns[:mask_names?] == true

    assigns =
      assigns
      |> assign(:shown_name, shown)
      |> assign(:name_masked?, shown != assigns.name)
      |> assign(:excerpts_masked?, masked?)
      |> assign(:unread_text, unread_label(assigns.unread))
      |> assign(:dense?, dense_row?(assigns.kind, assigns.space))
      |> assign(:group?, Map.get(assigns.space, :kind) == "group")

    ~H"""
    <%= cond do %>
      <% @restricted? -> %>
        <%!-- A channel the reader cannot open: no link, and a no-entry
             marker, never the lock (the lock means "private, and yours"). --%>
        <div
          data-role="restricted-channel-row"
          data-space-id={@space.id}
          data-pinned-position={@pinned_position}
          aria-disabled="true"
          class="flex min-h-11 items-center gap-2 pl-7 pr-4"
        >
          <span
            data-role="chat-list-glyph"
            data-glyph="restricted"
            class="hero-no-symbol size-[18px] shrink-0 text-subtle"
            aria-hidden="true"
          >
          </span>
          <span class="min-w-0 flex-1 truncate text-[15px] font-normal text-base-content">
            {@shown_name}
          </span>
          <span class="shrink-0 text-xs text-subtle">Restricted, ask an admin</span>
        </div>
      <% @dense? -> %>
        <div class="flex items-center" data-role="chat-list-row-wrap" data-space-id={@space.id}>
          <.link
            id={"#{@id_prefix}-row-#{@space.id}"}
            patch={~p"/chat/#{ChatLive.space_nav_target(@space)}"}
            data-role="chat-list-row"
            data-space-id={@space.id}
            data-row-kind={@kind}
            data-row-shape="dense"
            data-unread={to_string(@unread > 0)}
            data-reorder={@reorder && "true"}
            data-pinned-position={@reorder && @pinned_position}
            data-pinned-count={@reorder && @pinned_count}
            phx-hook={@long_press && "RowLongPress"}
            data-long-press-event={@long_press && "open_list_sheet"}
            data-long-press-sheet={@long_press && "row"}
            data-long-press-space-id={@long_press && @space.id}
            aria-current={@current && "page"}
            class={[
              "chat-list-row group/row relative flex min-h-11 min-w-0 flex-1 items-center gap-2 pl-7 pr-4 focus-visible-ring",
              @pressed,
              @hover,
              @current && "bg-base-300"
            ]}
          >
            <span
              data-role="chat-list-glyph"
              data-glyph={if(@private?, do: "lock", else: "hash")}
              class={[
                channel_glyph(@private?, @unread > 0),
                "size-[18px] shrink-0",
                if(@unread > 0, do: "text-base-content", else: "text-subtle")
              ]}
              aria-hidden="true"
            >
            </span>
            <span :if={@private?} class="sr-only">Private channel</span>
            <span
              data-role="chat-list-row-name"
              class={[
                "min-w-0 flex-1 truncate text-[15px] text-base-content",
                if(@unread > 0, do: "font-semibold", else: "font-normal")
              ]}
            >
              {@shown_name}
            </span>
            <span
              :if={@unread_text}
              data-role="chat-list-unread-count"
              class={[
                "flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full bg-base-300 px-1.5 text-xs font-semibold tabular-nums text-base-content",
                @reorder && "lg:group-hover/row:invisible lg:group-focus-visible/row:invisible"
              ]}
            >
              <span aria-hidden="true">{@unread_text}</span>
              <span class="sr-only">{@unread_text} unread</span>
            </span>
            <%!-- Over the pill slot when there is a pill (the pill goes
                 invisible, keeping its box), else over the trailing padding:
                 never over the name. --%>
            <.row_grip :if={@reorder} class={if(@unread_text, do: "right-4", else: "right-0.5")} />
          </.link>
        </div>
      <% true -> %>
        <div class="flex items-center" data-role="chat-list-row-wrap" data-space-id={@space.id}>
          <.link
            id={"#{@id_prefix}-row-#{@space.id}"}
            patch={~p"/chat/#{ChatLive.space_nav_target(@space)}"}
            data-role="chat-list-row"
            data-space-id={@space.id}
            data-row-kind={@kind}
            data-unread={to_string(@unread > 0)}
            data-reorder={@reorder && "true"}
            data-pinned-position={@reorder && @pinned_position}
            data-pinned-count={@reorder && @pinned_count}
            phx-hook={@long_press && "RowLongPress"}
            data-long-press-event={@long_press && "open_list_sheet"}
            data-long-press-sheet={@long_press && "row"}
            data-long-press-space-id={@long_press && @space.id}
            aria-current={@current && "page"}
            class={[
              "chat-list-row group/row relative flex min-h-11 min-w-0 flex-1 items-center gap-3 px-4 py-3 focus-visible-ring",
              @pressed,
              @hover,
              @current && "bg-base-300"
            ]}
          >
            <.avatar
              kind={@kind}
              name={@name}
              agent={@agent}
              human={@human}
              group?={@group?}
              masked?={@name_masked?}
            />
            <span class="min-w-0 flex-1">
              <span class={["flex items-baseline gap-2", @reorder && "relative"]}>
                <span
                  data-role="chat-list-row-name"
                  class={[
                    "min-w-0 flex-1 truncate text-[15px] text-base-content",
                    if(@unread > 0, do: "font-semibold", else: "font-normal")
                  ]}
                >
                  {@shown_name}
                </span>
                <time
                  :if={@excerpt}
                  id={"#{@id_prefix}-time-#{@space.id}"}
                  phx-hook="LocalTime"
                  datetime={DateTime.to_iso8601(@excerpt.inserted_at)}
                  data-local-time={DateTime.to_iso8601(@excerpt.inserted_at)}
                  data-role="chat-list-row-time"
                  class={[
                    "shrink-0 whitespace-nowrap tabular-nums text-xs",
                    if(@unread > 0, do: "text-base-content", else: "text-subtle"),
                    @reorder && "lg:group-hover/row:invisible lg:group-focus-visible/row:invisible"
                  ]}
                >
                  {Calendar.strftime(@excerpt.inserted_at, "%H:%M")}
                </time>
                <%!-- The time column (the direction's signature element):
                     the time goes invisible and keeps its box, so the name
                     never widens or moves. --%>
                <.row_grip :if={@reorder} class="right-0" />
              </span>
              <span
                :if={@excerpt}
                data-role="chat-list-excerpt"
                class={[
                  "block truncate text-[13px]",
                  if(@unread > 0, do: "text-base-content", else: "text-subtle")
                ]}
              >
                <%= if @excerpts_masked? do %>
                  <span aria-hidden="true">{masked_excerpt()}</span>
                  <span class="sr-only">Message hidden</span>
                <% else %>
                  {excerpt_text(@kind, @space, @excerpt)}
                <% end %>
              </span>
            </span>
            <span
              :if={@unread_text}
              data-role="chat-list-unread-dot"
              class="size-2 shrink-0 rounded-full bg-primary"
              role="img"
              aria-label={"#{@unread_text} unread"}
            >
            </span>
          </.link>
        </div>
    <% end %>
    """
  end

  attr(:class, :string, required: true)

  # The 6-dot grip (`## Pinned reorder`). `hidden` at rest and below lg;
  # shown only on desktop hover or keyboard focus of its row. Decorative: the
  # row link is what keyboard and assistive tech reach.
  defp row_grip(assigns) do
    ~H"""
    <span
      data-role="chat-list-row-grip"
      aria-hidden="true"
      class={[
        "pointer-events-none absolute top-1/2 hidden -translate-y-1/2 items-center justify-center text-subtle lg:group-hover/row:inline-flex lg:group-focus-visible/row:inline-flex",
        @class
      ]}
    >
      <svg viewBox="0 0 10 16" class="h-4 w-2.5" fill="currentColor">
        <circle cx="2.5" cy="3" r="1.5" />
        <circle cx="7.5" cy="3" r="1.5" />
        <circle cx="2.5" cy="8" r="1.5" />
        <circle cx="7.5" cy="8" r="1.5" />
        <circle cx="2.5" cy="13" r="1.5" />
        <circle cx="7.5" cy="13" r="1.5" />
      </svg>
    </span>
    """
  end

  # Dense iff the ROW is a channel row AND the space is channel-kind. An
  # execution, system or meeting space that lands in a channel row (a pinned
  # exec space, say) keeps the avatar shape: the `#` claims "channel".
  defp dense_row?(:channel, %{kind: "channel"}), do: true
  defp dense_row?(_kind, _space), do: false

  # Unread draws the glyph heavier (solid), as the name goes semibold.
  defp channel_glyph(false, false), do: "hero-hashtag"
  defp channel_glyph(false, true), do: "hero-hashtag-solid"
  defp channel_glyph(true, false), do: "hero-lock-closed"
  defp channel_glyph(true, true), do: "hero-lock-closed-solid"

  attr(:kind, :atom, required: true)
  attr(:name, :string, required: true)
  attr(:agent, :any, required: true)
  attr(:human, :any, default: nil)
  attr(:group?, :boolean, default: false)
  attr(:masked?, :boolean, required: true)

  # 42px disc. Masked: neutral, no initial, no accent, no image. Agent: the
  # agent's image or initial, ringed in its rung-3 slot. Human: the other
  # person's image (a DM whose person has one; else the initial below).
  # Group: a people-stack glyph, so "Sam, Alex" does not read as a DM with
  # Sam. Task: a check glyph. Otherwise the name's first letter (a channel's
  # without its `#`).
  defp avatar(assigns) do
    ~H"""
    <%= cond do %>
      <% @masked? -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="masked"
          class="size-[42px] shrink-0 rounded-full bg-base-300"
          aria-hidden="true"
        >
        </span>
      <% @agent -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="agent"
          data-agent-slot={@agent.slot}
          class="msg-agent-avatar flex size-[42px] shrink-0 items-center justify-center overflow-hidden rounded-full bg-base-300 text-[15px] font-semibold text-base-content"
          aria-hidden="true"
        >
          <img
            :if={@agent.avatar_url}
            src={@agent.avatar_url}
            alt=""
            class="size-full object-cover"
            loading="lazy"
          />
          <span :if={!@agent.avatar_url}>{initial(@agent.name)}</span>
        </span>
      <% @human -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="human"
          class="flex size-[42px] shrink-0 items-center justify-center overflow-hidden rounded-full bg-base-300"
          aria-hidden="true"
        >
          <img src={@human.avatar_url} alt="" class="size-full object-cover" loading="lazy" />
        </span>
      <% @group? -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="group"
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content"
          aria-hidden="true"
        >
          <span class="hero-user-group size-5"></span>
        </span>
      <% @kind == :task -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="task"
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content"
          aria-hidden="true"
        >
          <span class="hero-check size-5"></span>
        </span>
      <% true -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="initial"
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-[15px] font-semibold text-base-content"
          aria-hidden="true"
        >
          {initial(@name)}
        </span>
    <% end %>
    """
  end

  attr(:external_user, :any, required: true)

  # The external layout is chrome-less (no shell sidebar), so the identity
  # and the way out that `external_rail/1` carried live at the foot of the
  # list pane. Desktop only: below lg an external user is on
  # `external_mobile_switcher/1`, which has its own. No org label: that would
  # leak the internal structure.
  defp external_footer(assigns) do
    ~H"""
    <footer
      data-role="external-identity"
      class="flex flex-shrink-0 items-center gap-2 border-t border-edge px-3 py-2"
    >
      <PlatformWeb.AvatarComponents.human_avatar
        :if={@external_user}
        name={@external_user.name || @external_user.email || "You"}
        avatar_url={@external_user.avatar_url}
        seed={@external_user.oidc_sub || @external_user.email || @external_user.id}
        size="sm"
        class="flex-shrink-0"
      />
      <span class="min-w-0 flex-1 truncate text-sm text-base-content">
        {@external_user && (@external_user.name || @external_user.email)}
      </span>
      <a
        href={~p"/auth/logout"}
        class="flex size-[34px] shrink-0 items-center justify-center rounded-full text-subtle lg:hover:bg-base-300 lg:hover:text-base-content focus-visible-ring"
        aria-label="Log out"
        data-role="external-logout"
      >
        <span class="hero-arrow-right-start-on-rectangle size-5" aria-hidden="true"></span>
      </a>
    </footer>
    """
  end

  # ── desktop list pane (Burrow redesign 22 stage 2) ────────────────────

  # Phone `/chat`: the full-width list, as before. Phone `/chat/:slug`: not
  # shown (`hidden`), so the conversation has the screen. At lg, on both
  # routes, the 280px pane (240px at or below 1100px) beside the
  # conversation (master-desktop.html L46, L563). An external user's list is
  # desktop only on both routes: below lg they keep `external_mobile_switcher/1`.
  @pane_base "min-h-0 min-w-0 flex-1 flex-col bg-base-200 text-base-content"
  @pane_lg "lg:w-[280px] lg:max-[1100px]:w-[240px] lg:flex-none lg:border-r lg:border-edge"

  @doc false
  def pane_class(:index, false), do: "flex #{@pane_base} #{@pane_lg}"
  def pane_class(_action, _external?), do: "hidden lg:flex #{@pane_base} #{@pane_lg}"

  # master-desktop.html L712: spaces.length and dms.length, the rows the list
  # draws under Spaces and Direct.
  defp counts_line(true, _spaces, _dms), do: "names masked"

  defp counts_line(false, spaces, dms) do
    n = length(spaces)
    m = length(dms)
    "#{n} #{if n == 1, do: "space", else: "spaces"} · #{m} direct"
  end

  defp active_id(%{id: id}), do: id
  defp active_id(_), do: nil

  # An external user's list holds only their own channels and conversations:
  # no Agents row, no pinned task conversations, no Archived section. The
  # mount already scopes `@channels` and `@dm_conversations` to them.
  defp external_scrub(%{external?: true} = assigns) do
    assigns
    |> assign(:agents_block, nil)
    |> assign(:pinned_task_spaces, [])
    |> assign(:archived_open, false)
    |> assign(:archived_channels, [])
  end

  defp external_scrub(assigns), do: assigns

  # The channels the reader hid (`hidden_channel_ids`), flattened from their
  # sub-org buckets: the Options popover's "Show hidden" list.
  @doc false
  def hidden_channels(%{hidden_sub_orgs: buckets}) when is_map(buckets) do
    buckets |> Map.values() |> List.flatten() |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  def hidden_channels(_), do: []

  @doc false
  def masked_excerpt, do: @masked_excerpt

  # '<author>: <content>' everywhere but a one-to-one DM, where the author is
  # the row's own name and the prefix would only repeat it.
  defp excerpt_text(:dm, %{kind: "dm"}, %{content: content}), do: content

  defp excerpt_text(_kind, _space, %{author_name: author, content: content})
       when is_binary(author) and author != "",
       do: "#{author}: #{content}"

  defp excerpt_text(_kind, _space, %{content: content}), do: content

  defp initial(name) when is_binary(name) do
    name
    |> String.trim_leading("#")
    |> String.trim()
    |> String.first()
    |> case do
      nil -> ""
      ch -> String.upcase(ch)
    end
  end

  defp initial(_), do: ""

  # Every section's rows in display order (the moduledoc's `## Order` and
  # `## Holding the order`). The Agents row is not among `:pinned_rows`: it
  # renders first on its own.
  defp assign_sorted_rows(assigns) do
    rows = sorted_rows(assigns, assigns[:list_order_hold])

    assigns
    |> assign(:pinned_rows, rows.pinned)
    |> assign(:space_rows, rows.spaces)
    |> assign(:dm_rows, rows.direct)
    |> assign(:archived_rows, rows.archived)
  end

  @doc """
  The space ids each section displays right now, in order, as
  `%{pinned: ids, spaces: ids, direct: ids, archived: ids}`: what `ChatListHooks` snapshots when a hold
  begins. Reads the same assigns `chat_list/1` does (a socket's assigns do).
  """
  def section_order(assigns) do
    assigns
    |> sorted_rows(assigns[:list_order_hold])
    |> Map.new(fn {section, rows} ->
      {section, Enum.map(rows, &row_id/1)}
    end)
  end

  defp row_id(%{space: %{id: id}}), do: id
  defp row_id(%{id: id}), do: id

  defp sorted_rows(assigns, hold) do
    excerpts = assigns.list_excerpts
    identities = assigns.list_identities

    order = fn rows, section, name_fun ->
      ChatListData.order_rows(rows, excerpts, hold && hold[section], name_fun)
    end

    pinned =
      ChatLive.pinned_rail_entries(assigns.channel_sections.pinned, assigns.pinned_task_spaces)

    spaces =
      if assigns[:external?],
        do: Enum.filter(List.wrap(assigns.channels), &(&1.id not in pinned_ids(pinned))),
        else: Platform.Chat.Sidebar.flatten_sections(assigns.sidebar_sections)

    # Pinned (`## Order`): the task run by recency (and the hold), then the
    # conversation run in the user's SAVED order, never re-sorted.
    {tasks, conversations} = Enum.split_with(pinned, &(&1.kind == :task))

    %{
      pinned: order.(tasks, :pinned, &row_name(&1.kind, &1.space, identities)) ++ conversations,
      spaces: order.(spaces, :spaces, & &1.name),
      direct: order.(assigns.channel_sections.dms, :direct, &row_name(:dm, &1, identities)),
      archived: order.(assigns.archived_channels, :archived, & &1.name)
    }
  end

  @fold_keys %{
    pinned: "chat-list:pinned",
    spaces: "chat-list:spaces",
    direct: "chat-list:direct",
    archived: "chat-list:archived"
  }

  @doc "The phone list's fold keys in `chat_collapsed_sections` (`## Folding`)."
  def fold_keys, do: @fold_keys

  # One fold per section: its key, whether it is collapsed, the id of the rows
  # container its button controls, the collapsed unread marker (the number of
  # rows with unread, or nil) and the collapsed hidden-row total (the number
  # of rows the section renders when expanded, or nil when expanded or 0).
  # Archived never carries a marker or a total.
  defp assign_folds(assigns) do
    collapsed = assigns.list_collapsed || MapSet.new()
    unread = assigns.unread_counts
    restricted = assigns.restricted_channel_ids

    agents =
      case assigns.agents_block do
        %{space: space} -> [space]
        _ -> []
      end

    rows = %{
      pinned: agents ++ Enum.map(assigns.pinned_rows, & &1.space),
      spaces: assigns.space_rows,
      direct: assigns.dm_rows,
      archived: []
    }

    folds =
      Map.new(@fold_keys, fn {section, key} ->
        collapsed? = MapSet.member?(collapsed, key)

        count =
          Enum.count(rows[section], fn space ->
            Map.get(unread, space.id, 0) > 0 and not MapSet.member?(restricted, space.id)
          end)

        {section,
         %{
           key: key,
           collapsed?: collapsed?,
           controls: "chat-list-rows-#{section}",
           marker: if(collapsed? and count > 0, do: count),
           total: fold_total(section, collapsed?, rows[section])
         }}
      end)

    assign(assigns, :folds, folds)
  end

  # The rows the fold hides are the rows it renders when expanded, so the total
  # counts the same lists the section `for`s over (Pinned's Agents row
  # included, restricted rows included). Archived is "don't nag me": no total.
  defp fold_total(:archived, _collapsed?, _rows), do: nil

  defp fold_total(_section, true, rows) do
    case length(rows) do
      0 -> nil
      total -> total
    end
  end

  defp fold_total(_section, false, _rows), do: nil

  defp pinned_ids(pinned), do: Enum.map(pinned, & &1.space.id)

  @doc """
  A row's name before masking, as the row renders it: a channel's own name,
  else the person's name from `@list_identities` (a DM), else the space name.
  Mask it with `ChatLive.masked_space_name/2` to get what the row shows.
  """
  def row_name(:channel, space, _identities), do: space.name

  def row_name(_kind, space, identities) do
    case Map.get(identities, space.id) do
      %{name: name} -> name
      _ -> space.name || ""
    end
  end

  defp row_agent(space, identities) do
    case Map.get(identities, space.id) do
      %{agent: agent} -> agent
      _ -> nil
    end
  end

  defp row_human(space, identities) do
    case Map.get(identities, space.id) do
      %{human: human} -> human
      _ -> nil
    end
  end
end
