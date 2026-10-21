defmodule PlatformWeb.ChatLive.Partials.Overlays do
  @moduledoc """
  The top-level overlay layer of the chat template — the reaction picker,
  the long-press quick-reaction pill, the edit-removal warning dialog, the
  message-actions bottom sheet and the junk-batch confirmation modal.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail`,
  `ChatLive.Partials.Rail`, `ChatLive.Partials.MobileBrowser`,
  `ChatLive.Partials.Conversation` and `ChatLive.Partials.Composer`
  (ADR 0035): function components, no state, each taking a declared set
  of attrs. Extracted from `chat_live.html.heex` in task 01a0312e stage 7
  as a PURE MOVE — every `id`, `class`, `role`, `aria-*`, `data-*`,
  `phx-hook`, `phx-click`, `phx-window-keydown` and `phx-key` sits on the
  element it sat on before, and every `:if` travelled WITH its element.

  The regions, in template order:

    * `reaction_picker/1` — `#reaction-picker`, including
      `.reaction-picker-grid`
    * `longpress_pill/1` — `#longpress-menu`, the `MessageLift` hook host
      and `.longpress-pill`
    * `edit_removal_warning/1` — `#edit-removal-warning`
    * `message_actions_sheet/1` — the `<.sheet>` with
      `#message-actions-sheet`
    * `junk_batch_modal/1` — `#junk-batch-modal`

  ## WHAT DELIBERATELY DID NOT MOVE

  The three `<.live_component>` calls (settings, new channel, new
  conversation), `<.row_actions_sheet>` / `<.row_actions_dialog>`,
  `<.image_lightbox>`, the `ChatScrollToMessage` anchor,
  `chat_version_history`, `<.schedule_delete_modal>`,
  `<.move_to_org_picker>` / `<.move_to_org_dialog>` and
  `<.archive_undo_toast>` all stay at the template root. They are already
  components; re-wrapping one in a function component adds a layer and
  changes nothing a reader wants changed.

  ## NO COMPONENT HERE MAY ADD A WRAPPER ELEMENT

  Every overlay in this module is `position: fixed` with an `inset-0`
  scrim and a `z-50` stacking context, and `#longpress-menu` is read from
  JS by id (`MessageLift` / `LongpressMenu`). Each component renders the
  MOVED element as its template root, so `<.longpress_pill ... />` emits
  `#longpress-menu` as a direct child of the template root exactly as the
  inline markup did.

  ## THE BESPOKE CSS CLASSES ARE LOAD-BEARING

  `reaction-picker`, `reaction-picker-scrim`, `reaction-picker-panel`,
  `reaction-picker-header`, `reaction-picker-body`, `reaction-picker-sr`,
  `reaction-picker-search`, `reaction-picker-search-icon`,
  `reaction-picker-search-input`, `reaction-picker-search-clear`,
  `reaction-picker-modebar`, `reaction-picker-jumpbar`,
  `reaction-picker-chip`, `reaction-picker-count`,
  `reaction-picker-scroll`, `reaction-picker-inventory`,
  `reaction-picker-results`, `reaction-picker-empty`,
  `reaction-picker-section`, `reaction-picker-category`,
  `reaction-picker-grid`, `reaction-picker-row`, `reaction-picker-tile`,
  `reaction-picker-skeleton-tile`, `reaction-picker-error`,
  `reaction-picker-error-text`, `reaction-picker-retry`,
  `reaction-picker-close`, `longpress-scrim`, `longpress-pill`,
  `longpress-pill-btn`, `longpress-pill-divider` and `longpress-pill-more`
  are hand-written in `assets/css/app.css`, not Tailwind utilities.
  Tailwind's content scan covers `lib/**/*.ex` as well as `*.heex`, so the
  move does not change what is generated — but the class strings are
  byte-identical here for that reason, and must stay that way.

  Everything from `reaction-picker-sr` down is emitted by
  `assets/js/hooks/reaction_picker.js` and
  `assets/js/lib/emoji_picker_chrome.js`, not by this module — INCLUDING THE
  SEARCH FIELD (task 019e0814 stage 4). The field is deliberately not
  server-rendered: a LiveView-owned input would have its `value` re-synced by
  morphdom on every patch, so anyone posting a message in the space would wipe
  what the user had typed mid-search. It carries no `phx-change` either, for
  the same reason the grid is client-built — matching runs over an inventory
  the client already holds, and a round trip per keystroke is what the
  superseded ticket 019e0814-dba5-7e74-84cd-e48e6689f44d proposed. The tile's
  hover and focus treatment is folded INTO `.reaction-picker-tile` rather
  than composed from `hover:bg-base-200 transition-colors` at the call
  site: a class string built inside a JS template literal is one Tailwind
  scan away from disappearing, and the tile is the element here that
  cannot afford that (task 019e0814 stage 3).
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS

  attr(:reaction_picker_for, :any, required: true)

  @doc """
  The add-reaction picker.

  ## IT IS ALWAYS MOUNTED NOW, AND THAT IS THE WHOLE HAZARD

  `#reaction-picker` used to carry `:if={@reaction_picker_for}`, so the
  whole overlay left the DOM when closed. It cannot any more: the grid is
  built once by a JS hook and must survive a close (task 019e0814 stage
  3), so the container is permanently in the document and open/closed is
  STATE on it.

  What that puts permanently in the DOM is a full-viewport `inset-0`
  scrim carrying `phx-click="close_reaction_picker"`. Get the closed gate
  wrong and you ship an invisible click-eater over the entire chat
  surface: every message stops responding to clicks and NOTHING LOOKS
  WRONG. Three things gate it, all derived from the same assign so they
  cannot disagree:

    * `data-open` — the CSS gate. `app.css` sets `.reaction-picker
      { display: none }` and shows it only on `[data-open="true"]`. The
      old rule was an unconditional `display: flex`, which is exactly the
      shape that would have shipped the click-eater.
    * `inert` when closed — a second, independent layer. Even if a future
      CSS change made the container visible while closed, an inert
      subtree takes no pointer events and no focus.
    * `phx-window-keydown` only while open — a window binding that
      survived the close would push `close_reaction_picker` on every
      Escape anywhere in chat, one wasted round trip per press.

  `assets/test/reaction_picker_closed_gate_test.mjs` pins the CSS half;
  `chat_live_test.exs` pins the markup half. End-to-end case 3 exists to
  catch the click-eater in a browser.

  ## THE LAYERING

  This element stays LIVEVIEW-OWNED: the server drives `data-open` and
  `data-message-id`. `#reaction-picker-body` is the hook's
  `phx-update="ignore"` host and ships EMPTY — nothing server-rendered
  inside it would ever update again, which is the bug filed as task
  01a0693d against the transcript pane. The hook keeps all of its own
  state on that host and never writes an attribute back to this element,
  because morphdom re-syncs attributes on every patch and chat patches
  constantly.
  """
  def reaction_picker(assigns) do
    ~H"""
    <%!--
      Reaction picker — bottom sheet on mobile, centered modal on desktop.
      Shape is controlled by the `reaction-picker` CSS class: below the
      640px breakpoint the panel slides up from the bottom with safe-area
      padding (matches iOS/Android conventions); above it centers as a
      modal card. Escape key closes via phx-window-keydown so keyboard
      users have parity with backdrop click.
    --%>
    <div
      id="reaction-picker"
      class="reaction-picker fixed inset-0 z-50"
      data-open={if @reaction_picker_for, do: "true", else: "false"}
      data-message-id={@reaction_picker_for}
      inert={is_nil(@reaction_picker_for)}
      phx-window-keydown={if @reaction_picker_for, do: "close_reaction_picker"}
      phx-key="Escape"
    >
      <div
        class="reaction-picker-scrim absolute inset-0 bg-base-content/20"
        phx-click="close_reaction_picker"
        aria-hidden="true"
      >
      </div>
      <%!--
        `aria-modal="true"` is now honest: the hook traps Tab and
        Shift+Tab inside this panel, gives the grid a roving tabindex so
        the focusable set is about three elements rather than ~1,850, and
        restores focus to the control that opened the picker on close.
        The deferral this comment used to record ("full focus management
        lands in PR B") was that PR. `tabindex="-1"` makes the panel the
        initial focus target on open, which is what MOBILE keeps: the hook
        moves initial focus to the search field only on a fine pointer at
        640px and up, because raising a soft keyboard unbidden collapses
        the grid to two rows before the user has asked to search.
      --%>
      <div
        class="reaction-picker-panel border border-edge bg-base-100 p-3 shadow-xl"
        role="dialog"
        aria-modal="true"
        aria-label="Add reaction"
        tabindex="-1"
      >
        <div class="reaction-picker-header mb-2 flex items-center justify-between">
          <span class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Add reaction
          </span>
          <button
            type="button"
            phx-click="close_reaction_picker"
            title="Close"
            aria-label="Close reaction picker"
            class="reaction-picker-close rounded p-1 text-subtle hover:bg-base-content/5 hover:text-base-content"
          >
            <span class="hero-x-mark size-5"></span>
          </button>
        </div>
        <%!--
          THE HOOK'S HOST. It ships empty and MUST stay empty: under
          `phx-update="ignore"` anything server-rendered in here is frozen
          at first render and can never be updated again. The hook builds
          `.reaction-picker-scroll` and the categorised grid inside it on
          first open, from the emoji island, and reuses them for the
          lifetime of the page.
        --%>
        <div
          id="reaction-picker-body"
          class="reaction-picker-body"
          phx-hook="ReactionPicker"
          phx-update="ignore"
        >
        </div>
      </div>
    </div>
    """
  end

  attr(:longpress_menu_for, :any, required: true)
  attr(:quick_emojis, :list, required: true)

  @doc """
  The mobile double-tap quick-react pill.

  The emoji come from `@quick_emojis` — the same assign the desktop hover
  action row and the message-actions sheet render, sourced from
  `Platform.Chat.Emoji.quick_defaults/0` (task 019e0814 stage 2). This markup
  used to carry its own six-emoji `~w()` literal, which is how this surface
  came to offer six while the other two offered four. Do not put a literal
  back; if the set is wrong, change `quick_defaults/0`.
  """
  def longpress_pill(assigns) do
    ~H"""
    <%!--
      Quick-react popover (mobile). Triggered by double-tap on a message
      authored by someone else — see the `LongpressMenu` JS hook, which
      despite the legacy name now listens for a double-tap gesture rather
      than a 450ms hold. Scrim + blur fade in, target message clones and
      animates to viewport center via `MessageLift`, and the emoji pill
      floats above the lifted clone. Pill position is driven by
      `--clone-half-h`, set by the hook at mount. The historical action
      card (Copy / Open in thread / Pin) was removed: Copy duplicated the
      browser's native selection menu on mobile, and Pin was frequently
      triggered by accident. Thread-open is deferred to a follow-up UX
      pass; desktop still exposes both via the hover action bar.
    --%>
    <div
      :if={@longpress_menu_for}
      id="longpress-menu"
      class="fixed inset-0 z-50"
      role="dialog"
      aria-label="Message actions"
      data-target-message-id={@longpress_menu_for}
      phx-hook="MessageLift"
    >
      <div
        class="absolute inset-0 longpress-scrim"
        phx-click="close_longpress_menu"
        aria-hidden="true"
      >
      </div>

      <%!-- Emoji quick-react pill, floats above the lifted clone.
           Each tap fires `react` (persists the reaction via Chat.toggle_reaction
           → close_picker/1 closes both reaction_picker_for and longpress_menu_for). --%>
      <div class="longpress-pill" role="group" aria-label="Quick reactions">
        <button
          :for={emoji <- @quick_emojis}
          type="button"
          class="longpress-pill-btn"
          title={"React with #{emoji}"}
          phx-click="react"
          phx-value-message-id={@longpress_menu_for}
          phx-value-emoji={emoji}
        >
          {emoji}
        </button>
        <div class="longpress-pill-divider" aria-hidden="true"></div>
        <button
          type="button"
          class="longpress-pill-btn longpress-pill-more"
          title="More emoji"
          aria-label="More emoji"
          phx-click={
            JS.push("open_reaction_picker", value: %{"message-id" => @longpress_menu_for})
            |> JS.push("close_longpress_menu")
          }
        >
          <span class="hero-plus size-4"></span>
        </button>
      </div>
    </div>
    """
  end

  attr(:pending_save_edit, :any, required: true)

  @doc """
  The edit-removal confirmation dialog.
  """
  def edit_removal_warning(assigns) do
    ~H"""
    <%!-- Removal-warning modal (task 019e0f29 Stage 5, contract Section F.4
         Policy 4). Surfaces only when the user's edit shortens / removes
         content. Copy locked in by the designer on 2026-05-11 review round 1:
         terse, factual, no editorial. Buttons: Cancel (keeps editor open
         with the user's draft) / Edit anyway (fires the actual edit). --%>
    <div
      :if={@pending_save_edit}
      id="edit-removal-warning"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      phx-window-keydown="cancel_save_edit"
      phx-key="escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="edit-removal-warning-title"
        class="w-full max-w-md rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-xl"
      >
        <h2 id="edit-removal-warning-title" class="text-base font-semibold text-base-content">
          Edit removes text.
        </h2>
        <p class="mt-2 text-sm text-base-content">
          Agents that already read this still have the original in their memory.
        </p>
        <div class="mt-4 flex items-center justify-end gap-2">
          <button
            type="button"
            phx-click="cancel_save_edit"
            class="rounded-md px-3 py-1.5 text-sm text-base-content hover:bg-base-300 hover:text-base-content transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_save_edit"
            class="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Edit anyway
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:open_message_actions_id, :any, required: true)
  attr(:open_message_actions_msg, :any, required: true)
  attr(:current_participant, :any, required: true)
  attr(:quick_emojis, :list, required: true)
  attr(:agent_participant_ids, :any, default: MapSet.new())

  @doc """
  The per-message actions bottom sheet.

  Its explanatory comment block sat ABOVE the `ChatScrollToMessage`
  listener in `chat_live.html.heex`, six unrelated elements away from the
  `<.sheet>` it describes — earlier edits inserted markup between them.
  The comment travelled here, with the markup it documents; nothing was
  deleted.
  """
  def message_actions_sheet(assigns) do
    ~H"""
    <%!-- Per-message actions sheet (task 019e0f29 Stage 3 — fixes the designer's bug
         report that the chat-message 3-dot dropdown didn't open on touch).
         Single Sheet at the page bottom, sourced by :open_message_actions_id;
         same pattern as the per-row task-actions sheet from Task 05 Stage 2.

         Actions are the chat-message hover-toolbar's text-able actions
         (Copy / Pin / Reply). Quick-emoji react row + reaction picker are
         deferred — they'd need their own design beyond a simple action list.
         The Edit item lands in Stage 4 once the editable-messages contract
         ships. --%>
    <.sheet
      :if={@open_message_actions_id}
      id="message-actions-sheet"
      open={true}
      placement={:bottom}
      on_close="close_message_actions"
    >
      <:title>Message actions</:title>
      <div class="flex flex-col gap-1">
        <%!-- "What this message is answering" (task 01a0d8de stage 3). The
             first row, on agent messages only, with or without context of
             their own: the panel shows the agent's context when there is
             some and generates a summary when there is not. It closes this
             sheet first, so exactly one sheet is ever open. --%>
        <button
          :if={
            @open_message_actions_msg &&
              MapSet.member?(@agent_participant_ids, @open_message_actions_msg.participant_id)
          }
          type="button"
          data-role="message-actions-context"
          phx-click={
            Phoenix.LiveView.JS.push("close_message_actions")
            |> Phoenix.LiveView.JS.push("open_message_context",
              value: %{"message-id" => @open_message_actions_id}
            )
          }
          class="flex items-center gap-3 rounded-lg px-4 py-3 text-left text-base-content hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span class="hero-arrow-up-right size-5 text-base-content" aria-hidden="true"></span>
          <span class="font-medium">What this message is answering</span>
        </button>
        <div
          :if={
            @open_message_actions_msg &&
              MapSet.member?(@agent_participant_ids, @open_message_actions_msg.participant_id)
          }
          class="border-t border-edge"
          aria-hidden="true"
        >
        </div>
        <%!-- Quick-reaction strip (task 01a000c0 stage 1).

             WHY A STRIP AND NOT AN "Add reaction…" MENU ROW: design canvas
             01a000c4-5bd3-795c-b982-acbb9488e5f8 (ADR-0046) cut the menu row.
             On touch there is no hover, so the always-visible dashed "+" is
             today the only add-reaction path on a phone — a single tap. A menu
             row would turn that one tap into four (double-tap, read the menu,
             tap the row, wait for the picker, tap an emoji). One tap here has
             to stay one tap.

             EMOJI SET: @quick_emojis, the same assign the desktop hover action
             row and the double-tap longpress pill render, so pointer and touch
             cannot drift. That claim was FALSE when it was written: the
             longpress pill 150 lines above carried its own six-emoji `~w()`
             while this assign held four. Task 019e0814 stage 2 collapsed all
             three onto `Platform.Chat.Emoji.quick_defaults/0`. Do not hardcode
             a literal list here; if the set is wrong, change quick_defaults/0.

             THE "+" IS IN THIS ROW, NOT A ROW OF ITS OWN: the product ruling —
             "the reaction should be next to the other emojis as a + sign; when
             you hit that you get the other options". The desktop hover action
             row renders these same @quick_emojis beside its own "+", so touch
             and pointer end up the same shape and the same gesture. A labelled
             "More reactions…" menu row on one surface and a glyph on the other
             would be two ways to do one thing. The "+" is an additional
             CONTROL, never an entry in the assign — which is why the tests
             count the emoji and the "+" separately rather than asserting a
             single total.

             SIZING: 44x44 hit targets (size-11), the vertical hairline before
             the "+", and the "+"'s own base-200 fill / scale-on-press are
             borrowed from the orphaned .longpress-pill, .longpress-pill-divider
             and .longpress-pill-more treatment in app.css rather than
             reinvented. --%>
        <div
          id="message-actions-quick-reactions"
          class="flex items-center gap-1 px-1 pb-2"
          role="group"
          aria-label="Quick reactions"
        >
          <button
            :for={emoji <- @quick_emojis}
            type="button"
            aria-label={"React with #{emoji}"}
            title={"React with #{emoji}"}
            phx-click={
              Phoenix.LiveView.JS.push("react")
              |> Phoenix.LiveView.JS.push("close_message_actions")
            }
            phx-value-message-id={@open_message_actions_id}
            phx-value-emoji={emoji}
            class="flex size-11 shrink-0 items-center justify-center rounded-lg text-2xl leading-none text-base-content hover:bg-base-200 active:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            {emoji}
          </button>
          <%!-- Hairline before the "+", matching .longpress-pill-divider (1px x
               24px on --color-base-300). It says the "+" is a different KIND of
               target from the emoji beside it — one opens the picker, the
               others react — without pulling it out of the row. --%>
          <div class="h-6 w-px shrink-0 bg-base-300" aria-hidden="true"></div>
          <%!-- Escape hatch for anything outside @quick_emojis. Same event chain
               the deleted "More reactions…" row used: open the existing
               #reaction-picker, then close this sheet. Filled on --color-base-200
               with a press-scale rather than a press-fill (borrowed verbatim from
               .longpress-pill-more / .longpress-pill-btn:active), because at rest
               it already carries that fill. No --color-primary: an add-reaction
               control is not an action to advertise. --%>
          <button
            type="button"
            id="message-actions-more-reactions"
            aria-label="More reactions"
            title="More reactions"
            phx-click={
              Phoenix.LiveView.JS.push("open_reaction_picker",
                value: %{"message-id" => @open_message_actions_id}
              )
              |> Phoenix.LiveView.JS.push("close_message_actions")
            }
            class="flex size-11 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content transition-transform active:scale-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            <span class="hero-plus size-5"></span>
          </button>
        </div>
        <div class="border-t border-edge" aria-hidden="true"></div>
        <button
          type="button"
          phx-click={
            Phoenix.LiveView.JS.push("toggle_inline_thread",
              value: %{"message-id" => @open_message_actions_id}
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class="flex items-center gap-3 rounded-lg px-4 py-3 text-left text-base-content hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span class="hero-chat-bubble-left-right size-5 text-base-content"></span>
          <span class="font-medium">Reply in thread</span>
        </button>
        <button
          id="message-actions-pin"
          type="button"
          phx-click={
            Phoenix.LiveView.JS.push("pin_toggle",
              value: %{
                "message-id" => @open_message_actions_id,
                "space-id" => @open_message_actions_msg && @open_message_actions_msg.space_id
              }
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class="flex items-center gap-3 rounded-lg px-4 py-3 text-left text-base-content hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span class="hero-bookmark size-5 text-base-content"></span>
          <span class="font-medium">Pin / Unpin</span>
        </button>
        <%!-- Edit affordance — Policy 3 of the editable-messages contract
             (own non-agent text messages only). The message struct is lifted
             into @open_message_actions_msg by the open_message_actions
             handler so the visibility filter can be evaluated at template
             render time. The hover-pencil affordance on the chat row was
             removed in task 019e2452; this sheet item is now the SOLE edit
             entry point on all viewports. --%>
        <button
          :if={
            @open_message_actions_msg && @current_participant &&
              @open_message_actions_msg.participant_id == @current_participant.id &&
              @open_message_actions_msg.content_type == "text"
          }
          type="button"
          phx-click={
            Phoenix.LiveView.JS.push("edit_message_clicked",
              value: %{"message-id" => @open_message_actions_id}
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class="flex items-center gap-3 rounded-lg px-4 py-3 text-left text-base-content hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span class="hero-pencil-square size-5 text-base-content"></span>
          <span class="font-medium">Edit message</span>
        </button>
      </div>
    </.sheet>
    """
  end

  attr(:show_junk_batch_modal, :boolean, required: true)
  attr(:junk_batch_target, :any, required: true)

  @doc """
  The junk-batch rollback confirmation modal.
  """
  def junk_batch_modal(assigns) do
    ~H"""
    <%!-- Junk-batch confirmation modal (M5b/019f6e2c stage 4). Opened by
         `PlatformWeb.ChatLive.CanvasHooks` when a `junk_batch:*` canvas
         action_row is clicked; closed by `close_junk_batch_modal` or the
         backdrop. Shape mirrors the tasks-live `#reopen-modal` (mobile-first
         bottom-sheet, centered dialog on sm+). Empty-batch guard: when
         `preview_count == 0`, the destructive button is hidden entirely
         and only Close remains — that IS the acceptance-criterion-5
         empty-state affordance. --%>
    <div
      :if={@show_junk_batch_modal && @junk_batch_target}
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      id="junk-batch-modal"
      data-role="junk-batch-modal"
    >
      <%!-- Backdrop --%>
      <div class="absolute inset-0 bg-black/40" phx-click="close_junk_batch_modal" />

      <%!-- Sheet / dialog --%>
      <div class="relative w-full max-w-lg rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)] max-h-[90vh] overflow-y-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between border-b border-edge px-4 py-3">
          <div class="min-w-0">
            <h2 class="text-base font-semibold">Roll back this batch</h2>
            <p class="mt-0.5 text-xs text-subtle">
              Meeting-triage rollback
            </p>
          </div>
          <button
            type="button"
            phx-click="close_junk_batch_modal"
            class="btn btn-sm btn-ghost btn-square"
            aria-label="Close"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </div>

        <%!-- Body --%>
        <div class="flex flex-col gap-3 px-4 py-4">
          <%= if @junk_batch_target.preview_count > 0 do %>
            <p class="text-sm text-base-content">
              This will soft-delete
              <span class="font-semibold" data-role="junk-batch-preview-count">
                {@junk_batch_target.preview_count}
              </span>
              {if @junk_batch_target.preview_count == 1, do: "task", else: "tasks"} filed from this canvas. Continue?
            </p>
          <% else %>
            <p class="text-sm text-base-content" data-role="junk-batch-empty-note">
              Nothing to roll back — every task from this batch has already been handled.
            </p>
          <% end %>

          <div class="flex items-center justify-end gap-2 pt-1">
            <button
              type="button"
              phx-click="close_junk_batch_modal"
              class="btn btn-ghost btn-sm"
            >
              Close
            </button>
            <button
              :if={@junk_batch_target.preview_count > 0}
              type="button"
              phx-click="confirm_junk_batch"
              class="btn btn-error btn-sm"
              data-role="junk-batch-confirm"
            >
              Junk {@junk_batch_target.preview_count} {if @junk_batch_target.preview_count == 1,
                do: "task",
                else: "tasks"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
