defmodule PlatformWeb.ChatLive.Partials.Conversation do
  @moduledoc """
  The top half of the conversation pane — everything between
  `<div id="chat-drop-zone">` and the message list.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail`,
  `ChatLive.Partials.Rail` and `ChatLive.Partials.ChatList` (ADR 0035):
  function components, no state, each taking a declared set of attrs.
  Extracted from `chat_live.html.heex` in task 01a0312e stage 5 as a PURE
  MOVE — every `id`, `phx-hook`, `phx-click`, `phx-value-*`, `data-*` and
  `aria-*` sits on the element it sat on before.

  The regions, in template order:

    * `space_header/1` — the `<header>` space bar: the mobile and desktop
      title branches, the group promote form, the Meet button, the search
      form, the canvas/pin counters, the agent eye and settings
    * `search_drawer/1` — the search-results drawer
    * `pins_drawer/1` — the pinned-messages drawer
    * `canvases_drawer/1` — the live-canvases drawer and its new-canvas form

  ## WHAT DELIBERATELY STAYED BEHIND

  `<div id="chat-drop-zone" phx-hook="DragDropUpload">` is NOT part of this
  module. It is the drop target for the WHOLE conversation pane — message
  list and composer included — so wrapping it inside a component would change
  which element the hook binds to and shrink the droppable area to the header.
  Its children moved; the wrapper did not. `<div id="inline-focus-listener">`
  stayed for the same reason: it is a bare hook anchor with no markup to
  decompose, and a component per hook element is a rename.

  ## THE HEADER HAS TWO TITLE NODES AND BOTH MASK

  The space name is rendered TWICE in `space_header/1` — a `lg:hidden`
  mobile branch and a `hidden lg:flex` desktop branch — and each applies
  screen-share masking through `space_header_name/4` + `space_mask/1`, with
  its own `scope_pill` label masked through `SidebarMask.label_for_bucket/3`.
  A mask applied to only one of the two breakpoints is the exact bug shape
  task 01a00c66 existed to find, and a desktop-only test cannot see a
  mobile-only leak. Both branches are preserved identically.

  ## THE MASKING ATTRS ARE NOT OPTIONAL

  `ChatLive.space_mask/1` and `ChatLive.masked_space_name/2` read
  `:sidebar_sections`, `:mask_names?` and `:revealed_section_ids` out of the
  map they are handed through TOLERANT `assigns[...]` access. A component
  that FORGETS to declare them does not crash and does not render blank — it
  silently renders REAL WORKSPACE NAMES with the mask switched on, and every
  markup assertion still passes. So all three are declared on `space_header/1`
  (both branches). The phone's pinned strip and channel pills, which declared
  them too, were deleted with the drawer (task 01a1557a-8562 stage 5); the
  phone Chat list replaced all three.

  ## WHY THE MASK CALL IS WRAPPED, NOT QUALIFIED

  `space_mask/1` lives in `PlatformWeb.ChatLive`, which imports this module —
  so it cannot be imported back. It is wrapped in a private function of the
  SAME NAME AND ARITY rather than called as `ChatLive.space_mask(...)`
  because call sites inside `truncate` spans sit on lines already close to
  the formatter's width: a longer call reflows the interpolation onto its own
  line, which puts whitespace INSIDE the span and changes the rendered text
  while every markup assertion stays green (task 01a0312e stage 3 finding).
  Same call text, same wrapping, no reflow. The `masked_space_name/2` and
  `space_nav_target/1` wrappers left with their only callers, the channel
  pills and the pinned strip (task 01a1557a-8562 stage 5).
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [
      search_headline: 1,
      space_header_name: 4
    ]

  # `relative_time/1` left this list in task 01a0740d stage 3 along with the
  # flat canvas rows that used it. The explorer's browse row is title-only by
  # design (the group header has already said where you are) and its search row
  # calls the same shared helper from inside the component, so importing it here
  # would be an import for nothing.
  import PlatformWeb.Components.ChatHelpers, only: [present?: 1]
  import PlatformWeb.Components.Canvases.CanvasExplorer, only: [canvas_explorer: 1]
  import PlatformWeb.CoreComponents, only: [icon: 1, input: 1]
  import PlatformWeb.Components.ChatMessage, only: [local_time: 1]
  import PlatformWeb.Components.EmptyState, only: [empty_state: 1]
  import PlatformWeb.Components.ScopePill, only: [scope_pill: 1]
  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.GoalCadenceForm
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.MembersComponent
  alias PlatformWeb.ChatLive.Partials.AgentsSheet
  alias PlatformWeb.ChatLive.PresenceHooks

  attr(:active_space, :any, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  attr(:space_participants, :list, required: true)
  attr(:user_id, :any, required: true)
  # The three masking attrs. BOTH breakpoint branches below call
  # `space_header_name/4` with `space_mask(assigns)` and build a
  # `SidebarMask.context/3` for their scope pill; all of that reads these
  # three through tolerant access, so a missing declaration unmasks silently
  # on whichever branch the test in hand cannot see.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:active_space_scope, :any, required: true)
  # The org row behind `@active_space_scope`, `%{slug, name}` or nil (task
  # 01a0938b). Both header pills label from its NAME and pass its SLUG as
  # `value`; see the call-site contract on the desktop pill below.
  attr(:active_space_org, :any, default: nil)
  attr(:scope_filter, :any, required: true)
  attr(:meetings_enabled, :boolean, required: true)
  attr(:in_meeting, :boolean, required: true)
  attr(:search_form, :any, required: true)
  attr(:search_query, :any, required: true)
  attr(:canvases, :list, required: true)
  attr(:show_canvases, :boolean, required: true)
  attr(:pins, :list, required: true)
  attr(:show_pins, :boolean, required: true)
  attr(:agent_presence, :map, required: true)
  attr(:has_agent_participant, :boolean, required: true)
  # The Agents sheet (task 01a1557a-8f80 stage 2): its open flag and
  # `Chat.agent_attention_state/1`, for the header entry and the popover.
  attr(:agents_sheet_open, :boolean, required: true)
  attr(:agent_attention, :any, required: true)
  # The Members sheet (task 01a1557a-8f80 stage 3): its open flag and the
  # viewer whose presence union decides online/away, for the popover instance.
  attr(:show_members, :boolean, required: true)
  attr(:current_user_record, :any, default: nil)
  attr(:goal_panel, :any, required: true)
  attr(:goal_edit, :boolean, required: true)
  attr(:can_edit_goal?, :boolean, required: true)
  # Task 01a0ca99: true only for an admin on the one channel where
  # `Sidebar.first_goal_offered?/1` holds. With `@goal_panel` nil it is the
  # strip's empty-and-admin state: the same line, carrying the invitation.
  attr(:goal_invite?, :boolean, default: false)
  # Task 01a0cef1: the editor's project options, `{label, value}` pairs from
  # `Sidebar.goal_scope_options/1`, and the inline refusal of a scope the
  # channel's org cannot see (`:unknown_project`, else nil).
  attr(:goal_scope_options, :list, default: [])
  attr(:goal_scope_error, :atom, default: nil)
  # Task 01a0e882 stage 3: the Check progress selection while the editor
  # is open (`GoalCadenceForm.selection/0`, else nil) and the viewer's
  # resolved IANA zone (nil renders UTC).
  attr(:goal_cadence_form, :map, default: nil)
  attr(:goal_time_zone, :string, default: nil)
  # Task 01a1557a-8a6d stage 1 (rung 7): the phone title button opens the
  # space sheet (`SpaceSheetHooks`). `@space_sheet` drives its
  # `aria-expanded`; `@agent_status` (PresenceHooks) is the agent-DM
  # subtitle.
  attr(:space_sheet, :any, default: nil)
  attr(:agent_status, :any, default: nil)

  @doc """
  The conversation `<header>` — space title, meeting entry, search, the
  canvas/pin counters, the agent eye and settings.

  The `@active_space && !@embedded` gate travelled INTO the component with
  the markup (same convention as `Rail.rail/1` and `ChatList.chat_list/1`),
  so the call site states no render condition of its own.
  """
  def space_header(assigns) do
    ~H"""
    <header
      :if={@active_space && !@embedded}
      class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-content/10 px-5"
    >
      <%!-- Screen-share masking (task 01a00c66 stage 5). The open channel's
           own name sits in this header at the top of the screen; masking the
           rail row for `#vandelay-ind` and leaving the header spelling it out is
           the same leak with an extra step. `space_label/3` looks the name up
           across the whole rail because this header has no section in hand.
           Applied to BOTH breakpoint branches below — the mobile and desktop
           titles are separate nodes, and a mask applied to one of them is the
           shape of bug this stage exists to find. --%>
      <%!-- `max-lg:` only (task 01a1557a-8a6d stage 1): on the phone the
           title takes the row's spare width, so the name truncates last.
           At lg the row lays out exactly as before. --%>
      <div class="flex items-center gap-2 overflow-hidden max-lg:min-w-0 max-lg:flex-1">
        <%!-- Mobile: static channel name. Channel switching on the phone is the
             Chat list (task 01a1557a-8562), reached through the back chevron
             below or the tab bar's Chat tab; the pills strip and the drawer
             it opened were deleted in that task's stage 5. --%>
        <div class="flex min-w-0 flex-1 items-center gap-2 overflow-hidden lg:hidden">
          <%!-- Back to the phone Chat list (task 01a1557a-8562 stage 2,
               coverage row 64). A plain patch link with NO phx-click: a bare
               `phx-click` on a patch link throws in the client, and anything
               that must reset on the way back resets in `handle_params/3`.
               An external user follows it too: their /chat has no active
               space, so it lands on `#external-mobile-switcher`, their own
               list. Rung 7 restyles the rest of this header. --%>
          <.link
            patch={~p"/chat"}
            class="-ml-3 flex size-11 shrink-0 items-center justify-center rounded-lg text-base-content lg:hidden focus-visible-ring"
            aria-label="Back to chat list"
            data-role="chat-back"
          >
            <span class="hero-chevron-left size-5" aria-hidden="true"></span>
          </.link>
          <%!-- The title IS the way into the space sheet (task 01a1557a-8a6d
               stage 1): one button holding the name, a chevron and a
               subtitle. The name goes through `space_header_name/4` +
               `space_mask/1` like every other title node, and so does the
               accessible name, so masking covers what a screen reader says
               too. Focus comes back here when the sheet closes: the Sheet
               hook stores the element focused when it opened (this button,
               which the tap focused) and restores it on close. --%>
          <% title =
            title_prefix(@active_space) <>
              space_header_name(@active_space, @space_participants, @user_id, space_mask(assigns)) %>
          <button
            type="button"
            phx-click="open_space_sheet"
            data-role="space-title"
            aria-haspopup="dialog"
            aria-controls="space-sheet"
            aria-expanded={to_string(@space_sheet != nil)}
            aria-label={"Space details, " <> title}
            class="flex min-h-11 min-w-0 flex-col justify-center rounded-lg text-left text-base-content focus-visible-ring"
          >
            <span class="flex min-w-0 items-center gap-1">
              <span class="min-w-0 truncate font-semibold">{title}</span>
              <span class="hero-chevron-down size-4 shrink-0 text-subtle" aria-hidden="true"></span>
            </span>
            <span class="truncate text-xs text-subtle" data-role="space-title-subtitle">
              {space_subtitle(@active_space, @space_participants, @user_id, @agent_status)}
            </span>
          </button>
          <%!-- The compact mobile scope pill that sat here moved to the space
               sheet's Scope row (task 01a1557a-8a6d stage 3), with the same
               masked label and the same `scope_filter` event. --%>
        </div>
        <%!-- Desktop: static title --%>
        <span class="hidden lg:flex items-center gap-2 overflow-hidden">
          <span
            :if={@active_space.kind == "channel"}
            class="text-subtle text-lg font-bold"
          >
            #
          </span>
          <span class="truncate font-bold text-base">
            {space_header_name(
              @active_space,
              @space_participants,
              @user_id,
              space_mask(assigns)
            )}
          </span>
          <%!-- Prominent chat-header scope-pill (chat plan v2 Stage 4).
               Only rendered for channels (DMs/groups have no scope). The
               wrapper class drives the larger-size visual variant; the
               inner pill remains clickable and pushes the `scope_filter`
               event with the channel's scope. Active state is implied
               from `@scope_filter` so a clicked-again pill reads as the
               currently-selected filter. --%>
          <% header_scope = !@external? && @active_space_scope %>
          <span :if={header_scope} class="chat-header-scope-pill">
            <%!-- Declared surface, as on the mobile pill above.

                 Call-site contract (task 01a0938b), identical on the mobile
                 pill and the rail's hidden-drawer group label:
                   scope = `@active_space_scope` (a compiled atom, or the slug
                           binary for an org created at runtime)
                   label = masked ? placeholder : `@active_space_org.name`
                   value = masked ? nil : `@active_space_org.slug`
                 The masked label is looked up by the org's NAME, never
                 through a closed scope->name map: `label_for_bucket/3` returns
                 nil for a nil bucket, and a nil label falls back to the
                 title-cased slug in text and aria-label and to the real slug
                 in `data-scope`, which is a leak in all three spellings. The
                 unmasked `value` is what keeps `data-scope` (and so the
                 colour rule) on a chip whose label is a binary. --%>
            <.scope_pill
              scope={header_scope}
              surface={:base_100}
              clickable={true}
              active={@scope_filter == header_scope}
              label={
                if @mask_names?,
                  do:
                    Platform.Chat.SidebarMask.label_for_bucket(
                      Platform.Chat.SidebarMask.context(
                        @sidebar_sections,
                        @mask_names?,
                        @revealed_section_ids
                      ),
                      @sidebar_sections,
                      @active_space_org && @active_space_org.name
                    ),
                  else: @active_space_org && @active_space_org.name
              }
              value={if !@mask_names? && @active_space_org, do: @active_space_org.slug}
            />
          </span>
          <%!-- DECISION (task 01a0b491, stage 4): `topic` is SUPPRESSED while a
               goal renders. Two strings answering "what is this space about"
               in one header will diverge, and the goal is the one with an
               owner, a measurement and a daily heartbeat behind it — the
               topic is free text nothing checks. So the goal REPLACES the
               topic rather than sitting beside it, and on every space
               without a goal (which is all but one) the topic renders
               exactly as it always did. Recorded here rather than inherited
               silently. --%>
          <span
            :if={@active_space.kind == "channel" && @active_space.topic && is_nil(@goal_panel)}
            class="truncate text-xs text-subtle"
          >
            — {@active_space.topic}
          </span>
          <span
            :if={@active_space.kind == "group"}
            class="text-xs text-subtle"
          >
            — {length(@space_participants)} members
          </span>
        </span>

        <%!-- Promote to channel button for groups --%>
        <form
          :if={@active_space.kind == "group" && !@active_space.is_direct}
          id="promote-to-channel-form"
          phx-hook="ButtonLoading"
          phx-submit="promote_to_channel"
          class="hidden lg:flex items-center gap-1 ml-2"
        >
          <input
            name="name"
            type="text"
            aria-label="Channel name"
            placeholder="Channel name…"
            class="input input-bordered input-xs w-32"
            required
          />
          <button type="submit" class="btn btn-xs btn-ghost">
            Convert to Channel
          </button>
        </form>
      </div>

      <%!-- Join Meeting button.

         `!@external?` (task 019fb955-f8b1 stage 5): the LiveKit room is
         keyed off the space, so this button offered an external user in
         a meeting's bound chat space the very join `MeetingHooks`
         refuses server-side as of stage 4 — "chat is chat only". THE
         SERVER REFUSAL IS THE GATE; this is cosmetics over it. Removing
         the condition here re-exposes a dead button, not a hole. A
         button that does nothing when clicked is quiet degradation, and
         that is the whole reason this line exists.

         Desktop only since task 01a1557a-8a6d stage 1: below lg the Call
         button at the end of the header carries the same gate and event. --%>
      <button
        :if={@meetings_enabled && !@in_meeting && !@external?}
        phx-click="meeting_join"
        class="hidden lg:flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-medium text-base-content hover:text-primary hover:bg-primary/10 transition-colors"
        title="Start or join a meeting in this space"
      >
        <span class="hero-video-camera size-4"></span>
        <span class="hidden md:inline">Meet</span>
      </button>

      <div class="flex flex-shrink-0 items-center gap-3 text-xs text-subtle">
        <.form
          for={@search_form}
          id="chat-search-form"
          phx-change="search_submit"
          phx-submit="search_submit"
          class="hidden lg:block"
        >
          <div class="flex items-center gap-2">
            <.input
              field={@search_form[:query]}
              type="text"
              aria-label="Search messages in this space"
              placeholder="Search messages…"
              autocomplete="off"
              phx-debounce="250"
              class="input input-sm w-64 text-sm"
            />

            <button
              :if={present?(@search_query)}
              type="button"
              phx-click="search_clear"
              class="rounded px-2 py-1 text-xs hover:bg-base-300"
            >
              Clear
            </button>
          </div>
        </.form>

        <button
          :if={@canvases != []}
          phx-click="canvas_panel_toggle"
          class={[
            "hidden lg:flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium text-base-content hover:text-base-content transition-colors hover:bg-base-300",
            @show_canvases && "!bg-base-300 !text-primary"
          ]}
        >
          <span class="hero-puzzle-piece size-4"></span>
          <span class="hidden md:inline">{length(@canvases)}</span>
        </button>

        <button
          :if={@pins != []}
          phx-click="pin_panel_toggle"
          class={[
            "hidden lg:flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium text-base-content hover:text-base-content transition-colors hover:bg-base-300",
            @show_pins && "!bg-base-300 !text-primary"
          ]}
        >
          <span class="hero-bookmark-solid size-4"></span>
          <span>{length(@pins)} pinned</span>
        </button>

        <%!-- The Agents entry (task 01a1557a-8f80 stage 2). It replaces the
             header agent eye: the eye toggled the ephemeral mutex, which a
             mention re-armed, so it could not hold "agents off". The Agents
             popover anchored here (the phone sheet is opened from the space
             sheet's Agents row) writes the persisted master switch, policy and
             per-agent silence. Rendered under `agents_entry?/3`: an agent is
             present and the space is not a DM (`attention_router.ex` makes
             DMs unconditionally `:directed`). `min-h-11 min-w-11` is the
             44px touch target, released at `md`. --%>
        <div
          :if={agents_entry?(@agent_presence, @has_agent_participant, @active_space)}
          class="relative hidden lg:block"
        >
          <button
            type="button"
            phx-click="agents_open"
            data-role="agents-open"
            aria-label="Agents"
            aria-haspopup="dialog"
            aria-expanded={to_string(@agents_sheet_open)}
            class="hidden lg:flex min-h-11 min-w-11 items-center justify-center gap-1 rounded px-2 py-0.5 text-xs font-medium text-subtle transition-colors active:bg-base-200 lg:hover:bg-base-200 lg:hover:text-base-content md:min-h-0 md:min-w-0"
          >
            <.icon name="hero-cpu-chip" class="size-4" />
            <span class="hidden md:inline">{AgentsSheet.awake_label(@agent_attention)}</span>
          </button>
          <AgentsSheet.agents_sheet
            surface={:popover}
            open={@agents_sheet_open}
            state={@agent_attention}
            active_space={@active_space}
          />
        </div>

        <%!-- The Members entry (task 01a1557a-8f80 stage 3): every space but a
             DM. The popover instance of `MembersComponent` is anchored under
             it; the phone opens the sheet instance from the space sheet's
             Members row. `min-h-11 min-w-11` is the Agents entry's touch
             target, released at `md`. --%>
        <div :if={@active_space.kind != "dm"} class="relative hidden lg:block">
          <button
            type="button"
            phx-click="members_open"
            data-role="members-open"
            aria-label="Members"
            aria-haspopup="dialog"
            aria-expanded={to_string(@show_members)}
            class="hidden lg:flex min-h-11 min-w-11 items-center justify-center gap-1 rounded px-2 py-0.5 text-xs font-medium text-subtle transition-colors active:bg-base-200 lg:hover:bg-base-200 lg:hover:text-base-content md:min-h-0 md:min-w-0"
          >
            <.icon name="hero-users" class="size-4" />
            <span class="hidden md:inline">{MembersComponent.people_label(@space_participants)}</span>
          </button>
          <.live_component
            module={MembersComponent}
            id="chat-members-popover"
            surface={:popover}
            open={@show_members}
            space={@active_space}
            space_name={
              space_header_name(@active_space, @space_participants, @user_id, space_mask(assigns))
            }
            current_user_id={@user_id}
            viewer={@current_user_record}
          />
        </div>

        <button
          phx-click="settings_open"
          class="hidden lg:flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium text-base-content hover:text-base-content transition-colors hover:bg-base-300"
          title="Space settings"
        >
          <span class="hero-cog-6-tooth size-4"></span>
          <span class="hidden md:inline">settings</span>
        </button>
      </div>

      <%!-- Phone Call (task 01a1557a-8a6d stage 1): the Meet button's gate
           and event, as the header's one coloured control. The server
           refusal in `Meetings.join_for_user/3` is still the gate. --%>
      <button
        :if={@meetings_enabled && !@in_meeting && !@external?}
        type="button"
        phx-click="meeting_join"
        data-role="space-call"
        aria-label="Start a call"
        class="flex size-11 shrink-0 items-center justify-center rounded-lg lg:hidden focus-visible-ring"
      >
        <span class="hero-phone size-5 text-primary" aria-hidden="true"></span>
      </button>
    </header>
    <%!-- The agents goal strip (task 01a0b491, stage 4).

         A SIBLING of the header, not a child of it: the header is `h-12`
         and the goal needs its own line, so nesting it would either
         squeeze the title row or force the header taller for every space
         in the product. Rendered only when `@goal_panel` is present —
         flag off, no goal on this space, or embedded mode, and this is
         zero DOM. An ordinary channel's header is byte-for-byte what it
         was before this feature existed, which is the positive control
         for every claim below.

         NO stat tile, NO delta colour, NO progress bar, NO agent roster.
         "Close backlog items" has no denominator, and a bar would have to
         invent one; an invented denominator is a number that looks
         measured. `--color-warning` appears in exactly ONE place on this
         surface — the FAULT no-measurement state (an unknown project scope,
         a failed count) — and nowhere else, not on the delta, not on a
         falling count, and not on an uncounted goal, which is a normal
         state the heartbeat fires for (task 01a0ca9f stage 3). --%>
    <%!-- `max-lg:hidden` (task 01a1557a-8a6d stage 3): below lg the goal
         lives on the space sheet's Goal page, which renders the SAME
         `goal_panel/1`. Desktop is unchanged. --%>
    <div
      :if={(@goal_panel || @goal_invite?) && !@embedded}
      class="flex flex-shrink-0 items-start gap-2 border-b border-base-content/10 px-5 py-2 max-lg:hidden"
      data-role="agents-goal-strip"
    >
      <.goal_panel
        active_space={@active_space}
        goal_panel={@goal_panel}
        goal_edit={@goal_edit}
        can_edit_goal?={@can_edit_goal?}
        goal_invite?={@goal_invite?}
        goal_scope_options={@goal_scope_options}
        goal_scope_error={@goal_scope_error}
        goal_cadence_form={@goal_cadence_form}
        goal_time_zone={@goal_time_zone}
      />
    </div>
    """
  end

  attr(:active_space, :any, required: true)
  attr(:goal_panel, :any, required: true)
  attr(:goal_edit, :boolean, required: true)
  attr(:can_edit_goal?, :boolean, required: true)
  attr(:goal_invite?, :boolean, default: false)
  attr(:goal_scope_options, :list, default: [])
  attr(:goal_scope_error, :atom, default: nil)
  attr(:goal_cadence_form, :map, default: nil)
  attr(:goal_time_zone, :string, default: nil)
  # DOM ids inside (the cadence selects and their labels) are prefixed by
  # this, so the space sheet's copy does not duplicate the strip's. The
  # strip passes nothing: its ids are exactly what they were.
  attr(:id_prefix, :string, default: "")

  @doc """
  The goal's body: leader face, sentence and measurement, the pencil, and the
  edit form with its project select and Check progress controls. Moved
  verbatim out of the agents goal strip (task 01a1557a-8a6d stage 3) so the
  strip and the phone space sheet's Goal page render ONE goal UI, not two.
  Every `data-role` and `phx-*` attribute is on the element it was on; the
  only change is the `id_prefix` on the two cadence ids.
  """
  def goal_panel(assigns) do
    ~H"""
    <%!-- The same leader face as the rail row, once. Swapping the leader
         through `role_assignments` broadcasts on `Roles.assignments_topic/0`
         and repaints both with no reload — the change is legible across
         the room because it is a different face, not a different word. --%>
    <%!-- No placeholder face: in the invitation state there is no panel,
         so there is no leader to claim and nothing renders here. --%>
    <.agent_avatar
      :if={@goal_panel && @goal_panel.leader}
      name={@goal_panel.leader.name}
      avatar_url={@goal_panel.leader.avatar_url}
      size="xs"
      class="ring-2 ring-primary mt-0.5"
      title={"#{@goal_panel.leader.name} leads"}
    />
    <div class="flex min-w-0 flex-1 flex-col gap-0.5">
      <span
        :if={@goal_panel && @goal_panel.leader}
        class="text-xs text-subtle"
        data-role="agents-goal-leader"
      >
        {@goal_panel.leader.name} leads
      </span>
      <%= if @goal_edit do %>
        <%!-- ONE form, ONE write. The invitation and the pencil both open
             THIS form, and it always submits `save_goal`, which always
             runs `Chat.update_space/2` through the stage-1 changeset.
             The handler's only `goal in [nil, ""]` branch is the
             install-level first-goal scope gate (task 01a0ca99), not a
             second write path. --%>
        <%!-- THE PROJECT SELECT (task 01a0cef1, Saru's canvas "Design
             direction: choosing the project a goal counts") sits on the
             goal's own line: input, select, Save, Cancel on ONE row from
             `sm:` up. Below `sm` the form wraps and the input takes the
             full width (`max-sm:basis-full`), so the select drops to its
             own line with the pencil's `max-sm:min-h-11` tap target. No
             label beyond `aria-label`; base tokens only, `--color-primary`
             stays on Save. The scope's READING state is the existing
             "open tasks in <name>" measurement clause, not new markup. --%>
        <%!-- CHECK PROGRESS (task 01a0e882 stage 3, Saru's canvas "Design
             direction: goal check cadence"). The cadence controls are a
             SECOND LINE inside the SAME form, so Save and Cancel commit or
             discard both. The first line keeps the one-row classes it had
             on its own `<form>` (now on the inner row), so from `sm:` up
             the goal row lays out exactly as before. `phx-change` only
             re-assigns the preview selection; nothing is written until
             Save. No cron text anywhere: options and preview are words
             and wall-clock times from `GoalCadenceForm`. --%>
        <form
          phx-submit="save_goal"
          phx-change="goal_form_change"
          class="flex flex-col gap-2"
          data-role="agents-goal-form"
        >
          <div class="flex flex-wrap items-center gap-2 sm:flex-nowrap">
            <input
              type="text"
              name="goal"
              value={@goal_panel && @goal_panel.goal}
              maxlength="500"
              aria-label="Goal"
              placeholder="Close backlog items"
              phx-mounted={JS.focus()}
              class="input input-bordered input-sm min-w-0 flex-1 max-sm:basis-full"
            />
            <select
              name="goal_project_id"
              aria-label="Project"
              class="select select-bordered select-sm sm:shrink-0 max-sm:min-h-11"
              data-role="agents-goal-scope"
            >
              <option value="" selected={goal_scope_value(@active_space) == ""}>
                All projects
              </option>
              <option
                :for={{label, value} <- @goal_scope_options}
                value={value}
                selected={goal_scope_value(@active_space) == value}
              >
                {label}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-primary">Save</button>
            <button type="button" phx-click="cancel_goal_edit" class="btn btn-sm btn-ghost">
              Cancel
            </button>
          </div>
          <.goal_cadence_controls
            :if={@can_edit_goal? && @goal_cadence_form}
            selection={@goal_cadence_form}
            time_zone={@goal_time_zone}
            id_prefix={@id_prefix}
          />
        </form>
        <%!-- The refusal renders INLINE under the form, in `--color-error`,
             and nowhere else: not a flash, not a warning. --%>
        <span
          :if={@goal_scope_error == :unknown_project}
          class="text-xs text-error"
          data-role="agents-goal-scope-error"
        >
          That project is not available in this channel's org.
        </span>
      <% else %>
        <%!-- EMPTY + ADMIN (task 01a0ca99): the invitation occupies the
             line the goal will occupy, at the goal sentence's `text-sm`,
             inside the strip's existing padding and border, so nothing
             moves between wanting a goal, typing it and having it. Ghost,
             `/60` (the measured AA floor; `/40` fails), and no warning,
             error or info token: a goal-less channel is not a fault. The
             tap target matches the pencil's `max-sm:` treatment, and
             `max-sm:-my-2` hands the extra height back to the strip's own
             `py-2`. MEASURED at 375x812 without it: the 44px box grew the
             strip to 61px while the editing form's strip is 45px, so the
             page jumped 16px on click. With it the box stays 44px tall and
             the strip is the same height in both states. --%>
        <button
          :if={!@goal_panel}
          type="button"
          phx-click="edit_goal"
          class="btn btn-ghost btn-sm self-start px-0 text-sm font-normal text-base-content max-sm:-my-2 max-sm:min-h-11 max-sm:min-w-11"
          data-role="agents-goal-invite"
        >
          Set a goal for this channel
        </button>
        <%!-- WRAPS BELOW `sm`, single row from `sm:` upward. MEASURED at
             375x812 before this change, against goals of growing length:
             the measurement clause reached 0px at 38 characters and the
             strip overflowed the viewport (scrollWidth 382 > clientWidth
             375) at 40, while the goal input allows `maxlength="500"`.
             The desktop rule below — sentence `shrink-0`, clause
             `min-w-0 truncate` — is correct at 1280px where there is
             slack, and at 375px it spends the entire deficit on the one
             fragment that carries the heartbeat's payload. So: let the
             row become two lines below `sm` instead of truncating the
             numeral away. `sm:flex-nowrap` and `sm:shrink-0` restore the
             desktop rule exactly — at >=640px the computed layout is
             identical to what shipped in v1, which is why v1's existing
             assertions in `chat_live_agents_goal_surface_test.exs` must
             stay green. --%>
        <div
          :if={@goal_panel}
          class="flex min-w-0 flex-wrap items-baseline gap-2 sm:flex-nowrap"
          data-role="agents-goal-row"
        >
          <%!-- The goal sentence at FULL `--color-base-content`: it is
               the most meaningful string on the surface, and the
               truncation rule says the most meaningful fragment is the
               last thing allowed to truncate. `sm:shrink-0` here,
               `min-w-0 truncate` on the clause beside it. Below `sm` the
               sentence is NOT `shrink-0`: it wraps onto a second line and
               the clause keeps its own line at full width. --%>
          <span class="text-sm text-base-content sm:shrink-0" data-role="agents-goal-sentence">
            {@goal_panel.goal}
          </span>
          <%!-- The measurement clause at `/60`, which is the measured
               contrast FLOOR and not a preference: composited, `/40`
               (the treatment `topic` uses two lines up) is 2.85:1 light
               and 3.53:1 dark and fails AA in both themes; `/60` is
               5.74:1 and 6.26:1. --%>
          <%!-- An UNCOUNTED goal (task 01a0ca9f stage 3, Saru's canvas
               "Design direction: the goal strip when a goal has no
               count"). The heartbeat fires for it, so this is a normal
               state and not a fault: `/60`, the same tier as the measured
               clause, NOT `text-warning` and NOT `text-info`. No mono span,
               no rule, no icon — there is no numeral to set in mono, and a
               glyph would read as a status. Same slot, size and
               truncation as the other two branches. This branch sits
               BEFORE the `missing?` one because an uncounted slot is
               `missing?: true` too (every no-number consumer keeps
               treating it as no-number); it matches on `kind` only, so a
               counted slot (`missing?: false`, no `kind`) never reaches it. --%>
          <%= cond do %>
            <% @goal_panel.measurement[:kind] == :uncounted -> %>
              <span
                class="min-w-0 truncate text-xs text-subtle"
                data-role="agents-goal-measurement-uncounted"
              >
                {AgentsGoalHeartbeat.format_measurement(@goal_panel.measurement)}
                <.goal_cadence_tail cadence={@goal_panel[:cadence]} />
              </span>
            <% @goal_panel.measurement[:missing?] -> %>
              <%!-- The warning is reserved for a genuine fault:
                   `:unknown_scope` (the goal's project scope names no
                   project that exists), `:count_failed`, and the unkinded
                   missing slots. --%>
              <span
                class="min-w-0 truncate text-xs text-warning"
                data-role="agents-goal-measurement-missing"
              >
                {AgentsGoalHeartbeat.format_measurement(@goal_panel.measurement)}
                <.goal_cadence_tail cadence={@goal_panel[:cadence]} />
              </span>
            <% true -> %>
              <span
                class="min-w-0 truncate text-xs text-subtle"
                data-role="agents-goal-measurement"
              >
                <%!-- The number, and ONLY the number, in JetBrains Mono
                     inline in the sentence. A changing digit is legible
                     at a glance in mono without building a tile around
                     it. --%>
                <span class="font-mono" data-role="agents-goal-number">
                  {@goal_panel.measurement.value}
                </span>
                {AgentsGoalHeartbeat.format_measurement_tail(@goal_panel.measurement)}
                <.goal_cadence_tail cadence={@goal_panel[:cadence]} />
              </span>
          <% end %>
          <%!-- TAP TARGET, and this is independent of the reflow above:
               MEASURED at 375x812 BEFORE any change, the control's box was
               32 x 21 px — under 44px in BOTH dimensions, and it was that
               size before this stage existed. `max-sm:` raises the target
               with PADDING below `sm` and leaves the glyph at `size-3.5`,
               because a bigger pencil is a louder surface and the
               no-chrome contract above forbids that. `max-sm:` rather than
               a `sm:` reset is deliberate: it adds no class that is live
               at >=640px, so the desktop computed box stays 32 x 21 with
               nothing to restore. Matches the 44px touch floor every phone
               control here keeps (`min-h-11 min-w-11`). --%>
          <button
            :if={@can_edit_goal?}
            type="button"
            phx-click="edit_goal"
            class="btn btn-ghost btn-xs shrink-0 max-sm:min-h-11 max-sm:min-w-11"
            aria-label="Edit goal"
            title="Edit goal"
          >
            <span class="hero-pencil-square size-3.5"></span>
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:selection, :map, required: true)
  attr(:time_zone, :string, default: nil)
  attr(:id_prefix, :string, default: "")

  # The Check progress line: a cadence select, an "at" hour select for
  # Once a day only (option VALUE is the UTC hour, label the viewer's local
  # time), and the xs /60 preview. Tokens: the scope select's
  # `select select-bordered select-sm` and its `max-sm:min-h-11` tap
  # target; helper text on the muted `/60` slot; no accent or warning.
  defp goal_cadence_controls(assigns) do
    now = DateTime.utc_now()

    assigns =
      assigns
      |> assign(:cadence_value, Atom.to_string(assigns.selection.cadence))
      |> assign(:cadence_options, GoalCadenceForm.cadence_options(assigns.selection))
      |> assign(:hour_options, GoalCadenceForm.hour_options(assigns.time_zone, now))
      |> assign(:preview, GoalCadenceForm.preview(assigns.selection, assigns.time_zone, now))

    ~H"""
    <div class="flex flex-col gap-1" data-role="agents-goal-cadence-line">
      <div class="flex flex-wrap items-center gap-2">
        <label class="text-xs font-medium text-base-content" for={@id_prefix <> "agents-goal-cadence"}>
          Check progress
        </label>
        <select
          id={@id_prefix <> "agents-goal-cadence"}
          name="goal_cadence"
          class="select select-bordered select-sm max-sm:min-h-11"
          data-role="agents-goal-cadence"
        >
          <option
            :for={{label, value} <- @cadence_options}
            value={value}
            selected={value == @cadence_value}
          >
            {label}
          </option>
        </select>
        <%= if @selection.cadence == :daily do %>
          <label
            class="text-xs font-medium text-base-content"
            for={@id_prefix <> "agents-goal-cadence-hour"}
          >
            at
          </label>
          <select
            id={@id_prefix <> "agents-goal-cadence-hour"}
            name="goal_cadence_hour"
            class="select select-bordered select-sm max-sm:min-h-11"
            data-role="agents-goal-cadence-hour"
          >
            <option
              :for={{label, hour} <- @hour_options}
              value={hour}
              selected={hour == @selection.hour_utc}
            >
              {label}
            </option>
          </select>
        <% end %>
      </div>
      <span class="text-xs text-subtle" data-role="agents-goal-cadence-preview">
        {@preview}
      </span>
    </div>
    """
  end

  attr(:cadence, :any, default: nil)

  # The strip's cadence tail, inside the measurement span so it truncates
  # with the clause. Hourly (the default) renders NOTHING. Its own `/60`
  # keeps it out of `text-warning` in the missing branch; Off is a choice,
  # not a fault, so it is never warning-coloured.
  defp goal_cadence_tail(assigns) do
    assigns = assign(assigns, :tail, GoalCadenceForm.tail(cadence_of(assigns.cadence)))

    ~H"""
    <span :if={@tail} class="text-subtle" data-role="agents-goal-cadence-tail">
      {@tail}
    </span>
    """
  end

  defp cadence_of(%{cadence: cadence}), do: cadence
  defp cadence_of(_), do: nil

  attr(:search_query, :any, required: true)
  attr(:search_results, :list, required: true)
  attr(:participants_map, :map, required: true)

  @doc """
  The search-results drawer, gated on `present?(@search_query)`.
  """
  def search_drawer(assigns) do
    ~H"""
    <%!-- `max-lg:hidden` (task 01a1557a-8a6d stage 2): below lg the space
         sheet's Search page lists the results, so a phone search must not
         also paint this drawer above the messages. Desktop is unchanged. --%>
    <div
      :if={present?(@search_query)}
      class="border-b border-edge bg-base-200 px-5 py-3 max-lg:hidden"
    >
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Search Results
          </p>
          <p class="text-sm text-base-content">
            “{@search_query}” · {length(@search_results)} match{if length(@search_results) == 1,
              do: "",
              else: "es"}
          </p>
        </div>

        <button phx-click="search_clear" class="btn btn-ghost btn-xs">
          Clear
        </button>
      </div>

      <div class="mt-3 space-y-2">
        <button
          :for={result <- @search_results}
          type="button"
          phx-click="search_open_result"
          phx-value-message-id={result.id}
          class="block w-full rounded-xl border border-edge bg-base-100 px-3 py-2 text-left transition-colors hover:border-primary/40 hover:bg-base-100/80"
        >
          <div class="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-widest text-subtle">
            <span>{PresenceHooks.sender_name(@participants_map, result.participant_id)}</span>
            <.local_time
              id={"search-time-#{result.id}"}
              timestamp={result.inserted_at}
            />
            <span
              :if={is_binary(result.thread_id)}
              class="rounded-full bg-base-300 px-2 py-0.5 normal-case tracking-normal text-[10px]"
            >
              Thread
            </span>
            <span
              :if={result.search_rank}
              class="font-mono normal-case tracking-normal text-[10px] text-subtle"
            >
              rank {Float.round(result.search_rank, 3)}
            </span>
          </div>

          <p class="mt-1 text-sm leading-6 text-base-content">
            {search_headline(result)}
          </p>
        </button>

        <%!-- Empty state per docs/design-system/03-voice.md §5.5 — search
             no-results uses :standard with the magnifying-glass icon. --%>
        <.empty_state
          :if={@search_results == [] and present?(@search_query)}
          variant={:standard}
          icon_name="hero-magnifying-glass"
        >
          <:title>No matches</:title>
          <:body>No messages match "{@search_query}".</:body>
          <:actions>
            <button
              type="button"
              phx-click="search_clear"
              class="btn btn-ghost btn-sm w-full"
            >
              Clear search
            </button>
          </:actions>
        </.empty_state>
      </div>
    </div>
    """
  end

  attr(:active_space, :any, required: true)
  attr(:pins, :list, required: true)
  attr(:show_pins, :boolean, required: true)

  @doc """
  The pinned-messages drawer, gated on `@show_pins && @pins != []`.
  """
  def pins_drawer(assigns) do
    ~H"""
    <div
      :if={@show_pins && @pins != []}
      class="border-b border-edge bg-base-200 px-5 py-2"
    >
      <p class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content">
        Pinned Messages
      </p>
      <div class="flex flex-col gap-1 max-h-40 overflow-y-auto">
        <div
          :for={pin <- @pins}
          class="flex items-center justify-between rounded bg-base-100 px-3 py-1.5 text-sm"
        >
          <span class="truncate text-base-content text-xs">
            <span class="hero-bookmark-solid size-3 inline-block align-text-bottom"></span>
            pinned message
            <span class="font-mono text-subtle text-[10px]">
              {String.slice(pin.message_id, 0, 8)}…
            </span>
          </span>
          <button
            :if={@active_space && is_nil(@active_space.archived_at)}
            phx-click="pin_toggle"
            phx-value-message-id={pin.message_id}
            phx-value-space-id={pin.space_id}
            class="ml-2 text-xs font-medium text-base-content hover:text-error"
          >
            Unpin
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:active_canvas, :any, required: true)
  attr(:current_participant, :any, required: true)
  attr(:new_canvas_form, :any, required: true)
  attr(:show_canvases, :boolean, required: true)
  attr(:canvas_sort, :atom, required: true)
  attr(:canvas_search_query, :string, required: true)
  attr(:canvas_unindexed_count, :integer, required: true)

  # ── The explorer's inputs (task 01a0740d stage 3) ─────────────────────────
  #
  # All resolved in `CanvasHooks`, never here. The drawer hands the explorer
  # what it was given: it does not know what a live meeting is, which spaces
  # the viewer is in, or how a `cloned_from` id becomes a title. Those are
  # queries, and a template that runs queries runs them on every keystroke of
  # the busiest LiveView in the app.
  #
  # `canvas_groups` is MODE-AWARE and arrives already correct for
  # `@canvas_search_query`: browse groups from `Chat.list_canvas_groups/2`, or
  # search groups derived from `Chat.search_canvases/3`. It is one assign
  # rather than two-plus-a-branch here for the reason the drawer already
  # records about `search_active?/1` — the pane that renders and the branch
  # that queried must not be able to disagree about which mode it is in.
  attr(:canvas_groups, :list, required: true)
  attr(:canvas_pinned_groups, :list, required: true)
  attr(:canvas_parent_titles, :map, required: true)
  attr(:canvas_expanded_keys, :list, required: true)
  attr(:canvas_explorer_collapsed, :boolean, required: true)
  attr(:canvas_archive_count, :integer, required: true)
  attr(:canvas_search_focus, :boolean, required: true)

  # The New canvas form's Prototype choice (task 01a1316b-4e46 stage 2). The
  # upload config is `@uploads.prototype_bundle` from ChatLive; nil (and
  # `can_publish_prototype?` false) renders the form exactly as before.
  # `ChatLive.PrototypeUpload.allowed?/2` decides the boolean once per space
  # change, never here.
  attr(:prototype_upload, :any, default: nil)
  attr(:can_publish_prototype?, :boolean, default: false)

  @doc """
  The live-canvases drawer and its `#new-canvas-form`.

  ## The list is `CanvasExplorer`, not this module's own markup

  Task `01a0740d` stage 3 replaced this drawer's flat single-space list AND its
  flat results list with `PlatformWeb.Components.Canvases.CanvasExplorer`. What
  stayed here is everything the explorer deliberately does not own: the search
  form and its 300ms debounce, the `canvas-search-indexing-state` caveat line
  and its three recompute points, the sort control, and the new-canvas form.

  The explorer is grouped and multi-space, so a search now reaches every space
  the viewer participates in rather than only the one they are standing in.
  """
  def canvases_drawer(assigns) do
    assigns =
      assign(
        assigns,
        :prototype_choice?,
        prototype_choice?(
          assigns.can_publish_prototype?,
          assigns.prototype_upload,
          assigns.new_canvas_form
        )
      )

    ~H"""
    <div
      :if={@show_canvases}
      class="border-b border-edge bg-base-200 px-5 py-3"
    >
      <div class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_320px]">
        <%!-- `min-w-0` is load-bearing, added in task 01a07402 stage 5.
             A grid item defaults to `min-width: auto`, i.e. it refuses to
             shrink below its MIN-CONTENT width — and the search snippet is
             `truncate`, which means `white-space: nowrap`, so its min-content
             width is the whole untruncated line. Measured at 375px: the
             snippet demanded 462px, dragged this column out to 769px and took
             the New canvas card off-screen with it. `truncate` cannot ellipse
             anything until an ancestor is allowed to be narrower than its
             text. The `xl` track above already says `minmax(0,1fr)` for the
             same reason, which is why only the mobile width broke. --%>
        <div class="min-w-0 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Live Canvases
          </p>

          <%!-- Search input (task 01a07402 stage 5). `phx-change` on the form
               rather than the input so the payload is `%{"query" => ...}`
               whatever the browser does with implicit submission. The 300ms
               debounce is what keeps a full-text query off every keystroke.

               THE LABEL SAYS "your spaces", NOT "this channel". Task 01a0740d
               stage 3 made this query multi-space: every space the viewer
               participates in, plus the one they are standing in. A
               screen-reader user told "this channel" would have no way to
               account for a result from somewhere else, and the group headers
               that explain it are below the field, not on it. --%>
          <form phx-change="canvas_search" class="flex items-center gap-2">
            <.input
              type="search"
              name="query"
              value={@canvas_search_query}
              aria-label="Search canvases across your spaces"
              placeholder="Search titles and contents"
              data-role="canvas-search-input"
              phx-debounce="300"
              class="input input-xs input-bordered w-full text-xs"
            />
          </form>

          <%!-- ── FOCUS THE FIELD WHEN THE STRIP'S SEARCH ICON ASKS ────────
               The explorer's collapsed strip carries a search icon that must
               open the list AND land the cursor in the field. The explorer owns
               no field — this one is the drawer's — so it emits
               `canvas_explorer_expand` with `phx-value-focus="search"` and
               `CanvasHooks` flips `:canvas_search_focus`.

               A MOUNT-TIME `JS.focus`, not a `push_event`: `push_event/3` needs
               a JS hook on the receiving end, and the only focus hook in the app
               (`InlineFocus`) is hard-wired to inline thread compose ids. This
               needs no new JavaScript at all — `phx-mounted` is the same
               mechanism `Partials` already uses for `JS.focus_first/0` in three
               places.

               It works because the element is ABSENT until the flag is set, so
               inserting it is what fires `phx-mounted`. That also explains why
               `"canvas_explorer_collapse"` clears the flag: left set, the
               trigger stays in the DOM and a second search-icon expand would
               mount nothing and focus nothing.

               `sr-only` rather than `hidden`: `display: none` is not focus- or
               animation-eligible in every engine, and this element's whole job
               is to be processed on insert. It has no text, so there is nothing
               for a screen reader to announce either way. --%>
          <div
            :if={@canvas_search_focus}
            id="canvas-search-focus-trigger"
            phx-mounted={JS.focus(to: ~s([data-role="canvas-search-input"]))}
            class="sr-only"
          >
          </div>

          <%!-- ── THE PARTIAL-INDEX LINE ───────────────────────────────────
               Directly under the search form and OUTSIDE both mode divs, so it
               renders on one condition in list mode and results mode alike:
               `unindexed_count > 0`, and nothing else. It lived INSIDE the
               results-mode div until task 01a07402 stage 6, which gated it on a
               non-blank query as well and so hid it from the state a reader
               arrives in — and the branch's own test only ever asserted it
               after typing, so a full green suite was consistent with the line
               never appearing until you searched. Do not put it back inside a
               mode div: "a single line above the results" in the design canvas
               is placement, not a condition.

               It is the difference between "not found" and "not searched yet" —
               opposite conclusions for the reader — so it sits ABOVE whichever
               pane follows, where it is read before that pane is.
               Neutral, not `--color-warning`: nothing is wrong and nobody is
               being asked for anything. The colour is `--color-neutral` via
               the utility below in LIGHT. In DARK, task 01a0792c overrides
               that with a rule in `app.css` scoped to this element
               (`--color-base-content` at 55%), because `--color-neutral`
               measured 2.23:1 on this box against a 4.5:1 floor. Both themes
               are guarded by
               `Platform.Design.CanvasSearchSnippetContrastTest`.
               No icon, no spinner and no
               percentage, on purpose — a percentage invites someone to sit and
               watch a backfill.

               The count behind it is deliberately NOT recomputed in the render
               path; `CanvasHooks.refresh_unindexed_count/1` names the four
               moments it is recomputed at and what stays stale between them.

               KNOWN LIMIT, ticket `01a077b2-8882`: `unindexed_count/1` counts
               canvases with no index row, and stage 3 SKIPS a canvas it cannot
               index (a >1MB tsvector raises `54000 program_limit_exceeded`)
               while deliberately leaving it counted. A permanently unindexable
               canvas is therefore indistinguishable from one the backfill has
               not reached yet, and it keeps this line lit in its space forever.
               If you are looking at a line that never goes away, that is the
               thread to pull — the backfill is not necessarily wedged. --%>
          <p
            :if={@canvas_unindexed_count > 0}
            data-role="canvas-search-indexing-state"
            class="px-1 text-[11px] text-neutral"
          >
            Older canvases are still being indexed, so a phrase you remember may not be findable yet.
          </p>

          <%!-- ── SORT, BROWSE MODE ONLY ───────────────────────────────────
               Options and labels come from `CanvasHooks.sort_options/0`, so the
               allow-list that PARSES the incoming value and the list that
               OFFERS it are one list. A select that can emit a value its
               handler rejects is a bug waiting for whoever adds the fifth
               option.

               Deliberately browse-mode only, unchanged from the flat list this
               replaced: results come back in `ts_rank_cd` order from
               `Chat.search_canvases/3` and this control does NOT apply to
               them. Offering a sort that silently does nothing would be worse
               than not offering it.

               WHAT CHANGED IN STAGE 3, because it is the only reason this
               control still means anything: the sort is now passed THROUGH to
               `Chat.list_canvas_groups/2` as its `:order` option. The explorer
               holds one bounded page of each group, so an in-memory sort here
               would order 20 rows out of 41 and present the answer as the
               group's order — not a slower version of the query, a different
               and wrong one. Left unwired it would have been a live control
               that moved nothing, which is the failure the paragraph above
               refuses. --%>
          <form
            :if={not CanvasHooks.search_active?(@canvas_search_query)}
            phx-change="canvas_sort"
            class="flex items-center gap-2"
          >
            <label for="canvas-sort" class="text-[11px] font-medium text-base-content">Sort</label>
            <select
              id="canvas-sort"
              name="order"
              class="select select-xs select-bordered w-auto text-xs"
            >
              <option
                :for={{value, label} <- CanvasHooks.sort_options()}
                value={value}
                selected={to_string(@canvas_sort) == value}
              >
                {label}
              </option>
            </select>
          </form>

          <%!-- ── THE EXPLORER ─────────────────────────────────────────────
               One component for both modes. It decides collapse, paging and
               match-opening off what it is handed; it does not query.

               The height bound stays here rather than moving into the
               component, because it is a fact about THIS drawer: the drawer is
               a flex child of a `flex-col overflow-hidden` column, so without
               one the overflow is CLIPPED with no scrollbar anywhere and the
               last groups become unreachable rather than merely far down
               (reported at 16 canvases, long before grouping existed). The
               explorer's own bound is the page size, which is a different
               guarantee: it caps what is RENDERED, not what is visible.

               No bound while collapsed — the 44px strip is three icons tall and
               a `max-h` there would only be a scrollbar on nothing. --%>
          <.canvas_explorer
            id="canvas-explorer"
            query={@canvas_search_query}
            collapsed={@canvas_explorer_collapsed}
            pinned_groups={@canvas_pinned_groups}
            space_groups={@canvas_groups}
            expanded_keys={@canvas_expanded_keys}
            parent_titles={@canvas_parent_titles}
            active_canvas_id={@active_canvas && @active_canvas.id}
            archive_count={@canvas_archive_count}
            class={[
              "overflow-hidden rounded-xl border border-edge",
              not @canvas_explorer_collapsed && "max-h-80 overflow-y-auto"
            ]}
          />
        </div>

        <.form
          for={@new_canvas_form}
          id="new-canvas-form"
          phx-hook="ButtonLoading"
          phx-change="canvas_new_change"
          phx-submit="canvas_create"
          class="space-y-3 rounded-2xl border border-edge bg-base-100 p-4"
        >
          <div>
            <p class="text-sm font-semibold text-base-content">New canvas</p>
            <p class="text-xs text-subtle">
              Creates a canvas and posts a linked canvas message.
            </p>
          </div>

          <div
            :if={@can_publish_prototype? and @prototype_upload}
            role="radiogroup"
            aria-label="Canvas type"
            class="grid grid-cols-2 gap-1 rounded-field border border-edge p-1"
            data-role="new-canvas-kind"
          >
            <label
              :for={{value, label} <- [{"blank", "Blank"}, {"prototype", "Prototype"}]}
              class={[
                "flex min-h-9 cursor-pointer items-center justify-center rounded-field text-sm",
                new_canvas_kind(@new_canvas_form) == value &&
                  "bg-base-200 font-semibold text-base-content",
                new_canvas_kind(@new_canvas_form) != value && "text-subtle"
              ]}
            >
              <input
                type="radio"
                name={@new_canvas_form[:kind].name}
                value={value}
                checked={new_canvas_kind(@new_canvas_form) == value}
                class="sr-only"
                data-role={"new-canvas-kind-#{value}"}
              />
              {label}
            </label>
          </div>

          <.input
            field={@new_canvas_form[:title]}
            label="Title"
            placeholder={if @prototype_choice?, do: "Checkout flow", else: "Sprint planning board"}
          />

          <div :if={@prototype_choice?} class="space-y-2" data-role="prototype-drop">
            <label
              for={@prototype_upload.ref}
              phx-drop-target={@prototype_upload.ref}
              class="flex min-h-24 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border border-dashed border-edge bg-base-200 px-3 py-4 text-center"
            >
              <span class="hero-arrow-up-tray size-5 text-neutral" aria-hidden="true"></span>
              <span class="text-sm text-base-content">Drop a zip of the prototype</span>
              <span class="text-xs text-subtle">
                index.html at the top, with its CSS, JS and images beside it
              </span>
              <.live_file_input upload={@prototype_upload} class="sr-only" />
            </label>
            <div
              :for={entry <- @prototype_upload.entries}
              class="flex items-center gap-2 text-xs"
              data-role="prototype-drop-entry"
            >
              <span class="hero-document size-4 shrink-0 text-neutral" aria-hidden="true"></span>
              <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
              <span class="shrink-0 font-mono text-neutral">{entry.progress}%</span>
            </div>
            <p
              :for={err <- upload_errors(@prototype_upload)}
              class="text-xs text-error"
              role="alert"
            >
              {prototype_upload_error(err)}
            </p>
          </div>

          <button
            :if={not @prototype_choice?}
            type="submit"
            class="btn btn-neutral w-full"
            disabled={is_nil(@current_participant)}
          >
            Create canvas
          </button>
          <button
            :if={@prototype_choice?}
            type="submit"
            class="btn btn-primary w-full"
            disabled={is_nil(@current_participant) or @prototype_upload.entries == []}
            data-role="prototype-publish"
          >
            Publish prototype
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp new_canvas_kind(form) do
    case form[:kind].value do
      "prototype" -> "prototype"
      _ -> "blank"
    end
  end

  defp prototype_choice?(can_publish?, upload, form),
    do: can_publish? and not is_nil(upload) and new_canvas_kind(form) == "prototype"

  defp prototype_upload_error(:too_large), do: "That zip is too large."
  defp prototype_upload_error(:not_accepted), do: "Only a .zip can be published."
  defp prototype_upload_error(:too_many_files), do: "Drop one zip."
  defp prototype_upload_error(other), do: "Upload failed: #{other}"

  # `canvas_result_snippet/1` USED TO LIVE HERE. It moved, unchanged, to
  # `PlatformWeb.Components.Canvases.CanvasExplorer.explorer_row_snippet/1`
  # in task 01a0740d stage 3, when the explorer took over this drawer's
  # results markup — the snippet is part of a search ROW, and the rows are no
  # longer rendered here. The data-roles, classes and `phx-no-format` went
  # with it verbatim, because `app.css` keys two rules off
  # `[data-role="canvas-result-snippet"]` and
  # `[data-role="canvas-result-snippet-leading"]` and this drawer's own tests
  # assert that three-part structure. `marked_text/1` and
  # `split_marked_snippet/1` left this module's import list with it; they had
  # no other caller here.

  # The goal space's stored scope as the select's value: "" (All projects)
  # when the key is absent.
  defp goal_scope_value(%{metadata: %{"goal_project_id" => id}}) when is_binary(id), do: id
  defp goal_scope_value(_space), do: ""

  # A wrapper, not a qualified call — see "WHY THE MASK CALL IS WRAPPED" in
  # the moduledoc.
  defp space_mask(assigns), do: ChatLive.space_mask(assigns)

  @doc """
  Whether the Agents entry renders: an agent is joined or seated, and the
  space is not a DM (`attention_router.ex` makes DMs unconditionally
  `:directed`). The header `agents-open` button and the space sheet's Agents
  row (task 01a1557a-8a6d) both read this, so they render under one condition.
  """
  def agents_entry?(agent_presence, has_agent_participant, space) do
    (agent_presence[:joined?] || has_agent_participant) && space.kind != "dm"
  end

  @doc "The `#` a channel's title carries; nothing for any other kind."
  def title_prefix(%{kind: "channel"}), do: "#"
  def title_prefix(_space), do: ""

  @doc """
  The phone title button's subtitle (task 01a1557a-8a6d stage 1). A direct
  message with an agent shows the agent status, one with a person shows
  "Direct message", and every other kind counts its people.
  """
  def space_subtitle(%{kind: "dm"}, participants, user_id, agent_status) do
    other = Enum.find(participants, &(&1.participant_id != user_id))

    case other do
      %{participant_type: "agent"} -> agent_status_label(agent_status)
      _ -> "Direct message"
    end
  end

  def space_subtitle(_space, participants, _user_id, _agent_status),
    do: people_count(length(participants))

  defp people_count(1), do: "1 person"
  defp people_count(n), do: "#{n} people"

  defp agent_status_label(:online), do: "Online"
  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:thinking), do: "Thinking"
  defp agent_status_label(_status), do: "Agent"
end
