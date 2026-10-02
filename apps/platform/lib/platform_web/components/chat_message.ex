defmodule PlatformWeb.Components.ChatMessage do
  @moduledoc """
  Renders one message row in the chat stream.

  Extracted from `chat_live.html.heex` in Stage 2 of task 019e0f29 (#11).
  Markup is intentionally identical to the prior inline block so visual
  parity is preserved; the only addition is a placeholder 3-dot menu in the
  hover toolbar (the Edit item itself lands in Stage 4 once the
  editable-messages contract is in place).
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias Phoenix.LiveView.JS

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1, agent_avatar: 1]
  import PlatformWeb.Components.ChatHelpers

  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.MessageContextHooks

  attr(:dom_id, :string, required: true)
  attr(:msg, :map, required: true)
  attr(:current_participant, :any, default: nil)
  attr(:agent_participant_ids, :any, required: true)
  attr(:agent_colors_map, :map, required: true)
  attr(:participants_map, :map, required: true)
  attr(:quick_emojis, :list, required: true)
  attr(:pinned_message_ids, :any, required: true)
  attr(:highlighted_message_id, :any, default: nil)
  attr(:canvases_by_id, :map, required: true)
  attr(:attachments_map, :map, required: true)
  attr(:thread_previews, :map, required: true)
  attr(:expanded_threads, :any, required: true)
  attr(:inline_thread_messages, :map, required: true)
  attr(:mention_suggestions, :list, default: [])
  attr(:mention_source, :any, default: nil)
  attr(:editing_message_id, :any, default: nil)
  # Task 019e95ea stage 2: true when the parent space is an archived
  # read-only snapshot. Gates every interaction affordance (quick-emoji
  # bar, hover toolbar, longpress sheet, reaction add, thread reply) in
  # one place — the context layer independently rejects the writes.
  attr(:read_only, :boolean, default: false)

  def chat_message(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class={[
        "group relative rounded-2xl",
        MapSet.member?(@agent_participant_ids, @msg.participant_id) && "msg-agent",
        @highlighted_message_id == @msg.id && "bg-primary/5 ring-1 ring-primary/20",
        @current_participant && @msg.participant_id == @current_participant.id &&
          !MapSet.member?(@agent_participant_ids, @msg.participant_id) && "bg-base-200/60"
      ]}
      style={
        if MapSet.member?(@agent_participant_ids, @msg.participant_id) do
          accent =
            Map.get(
              @agent_colors_map,
              @msg.participant_id,
              Platform.Agents.ColorPalette.default_accent()
            )

          "--agent-accent: #{accent};"
        end
      }
      data-participant-id={@msg.participant_id}
      data-date={
        @msg.inserted_at &&
          Platform.Chat.message_ordered_at(@msg) |> DateTime.to_date() |> Date.to_iso8601()
      }
      data-message-id={@msg.id}
      data-is-own-message={
        if(@current_participant && @msg.participant_id == @current_participant.id,
          do: "true",
          else: "false"
        )
      }
      phx-hook={if @read_only, do: nil, else: "LongpressMenu"}
    >
      <%!-- Day-bucket separator (task 019e21c7 Stage 5). Rendered inside
           the stream item so morphdom reconciles it via the parent's
           stable phx-id and never destroys the node on stream_insert.
           `:day_label` is computed server-side in MessagesHooks. --%>
      <div
        :if={@msg.day_label}
        class="js-date-separator flex items-center gap-3 my-4 -mx-2"
        data-date={@msg.day_label}
      >
        <div class="flex-1 border-t border-edge"></div>
        <span class="text-[11px] uppercase tracking-widest text-base-content/40 font-semibold px-2">
          {format_day_label(@msg.day_label)}
        </span>
        <div class="flex-1 border-t border-edge"></div>
      </div>

      <%!-- `message-row-inner` is the padding box. It carries a stable class
           because a grouped continuation row needs tighter vertical padding
           than the first row of a group, and that rule lives in app.css
           rather than in the grouping JS — see `.message-row--grouped`. --%>
      <div class="message-row-inner flex gap-3 px-2 py-2 transition-all duration-200 ease-[cubic-bezier(0.16,1,0.3,1)] hover:bg-base-200/40 active:scale-[0.99] rounded-2xl">
        <%!-- Avatar circle (hidden when grouped with previous message via JS) --%>
        <div class="flex-shrink-0 mt-0.5 message-avatar">
          <%= if MapSet.member?(@agent_participant_ids, @msg.participant_id) do %>
            <%!-- `msg-agent-avatar` is the accent ring (a box-shadow keyed off
                 `--agent-accent`, set on the row above). It lands on the
                 component's OUTER wrapper, which is why that wrapper carries
                 `rounded-full` — see AvatarComponents.render_avatar/1. The ring
                 therefore survives an image avatar unchanged, and `agents.color`
                 stays the ring colour rather than leaking into the circle. --%>
            <.agent_avatar
              name={PresenceHooks.sender_name(@participants_map, @msg)}
              avatar_url={PresenceHooks.sender_avatar_url(@participants_map, @msg)}
              size="md"
              class="msg-agent-avatar"
            />
          <% else %>
            <.human_avatar
              name={PresenceHooks.sender_name(@participants_map, @msg)}
              avatar_url={PresenceHooks.sender_avatar_url(@participants_map, @msg)}
              seed={PresenceHooks.sender_avatar_seed(@participants_map, @msg)}
              size="md"
            />
          <% end %>
        </div>

        <%!-- Message body --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-baseline gap-2 message-header">
            <span class={[
              "text-sm font-bold",
              if(MapSet.member?(@agent_participant_ids, @msg.participant_id),
                do: "msg-agent-name",
                else: "text-base-content"
              )
            ]}>
              {PresenceHooks.sender_name(@participants_map, @msg)}
              <span
                :if={MapSet.member?(@agent_participant_ids, @msg.participant_id)}
                class="msg-agent-badge"
              >
                AI
              </span>
            </span>
            <%!-- The clock on a row is the instant it SORTS at, not the
                 instant the row was written: for an agent's spoken line in a
                 meeting those differ by the ack delay, and a row moved up
                 into its spoken position while still printing its ack time
                 reads as a scrollback that is simply out of order (task
                 01a07401). For every row without a `spoken_at` — which is
                 every row outside a meeting — this is `inserted_at`
                 unchanged. --%>
            <.local_time
              id={"message-time-#{@msg.id}"}
              timestamp={Platform.Chat.message_ordered_at(@msg)}
              class="text-[10px] text-base-content/40"
            />
            <%!-- "Context" (task 01a0d8de stage 3; design canvas "Design
                 direction: agent message context"). Rendered only on AGENT
                 messages that carry something to show without generating it
                 (`reply_context` or `reply_to_message_id` in metadata, which
                 built-in agents write too). Always visible, not hover-gated:
                 the reader who needs it is scanning, and touch has no hover.
                 Also rendered when read-only, since it only reads. `shrink-0`
                 and placed after the time, so the name and time keep
                 truncation priority and the hover row keeps the right edge.
                 It carries no `data-message-id`: that attribute is how the
                 scroll hooks find the ROW, and a first match on this button
                 would scroll to the header instead.

                 `message-context-trigger` is the app.css handle for its
                 touch hit area (45px tall below lg, via a transparent
                 `::after`) and the stage 5 fix beside it: on `hover: none`
                 the hover strip no longer reveals on the focus a tap gives
                 this button, which is what used to swallow the tap. --%>
            <button
              :if={
                MapSet.member?(@agent_participant_ids, @msg.participant_id) &&
                  MessageContextHooks.has_context?(@msg)
              }
              type="button"
              phx-click="open_message_context"
              phx-value-message-id={@msg.id}
              data-role="message-context-trigger"
              data-context-message-id={@msg.id}
              aria-haspopup="dialog"
              class="message-context-trigger shrink-0 text-[10px] text-base-content/40 hover:text-base-content/70 hover:underline focus-visible:underline transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100 rounded"
            >
              Context
            </button>
            <%!-- (edited) affix per contract Section D.1 — visible only on
               messages with >1 version row (i.e. at least one edit on top
               of the original v1). Clicking opens the version history
               popover (Section D.2). --%>
            <button
              :if={is_integer(Map.get(@msg, :versions_count)) && @msg.versions_count > 1}
              type="button"
              phx-click="show_version_history"
              phx-value-message-id={@msg.id}
              aria-label="Show edit history"
              title="View version history"
              class="text-[10px] text-base-content/40 hover:text-base-content/70 hover:underline transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100 rounded"
            >
              (edited)
            </button>

            <%!-- Revealed by OPACITY, not `hidden`, and the distinction is the whole
                 keyboard story (task 01a000c0 stage 3).

                 This row was `hidden`, swapped to `flex` under a group-hover
                 variant. `hidden` is `display: none`, so nothing inside it was
                 tab-reachable — not the quick-react emoji, not copy, reply,
                 thread or pin. Adding a group-focus-within variant does NOT
                 fix that: a `display: none` element cannot take focus, so
                 focus can never get inside to trigger focus-within. It is
                 circular, and it is the tempting one-word fix.

                 (Those two variants are described rather than spelled: files
                 under an `@source` path are scanned as plain text, so a
                 utility written literally in a comment is a build candidate
                 even with no markup using it. Quoting them here was emitting
                 a real, unused rule into the compiled stylesheet until
                 task 01a000c0 stage 4 rephrased this.)

                 Opacity keeps every button in the tab order and focusable, so
                 Tab reaches them and `group-focus-within` then reveals the row
                 it is already inside. `pointer-events` is gated alongside, or
                 the invisible row would swallow clicks aimed at the message.

                 No transition on the reveal: the design direction cut fade,
                 slide and transform because at this row density it reads as
                 flicker. `transition-colors` on the buttons is hover colour,
                 not the reveal, and stays.

                 The row costs no vertical space — it is `ml-auto` on the
                 existing header line — which is why moving the "+" here
                 removes the reflow instead of relocating it.

                 `message-action-row` is the handle app.css needs to keep this
                 row alive on a grouped continuation row, where the header
                 around it is stripped down to nothing (task 01a000c0
                 stage 4). Without it the whole header was `display: none`
                 there and every control in here — the "+" included — was
                 unreachable by keyboard on most messages in a conversation. --%>
            <div
              :if={!@read_only}
              class="message-action-row ml-auto flex items-center gap-1 opacity-0 pointer-events-none group-hover:opacity-100 group-hover:pointer-events-auto group-focus-within:opacity-100 group-focus-within:pointer-events-auto"
            >
              <button
                :for={emoji <- @quick_emojis}
                phx-click="react"
                phx-value-message-id={@msg.id}
                phx-value-emoji={emoji}
                title={"React with #{emoji}"}
                class="rounded px-1.5 py-0.5 text-sm hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                {emoji}
              </button>

              <%!-- Add-reaction, moved here from the reaction row below the
                   message body (task 01a000c0 stage 3). It joins the
                   quick-react buttons that were already here, so this row was
                   always partly about reacting — the consolidation is putting
                   the general case next to the shortcuts rather than in a
                   second corner revealed by the same gesture.

                   The count is deliberately not written down here. @quick_emojis
                   is `Platform.Chat.Emoji.quick_defaults/0` (task 019e0814
                   stage 2) and this row renders whatever it holds; a number in
                   this comment is a fourth place for the set to drift, which is
                   the defect that stage exists to close.

                   Treatment is copied verbatim from its siblings: no new
                   colour, no text label (it would be the only word in a glyph
                   row), no divider. Accessible name via aria-label only. --%>
              <button
                aria-label="Add reaction"
                title="Add reaction"
                phx-click="open_reaction_picker"
                phx-value-message-id={@msg.id}
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-plus size-4"></span>
              </button>

              <button
                :if={present?(@msg.content)}
                phx-hook="CopyToClipboard"
                id={"copy-msg-#{@msg.id}"}
                data-clipboard-text={@msg.content}
                title="Copy message"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-clipboard-document-list size-4"></span>
              </button>

              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                title="Reply"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-chat-bubble-left-right size-4"></span>
              </button>

              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                title="Open thread"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/40 hover:text-base-content/60 hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-arrow-top-right-on-square size-4"></span>
              </button>

              <button
                phx-click="pin_toggle"
                phx-value-message-id={@msg.id}
                phx-value-space-id={@msg.space_id}
                title={if MapSet.member?(@pinned_message_ids, @msg.id), do: "Unpin", else: "Pin"}
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class={[
                  "size-4",
                  if(MapSet.member?(@pinned_message_ids, @msg.id),
                    do: "hero-bookmark-solid",
                    else: "hero-bookmark"
                  )
                ]}>
                </span>
              </button>

              <%!-- "Summarise what led here" (task 01a0d8de stage 3). Only on
                   agent messages with NO context of their own; those get no
                   header marker, because marking every agent message would put
                   a control on most of the chat. Opens the same panel as the
                   header's "Context" button, with a generated summary. --%>
              <button
                :if={
                  MapSet.member?(@agent_participant_ids, @msg.participant_id) &&
                    !MessageContextHooks.has_context?(@msg)
                }
                type="button"
                phx-click="summarise_message_context"
                phx-value-message-id={@msg.id}
                data-role="message-context-summarise"
                aria-label="Summarise what led here"
                title="Summarise what led here"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-document-text size-4" aria-hidden="true"></span>
              </button>

              <%!-- 3-dot overflow menu (task 019e0f29 Stage 3). Replaces the
                 Stage-2 placeholder DaisyUI dropdown that didn't open on
                 touch (Marlowe bug report). Now fires `open_message_actions`
                 which sets a single LV-level `:open_message_actions_id`
                 assign; chat_live.html.heex renders one Sheet at the page
                 bottom that surfaces the actions for the open message. --%>
              <button
                type="button"
                phx-click="open_message_actions"
                phx-value-id={@msg.id}
                aria-label="More message actions"
                title="More"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-ellipsis-horizontal size-4"></span>
              </button>
            </div>
          </div>

          <div
            :if={@msg.content_type == "canvas"}
            class="mt-1"
          >
            <div :if={Map.get(@canvases_by_id, @msg.canvas_id)} class="min-w-0 overflow-hidden">
              <.canvas_document
                canvas={Map.get(@canvases_by_id, @msg.canvas_id)}
                inline={true}
                dom_id_base="chat-message-inline"
              />
            </div>

            <div
              :if={is_nil(Map.get(@canvases_by_id, @msg.canvas_id))}
              phx-click="canvas_open_mobile"
              phx-value-message-id={@msg.id}
              class="rounded-lg bg-base-200 px-3 py-2 cursor-pointer hover:bg-base-300 transition-colors"
            >
              <p class="truncate text-sm font-semibold text-base-content">
                {CanvasHooks.message_canvas_title(@msg, @canvases_by_id)}
              </p>
              <p class="text-[11px] uppercase tracking-widest text-base-content/50">
                Canvas
              </p>
            </div>
          </div>

          <%!-- Correction header (task 019e0f29 Stage 6, contract Section D.4).
             When this message is a correction (`corrects_message_id` non-nil),
             prepend a clickable header that scrolls to the original message
             and briefly pulses it via a CSS keyframe. --%>
          <button
            :if={Map.get(@msg, :corrects_message_id)}
            type="button"
            phx-click="scroll_to_message"
            phx-value-id={@msg.corrects_message_id}
            class="flex items-center gap-1 text-[11px] text-base-content/60 hover:text-base-content/80 transition-colors mb-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring rounded"
          >
            <span class="hero-arrow-up-circle size-3.5"></span>
            <span>Correction to earlier message</span>
          </button>

          <%!-- Inbound email provenance (task 01a0cf21 stage 3). An email is
             outside text posted by the "Email (external)" system participant,
             so it is labelled as such above the body rather than looking like
             a Suite participant's own message. Values come from the message
             metadata `Platform.Mail.Inbound` stamped; HEEx escapes them. --%>
          <% email_meta = email_inbound_metadata(@msg) %>
          <div
            :if={email_meta}
            data-role="mail-inbound-provenance"
            class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-base-content/60 mb-1"
          >
            <span class="hero-envelope size-3.5 shrink-0" aria-hidden="true"></span>
            <span>
              Email to {email_meta["account_address"] || "this account"}, from {email_meta[
                "from"
              ] || "an unknown sender"}
            </span>
            <span
              :if={email_meta["message_id"]}
              data-role="mail-inbound-message-id"
              class="font-mono break-all"
            >
              {email_meta["message_id"]}
            </span>
          </div>

          <%!-- Peer-install provenance (task 01a0d90f stage 5). A message
             from a shared space on another Suite install is outside text
             posted by a "<name> (via <peer>)" system participant, so it is
             labelled as such above the body, as the mail block above is.
             Values come from the metadata `Platform.Federation.Peers.Ingest`
             stamped; HEEx escapes them. --%>
          <% federation_meta = federation_inbound_metadata(@msg) %>
          <div
            :if={federation_meta}
            data-role="federation-inbound-provenance"
            class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-base-content/60 mb-1"
          >
            <span class="hero-globe-alt size-3.5 shrink-0" aria-hidden="true"></span>
            <span>
              Shared from {federation_meta["peer_display_name"] || "a Suite peer"}, by {federation_meta[
                "remote_author"
              ] || "an unknown author"}
            </span>
          </div>

          <%!-- Inline editor (task 019e0f29 Stage 5). When this message is
             the one being edited, render the editor in place of the
             bubble. Otherwise render the bubble as before. --%>
          <PlatformWeb.Components.ChatMessageEditor.chat_message_editor
            :if={@editing_message_id == @msg.id}
            msg={@msg}
          />

          <div
            :if={
              @editing_message_id != @msg.id and @msg.content_type != "canvas" and
                present?(@msg.content)
            }
            class="text-sm text-base-content break-words chat-markdown"
          >
            {Platform.Chat.ContentRenderer.render_message(@msg.content)}
          </div>

          <%!-- Image gallery --%>
          <% images = Enum.filter(Map.get(@attachments_map, @msg.id, []), &image_attachment?/1) %>
          <% non_images =
            Enum.reject(Map.get(@attachments_map, @msg.id, []), &image_attachment?/1) %>
          <div
            :if={images != []}
            class={"image-gallery count-#{min(length(images), 5)}"}
          >
            <div
              :for={{attachment, idx} <- Enum.with_index(images)}
              phx-click="open_lightbox"
              phx-value-url={attachment_url(attachment)}
              class={"gallery-item cursor-pointer#{if length(images) == 3 and idx == 0, do: " span-2", else: ""}"}
            >
              <img
                src={attachment_url(attachment)}
                alt={attachment.filename}
                loading="lazy"
                onerror="this.closest('.gallery-item').classList.add('broken')"
              />
              <div class="gallery-placeholder">
                <svg
                  aria-hidden="true"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <rect x="3" y="3" width="18" height="18" rx="2" /><circle
                    cx="8.5"
                    cy="8.5"
                    r="1.5"
                  /><path d="M21 15l-5-5L5 21" />
                </svg>
                <span>{attachment.filename}</span>
              </div>
              <span class="gallery-filename">{attachment.filename}</span>
              <div class="gallery-overlay">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" /><line
                    x1="11"
                    y1="8"
                    x2="11"
                    y2="14"
                  /><line x1="8" y1="11" x2="14" y2="11" />
                </svg>
              </div>
            </div>
          </div>
          <div :if={non_images != []} class="mt-1 flex flex-col gap-2">
            <a
              :for={attachment <- non_images}
              href={attachment_url(attachment)}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex w-fit items-center gap-2 rounded bg-base-200 px-2 py-1 text-sm text-primary hover:bg-base-300 hover:no-underline"
            >
              <span class="hero-paper-clip size-4"></span>
              <span>{attachment.filename}</span>
              <span class="text-xs text-base-content/40">
                ({format_bytes(attachment.byte_size)})
              </span>
            </a>
          </div>

          <%!-- Reaction pills, rendered only when there are reactions to show
               (task 01a000c0 stage 4).

               This used to render unconditionally and carry
               `data-empty={@msg.reactions == []}`, which app.css read to
               collapse the empty case to zero height inside
               `@media (hover: hover) and (pointer: fine)` — and then to hand
               that height BACK on hover. Growing a message under the cursor
               and shoving everything below it down is the bug this whole
               ticket exists to remove.

               Once stage 3 moved the "+" into the header action row, an empty
               row had no children at all, so the honest reconciliation is to
               stop rendering it rather than to render an empty box and
               permanently collapse it. Not rendering is the stronger of the
               two: there is no attribute left to get backwards, and no rule
               left that could collapse a row that DOES have reactions. It
               also keeps an empty `role="toolbar"` out of the accessibility
               tree on every message nobody has reacted to — which is most of
               them. --%>
          <div
            :if={@msg.reactions != []}
            role="toolbar"
            aria-label="Message actions"
            class="reaction-row flex flex-wrap gap-1 mt-0.5"
          >
            <%!-- Reaction pills stay visible on read-only snapshots (they
                 are part of the frozen history) but stop toggling. --%>
            <button
              :for={r <- @msg.reactions}
              id={"reaction-#{@msg.id}-#{r.emoji}"}
              phx-hook="ReactorPopover"
              phx-click={if @read_only, do: nil, else: "react"}
              phx-value-message-id={@msg.id}
              phx-value-emoji={r.emoji}
              data-emoji={r.emoji}
              data-reactors={Jason.encode!(r.reactors)}
              data-extra-count={r.extra_count}
              aria-label={reactor_aria_label(r)}
              class={[
                "reaction-pill flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs transition-colors",
                "hover:bg-base-300",
                r.reacted_by_me && "border-primary bg-primary/10 text-primary",
                !r.reacted_by_me && "border-edge text-base-content/60"
              ]}
            >
              <span>{r.emoji}</span>
              <span>{r.count}</span>
            </button>

            <%!-- The dashed add-reaction "+" that used to live here moved into the
                 upper-right action row (task 01a000c0 stage 3). It was the
                 second hover affordance on the same object, in a different
                 corner, revealed by the same gesture — and being below the
                 body it cost vertical space, which is what made the row grow
                 on hover and shift everything under it.

                 So this row is now pills and nothing else, which is why
                 stage 4 could gate it on there being pills to show. --%>
          </div>

          <%!-- Inline thread: indicator + expanded thread --%>
          <div :if={
            Map.has_key?(@thread_previews, @msg.id) or
              MapSet.member?(@expanded_threads, @msg.id)
          }>
            <%!-- Thread indicator (collapsed state) --%>
            <div
              :if={not MapSet.member?(@expanded_threads, @msg.id)}
              phx-click="toggle_inline_thread"
              phx-value-message-id={@msg.id}
              class="thread-indicator"
            >
              <div class="thread-avatars">
                <div class="t-av ai">↩</div>
              </div>
              <span class="ti-count">
                {Map.get(@thread_previews, @msg.id, %{}) |> Map.get(:reply_count, 0)}
                {if Map.get(@thread_previews, @msg.id, %{}) |> Map.get(:reply_count, 0) == 1,
                  do: "reply",
                  else: "replies"}
              </span>
              <span
                :if={Map.get(@thread_previews, @msg.id, %{}) |> Map.get(:last_reply_at)}
                class="ti-time"
              >
                · {relative_time(
                  Map.get(@thread_previews, @msg.id, %{})
                  |> Map.get(:last_reply_at)
                )}
              </span>
            </div>

            <%!-- Expanded thread --%>
            <div
              :if={MapSet.member?(@expanded_threads, @msg.id)}
              class="thread-replies"
              id={"inline-thread-#{@msg.id}"}
              phx-hook="InlineThread"
            >
              <div
                :for={tmsg <- Map.get(@inline_thread_messages, @msg.id, [])}
                class={[
                  "thread-reply",
                  if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                    do: "agent-reply"
                  )
                ]}
              >
                <%!-- Inline thread preview. This used to be a bare `msg-avatar`
                     div holding a single letter for BOTH kinds. `.msg-avatar`
                     had no rule of its own anywhere in the stylesheet — only
                     `.thread-reply .msg-avatar { width/height/font-size }` — so
                     the `ai`/`human` modifier painted nothing and neither an
                     agent nor a human ever showed a face here. Both branches now
                     go through the shared components, which is also what gives
                     the human path its avatar back. --%>
                <%= if MapSet.member?(@agent_participant_ids, tmsg.participant_id) do %>
                  <.agent_avatar
                    name={PresenceHooks.sender_name(@participants_map, tmsg)}
                    avatar_url={PresenceHooks.sender_avatar_url(@participants_map, tmsg)}
                    size="sm"
                  />
                <% else %>
                  <.human_avatar
                    name={PresenceHooks.sender_name(@participants_map, tmsg)}
                    avatar_url={PresenceHooks.sender_avatar_url(@participants_map, tmsg)}
                    seed={PresenceHooks.sender_avatar_seed(@participants_map, tmsg)}
                    size="sm"
                    class="shrink-0"
                  />
                <% end %>
                <div class="msg-body">
                  <div class="msg-header">
                    <span class={[
                      "msg-username",
                      if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                        do: "ai-name"
                      )
                    ]}>
                      {PresenceHooks.sender_name(@participants_map, tmsg)}
                    </span>
                    <span
                      :if={MapSet.member?(@agent_participant_ids, tmsg.participant_id)}
                      class="ai-badge"
                    >
                      AI
                    </span>
                    <.local_time
                      id={"inline-thread-ts-#{tmsg.id}"}
                      timestamp={tmsg.inserted_at}
                      class="msg-time"
                    />
                  </div>
                  <div class="msg-text">
                    {Platform.Chat.ContentRenderer.render_message(tmsg.content)}
                  </div>
                </div>
              </div>

              <%!-- Thread composer — absent on read-only snapshots. --%>
              <div
                :if={!@read_only}
                class="thread-composer"
                style="flex-direction: column; align-items: stretch;"
              >
                <.form
                  for={%{}}
                  id={"inline-thread-compose-form-#{@msg.id}"}
                  phx-submit="send_inline_thread_message"
                  class="thread-composer-form"
                  style="position: relative;"
                >
                  <%!-- @mention autocomplete dropdown (inline thread) --%>
                  <div
                    :if={
                      @mention_suggestions != [] &&
                        @mention_source == "inline-thread-compose-form-#{@msg.id}"
                    }
                    style="position: absolute; bottom: 100%; left: 0; z-index: 50; width: 16rem; margin-bottom: 4px;"
                  >
                    <div class="rounded-2xl border border-base-content/10 bg-base-100 shadow-lg overflow-hidden">
                      <div class="py-1">
                        <button
                          :for={{suggestion, idx} <- Enum.with_index(@mention_suggestions)}
                          type="button"
                          data-mention-suggestion={if idx == 0, do: "first"}
                          phx-click={
                            JS.dispatch("chat:insert-mention",
                              to: "#inline-thread-compose-#{@msg.id}",
                              detail: %{name: suggestion.display_name || "User"}
                            )
                          }
                          class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
                        >
                          <%!-- The inline-thread twin of the compose dropdown in
                               `chat_live.html.heex`. It had NO kind branch at
                               all: agents, humans and the `here` sentinel alike
                               got one hand-rolled letter, so nobody's face ever
                               appeared. Now mirrors the main dropdown's three
                               branches, over the same suggestion shape — the
                               identity map carries `name`, `avatar_url` and
                               `avatar_seed` for every kind. --%>
                          <%= cond do %>
                            <% suggestion.participant_type == "broadcast" -> %>
                              <div class="w-6 h-6 rounded-full bg-warning/15 text-warning flex items-center justify-center flex-shrink-0">
                                <span class="hero-megaphone size-4"></span>
                              </div>
                            <% suggestion.participant_type == "agent" -> %>
                              <.agent_avatar
                                name={suggestion.display_name || "Agent"}
                                avatar_url={suggestion.avatar_url}
                                size="sm"
                                class="flex-shrink-0"
                              />
                            <% true -> %>
                              <.human_avatar
                                name={suggestion.display_name || "User"}
                                avatar_url={suggestion.avatar_url}
                                seed={suggestion.avatar_seed}
                                size="sm"
                                class="flex-shrink-0"
                              />
                          <% end %>
                          <span class="flex-1 truncate font-medium">
                            {suggestion.display_name || "User"}
                          </span>
                          <span class={[
                            "rounded-full px-1.5 py-0.5 text-[10px] uppercase tracking-wider",
                            suggestion.participant_type == "agent" &&
                              "bg-primary/10 text-primary",
                            suggestion.participant_type != "agent" &&
                              "bg-base-300 text-base-content/50"
                          ]}>
                            {suggestion.participant_type}
                          </span>
                        </button>
                      </div>
                    </div>
                  </div>
                  <input
                    type="hidden"
                    name="inline_thread_compose[message_id]"
                    value={@msg.id}
                  />
                  <input
                    type="text"
                    name="inline_thread_compose[text]"
                    id={"inline-thread-compose-#{@msg.id}"}
                    placeholder="Reply in thread..."
                    autocomplete="off"
                    class="thread-input"
                    phx-hook="ComposeInput"
                  />
                  <button
                    type="submit"
                    class="thread-send"
                    disabled={is_nil(@current_participant)}
                    title="Reply"
                  >
                    <span class="hero-paper-airplane size-3.5 -rotate-45"></span>
                  </button>
                </.form>
              </div>

              <%!-- Collapse thread --%>
              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                class="thread-collapse"
              >
                ▲ Collapse thread
              </button>
            </div>
          </div>
        </div>
        <%!-- end message body --%>

        <%!-- Left-gutter reply button (desktop, hidden until hover via CSS) --%>
        <button
          :if={!@read_only}
          phx-click="toggle_inline_thread"
          phx-value-message-id={@msg.id}
          class="msg-reply-gutter"
          title="Reply"
        >
          ↩
        </button>
      </div>
      <%!-- end inner flex row --%>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:timestamp, :any, default: nil)
  attr(:class, :string, default: nil)

  def local_time(assigns) do
    ~H"""
    <time
      :if={match?(%DateTime{}, @timestamp)}
      id={@id}
      datetime={DateTime.to_iso8601(@timestamp)}
      data-local-time={DateTime.to_iso8601(@timestamp)}
      phx-hook="LocalTime"
      class={@class}
    >
      {format_timestamp(@timestamp)}
    </time>
    """
  end

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%I:%M %p")

  # Render a `YYYY-MM-DD` day-bucket label as "Today" / "Yesterday" /
  # "Mon, Mar 16". Used by the in-row date separator (task 019e21c7).
  # Mirrors the JS labels the previous hook produced — UTC reference
  # day so it matches what the message rows themselves bucket by.
  defp format_day_label(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        today = Date.utc_today()

        cond do
          Date.compare(date, today) == :eq -> "Today"
          Date.compare(date, Date.add(today, -1)) == :eq -> "Yesterday"
          true -> Calendar.strftime(date, "%a, %b %-d")
        end

      _ ->
        date_str
    end
  end

  defp format_day_label(_), do: ""

  # Metadata of a peer-install message (task 01a0d90f stage 5), or nil.
  defp federation_inbound_metadata(msg) do
    case Map.get(msg, :metadata) do
      %{"source" => "federation_inbound"} = metadata -> metadata
      _ -> nil
    end
  end

  # Metadata of an inbound-email message (task 01a0cf21 stage 3), or nil.
  defp email_inbound_metadata(msg) do
    case Map.get(msg, :metadata) do
      %{"source" => "email_inbound"} = metadata -> metadata
      _ -> nil
    end
  end
end
