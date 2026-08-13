defmodule PlatformWeb.ChatLive.Partials do
  @moduledoc """
  Function components for self-contained render regions of ChatLive.

  See ADR 0035. These aren't LiveComponents (no state), they're just
  render splits — each takes a small set of attrs and produces markup.
  They keep `chat_live.html.heex` at a tractable size.

  Extracted here:
    * `notification_banner/1` — notification opt-in bar
    * `pin_control/1` — per-row pin / unpin control in the sidebar rail
    * `move_to_org_control/1` — admin "Move to organisation…" row control
    * `move_to_org_picker/1` — the destination chooser that control opens
    * `move_to_org_dialog/1` — the confirmation a chosen destination opens
    * `row_actions_control/1` — per-row overflow control in the mobile drawer
    * `row_actions_sheet/1` — the bottom sheet that control opens
    * `upload_dialog/1` — staging modal for attachments
    * `canvas_overlay/1` — active-canvas side panel + mobile full-screen
    * `meeting_panel/1` — in-meeting UI (desktop sidebar + mobile overlay)
    * `image_lightbox/1` — full-screen image viewer
  """

  use Phoenix.Component

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive.CanvasHooks

  @doc "Notification opt-in banner (when push permission is 'prompt')."
  attr(:push_permission, :string, required: true)

  def notification_banner(assigns) do
    ~H"""
    <div
      :if={@push_permission == "prompt"}
      class="flex items-center justify-between gap-3 border-b border-info/20 bg-info/10 px-4 py-2"
    >
      <p class="text-sm text-info">
        <span class="hero-bell-alert mr-1 inline-block h-4 w-4 align-text-bottom" />
        Enable notifications to get alerts when agents respond or you're mentioned.
      </p>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-info btn-sm flex-shrink-0"
      >
        Enable
      </button>
    </div>
    """
  end

  @doc """
  Pin / unpin control for one sidebar conversation row (task 019fd80f stage 3).

  Renders as a SIBLING of the row's navigate-link, never a child. A `<button>`
  nested in an `<a>` is invalid HTML, and LiveView binds click on `window` in
  the bubble phase, so a nested control needs a `stopPropagation` guard that
  swallows the event along with the navigation. This is the same shape the
  sub-org hide button and the task-pin unpin button already use.

  ## Visible at rest

  The control renders at rest on every row, at `--color-base-content` 60%,
  the same resting treatment the task row's unpin control already carries.
  It used to be `opacity-0` plus a hover/focus reveal.

  Two independent reasons it is visible now, from opposite directions:

    * Rowan asked for the always-visible shape on the Pin-to-Chat work ("a
      discoverable small pin icon next to the task"), which is why task rows
      have had it since that stage.
    * Marlowe, 2026-08-11: "when developing pinned channels, use similar
      interactions as what's used for pinned tasks (hover doesn't work on
      mobile)."

  Marlowe's half is the load-bearing one. Tailwind compiles `hover:` and
  `group-hover:` inside `@media (hover: hover)`, so on a touch device the
  reveal rule never matches at all. A hover-only control is not
  hard-to-reach there; it is unreachable. `focus-within:` answers the
  keyboard case and answers nothing for a finger.

  ONE treatment on every row, pinned or not. The only thing that varies with
  pinned-ness is the verb in the accessible name and the state the click
  posts. That was already true when the control was hover-revealed and it
  stays true now: an earlier revision gave pinned rows a permanent FILLED
  variant to mark the row's pinned state, which Marlowe removed on review ("No
  need to append a pin icon to pinned items. The section header is
  sufficient") because pinning LIFTS a conversation into the Pinned block, so
  the block is the state and a mark on every row in it distinguishes nothing.
  Visible-at-rest does not bring that back — same glyph, same colour, one
  code path.

  ## Width

  The control is `flex-shrink-0` and occupies its 24px on every row. The name
  keeps `flex-1 min-w-0 truncate` and the control never squeezes, so the icon
  cannot be crushed by a long display name and the name never loses space to
  it. The touch target is 44x44, taken from a hit-area pseudo-element rather
  than from the box, so the row keeps its height and the name keeps its
  width (see `.channel-row-pin-button` in app.css).

  ## Accessible name

  Carries the verb AND the target: "Pin Gen-migration", "Unpin Rowan
  Ellis". A bare "Pin" is meaningless in a list of twenty identical
  controls.
  """
  attr(:space_id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:pinned, :boolean, required: true)

  def pin_control(assigns) do
    ~H"""
    <button
      type="button"
      class="channel-row-pin-button"
      phx-click="toggle_pinned"
      phx-value-space_id={@space_id}
      phx-value-pinned={to_string(not @pinned)}
      data-role="pin-control"
      data-space-id={@space_id}
      aria-label={"#{if @pinned, do: "Unpin", else: "Pin"} #{@name}"}
      title={if @pinned, do: "Unpin", else: "Pin"}
    >
      <span class="hero-map-pin size-3.5"></span>
    </button>
    """
  end

  @doc """
  Fabrikam-admin "Move to organisation…" control for one channel row.

  ## Why this exists

  Refiling a channel used to be a drag between sidebar sections. That gesture
  is being retired (task 019fd76a stage 2) because it performs a company-wide
  write on a drop, with a consequence the gesture never states: canvas read
  follows org membership (`Chat.CanvasAccess.org_readable_space?/2`), so a
  move hands the destination org's members a direct link to this channel's
  canvases and takes it from the source org's. This control replaces it and
  becomes the ONLY reassignment path in the product.

  ## The row holds only the trigger

  The destination list is `move_to_org_picker/1`, a centred dialog rendered
  once at the top level of the template. It was built first as a popover
  hanging off this row, following the `lifecycle_menu/1` pattern, and that
  does not work here: `#chat-section-list` is `overflow-y-auto`, which
  computes `overflow-x` to `auto` too, so it clips on both axes. Measured on
  the running app, the popover on a lower row ran to 992px against a nav
  bottom of 810px, putting every destination out of reach, and on the sub-org
  rows it crossed the rail's left edge by about 9px and cut into the leading
  colour dots. The rail is roughly 224px wide, so no width fixes both.
  """
  attr(:space_id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:open, :boolean, default: false)

  def move_to_org_control(assigns) do
    ~H"""
    <div
      class={
        [
          "flex-shrink-0",
          # Revealed on row hover or keyboard focus, like the pin and hide
          # controls beside it — except while the chooser is open, when the
          # trigger must stay put even though the pointer has left the row.
          not @open && "opacity-0 focus-within:opacity-100 group-hover/row:opacity-100"
        ]
      }
      data-role="move-to-org"
    >
      <button
        type="button"
        id={"move-to-org-trigger-#{@space_id}"}
        class="channel-row-hide-button focus-visible-ring"
        phx-click="toggle_reassign_menu"
        phx-value-channel_id={@space_id}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open)}
        aria-controls="move-to-org-picker"
        aria-label={"Move ##{@name} to another organisation"}
        title="Move to organisation…"
        data-role="move-to-org-trigger"
      >
        <span class="hero-building-office-2 size-3.5"></span>
      </button>
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

  The touch counterpart to `pin_control/1`. That control, and the sub-org
  row's `.channel-row-hide-button`, are both revealed by `group-hover/row:` or
  `focus-within:`. Tailwind compiles `hover:` inside `@media (hover: hover)`,
  so on a phone neither variant ever matches and pin, unpin and hide have no
  touch path at all. This control is therefore ALWAYS visible — no `opacity-0`
  and no hover variant anywhere in its class list, which
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
      class="mr-2 flex min-h-11 min-w-11 flex-shrink-0 items-center justify-center rounded-lg text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
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
  `Components.MoreSheet` and `Components.Chat.AddParticipantSheet` wrap. No
  second sheet, no bespoke popover.

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
            class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-3 text-left text-base text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
            phx-click="toggle_pinned"
            phx-value-space_id={@target && @target.space_id}
            phx-value-pinned={@target && to_string(not @target.pinned)}
            data-role="row-actions-pin"
          >
            <span class="hero-map-pin size-5 flex-shrink-0" aria-hidden="true"></span>
            <span>
              {if @target && @target.pinned, do: "Unpin conversation", else: "Pin conversation"}
            </span>
          </button>
        </li>
        <li class="border-t border-base-300">
          <button
            type="button"
            class="flex min-h-11 w-full items-center gap-3 rounded-lg px-2 py-3 text-left text-base text-base-content transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
            phx-click="hide_channel"
            phx-value-id={@target && @target.space_id}
            data-role="row-actions-hide"
          >
            <span class="hero-eye-slash size-5 flex-shrink-0" aria-hidden="true"></span>
            <span>Hide from my rail</span>
          </button>
        </li>
      </ul>
    </.sheet>
    """
  end

  @doc "Upload staging dialog — drop zone, thumb grid, agent tag chips, caption, send."
  attr(:open, :boolean, required: true)
  attr(:active_space, :any, default: nil)
  attr(:uploads, :any, required: true)
  attr(:caption, :string, default: "")
  attr(:tagged_agents, :any, required: true)

  def upload_dialog(assigns) do
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
          :if={@uploads.attachments.entries == []}
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
          <div class="upload-dropzone-formats">
            PNG · JPG · GIF · WebP · SVG — max 15 MB each
          </div>
        </label>

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
        <div :if={@uploads.attachments.entries != []}>
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
              <strong>{length(@uploads.attachments.entries)}</strong>
              {if length(@uploads.attachments.entries) == 1, do: "image", else: "images"} selected
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
                  @uploads.attachments.entries == [] or
                    Enum.any?(
                      @uploads.attachments.entries,
                      &(&1.progress > 0 and &1.progress < 100)
                    )
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

  @doc "Active-canvas side panel (desktop) and full-screen overlay (mobile)."
  attr(:canvas, :any, default: nil)
  attr(:show_versions_panel, :boolean, default: false)
  attr(:canvas_versions, :list, default: [])
  attr(:restore_confirm_revision, :integer, default: nil)

  def canvas_overlay(assigns) do
    ~H"""
    <div
      :if={@canvas}
      id="canvas-sidebar"
      phx-hook="CanvasSidebarResize"
      class="hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100 relative"
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
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
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
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-panel" />
      </div>
      <.canvas_versions_panel
        :if={@show_versions_panel}
        canvas={@canvas}
        versions={@canvas_versions}
        restore_confirm_revision={@restore_confirm_revision}
      />
    </div>

    <div :if={@canvas} class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden safe-area-x">
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
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
        <.canvas_document canvas={@canvas} dom_id_base="chat-live-canvas-overlay" />
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
        "absolute inset-y-0 right-0 z-30 flex w-80 flex-col border-l border-base-300 bg-base-100 shadow-xl transition-transform",
        @mobile && "fixed top-12 bottom-[var(--bottom-nav-height,0px)]"
      ]}
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
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

  @doc "In-meeting UI — desktop side panel + mobile full-screen overlay."
  attr(:in_meeting, :boolean, required: true)
  attr(:active_space, :any, default: nil)
  attr(:mic_enabled, :boolean, required: true)
  attr(:camera_enabled, :boolean, required: true)
  attr(:screen_share_enabled, :boolean, required: true)
  attr(:meeting_participants, :list, default: [])

  def meeting_panel(assigns) do
    ~H"""
    <div
      :if={@in_meeting}
      id="meeting-panel"
      class="relative hidden lg:flex w-96 flex-shrink-0 flex-col border-l border-base-300 bg-base-100"
    >
      <div class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4">
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

      <div class="flex-1 overflow-y-auto p-3">
        <%!-- Screen-share preview (task 019e420f stage 3). JS owns
             these children — meeting_client.js attaches the live
             `<video>` here when a peer publishes a screen-share track,
             and toggles `hidden` based on the active state. Sits above
             the participants grid so it's never cropped by avatar
             tiles. `phx-update="ignore"` because the LV doesn't render
             the video element itself. --%>
        <div class="mb-2">
          <div
            data-quickmeet-screen-share-slot
            data-pane="desktop"
            data-screen-share-active="false"
            phx-update="ignore"
            id="meeting-screen-share-slot-desktop"
            class="hidden aspect-video w-full overflow-hidden rounded-lg bg-black"
          >
          </div>
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
        <.meeting_roster id="meeting-roster" participants={@meeting_participants} />
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants"
          phx-update="ignore"
          class="meeting-participant-grid gap-2"
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
        <div
          id="meeting-captions"
          phx-hook="MeetingCaptions"
          class="mt-2 rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 pointer-events-none transition-opacity duration-300"
        >
        </div>
      </div>

      <div class="flex items-center justify-center gap-2 border-t border-base-300 px-4 py-3">
        <button
          phx-click="meeting_toggle_mic"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@mic_enabled,
              do: "bg-base-200 hover:bg-base-300 text-base-content",
              else: "bg-error/20 text-error hover:bg-error/30"
            )
          ]}
          title={if @mic_enabled, do: "Mute microphone", else: "Unmute microphone"}
        >
          <span class={[
            "size-5",
            if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_camera"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@camera_enabled,
              do: "bg-base-200 hover:bg-base-300 text-base-content",
              else: "bg-error/20 text-error hover:bg-error/30"
            )
          ]}
          title={if @camera_enabled, do: "Turn off camera", else: "Turn on camera"}
        >
          <span class={[
            "size-5",
            if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
          ]}>
          </span>
        </button>
        <%!-- task 019e420f stage 2: client-side click handler. The
             gesture must reach `getDisplayMedia()` without yielding to
             the WebSocket; see `meeting_share_button.js`. --%>
        <button
          id="meeting-share-btn-desktop"
          phx-hook="MeetingShareButton"
          type="button"
          class={[
            "meeting-control-btn rounded-full p-2.5 transition-colors",
            if(@screen_share_enabled,
              do: "bg-primary/20 text-primary hover:bg-primary/30",
              else: "bg-base-200 hover:bg-base-300 text-base-content"
            )
          ]}
          title={if @screen_share_enabled, do: "Stop sharing screen", else: "Share screen"}
          data-role="meeting-share-button"
        >
          <span class="hero-computer-desktop size-5"></span>
        </button>
        <button
          phx-click="meeting_leave"
          class="meeting-control-btn rounded-full p-2.5 bg-error text-error-content hover:bg-error/80 transition-colors"
          title="Leave meeting"
        >
          <span class="hero-phone-x-mark size-5"></span>
        </button>
      </div>

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
      class="fixed inset-0 z-50 flex flex-col bg-base-100 lg:hidden safe-area-x"
    >
      <header class="flex h-12 flex-shrink-0 items-center justify-between border-b border-base-300 px-4 safe-area-top">
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

      <div class="flex-1 overflow-y-auto p-4">
        <%!-- Screen-share preview (task 019e420f stage 3). See the
             desktop variant for the rationale. --%>
        <div class="mb-2">
          <div
            data-quickmeet-screen-share-slot
            data-pane="mobile"
            data-screen-share-active="false"
            phx-update="ignore"
            id="meeting-screen-share-slot-mobile"
            class="hidden aspect-video w-full overflow-hidden rounded-lg bg-black"
          >
          </div>
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
        <.meeting_roster id="meeting-roster-mobile" participants={@meeting_participants} />
        <%!-- JS owns the children (meeting_client.js injects tiles); ignore on re-render --%>
        <div
          id="meeting-participants-mobile"
          phx-update="ignore"
          class="meeting-participant-grid gap-2"
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
        <div
          id="meeting-captions-mobile"
          phx-hook="MeetingCaptions"
          class="mt-2 rounded-lg bg-base-300/80 px-3 py-2 text-sm opacity-0 pointer-events-none transition-opacity duration-300"
        >
        </div>
      </div>

      <div class="flex items-center justify-center gap-3 border-t border-base-300 px-4 py-4 safe-area-bottom">
        <button
          phx-click="meeting_toggle_mic"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@mic_enabled,
              do: "bg-base-200 text-base-content",
              else: "bg-error/20 text-error"
            )
          ]}
        >
          <span class={[
            "size-6",
            if(@mic_enabled, do: "hero-microphone", else: "hero-microphone-slash")
          ]}>
          </span>
        </button>
        <button
          phx-click="meeting_toggle_camera"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@camera_enabled,
              do: "bg-base-200 text-base-content",
              else: "bg-error/20 text-error"
            )
          ]}
        >
          <span class={[
            "size-6",
            if(@camera_enabled, do: "hero-video-camera", else: "hero-video-camera-slash")
          ]}>
          </span>
        </button>
        <%!-- task 019e420f stage 2: client-side click handler — see
             the desktop variant above for the rationale. --%>
        <button
          id="meeting-share-btn-mobile"
          phx-hook="MeetingShareButton"
          type="button"
          class={[
            "meeting-control-btn rounded-full p-3 transition-colors",
            if(@screen_share_enabled,
              do: "bg-primary/20 text-primary",
              else: "bg-base-200 text-base-content"
            )
          ]}
          data-role="meeting-share-button"
        >
          <span class="hero-computer-desktop size-6"></span>
        </button>
        <button
          phx-click="meeting_leave"
          class="meeting-control-btn rounded-full p-3 bg-error text-error-content hover:bg-error/80 transition-colors"
        >
          <span class="hero-phone-x-mark size-6"></span>
        </button>
      </div>
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
          <span class="flex size-7 flex-shrink-0 items-center justify-center rounded-full bg-base-300 text-xs font-semibold uppercase">
            {roster_initial(p)}
          </span>
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

  defp roster_initial(p) do
    case roster_name(p) do
      <<first::utf8, _rest::binary>> -> String.upcase(<<first::utf8>>)
      _ -> "?"
    end
  end

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
      <div class="hidden group-hover:block group-focus-within:block absolute top-full right-0 mt-1 w-56 bg-base-200 border border-base-300 rounded-lg p-3 shadow-lg z-20">
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
        <label class="mt-3 pt-2 border-t border-base-300 flex items-center gap-2 text-xs cursor-pointer">
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
