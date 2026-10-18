defmodule PlatformWeb.ChatLive.Partials do
  @moduledoc """
  Function components for self-contained render regions of ChatLive.

  See ADR 0035. These aren't LiveComponents (no state), they're just
  render splits — each takes a small set of attrs and produces markup.
  They keep `chat_live.html.heex` at a tractable size.

  Extracted here:
    * `notification_banner/1` — notification opt-in bar
    * `move_to_org_picker/1` — the admin destination chooser for a channel
    * `move_to_org_dialog/1` — the confirmation a chosen destination opens
    * `row_actions_control/1` — per-row overflow control in the mobile drawer
    * `row_actions_sheet/1` — the bottom sheet that control opens
    * `row_actions_trigger/1` — per-row overflow control in the desktop rail
    * `row_actions_dialog/1` — the centred menu that trigger opens
    * `upload_dialog/1` — staging modal for attachments
    * `canvas_overlay/1` — active-canvas side panel + mobile full-screen
    * `meeting_panel/1` — in-meeting UI (desktop sidebar + mobile overlay)
    * `image_lightbox/1` — full-screen image viewer
    * `brand_new_user_empty_state/1` — the §5.1 "no spaces yet" state, shared
      by the desktop rail and the mobile content pane
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1, human_avatar: 1]
  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.Components.EmptyState, only: [empty_state: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.Components.Meetings.CallShell

  @doc """
  The brand-new-user empty state — `docs/design-system/03-voice.md` §5.1,
  "no spaces yet": what is empty, why, and the two agent-mediated actions
  (create a space / connect an agent).

  Lives HERE, in the shared module, because it renders on TWO surfaces that
  are mutually exclusive at any one viewport width: the desktop rail
  (`Rail.rail/1`, inside `#chat-sidebar`, which is `display: none` below
  `lg`) and the mobile content pane (`Conversation.mobile_no_spaces_pane/1`,
  which is `lg:hidden`). Before task 01a0312e stage 8 only the rail copy
  existed, so a brand-new user on a phone got a literally blank content pane
  with no create, join or browse affordance anywhere on screen — the
  `MobileBrowser` zero-state that should have covered them is opened by
  `toggle_mobile_browser`, and that trigger lives in the channel-pills strip,
  which is itself gated on `@active_space` and therefore never renders for a
  user who has no spaces to be active in. The empty state was behind a door
  with no handle.

  One definition rather than two so the §5.1 copy cannot drift between the
  two breakpoints. The component renders no wrapper of its own — each caller
  owns its own positioning and its own render condition.
  """
  def brand_new_user_empty_state(assigns) do
    ~H"""
    <.empty_state variant={:conversational}>
      <:system_message>— no spaces yet —</:system_message>
      <:body>Welcome to Burrow. To get started, create a space or connect your agent.</:body>
      <:chips label="+ Create a space" event="new_channel_open" />
      <:chips label="+ Connect an agent" event={JS.navigate(~p"/control")} />
    </.empty_state>
    """
  end

  @doc """
  Notification opt-in banner, rendered when push permission is exactly
  `"prompt"` (task 019ffb7b stage 5).

  ## The one state it renders in

  `"prompt"` and nothing else. `"granted"` has nothing to offer, `"unknown"`
  has not heard from the client yet, `"unsupported"` browsers could never
  honour the offer, and `"denied"` is deliberately absent from this component:
  no web API can re-prompt after a browser-level block, so a strip pinned to
  the top of every chat with no action on it would be a nag nobody could
  clear. The blocked state lives on `/inbox`, in
  `PlatformWeb.Components.NotificationState`, which is a page the user chooses
  to visit. Do not add a `denied` branch here.

  For the same reason this stays on chat and is not hoisted into the shell:
  a permanent top-of-app strip is the shape that was rejected. `/inbox` is the
  durable home; this is a contextual offer where mentions actually arrive.

  ## Colour

  Tint is `--color-info` (10% fill, 20% border), which says "this is
  informational". The button is `--color-primary`, because turning
  notifications on is an action, and an action button painted in the same hue
  as the surface it sits on stops reading as a button at all. That was the
  defect: `btn-info` on `bg-info/10` was a button-shaped piece of the banner.
  Radius comes from `--radius-field` via daisyUI's `.btn`.

  Semantic token slots only, no raw hex.

  ## Layout

  The copy takes `min-w-0 truncate` and the button `shrink-0`, so a narrow
  viewport shortens the sentence and leaves the control at full size. Without
  `min-w-0` a flex item refuses to shrink below its content and the button is
  what gets squashed instead.

  The action and the dismiss x share ONE `shrink-0` wrapper. `justify-between`
  distributes free space between every direct child, so as three siblings the
  action button drifted into the middle of a wide banner with the x alone at
  the far edge. Grouped, the copy stays left and both controls sit together at
  the right, which is where the x belongs.

  `role="status"` because the banner renders nothing server-side (permission
  starts at `"unknown"`) and appears a moment after connect, when the
  `PushSubscribe` hook reports. It has to announce on appearance.

  ## Dismissal, and why it is PERSISTENT

  Marlowe, 2026-08-13: "this banner needs a way to be dismissed. A user should
  be able to dismiss this notification if they dont want notifications or they
  dont want to set it up right now."

  Those are two reasons with two different lifetimes. "I don't want
  notifications" is permanent; "not right now" is temporary. One x cannot
  express both, so it takes the lifetime that satisfies the harder case. A
  session-scoped dismissal would re-nag the user who already said they don't
  want notifications, on every single visit, which is the behaviour the
  feedback is asking to stop. So the x writes
  `users.preferences["notification_banner_dismissed"]` (see
  `Platform.Accounts.dismiss_notification_banner/1`) and the banner reads it
  at mount.

  Permanent is safe here ONLY because dismissing is never a dead end: the
  Inbox notification row (`PlatformWeb.Components.NotificationState`, on
  `/inbox`) is a permanent surface that always offers the same control and
  never consults this preference. The user who dismisses today and wants
  notifications next month has somewhere to go. If that row is ever removed,
  this dismissal has to become reversible from here, or the feature becomes
  unreachable after one click.

  ## The control

  A real `<button>` — in the tab order, with an accessible name that says what
  is being dismissed rather than a bare "Close". 24px box (the WCAG 2.5.8
  floor for a pointer target) with the tap area taken to 44x44 by a
  transparent `::after`, the same trick `.channel-row-pin-button` uses.

  VISIBLE AT REST. No `hover:` or `group-hover:` variant may gate it: Tailwind
  compiles both inside `@media (hover: hover)`, which never matches on a touch
  device, so a hover-revealed control is not subtle there, it is absent. This
  is the same rule the rail's pin control had to learn (Marlowe: "hover doesn't
  work on mobile"). `:hover` and `:focus-visible` move its colour only, as
  plain selectors in `app.css`.
  """
  attr(:push_permission, :string, required: true)
  attr(:dismissed, :boolean, default: false)

  def notification_banner(assigns) do
    ~H"""
    <div
      :if={@push_permission == "prompt" and not @dismissed}
      class="flex items-center justify-between gap-3 border-b border-info/20 bg-info/10 px-4 py-2"
      role="status"
      data-role="chat-notification-banner"
    >
      <p class="min-w-0 truncate text-sm text-info">
        <span class="hero-bell-alert mr-1 inline-block h-4 w-4 align-text-bottom" />
        Get notified when someone mentions you.
      </p>
      <div class="flex shrink-0 items-center gap-2">
        <button
          type="button"
          phx-click="enable_notifications"
          class="btn btn-primary btn-sm shrink-0"
          data-role="chat-notification-enable"
        >
          Turn on notifications
        </button>
        <button
          type="button"
          phx-click="dismiss_notification_banner"
          class="chat-notification-dismiss"
          aria-label="Dismiss notification setup"
          title="Dismiss"
          data-role="chat-notification-dismiss"
        >
          <span class="hero-x-mark size-3.5"></span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Destination chooser for "Move to organisation…". Renders when `@picker` is set.

  ## Keyboard

  Every destination is a real `<button>` in normal document order, so Tab
  reaches each one and Enter or Space activates it. The container is
  `role="group"`, deliberately NOT `role="menu"`: a menu promises arrow-key
  roving tabindex with a single tab stop, which is the opposite of what is
  wanted here. Once the drag path is gone this is the only way to refile a
  channel, so a mouse-only affordance would remove the capability outright
  for keyboard users.

  Same `.modal .modal-open` chrome as `move_to_org_dialog/1` below, because
  the two are consecutive steps of one action and reading as one object is
  the point. See that function's docs for why all three classes are needed.
  """
  attr(:picker, :map,
    default: nil,
    doc: "nil when closed, else `%{channel_id:, channel_name:, destinations:}`."
  )

  def move_to_org_picker(assigns) do
    ~H"""
    <div
      :if={@picker && @picker.destinations != []}
      id="move-to-org-picker"
      class="modal modal-open"
      phx-window-keydown="close_reassign_menu"
      phx-key="escape"
      data-role="move-to-org-picker"
    >
      <div
        class="modal-box max-w-sm"
        role="group"
        aria-labelledby="move-to-org-picker-title"
        phx-click-away="close_reassign_menu"
        phx-mounted={JS.focus_first()}
        tabindex="-1"
      >
        <%!-- Which channel is being moved is the one thing that must survive,
             so the name is never the part that gives way: the trailing words
             wrap below it instead. It is NOT `whitespace-nowrap` on a flex
             child, which was tried and fails on the real data — a 44-character
             channel name then has nothing to give and runs straight out of the
             card, taking "to organisation" off the edge with it. Wrapping
             keeps the whole name AND the box. --%>
        <h2 id="move-to-org-picker-title" class="break-words text-base font-semibold">
          {"Move ##{@picker.channel_name}"}
          <span class="font-normal text-base-content/60">to organisation</span>
        </h2>
        <div class="mt-3 flex flex-col gap-1">
          <button
            :for={dest <- @picker.destinations}
            type="button"
            phx-click="request_channel_reassign"
            phx-value-channel_id={@picker.channel_id}
            phx-value-target_section_id={dest.section_id}
            class="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm hover:bg-base-200 focus-visible-ring"
            data-role="move-to-org-destination"
            data-section-id={dest.section_id}
          >
            <span :if={dest.dot} class={["channel-section-color-dot", dest.dot]} aria-hidden="true">
            </span>
            <span class="min-w-0 truncate">{dest.name}</span>
          </button>
        </div>
        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost focus-visible-ring"
            phx-click="close_reassign_menu"
            data-role="move-to-org-picker-cancel"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Confirmation for "Move to organisation…". Renders when `@confirm` is set.

  ## The copy is load-bearing

  The third body line is a VERIFIED fact, not a hedge:
  `Chat.CanvasAccess.org_readable_space?/2` grants canvas read to any member
  of the channel's org via `Tenancy.member_of?/2`, with no channel membership
  required. An earlier draft of this dialog said "who can read it does not
  change", which was false. Do not soften or delete that line.

  ## Chrome

  Warning accent, not error, and no warning triangle: nothing is destroyed
  and nobody's access to the CHANNEL changes. The accent is spent on the
  confirm button's FILL (`btn-warning` is amber with
  `--color-warning-content` text) rather than on body text, because
  `--color-warning` as a text colour on `base-100` measures about 2.2:1 and
  misses the 4.5:1 floor in docs/design-system/04-accessibility.md.

  ## `.modal` needs `.modal-open`

  DaisyUI ships `.modal` as `visibility: hidden; pointer-events: none` and
  `.modal-box` as `scale: 95%; opacity: 0`, revealed only by a `.modal`
  ancestor carrying `.modal-open`, `[open]` or `:target` (assets/vendor
  daisyui.js). `.modal` + `.modal-box` alone renders a correctly-sized,
  correctly-placed, completely invisible dialog — the symptom Marlowe hit on
  task 019f4eaa. All three classes, or none of them.
  """
  attr(:confirm, :map,
    default: nil,
    doc: "nil when closed, else `%{channel_id:, channel_name:, from:, to:}`."
  )

  def move_to_org_dialog(assigns) do
    ~H"""
    <div
      :if={@confirm}
      id="move-to-org-dialog"
      class="modal modal-open"
      phx-window-keydown="cancel_channel_reassign"
      phx-key="escape"
      data-role="move-to-org-dialog"
    >
      <div
        class="modal-box max-w-md"
        role="dialog"
        aria-modal="true"
        aria-labelledby="move-to-org-title"
        aria-describedby="move-to-org-body"
        phx-click-away="cancel_channel_reassign"
        phx-mounted={JS.focus_first()}
        tabindex="-1"
      >
        <%!-- Wraps rather than truncates: a long channel name in a max-w-md
             card would otherwise lose the destination at the end of the
             question, which is the part being agreed to. --%>
        <h2 id="move-to-org-title" class="break-words text-lg font-semibold">
          {"Move ##{@confirm.channel_name} to #{@confirm.to.name}?"}
        </h2>
        <%!-- All four lines share ONE aria-describedby container so a screen
             reader hears the org-scope consequence, not just the first line. --%>
        <div id="move-to-org-body" class="mt-3 flex flex-col gap-2 text-sm text-base-content/80">
          <p>{"Everyone sees this channel filed under #{@confirm.to.name}."}</p>
          <p>Nobody is added to or removed from the channel.</p>
          <p>
            {"People in #{@confirm.to.name} will be able to open this channel's canvases by direct link, and people in #{@confirm.from.name} will not."}
          </p>
          <p>Personal layouts are not affected.</p>
        </div>
        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost focus-visible-ring"
            phx-click="cancel_channel_reassign"
            data-role="move-to-org-cancel"
          >
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-warning focus-visible-ring"
            phx-click="confirm_channel_reassign"
            data-role="move-to-org-confirm"
          >
            {"Move to #{@confirm.to.name}"}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Overflow control for one MOBILE DRAWER conversation row (task 019fe998).

  The touch counterpart to the rail's `row_actions_trigger/1`. Before either
  existed the rail row carried its actions directly, and a phone could reach
  none of them. "Move to organisation…" was `opacity-0` with
  `group-hover/row:opacity-100 focus-within:opacity-100` carried inline, and
  Tailwind compiles `group-hover:` inside `@media (hover: hover)`, which never
  matches on a touch device. The sub-org row's `.channel-row-hide-button` was
  `opacity-0` revealed by a plain-CSS `.channel-row-wrap:hover` /
  `:focus-within`: not media-gated, still asking a finger for a hover it
  cannot produce. Only the pin was visible at rest, and only from 2026-08-11.

  This control is therefore ALWAYS visible: no `opacity-0` and no hover
  variant anywhere in its class list, which
  `chat_live_drawer_row_actions_test.exs` asserts by refutation.

  ## One control, not a row of icons

  44px is the touch floor, so pin beside hide is 88px taken permanently from a
  375px drawer whose names already truncate. One overflow costs 44px once and
  holds every action the row grows later. The name keeps `flex-1 min-w-0
  truncate` on the sibling link and this control is `flex-shrink-0`, so a long
  display name can never crush it.

  ## Accessible name

  Carries the verb AND the target: "More actions for Rowan Ellis". A bare
  "More" is meaningless in a list of twenty identical controls, and a DM has
  no `name` field — reaching for `space.name` renders it empty, which has
  already shipped on this surface once. Callers pass the row's resolved label.

  Renders as a SIBLING of the row's navigate-link, never a child: a `<button>`
  inside an `<a>` is invalid HTML, and LiveView binds click on `window` in the
  bubble phase, so a nested control needs a `stopPropagation` guard that
  swallows navigation along with the event.

  ## Right gutter

  `mr-2` is load-bearing, not spacing taste. Without it the control's border
  box ends exactly on the viewport's right edge (measured: right 375 on a
  375px screen), and `focus-visible:ring-2` draws 2px OUTSIDE that box, so the
  keyboard focus ring was clipped by the screen edge. 8px is also the gutter
  the drawer's existing row control already uses (the pinned-task row's unpin
  button), so this matches the neighbouring control rather than inventing a
  third value.
  """
  attr(:space_id, :string, required: true)
  attr(:name, :string, required: true)

  def row_actions_control(assigns) do
    ~H"""
    <button
      type="button"
      class="mr-2 flex min-h-11 min-w-11 flex-shrink-0 items-center justify-center rounded-lg text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      phx-click="open_row_actions"
      phx-value-space_id={@space_id}
      data-role="drawer-row-actions"
      data-space-id={@space_id}
      aria-haspopup="dialog"
      aria-label={"More actions for #{@name}"}
    >
      <span class="hero-ellipsis-vertical size-5"></span>
    </button>
    """
  end

  @doc """
  The bottom sheet `row_actions_control/1` opens (task 019fe998).

  Wraps the shared `PlatformWeb.Components.Sheet` primitive — the same one
  `Components.MoreSheet` wraps. No second sheet, no bespoke popover.

  ## Placement and breakpoint

  Rendered at the TEMPLATE ROOT, not inside `#mobile-channel-browser`. `.sheet`
  is `position: fixed`, and a CSS `transform` on any ancestor becomes the
  containing block for fixed descendants — an overlay rendered inside a
  transformed rail centres on the rail instead of the viewport, which has
  shipped here before.

  `lg:hidden` is load-bearing, not decoration. Marlowe reported the bottom-sheet
  component rendering on desktop at all widths on 2026-07-12; the design
  system scopes sheets to mobile. Desktop keeps its hover-and-focus reveal.

  ## Actions

  Both reuse the EXISTING server handlers. `toggle_pinned` takes the desired
  next state rather than flipping what it finds, so a duplicated event from a
  render race is idempotent instead of a silent unpin. `hide_channel` takes
  `id`. Nothing here is destructive, so `--color-error` stays unspent: the day
  something in this sheet is destructive, it reads instantly.

  `@target` is nil whenever the sheet is closed, which keeps the header empty
  rather than holding the last-opened conversation's name.

  ## Close (task 019ffc5f stage 2)

  A third item, gated on `@target.closeable` (DM and group rows), rendering
  the touch counterpart of the rail dialog's Close from the SAME resolver.
  Its `data-role` is `row-actions-close-dm`, not `row-actions-close`: that
  bare name already belongs to the rail dialog's dismiss button, and both
  chromes sit in the DOM at every width, so sharing it would make the
  selector match two nodes.

  Close reads as the least of the three and is styled identically to them.
  Nothing is deleted and the row returns on the next message in that DM, so
  the red this sheet has never spent stays unspent.

  Hide is still offered on every row this sheet opens on, including DMs where
  it has no reverse. That predates this stage and is untouched by it.

  ## Accessible name on the pin row

  This is the drawer's unpin path, the touch counterpart to the pin item in
  the rail's `row_actions_dialog/1`, so it holds the same rule: the accessible
  name carries the verb AND the target. The visible label stays "Unpin
  conversation" and the `aria-label` extends it to "Unpin conversation Rowan
  Ellis". Extends rather than replaces, because WCAG 2.5.3 requires the
  accessible name to contain the visible label, so "Unpin Rowan Ellis"
  alone would break speech input on a control reading "Unpin conversation".

  The sheet title already shows the name, but a title is context a screen
  reader announces once on open, and the buttons below it are then two
  identical verbs. Naming the target on the control costs no width here: the
  sheet row is full-bleed and the string is never rendered.
  """
  attr(:target, :any,
    default: nil,
    doc: "nil when closed, else %{space_id:, name:, pinned:} for the row that opened it"
  )

  def row_actions_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-row-actions-sheet"
      open={@target != nil}
      placement={:bottom}
      on_close="close_row_actions"
      class="lg:hidden"
    >
      <:title>{@target && @target.name}</:title>

      <ul class="flex flex-col" role="list">
        <li>
          <button
            type="button"
            class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-3 text-left text-base text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            phx-click="toggle_pinned"
            phx-value-space_id={@target && @target.space_id}
            phx-value-pinned={@target && to_string(not @target.pinned)}
            data-role="row-actions-pin"
            aria-label={
              @target &&
                "#{if @target.pinned, do: "Unpin", else: "Pin"} conversation #{@target.name}"
            }
          >
            <span class="hero-map-pin size-5 flex-shrink-0" aria-hidden="true"></span>
            <span>
              {if @target && @target.pinned, do: "Unpin conversation", else: "Pin conversation"}
            </span>
          </button>
        </li>
        <li class="border-t border-edge">
          <button
            type="button"
            class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-3 text-left text-base text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            phx-click="hide_channel"
            phx-value-id={@target && @target.space_id}
            data-role="row-actions-hide"
          >
            <span class="hero-eye-slash size-5 flex-shrink-0" aria-hidden="true"></span>
            <span>Hide from my rail</span>
          </button>
        </li>
        <li :if={@target && @target.closeable} class="border-t border-edge">
          <button
            type="button"
            class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-3 text-left text-base text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            phx-click="close_dm"
            phx-value-id={@target.space_id}
            data-role="row-actions-close-dm"
            aria-label={"Close #{@target.name}"}
          >
            <span class="hero-minus-circle size-5 flex-shrink-0" aria-hidden="true"></span>
            <span>Close</span>
          </button>
        </li>
      </ul>
    </.sheet>
    """
  end

  @doc """
  Overflow trigger for one DESKTOP RAIL conversation row (task 019ff8ba stage 1).

  The desktop counterpart to `row_actions_control/1`. Same event, same
  payload, different chrome: the drawer opens a bottom sheet, the rail opens
  `row_actions_dialog/1`.

  ## Why the row's controls moved behind it

  A sub-org row carried three trailing controls — pin, "Move to
  organisation…", hide — and the pin was visible at rest on every row of the
  rail, all the time. Marlowe, 2026-08-13, choosing Option C off the design
  canvas: the pin leaves the row in EVERY mode, not only while arranging. One
  trigger replaces the set.

  The cost, stated rather than discovered later: pinning is two clicks now
  instead of one.

  ## Every row, including the pinned task rows

  Marlowe, 2026-08-13: "let's simplify and make it consistent where 3-dots brings
  up additional actions for a row in the Chat page (channel - unpin/pin, task -
  unpin since it gets pinned from a diff page)." So the trigger is the one
  trailing control on every row of the rail, and what varies is what its menu
  holds.

  Stage 1 shipped this control on every row EXCEPT the pinned task rows, on the
  reasoning that a task row's menu would be empty: a task pin comes off through
  `unpin_task_from_chat` rather than `toggle_pinned`, and it carries no hide and
  no org filing. Marlowe's answer is that the unpin IS the item, and it is the
  only one because a task is pinned from another page.

  ## Chrome

  `.channel-row-actions-button` in app.css: a 24px box at
  `--color-base-content` 60% at rest, with the 44x44 hit area coming from a
  pseudo-element so the touch target costs the conversation name no width.
  The declarations were the per-row pin's, shared by both selectors while
  both controls existed. Stage 3 dropped the pin's selector when the pin's
  markup went; nothing about the trigger's chrome changed with it.

  `hero-ellipsis-horizontal` rather than the drawer's vertical ellipsis: the
  rail row is a horizontal strip of controls, and the drawer's control is a
  44px touch target in a full-bleed list.

  ## `JS.push_focus/0`

  Escape must return focus to the trigger, and the dialog is server-rendered:
  closing it REMOVES the focused element from the DOM, which drops focus to
  `<body>`. `JS.push_focus/0` with no `:to` pushes this element (the client
  reads `sourceEl`), and every close path in `row_actions_dialog/1` pops it.
  The event name and the `phx-value-space_id` payload are unchanged from the
  drawer's control — `JS.push/2` merges the element's `phx-value-*`
  attributes, so the contract on the wire is identical.
  """
  attr(:space_id, :string, required: true)
  attr(:name, :string, required: true)

  def row_actions_trigger(assigns) do
    ~H"""
    <button
      type="button"
      class="channel-row-actions-button"
      phx-click={JS.push_focus() |> JS.push("open_row_actions")}
      phx-value-space_id={@space_id}
      data-role="row-actions-trigger"
      data-space-id={@space_id}
      aria-haspopup="dialog"
      aria-label={"More actions for #{@name}"}
      title="More actions"
    >
      <span class="hero-ellipsis-horizontal size-3.5"></span>
    </button>
    """
  end

  @doc """
  The menu `row_actions_trigger/1` opens on DESKTOP (task 019ff8ba stage 1).

  ## A centred dialog, not a dropdown

  `#chat-section-list` is `overflow-y-auto`, so `overflow-x` computes to
  `auto` and clips a row-anchored popover on both axes. Measured on the
  running app when the same shape was tried for "Move to organisation…": the
  popover ran to 992px against a nav bottom of 810px, and crossed the rail's
  left edge by about 9px. The rail is ~224px wide, so no width fixes both.
  The chrome here is `move_to_org_dialog/1`'s, copied rather than reinvented.

  ## Both chromes are in the DOM at once

  `row_actions_sheet/1` keeps `lg:hidden`; this keeps `hidden lg:contents`.
  The wrapper, rather than a `hidden lg:block` on the modal itself, because
  daisyUI's `.modal` is `display: grid` and a block override breaks its
  centring — and `.modal-box` has to stay a child of `.modal` to be revealed
  at all. `display: none` on the wrapper also keeps the dialog out of
  LiveView's click-away dispatch below `lg`, which gates on `JS.isVisible/1`.

  ## Items

  Pin or Unpin, then hide, then move — the order the rows themselves used.
  Each item is gated on what the ROW could do before this stage, so the menu
  adds no capability anywhere:

    * Pin / Unpin: every conversation row.
    * Hide from my rail: sub-org channel rows only. `hide_channel` writes
      `users.preferences["hidden_channel_ids"]`, and the Hidden drawer that
      reverses it lists channels, so offering it on a DM would create a state
      with no way back.
    * Move to organisation…: root-org admin, on a channel with an `org_id`. It
      stays reachable from a PINNED row: pinning lifts a channel out of its
      sub-org section, so gating this on "unpinned" would strand it.

  Both action events are copied verbatim, `toggle_pinned` carrying
  `phx-value-pinned` as the DESIRED next state rather than a flip, so a
  duplicated event from a render race is idempotent instead of a silent
  unpin.

  ## A pinned TASK row's menu holds ONE item

  A task conversation is pinned from the Tasks page and comes off through
  `unpin_task_from_chat` (`task_chat_pins`, participant-scoped self-unpin), not
  through the viewer's `toggle_pinned` preferences. Hide and org filing are
  meaningless on it. So the whole item list forks on `@target.kind` rather than
  gating four items individually: two disjoint menus read more clearly than one
  menu with three dead branches.

  The task item keeps `data-role="pinned-task-rail-unpin"` and its
  `phx-value-task-id`, the contract the row's own button carried before this
  amendment moved it into the menu. Same reason the pin item keeps
  `pin-control`: one operation, one role name, wherever it renders. It differs
  from the phone sheet's `pinned-task-drawer-unpin` because both chromes are in
  the DOM at every width.

  Its visible label is the bare verb, matching the conversation item, and its
  accessible name is the row's unchanged "Unpin <name> from Chat". "Unpin" is
  inside that string, so WCAG 2.5.3 holds.

  ## Close (task 019ffc5f stage 2)

  Last item, on DM and group rows only — the exact rows Hide is refused on,
  because `hidden_channel_ids` has no reverse for a conversation that is a
  person. Close takes the row off the rail and it comes back on its own: on
  the next message in that DM, or the moment the user opens it. Nothing is
  deleted, nothing is unsubscribed, and no drawer lists what is closed.

  Styled EXACTLY like its siblings, deliberately. `--color-error` stays
  unspent here as it does in the sheet: red would teach the fear this design
  exists to remove, on an action that reverses itself. The copy is "Close" and
  not Dismiss, Snooze, Hide or Tidy — "close a conversation" is what the user
  is doing, and every alternative either promises a timer or collides with the
  action directly above it in this same menu.

  ## Two chromes, two `data-role`s on the hide and close items

  `row_actions_sheet/1`'s hide item is `data-role="row-actions-hide"`; this
  one is `rail-row-actions-hide`. Both are in the DOM at every width, so one
  shared role makes `button[data-role="row-actions-hide"]` ambiguous and every
  drawer test that selects it fails on the count rather than on the behaviour.
  The pin is the exception below and can share a role, because the sheet's pin
  never carried `pin-control` to begin with.

  Close splits the same way and hits one extra constraint: `row-actions-close`
  was already this dialog's DISMISS button before the Close item existed, and
  a test asserts it. So the rail's Close item is `rail-row-actions-close`, and
  the sheet's is `row-actions-close-dm` rather than the bare name.

  ## The pin item keeps `data-role="pin-control"`

  The role, the `data-space-id`, the event and the desired-next-state payload
  are the ones the row's own `pin_control/1` carried before this menu took the
  operation over (that component is deleted; this is its only remaining
  renderer). One contract, one role name, so a caller that used to address the
  row addresses the menu item unchanged. The class differs because a labelled
  menu row is not a 24px icon box, and the glyph still forks on state:
  `hero-map-pin` to pin, `hero-x-mark` to unpin.

  ## Accessible names

  The pin item's visible label is the bare verb and its accessible name adds
  the conversation ("Pin Gen-migration"). WCAG 2.5.3 wants the visible label
  inside the accessible name, and "Pin" is. The task item follows the same
  rule with the string the task row already used ("Unpin <name> from Chat").
  The other two items take their accessible name from their visible label
  alone: the dialog's heading already names the target, and neither
  verb repeats anywhere else on screen.
  """
  attr(:target, :any,
    default: nil,
    doc: "nil when closed, else the `row_actions_target/5` map for the row that opened it"
  )

  attr(:root_admin?, :boolean, default: false)

  def row_actions_dialog(assigns) do
    ~H"""
    <div :if={@target} class="hidden lg:contents">
      <div
        id="chat-row-actions-dialog"
        class="modal modal-open"
        phx-window-keydown={JS.pop_focus() |> JS.push("close_row_actions")}
        phx-key="escape"
        data-role="row-actions-dialog"
      >
        <div
          class="modal-box max-w-xs"
          role="dialog"
          aria-modal="true"
          aria-labelledby="chat-row-actions-title"
          phx-click-away={JS.pop_focus() |> JS.push("close_row_actions")}
          phx-mounted={JS.focus_first()}
          tabindex="-1"
        >
          <%!-- Wraps rather than truncates. The name is the one thing that
               says which row this menu acts on. --%>
          <h2 id="chat-row-actions-title" class="break-words text-base font-semibold">
            {@target.name}
          </h2>
          <ul :if={@target.kind == :task} class="mt-3 flex flex-col" role="list">
            <li>
              <button
                type="button"
                class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
                phx-click="unpin_task_from_chat"
                phx-value-task-id={@target.task_id}
                data-role="pinned-task-rail-unpin"
                data-space-id={@target.space_id}
                aria-label={"Unpin #{@target.name} from Chat"}
              >
                <span class="hero-x-mark size-4 flex-shrink-0" aria-hidden="true"></span>
                <span>Unpin</span>
              </button>
            </li>
          </ul>
          <ul :if={@target.kind != :task} class="mt-3 flex flex-col" role="list">
            <li>
              <button
                type="button"
                class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
                phx-click="toggle_pinned"
                phx-value-space_id={@target.space_id}
                phx-value-pinned={to_string(not @target.pinned)}
                data-role="pin-control"
                data-space-id={@target.space_id}
                data-pinned={to_string(@target.pinned)}
                aria-label={"#{if @target.pinned, do: "Unpin", else: "Pin"} #{@target.name}"}
              >
                <span
                  class={[(@target.pinned && "hero-x-mark") || "hero-map-pin", "size-4 flex-shrink-0"]}
                  aria-hidden="true"
                >
                </span>
                <span>{if @target.pinned, do: "Unpin", else: "Pin"}</span>
              </button>
            </li>
            <li :if={@target.hideable} class="border-t border-edge">
              <button
                type="button"
                class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
                phx-click="hide_channel"
                phx-value-id={@target.space_id}
                data-role="rail-row-actions-hide"
                data-space-id={@target.space_id}
              >
                <span class="hero-eye-slash size-4 flex-shrink-0" aria-hidden="true"></span>
                <span>Hide from my rail</span>
              </button>
            </li>
            <%!-- Closes this dialog on the way, client-side, so the
                 destination chooser never opens on top of it. Same shape as
                 the drawer's `new_conversation_open |> close_mobile_browser`
                 pair; no new server event. --%>
            <li :if={@root_admin? and @target.movable} class="border-t border-edge">
              <button
                type="button"
                class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
                phx-click={
                  JS.pop_focus() |> JS.push("close_row_actions") |> JS.push("toggle_reassign_menu")
                }
                phx-value-channel_id={@target.space_id}
                data-role="move-to-org-trigger"
                data-space-id={@target.space_id}
              >
                <span class="hero-building-office-2 size-4 flex-shrink-0" aria-hidden="true"></span>
                <span>Move to organisation…</span>
              </button>
            </li>
            <%!-- LAST, and under the same hairline every item after the first
                 carries. Close is the one item that changes what the rail
                 SHOWS rather than what the conversation IS, so it sits below
                 the operations on the conversation itself rather than among
                 them. --%>
            <li :if={@target.closeable} class="border-t border-edge">
              <button
                type="button"
                class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-2 text-left text-sm text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
                phx-click="close_dm"
                phx-value-id={@target.space_id}
                data-role="rail-row-actions-close"
                data-space-id={@target.space_id}
                aria-label={"Close #{@target.name}"}
              >
                <span class="hero-minus-circle size-4 flex-shrink-0" aria-hidden="true"></span>
                <span>Close</span>
              </button>
            </li>
          </ul>
          <div class="modal-action">
            <%!-- "Cancel", not "Close", since task 019ffc5f put a Close ITEM
                 in this menu. Two buttons reading "Close" one above the other,
                 one of which removes the row and one of which does nothing, is
                 a coin flip. The `data-role` is unchanged: this is still the
                 dismiss, and callers address it by role. --%>
            <button
              type="button"
              class="btn btn-ghost btn-sm focus-visible-ring"
              phx-click={JS.pop_focus() |> JS.push("close_row_actions")}
              data-role="row-actions-close"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc "Upload staging dialog — drop zone, thumb grid, agent tag chips, caption, send."
  attr(:open, :boolean, required: true)
  attr(:active_space, :any, default: nil)
  attr(:uploads, :any, required: true)
  attr(:caption, :string, default: "")
  attr(:tagged_agents, :any, required: true)
  # Large files (task 01a120be stage 3): staged over-the-inline-cap files and
  # the server's limits (`LargeUploadHooks.limits/0`), so the hint and the
  # too-large copy both name the install's real limit.
  attr(:large_staged, :list, default: [])
  attr(:limits, :map, default: nil)

  def upload_dialog(assigns) do
    assigns =
      assign(
        assigns,
        :has_files?,
        assigns.uploads.attachments.entries != [] or assigns.large_staged != []
      )

    ~H"""
    <div :if={@open} class="upload-backdrop" phx-click="upload_dialog_close">
      <div class="upload-panel" phx-click="noop">
        <div class="upload-header">
          <div class="upload-header-icon">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><path d="M21 15l-5-5L5 21" />
            </svg>
          </div>
          <div class="upload-header-text">
            <div class="upload-title">Share Images</div>
            <div class="upload-subtitle">
              Upload images to <strong>{"##{(@active_space && @active_space.name) || ""}"}</strong>
            </div>
          </div>
          <button type="button" class="upload-close" phx-click="upload_dialog_close">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <%!-- Native HTML semantics: a <label for={input.id}> opens the file
             picker on click without any JS dispatch, which sidesteps:
               (a) the `live_file_input` hardcoded `id={@upload.ref}` collision
                   that silently dropped any user-supplied id;
               (b) the iOS gesture-loss problem when JS.dispatch routes the
                   click through an async boundary.
             `phx-drop-target={@upload.ref}` is Phoenix's native drag-drop
             registration — drops on this label register entries through the
             same code path as the file picker. --%>
        <label
          :if={not @has_files?}
          id="upload-dropzone"
          for={@uploads.attachments.ref}
          phx-drop-target={@uploads.attachments.ref}
          class="upload-dropzone"
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
            <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" /><polyline points="17 8 12 3 7 8" /><line
              x1="12"
              y1="3"
              x2="12"
              y2="15"
            />
          </svg>
          <div class="upload-dropzone-title">Drag & drop images here</div>
          <div class="upload-dropzone-or">or</div>
          <span id="upload-browse-btn" class="upload-browse-btn">
            Browse files
          </span>
          <div class="upload-dropzone-sub">You can also paste images with ⌘V</div>
          <div :if={@limits} class="upload-dropzone-formats" data-role="upload-limit-hint">
            Up to {@limits.label} per file
          </div>
          <div :if={!@limits} class="upload-dropzone-formats">
            PNG · JPG · GIF · WebP · SVG — max 15 MB each
          </div>
        </label>

        <.large_staged_rows :if={@large_staged != []} staged={@large_staged} limits={@limits} />

        <div :if={@uploads.attachments.entries != []} class="upload-grid-area">
          <div class="upload-grid">
            <div :for={entry <- @uploads.attachments.entries} class="upload-thumb">
              <%= if String.starts_with?(entry.client_type, "image/") do %>
                <.live_img_preview
                  entry={entry}
                  class="upload-thumb-inner"
                  style="width:100%;height:100%;object-fit:cover"
                />
              <% else %>
                <div class="upload-thumb-inner">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                    <rect x="3" y="3" width="18" height="18" rx="2" /><circle
                      cx="8.5"
                      cy="8.5"
                      r="1.5"
                    /><path d="M21 15l-5-5L5 21" />
                  </svg>
                </div>
              <% end %>
              <span class="upload-thumb-name">{entry.client_name}</span>
              <button
                type="button"
                class="upload-thumb-remove"
                phx-click="upload_entry_cancel"
                phx-value-ref={entry.ref}
              >
                ×
              </button>
              <div
                :if={entry.progress > 0 and entry.progress < 100}
                class="upload-thumb-progress-overlay"
                style="position:absolute;inset:0;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;color:#FFF;font-size:14px;font-weight:600;pointer-events:none"
              >
                {entry.progress}% uploading…
              </div>
            </div>
            <%!-- Same label-for trick as the dropzone (see comment above). --%>
            <label
              id="upload-add-more"
              for={@uploads.attachments.ref}
              class="upload-add-tile"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
              </svg>
              Add more
            </label>
          </div>
        </div>

        <div :if={upload_errors(@uploads.attachments) != []} style="padding:0 20px">
          <p
            :for={error <- upload_errors(@uploads.attachments)}
            class="text-xs"
            style="color:var(--danger);margin-bottom:4px"
          >
            {upload_error_to_string(error)}
          </p>
        </div>
        <div :for={entry <- @uploads.attachments.entries} style="padding:0 20px">
          <p
            :for={error <- upload_errors(@uploads.attachments, entry)}
            class="text-xs"
            style="color:var(--danger);margin-bottom:4px"
          >
            {entry.client_name}: {upload_error_to_string(error)}
          </p>
        </div>

        <div :if={@uploads.attachments.entries != []} class="upload-agent-section">
          <div class="upload-agent-label">Tag an agent</div>
          <div class="upload-agent-chips">
            <button
              :for={
                {slug, label} <- [
                  {"beacon", "Beacon"},
                  {"pixel", "Pixel"},
                  {"builder", "Builder"},
                  {"higgins", "Higgins"}
                ]
              }
              type="button"
              class={"agent-chip #{slug}#{if MapSet.member?(@tagged_agents, slug), do: " selected", else: ""}"}
              phx-click="upload_toggle_agent"
              phx-value-agent={slug}
            >
              <span class="chip-dot"></span> {label}
            </button>
          </div>
        </div>

        <%!-- Caption + Send. The textarea and submit button live OUTSIDE
             #upload-send-form (which holds only the file input and is rendered
             unconditionally in chat_live.html.heex) and target it via the
             HTML5 `form="upload-send-form"` cross-form attribute. This avoids
             the chicken-and-egg defect from the prior shipping attempt where
             the form was `:if`-guarded on `entries != []` — so on first
             paste/drop, `inputEl.form` resolved to null and LV's pushInput
             after `LiveUploader.trackFiles` had nowhere to serialize, and
             the entry never registered. With the form always present, paste
             on an empty modal works on the very first attempt. --%>
        <div :if={@has_files?}>
          <div class="upload-comment">
            <textarea
              name="caption"
              form="upload-send-form"
              class="upload-comment-input"
              placeholder="Add a comment about these images..."
              phx-debounce="200"
            >{@caption}</textarea>
          </div>

          <div class="upload-footer">
            <div class="upload-count">
              <%= if @large_staged == [] do %>
                <strong>{length(@uploads.attachments.entries)}</strong>
                {if length(@uploads.attachments.entries) == 1, do: "image", else: "images"} selected
              <% else %>
                <strong>{length(@uploads.attachments.entries) + length(@large_staged)}</strong>
                {if length(@uploads.attachments.entries) + length(@large_staged) == 1,
                  do: "file",
                  else: "files"} selected
              <% end %>
              <span :if={@limits} class="block text-xs text-base-content/60">
                Up to {@limits.label} per file
              </span>
            </div>
            <div class="upload-footer-actions">
              <button type="button" class="upload-btn-cancel" phx-click="upload_dialog_close">
                Cancel
              </button>
              <button
                type="submit"
                form="upload-send-form"
                class="upload-btn-send"
                disabled={
                  Enum.any?(
                    @uploads.attachments.entries,
                    &(&1.progress > 0 and &1.progress < 100)
                  ) or
                    (@uploads.attachments.entries == [] and @large_staged != [] and
                       Enum.all?(@large_staged, & &1.too_large?))
                }
              >
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                  <line x1="22" y1="2" x2="11" y2="13" /><polygon points="22 2 15 22 11 13 2 9 22 2" />
                </svg>
                Send to {"##{(@active_space && @active_space.name) || ""}"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:staged, :list, required: true)
  attr(:limits, :map, required: true)

  # One row per staged large file. A file over the install's limit reads
  # "(!) <name> is 1.1 GB. This Burrow install accepts files up to 1 GB." with the
  # error hue on the icon only (the token fails AA as small text), and never
  # uploads. Design canvas 01a120be-f336, "TOO LARGE".
  defp large_staged_rows(assigns) do
    ~H"""
    <ul class="flex flex-col gap-2 px-5 pb-2" data-role="large-staged">
      <li
        :for={file <- @staged}
        id={"large-staged-#{file.ref}"}
        data-too-large={to_string(file.too_large?)}
        class="flex items-start gap-2 rounded-box border border-edge bg-base-200 px-3 py-2 text-sm"
      >
        <%= if file.too_large? do %>
          <span class="hero-exclamation-circle size-5 shrink-0 text-error" aria-hidden="true"></span>
          <span class="min-w-0 flex-1 text-base-content">
            <span title={file.name}>
              {PlatformWeb.ChatLive.Partials.Composer.middle_truncate(file.name)}
            </span>
            is {Platform.Chat.UploadLimits.format_bytes(max(file.size, 0))}. This Burrow install accepts files up to {@limits &&
              @limits.label}.
          </span>
        <% else %>
          <span class="hero-document size-5 shrink-0 text-base-content/60" aria-hidden="true"></span>
          <span class="min-w-0 flex-1 truncate" title={file.name}>
            {PlatformWeb.ChatLive.Partials.Composer.middle_truncate(file.name)}
          </span>
          <span class="shrink-0 font-mono text-[11px] tabular-nums text-base-content/60">
            {Platform.Chat.UploadLimits.format_bytes(max(file.size, 0))}
          </span>
        <% end %>
        <button
          type="button"
          class="btn btn-ghost btn-xs shrink-0"
          phx-click="large_upload_unstage"
          phx-value-ref={file.ref}
        >
          Remove
        </button>
      </li>
    </ul>
    """
  end

  @doc "Active-canvas side panel (desktop) and full-screen overlay (mobile)."
  attr(:canvas, :any, default: nil)
  attr(:show_versions_panel, :boolean, default: false)
  attr(:canvas_versions, :list, default: [])
  attr(:restore_confirm_revision, :integer, default: nil)
  attr(:viewer, :any, default: nil)

  def canvas_overlay(assigns) do
    ~H"""
    <div
      :if={@canvas}
      id="canvas-sidebar"
      phx-hook="CanvasSidebarResize"
      class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-edge bg-base-100 relative"
    >
      <div
        class="absolute left-0 inset-y-0 w-1 cursor-col-resize hover:bg-primary/40 active:bg-primary/60 transition-colors z-10 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
        data-drag-handle
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize canvas sidebar"
        aria-valuemin="360"
        aria-valuemax="960"
        aria-valuenow="384"
        tabindex="0"
      />
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4">
        <div class="min-w-0 flex items-center gap-2">
          <div class="min-w-0">
            <p class="text-sm font-semibold">Live Canvas</p>
            <p class="truncate text-xs text-base-content/50">
              {@canvas.title || CanvasHooks.humanize_kind(@canvas)}
            </p>
          </div>
          <button
            phx-click="canvas_versions_toggle"
            class={[
              "btn btn-ghost btn-xs",
              @show_versions_panel && "text-primary"
            ]}
            title="Version history"
            aria-label="Toggle version history"
          >
            <span class="hero-clock size-4"></span>
          </button>
        </div>
        <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
          <span class="hero-x-mark size-4"></span>
        </button>
      </div>
      <div class="flex-1 overflow-y-auto px-4 py-4">
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-panel" viewer={@viewer} />
      </div>
      <.canvas_versions_panel
        :if={@show_versions_panel}
        canvas={@canvas}
        versions={@canvas_versions}
        restore_confirm_revision={@restore_confirm_revision}
      />
    </div>

    <div :if={@canvas} class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden safe-area-x">
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4 safe-area-top">
        <div class="min-w-0 flex items-center gap-2">
          <div class="min-w-0">
            <p class="text-sm font-semibold">Live Canvas</p>
            <p class="truncate text-xs text-base-content/50">
              {@canvas.title || CanvasHooks.humanize_kind(@canvas)}
            </p>
          </div>
          <button
            phx-click="canvas_versions_toggle"
            class={[
              "btn btn-ghost btn-xs",
              @show_versions_panel && "text-primary"
            ]}
            title="Version history"
            aria-label="Toggle version history"
          >
            <span class="hero-clock size-4"></span>
          </button>
        </div>
        <button phx-click="canvas_close" class="btn btn-ghost btn-xs" title="Close canvas">
          <span class="hero-x-mark size-4"></span>
        </button>
      </header>
      <div class="flex-1 overflow-y-auto px-4 py-4">
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-overlay" viewer={@viewer} />
      </div>
      <.canvas_versions_panel
        :if={@show_versions_panel}
        canvas={@canvas}
        versions={@canvas_versions}
        restore_confirm_revision={@restore_confirm_revision}
        mobile
      />
    </div>
    """
  end

  attr(:canvas, :any, required: true)
  attr(:versions, :list, default: [])
  attr(:restore_confirm_revision, :integer, default: nil)
  attr(:mobile, :boolean, default: false)

  def canvas_versions_panel(assigns) do
    ~H"""
    <div
      id={"canvas-versions-panel-#{(@mobile && "mobile") || "desktop"}-#{@canvas.id}"}
      class={[
        "absolute inset-y-0 right-0 z-30 flex w-80 flex-col border-l border-edge bg-base-100 shadow-xl transition-transform",
        @mobile && "fixed top-12 bottom-[var(--bottom-nav-height,0px)]"
      ]}
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4">
        <p class="text-sm font-semibold">Version history</p>
        <button
          phx-click="canvas_versions_close"
          class="btn btn-ghost btn-xs"
          title="Close version history"
        >
          <span class="hero-x-mark size-4"></span>
        </button>
      </div>

      <div class="flex-1 overflow-y-auto">
        <ul class="divide-y divide-base-300">
          <li
            :for={v <- @versions}
            id={"canvas-version-#{@canvas.id}-#{v.revision}"}
            class={[
              "px-4 py-3 hover:bg-base-200 group",
              @restore_confirm_revision == v.revision && "bg-warning/10"
            ]}
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="text-sm font-semibold tabular-nums">v{v.revision}</span>
                  <span class="text-xs text-base-content/50">{v.relative_time}</span>
                </div>
                <p class="truncate text-xs text-base-content/70">
                  <span
                    :if={v.author_type_badge}
                    class={[
                      "inline-block rounded px-1 mr-1 text-[10px] uppercase tabular-nums",
                      v.author_badge_class
                    ]}
                  >
                    {v.author_type_badge}
                  </span>
                  {v.author_name}
                </p>
                <p class="truncate text-xs text-base-content/50 mt-0.5">{v.op_summary}</p>
              </div>
              <div class="flex flex-col gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                <button
                  type="button"
                  phx-click="canvas_versions_restore_prompt"
                  phx-value-revision={v.revision}
                  class="btn btn-ghost btn-xs text-warning"
                  title="Restore this revision"
                >
                  Restore
                </button>
              </div>
            </div>

            <div
              :if={@restore_confirm_revision == v.revision}
              class="mt-3 rounded border border-warning/40 bg-warning/5 p-3"
            >
              <p class="text-xs text-base-content/80 mb-2">
                Replace current canvas with revision {v.revision}? The current state stays in history as a new revision.
              </p>
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  phx-click="canvas_versions_restore_cancel"
                  class="btn btn-ghost btn-xs"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  phx-click="canvas_versions_restore_confirm"
                  phx-value-revision={v.revision}
                  class="btn btn-warning btn-xs"
                >
                  Restore v{v.revision}
                </button>
              </div>
            </div>
          </li>
          <li
            :if={@versions == []}
            class="px-4 py-6 text-center text-xs text-base-content/50"
          >
            No version history yet.
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  In-meeting UI — desktop side panel + mobile full-screen overlay.

  ## The two surfaces are one screen now (task 01a05b14 stage 6)

  The roster and the four hand-rolled control buttons are gone. This
  panel renders `PlatformWeb.Components.Meetings.CallShell.call_rail/1`
  and `call_controls/1` — the SAME components `/meetings` renders — so
  People, Canvas and Transcript stop being a thing you can only see on
  one of the two surfaces. The event names are passed in because
  `ChatLive.MeetingHooks` owns `meeting_toggle_mic` /
  `meeting_toggle_camera` / `meeting_leave` and `MeetingLive` owns a
  different vocabulary; that is exactly what the event-name attrs on
  `call_controls/1` exist for.

  ## ONE rail across BOTH breakpoint subtrees

  The rail is hoisted OUT of the `hidden lg:flex` desktop panel and the
  `lg:hidden` mobile overlay, for the same reason the captions host was
  hoisted in task 019ff712: both subtrees are in the document at once
  (CSS, not the server, picks the visible one), so authoring the rail
  inside each would put two `#quickmeet-call-rail`s, two
  `MeetingTranscript` hooks and two sets of candidate buttons in one
  page. At `lg` the hoisted rail is an in-flow column beside the media
  panel; below `lg` it is a bottom sheet over the full-screen overlay,
  opened from the overlay header.

  ## What is NOT here, and why

    * **The intents-collapse bar.** `/meetings` passes it through the
      rail's `:canvas_extra` slot. Its five controls push
      `toggle_intents_collapse`, `toggle_intents_expanded`,
      `cancel_intent`, `pick_intent_reason` and `toggle_intent_mute` —
      handlers that live in `MeetingLive` and are wrapped in its
      `with_intents_gate/2` role check. Rendering the bar here would
      put five buttons on screen that push at no handler in `ChatLive`,
      which is the same "draw a state with nothing behind it" defect the
      `Listening` refusal exists to prevent. Porting the gate and the
      handlers is a second surface's worth of work, not a markup move.

    * **Invite an agent.** `CallShell.invite_section/1` renders from
      `@invite_rows` against `quickmeet_invite_agent`, which `MeetingHooks`
      handles with the same body `/meetings` runs
      (`MeetingHooks.invite_agent_into_call/3`, task 01a0691d). The
      section is unconditional on this surface: a signed-in chat viewer in
      a call may always invite.

    * **`Listening`.** Deliberately absent everywhere: nothing in the
      system can set `AgentActivity`'s `:listening`. See
      `CallShell`'s moduledoc.
  """
  attr(:in_meeting, :boolean, required: true)
  attr(:active_space, :any, default: nil)
  attr(:mic_enabled, :boolean, required: true)
  attr(:camera_enabled, :boolean, required: true)
  attr(:screen_share_enabled, :boolean, required: true)
  # Task 01a13c62 stage 3: the iOS app's native call, see `CallShell.call_controls/1`.
  attr(:native_call, :map, default: nil)
  attr(:mic_pending, :boolean, default: false)
  attr(:media_error, :string, default: nil)
  attr(:meeting_participants, :list, default: [])
  attr(:invite_rows, :list, default: [])

  # ── Call-shell assigns, all owned by `ChatLive.MeetingHooks` ─────────
  #
  # Defaulted rather than required: the panel must still render for a
  # space whose room came up through raw LiveKit with no `meetings` row,
  # in which case there is no meeting id to hydrate any of this from and
  # the honest result is an empty Canvas and Transcript.
  attr(:active_meeting_tab, :string, default: "people")
  attr(:rail_open, :boolean, default: false)
  attr(:meeting, :any, default: nil)
  attr(:agents_by_id, :map, default: %{})
  attr(:agent_activity, :any, default: nil)

  attr(:agent_activity_now, :any,
    default: nil,
    doc: """
    The 1-second clock `ChatLive.MeetingHooks` maintains (task 01a077e7).

    `join_call_shell/2` arms `MeetingHooks.schedule_agent_activity_tick/0`
    the moment a REAL quickmeet is joined, and the `:agent_activity_tick`
    clause re-assigns `:agent_activity_now` every
    `AgentActivity.tick_interval_ms/0` and re-arms. Threading it through
    here is not decoration: **passing it is what makes LiveView re-diff
    the rail on each tick.** The panel is a function component, so the
    diff only re-invokes it when one of the values passed AT THE CALL SITE
    changes. Until this attr existed, `chat_live.html.heex` passed no
    ticking value at all, so a tick was invisible to the diff and the
    whole `<.meeting_panel>` subtree was skipped — the rail repainted only
    when some OTHER assign happened to change. That is why an ETS-only
    `:speaking` (`AgentActivity.mark_speaking/4` writes ETS and broadcasts
    nothing) never reached this screen on its own.

    Read as `@agent_activity_now`, never `assigns[:agent_activity_now]`:
    bracket access on `assigns` bypasses change tracking, so even a passed
    value would not register as a dynamic.
    """
  )

  attr(:candidates, :list, default: [])
  attr(:candidates_closed, :list, default: [])
  attr(:candidate_events, :map, default: %{})
  attr(:candidate_order, :list, default: nil)
  attr(:candidate_error, :string, default: nil)
  attr(:captions_available, :boolean, default: true)

  def meeting_panel(assigns) do
    ~H"""
    <div
      :if={@in_meeting}
      id="meeting-panel"
      class="relative hidden lg:flex w-80 min-w-0 flex-shrink-0 flex-col border-l border-edge bg-base-100"
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4">
        <div class="flex items-center gap-2 min-w-0">
          <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
          <p class="text-sm font-semibold truncate">
            {(@active_space && @active_space.name) || "Meeting"}
          </p>
          <span id="meeting-duration" class="text-xs text-base-content/50 tabular-nums">0:00</span>
        </div>
        <div class="flex items-center gap-1">
          <.soundboard_menu id="soundboard-menu-desktop" />
          <button
            phx-click="meeting_leave"
            class="btn btn-ghost btn-xs text-error"
            title="Leave meeting"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto p-3" data-role="call-stage" data-pane="desktop">
        <%!-- Screen-share preview (task 019e420f stage 3). JS owns
             these children — meeting_client.js attaches the live
             `<video>` here when a peer publishes a screen-share track,
             and toggles `hidden` based on the active state. Sits above
             the participants grid so it's never cropped by avatar
             tiles. `phx-update="ignore"` because the LV doesn't render
             the video element itself. --%>
        <div class="relative mb-2" data-screen-share-viewer data-screen-share-active="false">
          <div
            data-quickmeet-screen-share-slot
            data-pane="desktop"
            data-screen-share-active="false"
            phx-update="ignore"
            id="meeting-screen-share-slot-desktop"
            class="hidden aspect-video w-full overflow-hidden rounded-lg bg-black"
          >
          </div>
          <button
            type="button"
            hidden
            data-screen-share-fullscreen
            aria-label="Enter full screen"
            aria-pressed="false"
            class="screen-share-fullscreen-button focus-visible-ring"
          >
            <span class="hero-arrows-pointing-out size-5" aria-hidden="true"></span>
            <span class="sr-only" data-screen-share-fullscreen-label>Enter full screen</span>
          </button>
          <p
            data-quickmeet-screen-share-sharer
            class="mt-1 text-xs text-base-content/50 truncate"
          >
          </p>
        </div>
        <%!-- v4 stage 2: local self-view parking slot for the /chat
             quick-meet panel. The page-level `MeetingClient` hook
             (meeting_client.js) births the single persistent local
             <video> in `[data-role="local-self-view"]` and then docks it
             into `[data-local-video-dock][data-dock-mode="gallery"]`
             below. This mirrors MeetingLive's
             `#meeting-local-self-view` (meeting_live.html.heex:284) but
             uses a DISTINCT id (`quickmeet-local-self-view`) so the two
             surfaces never collide on a duplicate id when both are in the
             DOM (the chat panel is embedded inside MeetingLive's right
             pane). Single-mount invariant: only ONE of the two
             `data-role="local-self-view"` nodes is rendered + visible per
             page (MeetingLive on /meetings, this quick-meet on /chat), so
             the global `querySelector('[data-role="local-self-view"]')`
             in the hook resolves to whichever panel is mounted. Zero-size,
             hidden, `phx-update="ignore"` so the LV patch never wipes the
             hook-owned <video>. --%>
        <div
          id="quickmeet-local-self-view"
          phx-update="ignore"
          class="hidden"
          data-role="local-self-view"
          data-pane="desktop"
        >
        </div>
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants"
          phx-update="ignore"
          data-role="call-tile-grid"
          class="meeting-participant-grid w-full gap-2.5"
        >
        </div>
        <%!-- v4 stage 2: gallery dock the hook reparents the persistent
             local <video> into. The quick-meet panel has a single
             (non-staged) layout — there are no MeetingLive stage modes
             here — so we give it ONE dock with `data-dock-mode="gallery"`,
             the mode `_currentStageMode()` defaults to when no
             `[data-pane="center-stage"]` is present (meeting_client.js
             line 138-141). `phx-update="ignore"` so the LV patch never
             detaches the docked <video>. --%>
        <div
          id="quickmeet-local-video-dock"
          phx-update="ignore"
          data-local-video-dock
          data-dock-mode="gallery"
          data-pane="desktop"
          class="mt-2 aspect-video w-full overflow-hidden rounded-lg bg-base-300 empty:hidden"
        >
        </div>
      </div>

      <%!-- Mic / Camera / Share / Leave are `CallShell.call_controls/1`
           now (task 01a05b14 stage 6) — the identical component
           `/meetings` mounts, so the two surfaces cannot drift again.

           The event names are THIS surface's: `ChatLive.MeetingHooks`
           handles `meeting_toggle_mic`, `meeting_toggle_camera`,
           `meeting_toggle_screen_share` and `meeting_leave`. They are
           attrs precisely because `/meetings` says something else.

           `share_id` + `share_hook` are load-bearing and are threaded
           through unchanged. `meeting_share_button.js` binds the click
           on ITS OWN element (`this.el`) via `phx-hook` — it does NOT
           look the button up by id — and calls `getDisplayMedia()`
           inside the gesture. The stable id stays because a shipped
           test pins it and because two panes must not collide, but the
           reason the hook keeps working is the `phx-hook` attribute,
           not the id. Dropping either would leave a Share button that
           silently fails only in a real browser. --%>
      <CallShell.call_controls
        class="min-h-[46px] shrink-0 justify-center gap-2 border-t border-edge px-2"
        mic_event="meeting_toggle_mic"
        camera_event="meeting_toggle_camera"
        share_event="meeting_toggle_screen_share"
        leave_event="meeting_leave"
        mic_on={@mic_enabled}
        camera_on={@camera_enabled}
        sharing={@screen_share_enabled}
        native={@native_call}
        mic_pending={@mic_pending}
        media_error={@media_error}
        mic_role="meeting-mic"
        camera_role="meeting-camera"
        share_role="meeting-share-button"
        leave_role="meeting-leave"
        share_id="meeting-share-btn-desktop"
        share_hook="MeetingShareButton"
        share_click?={false}
      />

      <div
        data-soundboard-toasts
        class="pointer-events-none absolute bottom-20 inset-x-0 z-10 flex flex-col items-center gap-1"
      >
      </div>

      <%!-- JS owns the children (track.attach outputs); ignore on re-render
           so toggling mic/camera doesn't wipe the <audio> elements. --%>
      <div id="meeting-media" class="hidden" phx-update="ignore"></div>
    </div>

    <div
      :if={@in_meeting}
      data-role="quickmeet-mobile-overlay"
      class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden safe-area-x"
    >
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-edge px-4 safe-area-top">
        <div class="flex items-center gap-2 min-w-0">
          <span class="bg-success rounded-full w-2 h-2 animate-pulse flex-shrink-0"></span>
          <p class="text-sm font-semibold truncate">
            {(@active_space && @active_space.name) || "Meeting"}
          </p>
          <span id="meeting-duration-mobile" class="text-xs text-base-content/50 tabular-nums">
            0:00
          </span>
        </div>
        <div class="flex items-center gap-1">
          <%!-- Opens the hoisted call rail as a bottom sheet. Mobile-only:
               at `lg` the rail is an in-flow column and always visible.
               Before task 01a05b14 stage 6 there was no way to reach
               People / Canvas / Transcript below `lg` on EITHER surface —
               the rail was `hidden lg:flex` and measured `width: 0` at
               390px. --%>
          <button
            type="button"
            phx-click="quickmeet_toggle_rail"
            aria-label="Toggle call panel"
            aria-expanded={to_string(@rail_open)}
            aria-controls="quickmeet-call-rail"
            title="Toggle call panel"
            class="btn btn-ghost btn-xs btn-square text-base-content/60"
            data-role="quickmeet-rail-toggle"
          >
            <span class="hero-user-group size-4"></span>
          </button>
          <.soundboard_menu id="soundboard-menu-mobile" />
          <button phx-click="meeting_leave" class="btn btn-ghost btn-xs" title="Back to chat">
            <span class="hero-arrow-left size-4"></span>
            <span class="text-xs">Chat</span>
          </button>
        </div>
      </header>

      <div
        data-soundboard-toasts
        class="pointer-events-none absolute bottom-24 inset-x-0 z-10 flex flex-col items-center gap-1"
      >
      </div>

      <div class="flex-1 overflow-y-auto p-4" data-role="call-stage" data-pane="mobile">
        <%!-- Screen-share preview (task 019e420f stage 3). See the
             desktop variant for the rationale. --%>
        <div class="relative mb-2" data-screen-share-viewer data-screen-share-active="false">
          <div
            data-quickmeet-screen-share-slot
            data-pane="mobile"
            data-screen-share-active="false"
            phx-update="ignore"
            id="meeting-screen-share-slot-mobile"
            class="hidden aspect-video w-full overflow-hidden rounded-lg bg-black"
          >
          </div>
          <button
            type="button"
            hidden
            data-screen-share-fullscreen
            aria-label="Enter full screen"
            aria-pressed="false"
            class="screen-share-fullscreen-button focus-visible-ring"
          >
            <span class="hero-arrows-pointing-out size-5" aria-hidden="true"></span>
            <span class="sr-only" data-screen-share-fullscreen-label>Enter full screen</span>
          </button>
          <p
            data-quickmeet-screen-share-sharer
            class="mt-1 text-xs text-base-content/50 truncate"
          >
          </p>
        </div>
        <%!-- v4 stage 2: local self-view parking slot + gallery dock for
             the MOBILE quick-meet overlay. Mirrors the desktop variant
             above. Both desktop and mobile quick-meet variants coexist in
             the chat-page DOM (one hidden by CSS at the lg breakpoint), so
             the parking slot + dock carry `data-pane="mobile"` and
             meeting_client.js picks the VISIBLE pane via matchMedia
             (parity with `_grid()` / `_screenShareSlot()`), keeping the
             local <video> docked in whichever overlay is on-screen. --%>
        <div
          id="quickmeet-local-self-view-mobile"
          phx-update="ignore"
          class="hidden"
          data-role="local-self-view"
          data-pane="mobile"
        >
        </div>
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants-mobile"
          phx-update="ignore"
          data-role="call-tile-grid"
          class="meeting-participant-grid w-full gap-2.5"
        >
        </div>
        <div
          id="quickmeet-local-video-dock-mobile"
          phx-update="ignore"
          data-local-video-dock
          data-dock-mode="gallery"
          data-pane="mobile"
          class="mt-2 aspect-video w-full overflow-hidden rounded-lg bg-base-300 empty:hidden"
        >
        </div>
      </div>

      <%!-- Mobile controls, same component, same event vocabulary, its
           own `share_id` so the two panes never collide on a duplicate
           id while both subtrees are in the document. `safe-area-bottom`
           and the bottom-nav clearance stay on the control row: this is
           the primary action row at 375px. --%>
      <CallShell.call_controls
        class="min-h-[46px] shrink-0 justify-center gap-2 border-t border-edge px-3 py-2 safe-area-bottom"
        mic_event="meeting_toggle_mic"
        camera_event="meeting_toggle_camera"
        share_event="meeting_toggle_screen_share"
        leave_event="meeting_leave"
        mic_on={@mic_enabled}
        camera_on={@camera_enabled}
        sharing={@screen_share_enabled}
        native={@native_call}
        mic_pending={@mic_pending}
        media_error={@media_error}
        mic_role="meeting-mic"
        camera_role="meeting-camera"
        share_role="meeting-share-button"
        leave_role="meeting-leave"
        share_id="meeting-share-btn-mobile"
        share_hook="MeetingShareButton"
        share_click?={false}
      />
    </div>

    <%!-- ── THE CALL RAIL, hoisted out of BOTH breakpoint subtrees ────
         The same `CallShell.call_rail/1` `/meetings` renders, but with
         THREE tabs, not four: People / Canvas / Transcript.

         NO `<:chat>` SLOT, AND THAT IS THE POINT (task 01a084bf stage 4).
         This panel is embedded IN the chat surface — the discussion is
         already on screen beside it — so a Chat pane here would be a
         second `ChatLive.Embedded` mount of the space the user is
         reading, and stage 3's whole discipline is that the one
         `live_render` MOVES and is never duplicated. `call_rail/1`
         derives its strip from the slots it was given
         (`CallShell.served_tabs/1`) and coerces `active_tab` against that
         same list, so this caller gets no Chat button and cannot land on
         a Chat pane it does not serve — including via a stale
         `"meeting_tab_select"` push carrying `"chat"`.

         The comment that used to sit here said "People / Canvas /
         Transcript, the same `CallShell.call_rail/1` /meetings renders",
         which was true until stage 1 added a fourth entry to the shared
         `@tabs` and this surface silently grew a Chat tab whose pane fell
         through to an empty state. That false comment is what surfaced
         the bug (ticket 01a089ae); it is corrected rather than deleted so
         the next reader knows the three-up is chosen, not stale.

         Authored ONCE and positioned by CSS, for
         the reason the captions host above it was hoisted in task
         019ff712: the `hidden lg:flex` desktop panel and the
         `lg:hidden` mobile overlay are BOTH in the document at all
         times — CSS, not the server, picks which is visible — so a copy
         in each would mean two `#quickmeet-call-rail`s, two
         `MeetingTranscript` hooks writing into two logs, and two
         `stop_candidate` buttons per card.

         At `lg`: an in-flow 312px column to the right of the media
         panel, mirroring `/meetings`.

         Below `lg`: a bottom sheet at `z-[55]`, one layer above the
         mobile overlay's `z-50`, sliding up from the overlay header's
         toggle. `top-12` clears that header so the meeting name and
         Leave stay reachable while the sheet is open, and the bottom
         edge clears BOTH the safe-area inset and the bottom nav, so
         Canvas's last card is not parked under the home indicator.

         THIS IS THE MOBILE FIX. Stage 5 measured
         `[data-component="call-rail"]` at `width: 0` on a 390px
         viewport and a capture failed outright. `width_class` carries
         `w-full` here rather than the desktop 312px because two width
         utilities on one element resolve by CSS SOURCE order and the
         override would have been non-deterministic.

         COLLAPSED (stage 5, round 2). `translate-y-full` moves the sheet
         by its OWN height, and the sheet's bottom edge is already
         `nav + safe-area` above the viewport's — so the collapsed top
         landed exactly `nav + safe-area` (56px on a phone) inside the
         viewport, over the mobile overlay's control bar, and a tap on
         Leave hit the Transcript tab instead. The collapsed transform
         therefore offsets by its height PLUS the same bottom clearance
         it sits on, which parks the sheet fully below the viewport
         whatever the inset is; `env(safe-area-inset-bottom)` is 0 in
         headless Chrome and a real inset only makes the peek larger,
         which is why the clearance is computed rather than hard-coded.
         `pointer-events-none` while collapsed is the belt for that
         brace: even mid-transition, nothing under the sliding sheet is
         intercepted, and `lg:pointer-events-auto` hands the in-flow
         desktop column its clicks back regardless of the toggle state.

         OPEN, the sheet's bottom edge sits `nav + safe-area` above the
         viewport's — ABOVE the overlay's control bar, which is the
         viewport's last 46px + inset — so the bar stays reachable
         while the sheet covers the tiles. The tiles are what a sheet is
         for; the bar is what a caller needs to leave. `/meetings` at
         390px places its bar above the nav the same way. --%>
    <div
      :if={@in_meeting}
      id="quickmeet-call-rail-host"
      data-role="quickmeet-call-rail-host"
      data-rail-open={to_string(@rail_open)}
      class={[
        "flex flex-col bg-base-100",
        "fixed inset-x-0 top-12 z-[55] transition-transform duration-200 ease-out",
        "bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]",
        if(@rail_open,
          do: "translate-y-0",
          else:
            "translate-y-[calc(100%+env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))] pointer-events-none"
        ),
        "lg:static lg:inset-auto lg:bottom-auto lg:z-auto lg:pointer-events-auto",
        "lg:w-[312px] lg:flex-shrink-0 lg:translate-y-0"
      ]}
    >
      <%!-- Mobile-only dismissal. The header toggle that opened the
           sheet is behind it once it is up, so without this the sheet
           has no close affordance at all. --%>
      <div class="flex flex-shrink-0 justify-end border-b border-l border-edge bg-base-200/40 px-2 py-1 lg:hidden">
        <button
          type="button"
          phx-click="quickmeet_toggle_rail"
          aria-label="Close call panel"
          title="Close"
          class="btn btn-ghost btn-xs btn-square text-base-content/60"
          data-role="quickmeet-rail-close"
        >
          <span class="hero-x-mark size-4"></span>
        </button>
      </div>

      <CallShell.call_rail
        id="quickmeet-call-rail"
        class="min-h-0 flex-1"
        width_class="w-full lg:w-[312px]"
        active_tab={@active_meeting_tab}
        tab_event="meeting_tab_select"
        participants={@meeting_participants}
        agents_by_id={@agents_by_id}
        meeting={@meeting}
        agent_activity={@agent_activity}
        now={@agent_activity_now}
        invite_rows={@invite_rows}
        invite_event="quickmeet_invite_agent"
        candidates={@candidates}
        candidates_closed={@candidates_closed}
        candidate_events={@candidate_events}
        candidate_order={@candidate_order}
        candidate_error={@candidate_error}
        captions_available={@captions_available}
      />
    </div>

    <%!-- Task 019ff712 stage 2: ONE caption host for the whole quick-meet
         panel. Captions used to be authored twice — once inside the
         `hidden lg:flex` desktop rail and again inside the `lg:hidden`
         mobile overlay — which doubled the DOM nodes and the hook
         instances for a single visible line. There is one approach to
         captions in every context, so the
         host is hoisted OUT of both breakpoint subtrees and positioned to
         sit below the video area and above the control row at BOTH widths:
         full-bleed above the mobile control row, and pinned inside the
         w-96 rail above the desktop control row at `lg`. `z-[60]` clears
         the mobile overlay's `z-50`. `phx-update="ignore"` matches
         MeetingLive's host — the hook writes `innerHTML`, and a LiveView
         patch would otherwise wipe committed lines. `data-role` so tests
         and tooling query by role rather than id. --%>
    <div
      :if={@in_meeting}
      id="meeting-captions"
      data-role="meeting-captions"
      phx-hook="MeetingCaptions"
      phx-update="ignore"
      class="pointer-events-none fixed z-[60] rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 transition-opacity duration-300 inset-x-4 bottom-32 lg:inset-x-auto lg:right-3 lg:w-[22rem]"
    >
    </div>
    """
  end

  @doc """
  Server-presence participant roster for the /chat quick-meet panel
  (task 019e4b3e v4 stage 3).

  ROOT CAUSE 2 fix: the quick-meet rail used to be CLIENT-ONLY — the
  `#meeting-participants` `phx-update="ignore"` grid was filled solely by
  `MeetingClient._ensureTile` from the LiveKit participants the viewer's
  OWN browser had subscribed. A webhook-driven participant (or a 2nd user
  whose media this viewer hasn't subscribed yet) never appeared, and the
  count was wrong. This roster is an LV-OWNED `:for` over
  `Meetings.active_participants_for_space/1` (mirrors MeetingLive), so it
  is the authoritative WHO-is-present surface (real name + count).

  Coexistence with the live media: this roster renders name + count under
  normal `phx-update`; the sibling `#meeting-participants` grid keeps its
  `phx-update="ignore"` so the JS-attached `<video>`/`<audio>` tiles are
  never wiped. The two are keyed off the same participant identity
  (`participant_type` + `participant_id`) — the roster owns identity, the
  media grid owns the live tracks. The literal "User" never renders: an
  orphaned/unresolved identity falls through to "Unknown participant".
  """
  attr(:id, :string, required: true)
  attr(:participants, :list, default: [])

  def meeting_roster(assigns) do
    ~H"""
    <div id={@id} class="mb-2" data-role="meeting-roster">
      <div class="mb-1 flex items-center justify-between px-0.5">
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
          In this meeting
        </span>
        <span
          class="text-xs tabular-nums text-base-content/50"
          data-role="meeting-roster-count"
        >
          {length(@participants)}
        </span>
      </div>
      <ul class="flex flex-col gap-1">
        <li
          :for={p <- @participants}
          id={"#{@id}-row-#{roster_identity(p)}"}
          data-role="meeting-roster-row"
          data-identity={roster_identity(p)}
          class="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-base-200"
        >
          <%!-- The roster is the authoritative who-is-present surface, and it
               is agent-inclusive by construction (`roster_identity/1` mints
               `agent:<id>` keys). It drew `roster_initial/1` — its own
               bitstring-pattern initial helper — over a flat circle for every
               kind. `build_meeting_participants/1` has carried `:avatar_url`
               for both kinds all along, resolved for agents off the preloaded
               `%Agent{}`. --%>
          <.agent_avatar
            :if={roster_agent?(p)}
            name={roster_name(p)}
            avatar_url={Map.get(p, :avatar_url)}
            size="sm"
            class="flex-shrink-0"
          />
          <.human_avatar
            :if={!roster_agent?(p)}
            name={roster_name(p)}
            avatar_url={Map.get(p, :avatar_url)}
            seed={roster_identity(p)}
            size="sm"
            class="flex-shrink-0"
          />
          <span class="min-w-0 truncate text-sm">{roster_name(p)}</span>
          <%!-- Per-identity media slot: meeting_client.js may attach the
               live <video>/<audio> here by identity without the LV ever
               wiping it (phx-update="ignore" on this leaf). --%>
          <span
            id={"#{@id}-media-#{roster_identity(p)}"}
            data-media-slot
            data-identity={roster_identity(p)}
            phx-update="ignore"
            class="ml-auto flex-shrink-0"
          >
          </span>
        </li>
      </ul>
    </div>
    """
  end

  # Stable LiveKit-style identity (`user:<id>` / `agent:<id>`) for a roster
  # view-model row — the same key MeetingHooks.do_join mints and the media
  # tiles attach by, so the roster row and its live track reconcile.
  defp roster_identity(%{participant_type: type, participant_id: id})
       when is_binary(type) and is_binary(id),
       do: "#{type}:#{id}"

  defp roster_identity(%{id: id}) when is_binary(id), do: id
  defp roster_identity(_), do: nil

  # The authoritative display name. Never the literal "User": an
  # unresolved identity (nil display_name) is honestly "Unknown participant".
  defp roster_name(%{display_name: name}) when is_binary(name) and name != "" and name != "User",
    do: name

  defp roster_name(_), do: "Unknown participant"

  # `roster_initial/1` lived here — a bitstring-pattern initial helper that the
  # usual `String.first` greps never found. Both kinds now render the shared
  # avatar components, which derive the initial themselves.
  defp roster_agent?(%{participant_type: "agent"}), do: true
  defp roster_agent?(_), do: false

  @doc """
  Soundboard icon + hover/focus popover showing the 1–8 key mappings and
  the per-user mute toggle. The MeetingSoundboard JS hook queries
  `[data-soundboard-mute]` checkboxes and `[data-soundboard-toasts]`
  containers — this component renders them; the hook owns behavior.
  """
  attr(:id, :string, required: true)

  def soundboard_menu(assigns) do
    ~H"""
    <div id={@id} class="group relative">
      <button
        type="button"
        class="btn btn-ghost btn-xs"
        aria-label="Soundboard — keyboard mappings and mute toggle"
      >
        <span class="hero-musical-note size-4"></span>
      </button>
      <div class="hidden group-hover:block group-focus-within:block absolute top-full right-0 mt-1 w-56 bg-base-200 border border-edge rounded-lg p-3 shadow-lg z-20">
        <p class="text-xs font-semibold mb-2 text-base-content/70">
          Press 1–7 during a call
        </p>
        <div class="grid grid-cols-[auto_1fr] gap-x-2 gap-y-1 text-xs items-center">
          <kbd class="kbd kbd-xs">1</kbd><span>Gong</span>
          <kbd class="kbd kbd-xs">2</kbd><span>Air horn</span>
          <kbd class="kbd kbd-xs">3</kbd><span>Applause</span>
          <kbd class="kbd kbd-xs">4</kbd><span>Crickets</span>
          <kbd class="kbd kbd-xs">5</kbd><span>Faahh</span>
          <kbd class="kbd kbd-xs">6</kbd><span>Shocked</span>
          <kbd class="kbd kbd-xs">7</kbd><span>Suspense</span>
        </div>
        <label class="mt-3 pt-2 border-t border-edge flex items-center gap-2 text-xs cursor-pointer">
          <input
            type="checkbox"
            class="checkbox checkbox-xs"
            data-soundboard-mute
          /> Mute incoming sounds
        </label>
      </div>
    </div>
    """
  end

  @doc "Full-screen image lightbox (click to dismiss)."
  attr(:url, :string, default: nil)

  def image_lightbox(assigns) do
    ~H"""
    <div
      :if={@url}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
      phx-click="close_lightbox"
    >
      <button
        class="absolute top-4 right-4 z-10 rounded-full bg-black/50 p-2 text-white hover:bg-black/70 transition-colors safe-area-top"
        phx-click="close_lightbox"
        aria-label="Close"
      >
        <span class="hero-x-mark size-6"></span>
      </button>
      <img
        src={@url}
        class="max-h-[90vh] max-w-[95vw] rounded-lg object-contain shadow-2xl"
        phx-click="close_lightbox"
      />
    </div>
    """
  end

  @doc "Format an upload error atom for display (shared by the dialog and inline compose errors)."
  def upload_error_to_string(:too_large), do: "File is too large"
  def upload_error_to_string(:too_many_files), do: "Too many files selected"
  def upload_error_to_string(:not_accepted), do: "File type is not accepted"
  def upload_error_to_string(error), do: inspect(error)
end
