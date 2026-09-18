defmodule PlatformWeb.ChatLive.Partials.Conversation do
  @moduledoc """
  The top half of the conversation pane — everything between
  `<div id="chat-drop-zone">` and the message list.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail`,
  `ChatLive.Partials.Rail` and `ChatLive.Partials.MobileBrowser` (ADR 0035):
  function components, no state, each taking a declared set of attrs.
  Extracted from `chat_live.html.heex` in task 01a0312e stage 5 as a PURE
  MOVE — every `id`, `phx-hook`, `phx-click`, `phx-value-*`, `data-*` and
  `aria-*` sits on the element it sat on before.

  The regions, in template order:

    * `space_header/1` — the `<header>` space bar: the mobile and desktop
      title branches, the group promote form, the Meet button, the search
      form, the canvas/pin counters, the agent eye and settings
    * `mobile_pinned_strip/1` — `<nav data-role="mobile-pinned-strip">`
    * `channel_pills/1` — `<nav aria-label="Channel switcher">`, including
      the left-anchored magnifying-glass button
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
  (both branches), `mobile_pinned_strip/1` and `channel_pills/1`.

  ## WHY THE TWO MASK CALLS ARE WRAPPED, NOT QUALIFIED

  `space_mask/1` and `masked_space_name/2` live in `PlatformWeb.ChatLive`,
  which imports this module — so they cannot be imported back. They are
  wrapped in private functions of the SAME NAME AND ARITY rather than called
  as `ChatLive.space_mask(...)` because two of the call sites sit inside
  `truncate` spans on lines already close to the formatter's width: a longer
  call reflows the interpolation onto its own line, which puts whitespace
  INSIDE the span and changes the rendered text while every markup assertion
  stays green (task 01a0312e stage 3 finding). Same call text, same wrapping,
  no reflow.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [
      search_headline: 1,
      sidebar_display_name: 2,
      space_header_name: 4,
      unread_label: 1
    ]

  import PlatformWeb.ChatLive.Partials, only: [brand_new_user_empty_state: 1]
  # `relative_time/1` left this list in task 01a0740d stage 3 along with the
  # flat canvas rows that used it. The explorer's browse row is title-only by
  # design (the group header has already said where you are) and its search row
  # calls the same shared helper from inside the component, so importing it here
  # would be an import for nothing.
  import PlatformWeb.Components.ChatHelpers, only: [present?: 1]
  import PlatformWeb.Components.Canvases.CanvasExplorer, only: [canvas_explorer: 1]
  import PlatformWeb.CoreComponents, only: [input: 1]
  import PlatformWeb.Components.ChatMessage, only: [local_time: 1]
  import PlatformWeb.Components.EmptyState, only: [empty_state: 1]
  import PlatformWeb.Components.ScopePill, only: [scope_pill: 1]
  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Chat.Sidebar
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.CanvasHooks
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
  attr(:active_agent_participant_id, :any, required: true)
  attr(:active_agent_armable_id, :any, required: true)
  attr(:active_agent_name, :any, required: true)
  attr(:active_agent_armable_name, :any, required: true)
  attr(:goal_panel, :any, required: true)
  attr(:goal_edit, :boolean, required: true)
  attr(:can_edit_goal?, :boolean, required: true)

  @doc """
  The conversation `<header>` — space title, meeting entry, search, the
  canvas/pin counters, the agent eye and settings.

  The `@active_space && !@embedded` gate travelled INTO the component with
  the markup (same convention as `Rail.rail/1` and `MobileBrowser.mobile_browser/1`),
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
           rail row for `#wayne-tech` and leaving the header spelling it out is
           the same leak with an extra step. `space_label/3` looks the name up
           across the whole rail because this header has no section in hand.
           Applied to BOTH breakpoint branches below — the mobile and desktop
           titles are separate nodes, and a mask applied to one of them is the
           shape of bug this stage exists to find. --%>
      <div class="flex items-center gap-2 overflow-hidden">
        <%!-- Mobile: static channel name. Channel switching now happens via the
             pills strip below the header (Refined Option A — Marlowe approval
             2026-05-10). The previous tap-channel-name-to-open-browser flow
             was confusing with the shell's hamburger menu — both opened
             drawers, so users could tap one when they meant the other. The
             pills strip makes channel switching 1-tap and removes the
             dual-affordance ambiguity. The overflow magnifying-glass icon at
             the right of the strip still opens the full channel browser
             (this template's @mobile_browser_open overlay) for the long-tail
             jump-to-channel case. --%>
        <div class="flex items-center gap-2 overflow-hidden lg:hidden">
          <span :if={@active_space.kind == "channel"} class="text-base-content/50">#</span>
          <span class="truncate font-semibold">
            {space_header_name(
              @active_space,
              @space_participants,
              @user_id,
              space_mask(assigns)
            )}
          </span>
          <%!-- Compact scope-pill on the mobile chat header (chat sidebar
               mobile Stage 2, Decision #6). Mirrors the desktop header pill
               (the `hidden lg:flex` block just below) but uses the foundation
               task's `:compact` size variant for the tight mobile bar. Only
               rendered for channels — `@active_space_scope` is nil for
               DMs/groups (no org-scope), so the pill is suppressed there. The
               `.chat-header-scope-pill-mobile` wrapper enlarges the compact
               pill's tap target to >=44x44px (app.css): the shared
               `.scope-pill-hit-expand` overlay only clears the 24px WCAG floor
               and would be clipped by this row's overflow-hidden. --%>
          <% mobile_header_scope = !@external? && @active_space_scope %>
          <span
            :if={mobile_header_scope}
            class="chat-header-scope-pill-mobile flex-shrink-0"
          >
            <%!-- Masked like the rail (task 01a00c66 stage 3): this pill sits
                 in the chat header at the top of the phone screen, which is
                 the MOST visible surface in a mirrored window. The label
                 override reaches the pill's `aria-label` too. --%>
            <.scope_pill
              scope={mobile_header_scope}
              size={:compact}
              clickable={true}
              active={@scope_filter == mobile_header_scope}
              label={
                @mask_names? &&
                  Platform.Chat.SidebarMask.label_for_bucket(
                    Platform.Chat.SidebarMask.context(
                      @sidebar_sections,
                      @mask_names?,
                      @revealed_section_ids
                    ),
                    @sidebar_sections,
                    PlatformWeb.ChatLive.bucket_for_scope(mobile_header_scope)
                  )
              }
            />
          </span>
        </div>
        <%!-- Desktop: static title --%>
        <span class="hidden lg:flex items-center gap-2 overflow-hidden">
          <span
            :if={@active_space.kind == "channel"}
            class="text-base-content/50 text-lg font-bold"
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
            <.scope_pill
              scope={header_scope}
              clickable={true}
              active={@scope_filter == header_scope}
              label={
                @mask_names? &&
                  Platform.Chat.SidebarMask.label_for_bucket(
                    Platform.Chat.SidebarMask.context(
                      @sidebar_sections,
                      @mask_names?,
                      @revealed_section_ids
                    ),
                    @sidebar_sections,
                    PlatformWeb.ChatLive.bucket_for_scope(header_scope)
                  )
              }
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
            class="truncate text-xs text-base-content/40"
          >
            — {@active_space.topic}
          </span>
          <span
            :if={@active_space.kind == "group"}
            class="text-xs text-base-content/40"
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
         that is the whole reason this line exists. --%>
      <button
        :if={@meetings_enabled && !@in_meeting && !@external?}
        phx-click="meeting_join"
        class="flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-medium text-base-content/60 hover:text-primary hover:bg-primary/10 transition-colors"
        title="Start or join a meeting in this space"
      >
        <span class="hero-video-camera size-4"></span>
        <span class="hidden md:inline">Meet</span>
      </button>

      <div class="flex flex-shrink-0 items-center gap-3 text-xs text-base-content/50">
        <.form
          for={@search_form}
          id="chat-search-form"
          phx-change="search_submit"
          phx-submit="search_submit"
          class="hidden md:block"
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
            "flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300",
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
            "flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300",
            @show_pins && "!bg-base-300 !text-primary"
          ]}
        >
          <span class="hero-bookmark-solid size-4"></span>
          <span>{length(@pins)} pinned</span>
        </button>

        <%!-- Agent eye — the ONE control for the agent mutex (task 019f9790
             stage 4). It replaces three competing header controls that used
             to sit here: the "Talking to {name}" pill with its own x-mark
             sub-button, the dimmed "{primary} listening" hint, and the
             `watch_enabled` toggle. Those three could disagree with each
             other and none of them was the thing that actually routes
             messages. This button IS the mutex (`ActiveAgentStore`):

               open   — a mutex is held; the next message goes to that agent.
                        Click closes it (`active_agent_clear`).
               closed — no mutex, but `ActiveAgentHooks.resolve_armable/2`
                        found a defensible target. Click opens it
                        (`active_agent_arm`).
               inert  — no mutex and no defensible target (several agents, no
                        history). Rendered `disabled` rather than hidden so
                        the header never reflows as agents join or leave.

             DM spaces render nothing: `attention_router.ex:343` makes DMs
             unconditionally `:directed`, so there is nothing here to toggle
             and offering the control would be a lie.

             `data-role` / `data-eye-state` exist so tests assert on state
             rather than on Tailwind classes. `min-h-11 min-w-11` gives the
             iOS-HIG 44px touch target on mobile (measured: 20px tall without
             it); released at `md` so the desktop hover surface still matches
             the sibling pin/settings buttons. --%>
        <% eye_state =
          cond do
            @active_agent_participant_id != nil -> "open"
            @active_agent_armable_id != nil -> "closed"
            true -> "inert"
          end %>
        <button
          :if={(@agent_presence[:joined?] || @has_agent_participant) && @active_space.kind != "dm"}
          data-role="agent-eye"
          data-eye-state={eye_state}
          disabled={eye_state == "inert"}
          phx-click={
            case eye_state do
              "open" -> "active_agent_clear"
              "closed" -> "active_agent_arm"
              _inert -> nil
            end
          }
          class={[
            "flex min-h-11 min-w-11 items-center justify-center gap-1 rounded px-2 py-0.5 text-xs transition-colors md:min-h-0 md:min-w-0",
            eye_state == "open" && "text-success hover:bg-base-300",
            eye_state == "closed" &&
              "text-base-content/50 hover:text-base-content hover:bg-base-300",
            eye_state == "inert" && "text-base-content/50 opacity-50"
          ]}
          title={
            case eye_state do
              "open" ->
                "Your next message goes to #{@active_agent_name || "Agent"} — click to talk to people only"

              "closed" ->
                "Click to resume with #{@active_agent_armable_name || "the agent"}"

              _inert ->
                "No agent is listening — @mention an agent to open the eye"
            end
          }
        >
          <span class={[
            "size-4",
            if(eye_state == "open", do: "hero-eye", else: "hero-eye-slash")
          ]}>
          </span>
          <span :if={eye_state == "open"} class="hidden md:inline">
            {@active_agent_name || "Agent"}
          </span>
        </button>

        <button
          phx-click="settings_open"
          class="flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-base-content transition-colors hover:bg-base-300"
          title="Space settings"
        >
          <span class="hero-cog-6-tooth size-4"></span>
          <span class="hidden md:inline">settings</span>
        </button>
      </div>
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
         surface — the no-measurement state — and nowhere else, not on the
         delta and not on a falling count. --%>
    <div
      :if={@goal_panel && !@embedded}
      class="flex flex-shrink-0 items-start gap-2 border-b border-base-content/10 px-5 py-2"
      data-role="agents-goal-strip"
    >
      <%!-- The same leader face as the rail row, once. Swapping the leader
           through `role_assignments` broadcasts on `Roles.assignments_topic/0`
           and repaints both with no reload — the change is legible across
           the room because it is a different face, not a different word. --%>
      <.agent_avatar
        :if={@goal_panel.leader}
        name={@goal_panel.leader.name}
        avatar_url={@goal_panel.leader.avatar_url}
        size="xs"
        class="ring-2 ring-primary mt-0.5"
        title={"#{@goal_panel.leader.name} leads"}
      />
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <span
          :if={@goal_panel.leader}
          class="text-xs text-base-content/60"
          data-role="agents-goal-leader"
        >
          {@goal_panel.leader.name} leads
        </span>
        <%= if @goal_edit do %>
          <%!-- ONE operation. There is no first-time path and no
               "set goal" control distinct from an "edit goal" control:
               this form always submits `save_goal`, which always runs
               `Chat.update_space/2` through the stage-1 changeset. No
               branch anywhere in the write path reads `is_nil(goal)`. --%>
          <form phx-submit="save_goal" class="flex items-center gap-2" data-role="agents-goal-form">
            <input
              type="text"
              name="goal"
              value={@goal_panel.goal}
              maxlength="500"
              aria-label="Goal"
              class="input input-bordered input-sm min-w-0 flex-1"
            />
            <button type="submit" class="btn btn-sm btn-primary">Save</button>
            <button type="button" phx-click="cancel_goal_edit" class="btn btn-sm btn-ghost">
              Cancel
            </button>
          </form>
        <% else %>
          <div class="flex min-w-0 items-baseline gap-2">
            <%!-- The goal sentence at FULL `--color-base-content`: it is
                 the most meaningful string on the surface, and the
                 truncation rule says the most meaningful fragment is the
                 last thing allowed to truncate. `shrink-0` here,
                 `min-w-0 truncate` on the clause beside it. --%>
            <span class="shrink-0 text-sm text-base-content" data-role="agents-goal-sentence">
              {@goal_panel.goal}
            </span>
            <%!-- The measurement clause at `/60`, which is the measured
                 contrast FLOOR and not a preference: composited, `/40`
                 (the treatment `topic` uses two lines up) is 2.85:1 light
                 and 3.53:1 dark and fails AA in both themes; `/60` is
                 5.74:1 and 6.26:1. --%>
            <%= if @goal_panel.measurement[:missing?] do %>
              <span
                class="min-w-0 truncate text-xs text-warning"
                data-role="agents-goal-measurement-missing"
              >
                {AgentsGoalHeartbeat.format_measurement(@goal_panel.measurement)}
              </span>
            <% else %>
              <span
                class="min-w-0 truncate text-xs text-base-content/60"
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
              </span>
            <% end %>
            <button
              :if={@can_edit_goal?}
              type="button"
              phx-click="edit_goal"
              class="btn btn-ghost btn-xs shrink-0"
              aria-label="Edit goal"
              title="Edit goal"
            >
              <span class="hero-pencil-square size-3.5"></span>
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:active_space, :any, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  # Masking attrs: the channel-chip branch calls `masked_space_name/2`.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)

  @doc """
  The mobile Pinned strip — `<nav data-role="mobile-pinned-strip">`.
  """
  def mobile_pinned_strip(assigns) do
    ~H"""
    <%!-- Mobile Pinned strip (task 019f923b Stage 1). `lg:hidden` mirrors the
         `hidden lg:flex` gate on <aside id="chat-sidebar">: without this
         strip, pinned spaces (both task-exec pins from `@pinned_task_spaces`
         and channel pins from `@channel_sections.pinned`) are unreachable
         on <lg viewports because the desktop rail is hidden.

         Renders horizontally-scrollable chips that mirror the desktop
         rail's mental model — `hero-clipboard-document-list-mini` for
         task-exec pins and, for pinned conversations, the desktop Pinned
         block's row identity: a bare name for a person, `#` for a channel.
         Chips carry the unread badge from `unread_label/1` when the space
         has unread messages, using the same visual language as the
         channel-pills strip immediately below.

         Auto-hides when BOTH lists are empty — no permanent header. The
         `:if` OR-guard means a user with only pinned tasks (or only pinned
         channels, once channel-pinning ships) still gets the strip; the
         strip only disappears when the user has no pins at all.

         Sits ABOVE the channel-pills strip so pinned spaces are the first
         navigation surface a user sees when landing in a channel on mobile.
         Pinned channels intentionally re-appear in the channel-pills strip
         below (via `Sidebar.flatten_sections/1`) — that duplication is
         deliberate visual emphasis on pinned items, not a bug to
         deduplicate.

         Conversation pinning IS wired as of task 019fd80f stage 2: every
         `channel_sections/4` call site passes the user's real pin list, so
         the conversation-chip branch below is live. It was dead before
         that, which is why it rendered `{space.name}` for every kind and
         produced a blank chip for a pinned DM. Render coverage for both
         kinds is in `chat_live_pinned_block_test.exs`. --%>
    <nav
      :if={
        @active_space && !@embedded &&
          (@pinned_task_spaces != [] || @channel_sections.pinned != [])
      }
      class="lg:hidden flex items-center gap-2 overflow-x-auto px-4 py-2 border-b border-base-content/10 bg-base-200/40"
      style="scrollbar-width: none; -webkit-overflow-scrolling: touch;"
      aria-label="Pinned"
      data-role="mobile-pinned-strip"
    >
      <.link
        :for={space <- @pinned_task_spaces}
        patch={~p"/chat/#{space_nav_target(space)}"}
        data-role="mobile-pinned-task-chip"
        data-space-id={space.id}
        class={[
          "flex items-center gap-1.5 px-3 py-1.5 rounded-full whitespace-nowrap text-[13px] font-medium shrink-0",
          if(@active_space.id == space.id,
            do: "bg-primary text-primary-content",
            else: "bg-base-100 text-base-content/80 border border-base-content/10"
          )
        ]}
      >
        <%!-- The task marker, and the SAME glyph the two rail surfaces use
             for a task row. It was `hero-map-pin-mini` here until
             2026-08-11: one concept carried two glyphs depending on which
             surface a person happened to be looking at, and the glyph is
             the only thing distinguishing the three kinds, so the two had
             to converge. `hero-clipboard-document-list-mini` is what Saru's
             design canvas for 019feec6-73d9 specifies. --%>
        <span class={[
          "hero-clipboard-document-list-mini size-3.5",
          if(@active_space.id == space.id,
            do: "text-primary-content/80",
            else: "text-base-content/40"
          )
        ]}>
        </span>
        <span class="truncate max-w-[10rem]">
          {Platform.Tasks.ChatPins.display_name_for_space(space)}
        </span>
        <span
          :if={unread_label(Map.get(@unread_counts, space.id, 0))}
          class="inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums bg-primary text-primary-content border border-base-100"
        >
          {unread_label(Map.get(@unread_counts, space.id, 0))}
        </span>
      </.link>
      <.link
        :for={space <- @channel_sections.pinned}
        patch={~p"/chat/#{space_nav_target(space)}"}
        data-role="mobile-pinned-channel-chip"
        data-space-id={space.id}
        class={[
          "flex items-center gap-1.5 px-3 py-1.5 rounded-full whitespace-nowrap text-[13px] font-medium shrink-0",
          if(@active_space.id == space.id,
            do: "bg-primary text-primary-content",
            else: "bg-base-100 text-base-content/80 border border-base-content/10"
          )
        ]}
      >
        <%!-- Same identity rule as the two rail surfaces: `#` plus a name
             for a channel, a bare name for a person.

             No `hero-bookmark-solid`: every chip in this strip is a pin, so
             a pin marker on all of them never varied and carried nothing.
             The task chips above carry `hero-clipboard-document-list-mini`,
             which does vary, since it separates a task from a
             conversation — and it is the same glyph the rail uses, so one
             concept has one mark on every surface.

             No empty indent slot on the person chips either, unlike the two
             rail surfaces. Chips sit in a horizontal scroller, so there is
             no name column to keep straight, and a blank 20px inside a pill
             would read as broken padding rather than as an absent glyph. --%>
        <%= if space.kind in ["dm", "group"] do %>
          <span class="truncate max-w-[10rem]">{sidebar_display_name(space, @user_id)}</span>
        <% else %>
          <span
            class={[
              "shrink-0",
              if(@active_space.id == space.id,
                do: "text-primary-content/80",
                else: "text-base-content/40"
              )
            ]}
            data-role="pinned-row-hash"
          >
            #
          </span>
          <span class="truncate max-w-[10rem]">{masked_space_name(assigns, space.name)}</span>
        <% end %>
        <span
          :if={unread_label(Map.get(@unread_counts, space.id, 0))}
          class="inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums bg-primary text-primary-content border border-base-100"
        >
          {unread_label(Map.get(@unread_counts, space.id, 0))}
        </span>
      </.link>
    </nav>
    """
  end

  attr(:active_space, :any, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  # Masking attrs: the channel pills call `masked_space_name/2`, and
  # `@sidebar_sections` is also the pill ORDER source for internal users.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)

  @doc """
  The mobile channel-pills strip — `<nav aria-label="Channel switcher">`.

  Its left-anchored magnifying-glass button is the ONLY mobile entry that
  carries `phx-value-intent="search"`, i.e. the one opener that asks
  `MobileBrowser.mobile_browser/1` for a search-focused drawer rather than a
  browse-first one. Losing that attribute silently downgrades the drawer.
  """
  def channel_pills(assigns) do
    ~H"""
    <%!-- Mobile-only channel pills strip — Refined Option A nav (Marlowe approval 2026-05-10).
         Replaces the previous tap-channel-name-to-open-browser flow. Horizontally
         scrollable pills with the active channel highlighted; the magnifying-glass
         icon at the LEFT opens the @mobile_browser_open drawer (search + full
         channel/DM list). 1-tap switching for the pills shown; 2-tap
         (magnifying glass → search) for the long tail.

         ORDERING CONTRACT (Marlowe decision 2026-07-05, this task's Stage 3):
         pills render `Sidebar.flatten_sections(@sidebar_sections)` — the user's
         curated drawer arrangement flattened left-to-right — NOT the raw
         @channels list. Consequences, both deliberate: (1) dragging sections
         in the drawer reorders the pills identically (one mental model,
         stable muscle memory — the unread badge signals activity without
         moving pills); (2) hidden channels/sections are absent here too —
         hidden means hidden everywhere. Historical note: the raw @channels
         order this replaced was channel CREATION order (Chat.list_spaces
         sorts by inserted_at), not "alphabetical" as previously claimed
         here. The old Stage 1B localStorage-pinning idea is superseded by
         the server-side section order. --%>
    <nav
      :if={@active_space && !@embedded}
      class="lg:hidden flex items-center gap-2 overflow-x-auto px-4 py-2 border-b border-base-content/10"
      style="scrollbar-width: none; -webkit-overflow-scrolling: touch;"
      aria-label="Channel switcher"
    >
      <%!-- Search/jump button anchored at the LEFT of the pills strip
           (Rowan request, Marlowe approval 2026-05-11). Sticks to the left
           edge so it stays in reach even as the channel pills overflow
           horizontally and scroll. phx-value-intent="search" (Stage 2):
           this entry declares search intent, so the drawer opens with the
           search field focused — other openers get a browse-first drawer. --%>
      <button
        phx-click="toggle_mobile_browser"
        phx-value-intent="search"
        class="flex items-center justify-center w-9 h-9 rounded-full shrink-0 bg-base-200 border border-base-content/10 text-base-content/50 hover:text-primary hover:bg-base-300 transition-colors sticky left-0 z-10"
        aria-label="Search channels and direct messages"
        title="Search channels and DMs"
      >
        <span class="hero-magnifying-glass size-4"></span>
      </button>

      <%!-- Channel pill source (task 019f9257-a83e): internal users get their
           curated flattened section order; external users have no
           `@sidebar_sections` (that resolver-driven org tree is empty for
           them), so their pills come from the flat granted-channel list
           `@channels` — the same set the external rail + switcher render.
           Without this branch the external pills strip showed only DMs and
           none of the user's channels. --%>
      <% switcher_channel_pills =
        if @external?, do: @channels, else: Sidebar.flatten_sections(@sidebar_sections) %>
      <.link
        :for={space <- switcher_channel_pills}
        patch={~p"/chat/#{space_nav_target(space)}"}
        class={[
          "flex items-center gap-1.5 px-3 py-1.5 rounded-full whitespace-nowrap text-[13px] font-medium shrink-0 transition-all",
          "active:scale-[0.97] ease-[cubic-bezier(0.16,1,0.3,1)]",
          if @active_space.id == space.id do
            "bg-primary text-primary-content shadow-[0_0_16px_oklch(0.78_0.14_207_/_0.18)]"
          else
            "bg-base-200 text-base-content/70 border border-base-content/10 hover:bg-base-300"
          end
        ]}
      >
        <span class={[
          if(@active_space.id == space.id,
            do: "text-primary-content/80",
            else: "text-base-content/40"
          )
        ]}>#</span>{masked_space_name(assigns, space.name)}<span
          :if={unread_label(Map.get(@unread_counts, space.id, 0))}
          class="inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums bg-primary text-primary-content border border-base-100"
        >{unread_label(Map.get(@unread_counts, space.id, 0))}</span>
      </.link>

      <%!-- DM pills (after channels, no divider for now to keep mobile compact) --%>
      <.link
        :for={space <- @dm_conversations}
        patch={~p"/chat/#{space_nav_target(space)}"}
        class={[
          "flex items-center gap-1.5 px-3 py-1.5 rounded-full whitespace-nowrap text-[13px] font-medium shrink-0 transition-all",
          "active:scale-[0.97] ease-[cubic-bezier(0.16,1,0.3,1)]",
          if @active_space.id == space.id do
            "bg-primary text-primary-content shadow-[0_0_16px_oklch(0.78_0.14_207_/_0.18)]"
          else
            "bg-base-200 text-base-content/70 border border-base-content/10 hover:bg-base-300"
          end
        ]}
      >
        {sidebar_display_name(space, @user_id)}<span
          :if={unread_label(Map.get(@unread_counts, space.id, 0))}
          class="inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums bg-primary text-primary-content border border-base-100"
        >{unread_label(Map.get(@unread_counts, space.id, 0))}</span>
      </.link>
    </nav>
    """
  end

  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  attr(:active_space, :any, default: nil)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)

  @doc """
  The brand-new-user pane for the MOBILE content region — the only
  create/join affordance a user with zero spaces gets below `lg`.

  ## The defect this exists to close (task 01a0312e stage 8)

  At 390px, a user whose `Chat.list_spaces/0`, `list_archived_spaces/0` and
  `list_user_conversations/1` are all empty rendered a content pane whose
  `innerText` was literally zero characters. Everything in the pane is gated
  on `@active_space`, and they have none. The two empty states that should
  have covered them could not:

    * `Rail.rail/1`'s §5.1 state IS in the DOM, but it is inside
      `#chat-sidebar`, which is `display: none` below `lg`.
    * `MobileBrowser.mobile_browser/1`'s §5.1 state is unreachable: the
      overlay opens on `toggle_mobile_browser`, whose only trigger is the
      magnifying glass in `channel_pills/1` — and that `<nav>` is gated on
      `@active_space && !@embedded`. Zero spaces means no active space means
      no trigger. The empty state sat behind a door with no handle.

  Fixing it by rendering the trigger unconditionally was the alternative
  considered and rejected: it changes what a user WITH channels sees on
  every route where no space is active, and it hands them a search box for a
  list they cannot see from there. Rendering the state directly in the
  content region touches exactly one population.

  ## Why the condition is this exact conjunction

    * `@active_space == nil` — with a space entered, the pane is the
      conversation and `Composer.message_scroller/1` owns its own empty
      state (§5.2).
    * `@channels == [] and @dm_conversations == []` — anyone with either has
      somewhere to go; showing them "no spaces yet" would be a lie.
    * `@archived_channels == []` — same test the rail applies, for the same
      reason (task 019f4eaa): archived channels are proof you are NOT new,
      and org-archive empties every channel of an org at once.
    * `!@embedded and !@external?` — the embedded surface is scoped to one
      space and has no new-channel affordance to offer, and external users
      never get one at all (`NewChannelComponent` is gated off their
      surface, so the chip would open nothing).

  `lg:hidden` keeps the desktop render untouched: above `lg` the rail's copy
  is the visible one and this node contributes no visible text.
  """
  def mobile_no_spaces_pane(assigns) do
    ~H"""
    <div
      :if={
        !@embedded and !@external? and is_nil(@active_space) and @channels == [] and
          @dm_conversations == [] and @archived_channels == []
      }
      id="chat-mobile-no-spaces"
      class="lg:hidden flex-1 min-h-0 overflow-y-auto px-4 py-6"
    >
      <.brand_new_user_empty_state />
    </div>
    """
  end

  attr(:search_query, :any, required: true)
  attr(:search_results, :list, required: true)
  attr(:participants_map, :map, required: true)

  @doc """
  The search-results drawer, gated on `present?(@search_query)`.
  """
  def search_drawer(assigns) do
    ~H"""
    <div
      :if={present?(@search_query)}
      class="border-b border-edge bg-base-200 px-5 py-3"
    >
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Search Results
          </p>
          <p class="text-sm text-base-content/70">
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
          <div class="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-widest text-base-content/50">
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
              class="font-mono normal-case tracking-normal text-[10px] text-base-content/40"
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
      <p class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
        Pinned Messages
      </p>
      <div class="flex flex-col gap-1 max-h-40 overflow-y-auto">
        <div
          :for={pin <- @pins}
          class="flex items-center justify-between rounded bg-base-100 px-3 py-1.5 text-sm"
        >
          <span class="truncate text-base-content/70 text-xs">
            <span class="hero-bookmark-solid size-3 inline-block align-text-bottom"></span>
            pinned message
            <span class="font-mono text-base-content/40 text-[10px]">
              {String.slice(pin.message_id, 0, 8)}…
            </span>
          </span>
          <button
            :if={@active_space && is_nil(@active_space.archived_at)}
            phx-click="pin_toggle"
            phx-value-message-id={pin.message_id}
            phx-value-space-id={pin.space_id}
            class="ml-2 text-xs text-base-content/40 hover:text-error"
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
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
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
               `--color-neutral`, not `--color-warning`: nothing is wrong and
               nobody is being asked for anything. No icon, no spinner and no
               percentage, on purpose — a percentage invites someone to sit and
               watch a backfill.

               The count behind it is deliberately NOT recomputed in the render
               path; `CanvasHooks.refresh_unindexed_count/1` names the three
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
            <label for="canvas-sort" class="text-[11px] text-base-content/50">Sort</label>
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
          phx-submit="canvas_create"
          class="space-y-3 rounded-2xl border border-edge bg-base-100 p-4"
        >
          <div>
            <p class="text-sm font-semibold text-base-content">New canvas</p>
            <p class="text-xs text-base-content/50">
              Creates a canvas and posts a linked canvas message.
            </p>
          </div>

          <.input
            field={@new_canvas_form[:title]}
            label="Title"
            placeholder="Sprint planning board"
          />

          <button
            type="submit"
            class="btn btn-neutral w-full"
            disabled={is_nil(@current_participant)}
          >
            Create canvas
          </button>
        </.form>
      </div>
    </div>
    """
  end

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

  # Wrappers, not qualified calls — see "WHY THE TWO MASK CALLS ARE WRAPPED"
  # in the moduledoc. Same name, same arity, same call text at the call site,
  # so no line grows and no interpolation reflows into a `truncate` span.
  defp space_mask(assigns), do: ChatLive.space_mask(assigns)
  defp masked_space_name(assigns, name), do: ChatLive.masked_space_name(assigns, name)
  defp space_nav_target(space), do: ChatLive.space_nav_target(space)
end
