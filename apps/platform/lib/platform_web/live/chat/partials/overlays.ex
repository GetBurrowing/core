defmodule PlatformWeb.ChatLive.Partials.Overlays do
  @moduledoc """
  The top-level overlay layer of the chat template — the reaction picker,
  the message-actions bottom sheet with its desktop popover, the reactors
  sheet, and the junk-batch confirmation modal.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail`,
  `ChatLive.Partials.Rail`, `ChatLive.Partials.ChatList`,
  `ChatLive.Partials.Conversation` and `ChatLive.Partials.Composer`
  (ADR 0035): function components, no state, each taking a declared set
  of attrs. Extracted from `chat_live.html.heex` in task 01a0312e stage 7
  as a PURE MOVE — every `id`, `class`, `role`, `aria-*`, `data-*`,
  `phx-hook`, `phx-click`, `phx-window-keydown` and `phx-key` sits on the
  element it sat on before, and every `:if` travelled WITH its element.

  The regions, in template order:

    * `reaction_picker/1` — `#reaction-picker`, including
      `.reaction-picker-grid`
    * `message_actions_sheet/1` — the `<.sheet>` with
      `#message-actions-sheet` and the desktop `#message-actions-popover`,
      both rendering `message_actions_content/1` (redesign rung 9 stage 2)
    * `reactors_sheet/1` — `#reactors-sheet` with the desktop
      `#reactors-popover`: who reacted with one emoji (redesign rung 9
      stage 3)
    * `message_attention_sheet/1` — `#message-attention-sheet` with the
      desktop `#message-attention-popover`: the "Get someone's attention"
      picker (redesign rung 12 stage 2)
    * `junk_batch_modal/1` — `#junk-batch-modal`

  ## WHAT DELIBERATELY DID NOT MOVE

  The three `<.live_component>` calls (settings, new channel, new
  conversation), `<.row_actions_sheet>` / `<.row_actions_dialog>`,
  `<ChatViewer.chat_viewer>`, the `ChatScrollToMessage` anchor,
  `chat_version_history`, `<.schedule_delete_modal>`,
  `<.move_to_org_picker>` / `<.move_to_org_dialog>` and
  `<.archive_undo_toast>` all stay at the template root. They are already
  components; re-wrapping one in a function component adds a layer and
  changes nothing a reader wants changed.

  ## NO COMPONENT HERE MAY ADD A WRAPPER ELEMENT

  Every overlay in this module is `position: fixed` with an `inset-0`
  scrim and a `z-50` stacking context. Each component renders the MOVED
  element as its template root, so `<.reaction_picker ... />` emits
  `#reaction-picker` as a direct child of the template root exactly as the
  inline markup did.

  The long-press quick-reaction pill that used to live here (and its lift
  hook) was deleted in redesign rung 9: nothing had opened it since the
  gesture became a double-tap. The tap pill that replaced it is per
  message, in `PlatformWeb.Components.ChatMessage`.

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
  and `reaction-picker-close` are hand-written in `assets/css/app.css`, not Tailwind utilities.
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

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

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
        fallback focus target; the hook focuses the search field on open
        on every device (direction canvas 01a1666e node m3 rule 5).
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
            Reactions
          </span>
          <button
            type="button"
            phx-click="close_reaction_picker"
            title="Close"
            aria-label="Close reaction picker"
            class="reaction-picker-close rounded p-1 text-subtle lg:hover:bg-base-200 lg:hover:text-base-content"
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

  attr(:open_message_actions_id, :any, required: true)
  attr(:open_message_actions_msg, :any, required: true)
  attr(:open_message_actions_mine, :any, default: MapSet.new())
  attr(:current_participant, :any, required: true)
  attr(:quick_emojis, :list, required: true)
  attr(:agent_participant_ids, :any, default: MapSet.new())
  attr(:pinned_message_ids, :any, default: MapSet.new())
  attr(:active_space, :any, default: nil)

  @doc """
  The per-message actions surface (redesign rung 9 stage 2; masters canvas
  01a1382f node `proto`, MM `stubMessageActions`, MD `messageActions`).

  ONE assign, two frames: the phone 'Message' bottom sheet (`lg:hidden`) and
  the desktop ⋯ popover (`hidden lg:block`, anchored to the message by the
  `MessageActionsPopover` hook, closed by click-away). Both render
  `message_actions_content/1`, so they cannot disagree about what a message
  offers. LiveView only fires `phx-click-away` on a VISIBLE element, so the
  popover's click-away never fires on a phone, where it is `display: none`.
  """
  def message_actions_sheet(assigns) do
    ~H"""
    <.sheet
      :if={@open_message_actions_id}
      id="message-actions-sheet"
      open={true}
      placement={:bottom}
      on_close="close_message_actions"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Message</:title>
      <p class="px-4 pb-2 text-base font-semibold text-base-content" aria-hidden="true">
        Message
      </p>
      <.message_actions_content
        id_prefix="message-actions"
        open_message_actions_id={@open_message_actions_id}
        open_message_actions_msg={@open_message_actions_msg}
        open_message_actions_mine={@open_message_actions_mine}
        current_participant={@current_participant}
        quick_emojis={@quick_emojis}
        agent_participant_ids={@agent_participant_ids}
        pinned_message_ids={@pinned_message_ids}
        active_space={@active_space}
      />
    </.sheet>
    <div
      :if={@open_message_actions_id}
      id="message-actions-popover"
      role="dialog"
      aria-label="Message"
      tabindex="-1"
      phx-hook="MessageActionsPopover"
      phx-click-away="close_message_actions"
      phx-window-keydown="close_message_actions"
      phx-key="Escape"
      data-anchor-message-id={@open_message_actions_id}
      class="fixed left-1/2 top-24 z-40 hidden w-80 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-1.5 shadow-lg focus:outline-none lg:block"
    >
      <.message_actions_content
        id_prefix="message-actions-popover"
        open_message_actions_id={@open_message_actions_id}
        open_message_actions_msg={@open_message_actions_msg}
        open_message_actions_mine={@open_message_actions_mine}
        current_participant={@current_participant}
        quick_emojis={@quick_emojis}
        agent_participant_ids={@agent_participant_ids}
        pinned_message_ids={@pinned_message_ids}
        active_space={@active_space}
      />
    </div>
    """
  end

  # Shared by every row: 48px on a phone with a pressed fill, a hover fill on
  # desktop only (`lg:hover:`; the phone has no hover), never primary.
  @row_class "flex min-h-12 w-full items-center gap-3 rounded-box px-3 text-left text-[15px] text-base-content active:bg-base-200 lg:min-h-9 lg:hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"

  attr(:id_prefix, :string, required: true)
  attr(:open_message_actions_id, :any, required: true)
  attr(:open_message_actions_msg, :any, required: true)
  attr(:open_message_actions_mine, :any, required: true)
  attr(:current_participant, :any, required: true)
  attr(:quick_emojis, :list, required: true)
  attr(:agent_participant_ids, :any, required: true)
  attr(:pinned_message_ids, :any, required: true)
  attr(:active_space, :any, required: true)

  @doc """
  The rows of the actions surface, in the masters' order: the message
  preview, the quick strip (the six `@quick_emojis` + ＋), Reply in thread,
  Get someone's attention (every message; rung 12), What this is answering (agent messages only), Pin or Unpin message, Copy
  text, Copy link, and Edit / Delete on the viewer's own messages.

  Copy text and Copy link are client-side (`MessageActionsCopy`): the row
  carries `data-clipboard-text` and the toast copy in `data-copy-toast`.
  Copy link is the ABSOLUTE deep link `ChatLive.resolve_deep_link_anchor/3`
  resolves. Delete asks with the native confirm before `delete_message`,
  which re-checks the author on the server.
  """
  def message_actions_content(assigns) do
    msg = assigns.open_message_actions_msg
    viewer = assigns.current_participant
    agent? = msg != nil and MapSet.member?(assigns.agent_participant_ids, msg.participant_id)
    own? = msg != nil and viewer != nil and msg.participant_id == viewer.id and not agent?

    assigns =
      assigns
      |> assign(:row_class, @row_class)
      |> assign(:agent?, agent?)
      |> assign(:own?, own?)
      |> assign(:editable?, own? and msg.content_type == "text")
      |> assign(
        :pinned?,
        MapSet.member?(assigns.pinned_message_ids, assigns.open_message_actions_id)
      )
      |> assign(:text, (msg && msg.content) || "")
      |> assign(:link, message_link(assigns.active_space, assigns.open_message_actions_id))

    ~H"""
    <div
      id={"#{@id_prefix}-content"}
      class="flex flex-col"
      phx-hook="MessageActionsCopy"
      data-actions-message-id={@open_message_actions_id}
    >
      <p
        data-role="message-actions-preview"
        class="mx-1 mb-2 line-clamp-2 break-words rounded-box border border-edge bg-base-200 px-3 py-2 text-[13px] text-subtle"
      >
        {@text}
      </p>
      <%!-- The quick strip. Its set is `@quick_emojis`, the one assign the tap
           pill's thumbs-up also reads; change `Emoji.quick_defaults/0`, never
           a literal here. The ＋ is a CONTROL, not a seventh emoji: it opens
           the existing picker. 'Mine' (the viewer already reacted) is a
           neutral raised fill with a base-content ring, never primary. --%>
      <div
        id={"#{@id_prefix}-quick-reactions"}
        class="flex items-center justify-between gap-1 px-1 pb-2"
        role="group"
        aria-label="Quick reactions"
      >
        <button
          :for={emoji <- @quick_emojis}
          type="button"
          aria-label={"React with #{Platform.Chat.Emoji.quick_name(emoji)}"}
          aria-pressed={to_string(MapSet.member?(@open_message_actions_mine, emoji))}
          data-mine={MapSet.member?(@open_message_actions_mine, emoji) && "true"}
          phx-click={
            Phoenix.LiveView.JS.push("react")
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          phx-value-message-id={@open_message_actions_id}
          phx-value-emoji={emoji}
          class={[
            "flex size-11 shrink-0 items-center justify-center rounded-full lg:size-9 text-2xl leading-none text-base-content transition-transform lg:text-xl active:scale-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring",
            if(MapSet.member?(@open_message_actions_mine, emoji),
              do: "bg-base-300 ring-1 ring-base-content",
              else: "bg-base-200"
            )
          ]}
        >
          {emoji}
        </button>
        <button
          type="button"
          id={"#{@id_prefix}-more-reactions"}
          aria-label="More reactions"
          phx-click={
            Phoenix.LiveView.JS.push("open_reaction_picker",
              value: %{"message-id" => @open_message_actions_id}
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class="flex size-11 shrink-0 items-center justify-center rounded-full lg:size-9 bg-base-200 text-xl leading-none text-base-content transition-transform active:scale-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span aria-hidden="true">＋</span>
        </button>
      </div>
      <div class="mx-1 border-t border-edge" aria-hidden="true"></div>
      <div class="flex flex-col pt-1" data-role="message-actions-rows">
        <button
          type="button"
          data-role="message-actions-reply"
          phx-click={
            Phoenix.LiveView.JS.push("open_inline_thread",
              value: %{"message-id" => @open_message_actions_id}
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class={@row_class}
        >
          <.icon name="hero-arrow-uturn-left" class="size-5 shrink-0 text-subtle" />
          <span data-role="message-actions-label">Reply in thread</span>
        </button>
        <%!-- Redesign rung 12: the second row on every message (masters
             mobile 1370, desktop 810). Adding attention never edits the
             message. It closes this sheet BEFORE opening the picker, so one
             sheet is open at a time. The glyph is the masters' `.atic`, in
             the sibling icons' text-subtle. --%>
        <button
          type="button"
          data-role="message-actions-attention"
          phx-click={
            Phoenix.LiveView.JS.push("close_message_actions")
            |> Phoenix.LiveView.JS.push("open_message_attention",
              value: %{"message-id" => @open_message_actions_id}
            )
          }
          class={@row_class}
        >
          <span
            class="inline-flex w-5 shrink-0 justify-center text-base font-extrabold leading-none text-subtle"
            aria-hidden="true"
          >
            @<sup class="-ml-0.5 text-[9px]">+</sup>
          </span>
          <span class="flex min-w-0 flex-col py-1.5">
            <span data-role="message-actions-label">Get someone's attention</span>
            <span class="text-[13px] text-subtle" data-role="message-actions-attention-meta">
              {attention_meta(@own?)}
            </span>
          </span>
        </button>
        <%!-- Agent messages only. It closes this sheet BEFORE opening the
             context sheet, so exactly one sheet is ever open. --%>
        <button
          :if={@agent?}
          type="button"
          data-role="message-actions-context"
          phx-click={
            Phoenix.LiveView.JS.push("close_message_actions")
            |> Phoenix.LiveView.JS.push("open_message_context",
              value: %{"message-id" => @open_message_actions_id}
            )
          }
          class={@row_class}
        >
          <.icon name="hero-arrow-up-right" class="size-5 shrink-0 text-subtle" />
          <span class="flex min-w-0 flex-col py-1.5">
            <span data-role="message-actions-label">What this is answering</span>
            <span class="text-[13px] text-subtle">context · summarise what led here</span>
          </span>
        </button>
        <button
          id={"#{@id_prefix}-pin"}
          type="button"
          data-role="message-actions-pin"
          phx-click={
            Phoenix.LiveView.JS.push("pin_toggle",
              value: %{
                "message-id" => @open_message_actions_id,
                "space-id" => @open_message_actions_msg && @open_message_actions_msg.space_id
              }
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class={@row_class}
        >
          <.icon name="hero-bookmark" class="size-5 shrink-0 text-subtle" />
          <span data-role="message-actions-label">
            {if @pinned?, do: "Unpin message", else: "Pin message"}
          </span>
        </button>
        <button
          type="button"
          data-role="message-actions-copy-text"
          data-clipboard-text={@text}
          data-copy-toast="Copied"
          phx-click="close_message_actions"
          class={@row_class}
        >
          <.icon name="hero-document-duplicate" class="size-5 shrink-0 text-subtle" />
          <span data-role="message-actions-label">Copy text</span>
        </button>
        <button
          type="button"
          data-role="message-actions-copy-link"
          data-clipboard-text={@link}
          data-copy-toast="Link copied"
          phx-click="close_message_actions"
          class={@row_class}
        >
          <.icon name="hero-link" class="size-5 shrink-0 text-subtle" />
          <span data-role="message-actions-label">Copy link</span>
        </button>
        <%!-- Own text messages only (Policy 3 of the editable-messages
             contract); `edit_message_clicked` re-checks the author. --%>
        <button
          :if={@editable?}
          type="button"
          data-role="message-actions-edit"
          phx-click={
            Phoenix.LiveView.JS.push("edit_message_clicked",
              value: %{"message-id" => @open_message_actions_id}
            )
            |> Phoenix.LiveView.JS.push("close_message_actions")
          }
          class={@row_class}
        >
          <.icon name="hero-pencil-square" class="size-5 shrink-0 text-subtle" />
          <span data-role="message-actions-label">Edit</span>
        </button>
        <%!-- Own messages only. The red is on the ICON, painted as its
             mask FILL (`bg-error`; a heroicon paints `currentColor`, which
             the utility overrides), so no `text-error` class exists at all
             here: red is never a text colour. `data-confirm`
             is LiveView's native confirm; the server re-checks the author. --%>
        <button
          :if={@own?}
          type="button"
          data-role="message-actions-delete"
          data-confirm="Delete this message?"
          phx-click={
            Phoenix.LiveView.JS.push("delete_message",
              value: %{"message-id" => @open_message_actions_id}
            )
          }
          class={@row_class}
        >
          <.icon name="hero-trash" class="size-5 shrink-0 bg-error" />
          <span data-role="message-actions-label">Delete</span>
        </button>
      </div>
    </div>
    """
  end

  # The meta line under "Get someone's attention": the phone master's own
  # copy (mobile 1370; desktop 810 shortens it to "notify an agent or person
  # — no edit"), and the others' copy both masters share.
  defp attention_meta(true), do: "notify an agent or person about this — no edit"
  defp attention_meta(_own?), do: "ask someone to look at this"

  attr(:open_message_attention, :any, required: true)

  @doc """
  The "Get someone's attention" picker (redesign rung 12; masters
  `stubAttention`, mobile 1384-1388, desktop 819-825). ONE assign
  (`MessageAttentionHooks`' `:open_message_attention`), two frames like the
  actions sheet: the phone bottom sheet (`lg:hidden`) and a `hidden lg:block`
  popover anchored to the message by `MessageActionsPopover`.

  Title: "Get someone's attention" on the viewer's own message, "Ask
  someone to look" on anyone else's. Then a one-line preview of the message,
  the search field (`attention_query`), and rung 10's `MentionList` in pick
  mode: the same rows, ranking and not-in-space copy as the composer's list,
  with already-added principals marked "added".
  """
  def message_attention_sheet(assigns) do
    ~H"""
    <.sheet
      :if={@open_message_attention}
      id="message-attention-sheet"
      open={true}
      placement={:bottom}
      on_close="close_message_attention"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>{@open_message_attention.title}</:title>
      <p class="px-4 pb-2 text-base font-semibold text-base-content" aria-hidden="true">
        {@open_message_attention.title}
      </p>
      <.message_attention_content id_prefix="message-attention" attention={@open_message_attention} />
    </.sheet>
    <div
      :if={@open_message_attention}
      id="message-attention-popover"
      role="dialog"
      aria-label={@open_message_attention.title}
      tabindex="-1"
      phx-hook="MessageActionsPopover"
      phx-click-away="close_message_attention"
      phx-window-keydown="close_message_attention"
      phx-key="Escape"
      data-anchor-message-id={@open_message_attention.message_id}
      class="fixed left-1/2 top-24 z-40 hidden w-80 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-1.5 shadow-lg focus:outline-none lg:block"
    >
      <p class="px-2 pb-1.5 pt-1 text-[13px] font-semibold text-base-content">
        {@open_message_attention.title}
      </p>
      <.message_attention_content
        id_prefix="message-attention-popover"
        attention={@open_message_attention}
      />
    </div>
    """
  end

  attr(:id_prefix, :string, required: true)
  attr(:attention, :map, required: true)

  defp message_attention_content(assigns) do
    ~H"""
    <div id={"#{@id_prefix}-content"} class="flex flex-col" data-role="message-attention-picker">
      <p
        data-role="message-attention-preview"
        class="mx-1 mb-2 truncate rounded-box border border-edge bg-base-200 px-3 py-2 text-[13px] text-subtle"
      >
        {@attention.preview}
      </p>
      <form
        id={"#{@id_prefix}-search"}
        phx-change="attention_query"
        phx-submit="attention_query"
        class="mx-1 mb-1"
      >
        <input
          type="search"
          name="query"
          value={@attention.query}
          placeholder="Search agents and people"
          aria-label="Search agents and people"
          autocomplete="off"
          phx-debounce="100"
          data-role="message-attention-search"
          class="h-11 w-full rounded-box border border-edge bg-base-200 px-3 text-[15px] text-base-content placeholder:text-subtle focus:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring lg:h-9 lg:text-[13px]"
        />
      </form>
      <PlatformWeb.ChatLive.Partials.MentionList.mention_list
        id={"#{@id_prefix}-list"}
        suggestions={@attention.suggestions}
        query={@attention.query}
        pick={@attention.message_id}
        added={@attention.added}
      />
    </div>
    """
  end

  defp message_link(nil, _id), do: nil
  defp message_link(_space, nil), do: nil

  defp message_link(space, id) do
    PlatformWeb.Endpoint.url() <>
      "/chat/#{Platform.Chat.space_path_segment(space)}?message=#{id}"
  end

  attr(:open_reactors, :any, required: true)
  attr(:current_participant, :any, default: nil)

  @doc """
  Who reacted with one emoji on one message (redesign rung 9 stage 3;
  masters stub 'Reacted 👍', direction m3 rule 5). Opened by a long-press on
  a reaction pill (`open_reactors`). The list is the one
  `MessageActionsHooks` re-read from the DATABASE on open, never the
  pill's client JSON. ONE assign, two frames, like the actions sheet: the
  phone bottom sheet (`lg:hidden`) and a `hidden lg:block` popover anchored
  by `MessageActionsPopover`. The viewer's own row carries the meta 'you'.
  """
  def reactors_sheet(assigns) do
    ~H"""
    <.sheet
      :if={@open_reactors}
      id="reactors-sheet"
      open={true}
      placement={:bottom}
      on_close="close_reactors"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Reacted {@open_reactors.emoji}</:title>
      <p class="px-4 pb-2 text-base font-semibold text-base-content" aria-hidden="true">
        Reacted {@open_reactors.emoji}
      </p>
      <.reactors_list
        id="reactors-sheet-list"
        open_reactors={@open_reactors}
        current_participant={@current_participant}
      />
    </.sheet>
    <div
      :if={@open_reactors}
      id="reactors-popover"
      role="dialog"
      aria-label={"Reacted #{@open_reactors.emoji}"}
      tabindex="-1"
      phx-hook="MessageActionsPopover"
      phx-click-away="close_reactors"
      phx-window-keydown="close_reactors"
      phx-key="Escape"
      data-anchor-message-id={@open_reactors.message_id}
      class="fixed left-1/2 top-24 z-40 hidden w-64 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-3 shadow-lg focus:outline-none lg:block"
    >
      <p class="pb-1 text-[13px] font-semibold text-base-content">
        Reacted {@open_reactors.emoji}
      </p>
      <.reactors_list
        id="reactors-popover-list"
        open_reactors={@open_reactors}
        current_participant={@current_participant}
      />
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:open_reactors, :map, required: true)
  attr(:current_participant, :any, required: true)

  defp reactors_list(assigns) do
    assigns =
      assign(assigns, :viewer_id, assigns.current_participant && assigns.current_participant.id)

    ~H"""
    <ul id={@id} class="flex flex-col px-1 pb-2" data-role="reactors-list">
      <li
        :for={r <- @open_reactors.reactors}
        class="flex min-h-11 items-center justify-between gap-3 px-3 lg:min-h-8"
        data-role="reactor-row"
        data-participant-id={r.id}
      >
        <span class="truncate text-[15px] text-base-content">{r.name}</span>
        <span :if={r.id == @viewer_id} class="text-[13px] text-subtle" data-role="reactor-you">
          you
        </span>
      </li>
      <li
        :if={@open_reactors.extra_count > 0}
        class="flex min-h-11 items-center px-3 text-[13px] text-subtle lg:min-h-8"
      >
        and {@open_reactors.extra_count} {if @open_reactors.extra_count == 1,
          do: "other",
          else: "others"}
      </li>
    </ul>
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
