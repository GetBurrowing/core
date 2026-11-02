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

  import PlatformWeb.Components.ChatInlineCanvas, only: [inline_canvas: 1]
  import PlatformWeb.Components.ChatClipPlayer, only: [clip_player: 1]
  import PlatformWeb.Components.ChatLinkCard, only: [link_cards: 1, file_card: 1]
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1, agent_avatar: 1]
  import PlatformWeb.Components.ChatHelpers
  import PlatformWeb.Components.ReplyQuote, only: [reply_quote: 1]

  import PlatformWeb.ChatLive.Partials.MentionList, only: [mention_list: 1]

  alias PlatformWeb.ChatLive.Partials.MentionList
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.Components.ReplyFailureRow

  attr(:dom_id, :string, required: true)
  attr(:msg, :map, required: true)
  attr(:current_participant, :any, default: nil)
  attr(:agent_participant_ids, :any, required: true)
  # Task 01a1557a rung 3 stage 2: agent participant id -> palette slot id
  # (`Platform.Chat.agent_slot_map_for_participants/1`). An agent row renders
  # `data-agent-slot`; app.css's pointer rules turn it into the slot's theme
  # tokens. An agent missing from the map is the blue slot.
  attr(:agent_slots_map, :map, default: %{})
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
  # The typed @query (MentionsHooks), for the thread list's empty row; nil
  # when the caller does not pass it.
  attr(:mention_query, :string, default: nil)
  attr(:editing_message_id, :any, default: nil)
  # Task 019e95ea stage 2: true when the parent space is an archived
  # read-only snapshot. Gates every interaction affordance (quick-emoji
  # bar, tap pill, actions sheet, reaction add, thread reply) in
  # one place — the context layer independently rejects the writes.
  attr(:read_only, :boolean, default: false)
  # Task 01a0fd62 stage 2: msg_id → [agent name] for THIS viewer's own
  # messages whose `@[agent]` mention was refused. Only the author's
  # LiveView ever has an entry (see MessagesHooks), so a row rendered for
  # anyone else finds nothing here and shows no notice.
  attr(:refused_summons, :map, default: %{})
  # The active space's kind, which picks who the notice says can act.
  attr(:space_kind, :string, default: "channel")
  # Task 01a13884 stage 4: message ids whose inline canvas has been mounted
  # (scrolled near the viewport), or `:all` to render every canvas directly.
  # See `PlatformWeb.Components.ChatInlineCanvas`.
  attr(:mounted_inline_canvas_ids, :any, default: :all)

  # Task 01a10322 stage 4: the viewing user, for the reply-failure row's
  # manager-only action.
  attr(:viewer_user_id, :string, default: nil)

  # A reply-failure notice is a system row, not a chat bubble: no avatar
  # column, no hover toolbar, no reactions. The day separator still renders,
  # so a notice that opens a day keeps its date line.
  def chat_message(
        %{msg: %{content_type: "system", metadata: %{"kind" => "reply_failure"}}} = assigns
      ) do
    ~H"""
    <div id={@dom_id} data-message-id={@msg.id} data-participant-id={@msg.participant_id}>
      <div
        :if={Map.get(@msg, :day_label)}
        class="js-date-separator flex items-center gap-3 my-4 -mx-2"
        data-date={@msg.day_label}
      >
        <div class="flex-1 border-t border-edge"></div>
        <span class="text-[11px] uppercase tracking-widest text-subtle font-semibold px-2">
          {format_day_label(@msg.day_label)}
        </span>
        <div class="flex-1 border-t border-edge"></div>
      </div>
      <ReplyFailureRow.row msg={@msg} viewer_user_id={@viewer_user_id} />
    </div>
    """
  end

  def chat_message(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class={[
        "group relative rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring",
        MapSet.member?(@agent_participant_ids, @msg.participant_id) && "msg-agent",
        @highlighted_message_id == @msg.id && "bg-primary/5 ring-1 ring-primary/20",
        @current_participant && @msg.participant_id == @current_participant.id &&
          !MapSet.member?(@agent_participant_ids, @msg.participant_id) && "bg-base-200/60"
      ]}
      data-agent-slot={
        MapSet.member?(@agent_participant_ids, @msg.participant_id) &&
          Platform.Agents.ColorPalette.slot_for(Map.get(@agent_slots_map, @msg.participant_id))
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
      phx-hook={if @read_only, do: nil, else: "MessageGestures"}
      tabindex={if @read_only, do: nil, else: "0"}
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
        <span class="text-[11px] uppercase tracking-widest text-subtle font-semibold px-2">
          {format_day_label(@msg.day_label)}
        </span>
        <div class="flex-1 border-t border-edge"></div>
      </div>

      <%!-- `message-row-inner` is the padding box. It carries a stable class
           because a grouped continuation row needs tighter vertical padding
           than the first row of a group, and that rule lives in app.css
           rather than in the grouping JS — see `.message-row--grouped`.
           It is also the band the pill opens on: app.css raises it to
           base-300 while the pill shows, and on desktop on hover, in
           media-gated CSS rather than a `hover:` utility. --%>
      <div class="message-row-inner relative flex gap-3 px-2 py-2 transition-all duration-200 ease-[cubic-bezier(0.16,1,0.3,1)] active:scale-[0.99] rounded-2xl">
        <.message_pill
          :if={!@read_only}
          msg={@msg}
          quick_emojis={@quick_emojis}
          reply?={
            MapSet.member?(@agent_participant_ids, @msg.participant_id) and
              is_nil(Map.get(@msg, :thread_id))
          }
        />
        <%!-- Avatar circle (hidden when grouped with previous message via JS) --%>
        <div class="flex-shrink-0 mt-0.5 message-avatar">
          <%= if MapSet.member?(@agent_participant_ids, @msg.participant_id) do %>
            <%!-- `msg-agent-avatar` is the slot ring (a box-shadow keyed off
                 `--ag`, which the row's `data-agent-slot` points at). It lands on the
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
            <span class={
              if(MapSet.member?(@agent_participant_ids, @msg.participant_id),
                do: "msg-agent-name",
                else: "text-sm font-bold text-base-content"
              )
            }>
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
              class="text-[10px] text-subtle"
            />
          </div>

          <%!-- The main-log reply quote (task 01a174f5 stage 3): the one
               message this row answers, one level only, set on the stream
               item by `ReplyQuoteHooks` (nil on a thread message and on an
               agent answer directly under its target). A visible quote is a
               button that jumps to the target; a deleted or no-access one is
               not. --%>
          <.reply_quote
            :if={is_nil(Map.get(@msg, :thread_id)) and Map.get(@msg, :reply_quote)}
            id={"reply-quote-#{@msg.id}"}
            quote={@msg.reply_quote}
            jump={true}
            class="mt-1 mb-1 max-w-xl"
          />

          <%!-- A text message can carry a canvas too: the composer's tray
               stages one beside the caption (redesign rung 11). --%>
          <div
            :if={
              @msg.content_type == "canvas" or
                (@msg.content_type == "text" and Map.get(@msg, :canvas_id))
            }
            class="mt-1"
          >
            <.inline_canvas
              :if={Map.get(@canvases_by_id, @msg.canvas_id)}
              msg={@msg}
              canvas={Map.get(@canvases_by_id, @msg.canvas_id)}
              title={CanvasHooks.message_canvas_title(@msg, @canvases_by_id)}
              mounted_ids={@mounted_inline_canvas_ids}
              viewer={@viewer_user_id && {:user, @viewer_user_id}}
            />

            <div
              :if={is_nil(Map.get(@canvases_by_id, @msg.canvas_id))}
              phx-click="canvas_open_mobile"
              phx-value-message-id={@msg.id}
              class="rounded-lg bg-base-200 px-3 py-2 cursor-pointer lg:hover:bg-base-300 transition-colors"
            >
              <p class="truncate text-sm font-semibold text-base-content">
                {CanvasHooks.message_canvas_title(@msg, @canvases_by_id)}
              </p>
              <p class="text-[11px] uppercase tracking-widest text-subtle">
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
            class="flex items-center gap-1 text-[11px] text-subtle lg:hover:text-base-content transition-colors mb-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring rounded"
          >
            <span class="hero-arrow-up-circle size-3.5"></span>
            <span>Correction to earlier message</span>
          </button>

          <%!-- Inbound email provenance (task 01a0cf21 stage 3). An email is
             outside text posted by the "Email (external)" system participant,
             so it is labelled as such above the body rather than looking like
             a Burrow participant's own message. Values come from the message
             metadata `Platform.Mail.Inbound` stamped; HEEx escapes them. --%>
          <% email_meta = email_inbound_metadata(@msg) %>
          <div
            :if={email_meta}
            data-role="mail-inbound-provenance"
            class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-subtle mb-1"
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
             from a shared space on another Burrow install is outside text
             posted by a "<name> (via <peer>)" system participant, so it is
             labelled as such above the body, as the mail block above is.
             Values come from the metadata `Platform.Federation.Peers.Ingest`
             stamped; HEEx escapes them. --%>
          <% federation_meta = federation_inbound_metadata(@msg) %>
          <div
            :if={federation_meta}
            data-role="federation-inbound-provenance"
            class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-subtle mb-1"
          >
            <span class="hero-globe-alt size-3.5 shrink-0" aria-hidden="true"></span>
            <span>
              Shared from {federation_meta["peer_display_name"] || "a Burrow peer"}, by {federation_meta[
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

          <%!-- A line that is only a link this viewer gets a card or a player
               for is dropped: the card replaces it (rung 13 rule 1; task
               01a1655c stage 3 for linked attachments). An outside link
               inside a sentence becomes an inline chip (link previews stage
               1). Unreadable attachment
               links are not in the map, so they stay plain links. A message
               with no `:link_cards` (thread panel, search) renders plain
               anchors exactly as before. --%>
          <% rendered_content =
            Platform.Chat.ContentRenderer.render_message(
              Platform.Chat.human_content(@msg),
              cards:
                Platform.Chat.LinkCards.bare_urls(Map.get(@msg, :link_cards)) ++
                  for(
                    a <- Map.get(@attachments_map, @msg.id, []),
                    do: "/chat/attachments/#{a.id}"
                  ),
              chips: PlatformWeb.Components.ChatLinkCard.chips(@msg.id, Map.get(@msg, :link_cards))
            ) %>
          <div
            :if={
              @editing_message_id != @msg.id and @msg.content_type != "canvas" and
                rendered_present?(rendered_content)
            }
            class="text-sm text-base-content break-words chat-markdown"
          >
            {rendered_content}
          </div>

          <%!-- (edited) affix per contract Section D.1: shown only on
             messages with >1 version row (at least one edit on top of the
             original v1). It opens version history, a sheet on a phone and a
             popover on desktop (Section D.2; redesign rung 9 stage 4), and is
             the ONLY way in, so it sits after the text, as the masters'
             `.edited` does, and never inside `.message-header`: a
             continuation row hides every header child (app.css,
             `.message-row--grouped .message-header > *`), which made it
             unreachable on most rows of a same-author run. --%>
          <button
            :if={is_integer(Map.get(@msg, :versions_count)) && @msg.versions_count > 1}
            type="button"
            phx-click="show_version_history"
            phx-value-message-id={@msg.id}
            id={"message-edited-#{@msg.id}"}
            data-role="message-edited"
            aria-haspopup="dialog"
            title="Version history"
            class="block text-[13px] text-subtle lg:hover:text-base-content lg:hover:underline transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-1 focus-visible:ring-offset-base-100 rounded"
          >
            (edited)
          </button>

          <.link_cards
            :if={@editing_message_id != @msg.id and Map.get(@msg, :link_cards) not in [nil, []]}
            msg_id={@msg.id}
            cards={@msg.link_cards}
          />

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
              id={"gallery-#{@msg.id}-#{attachment.id}"}
              data-role="gallery-item"
              data-viewer-open
              phx-click="viewer_open"
              phx-value-message_id={@msg.id}
              phx-value-attachment_id={attachment.id}
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
            <%!-- Received video (task 01a120be stage 3, 01a1655c): the
                 shared player, also used for video URLs (rung 13). Several
                 clips stack, each with its own file line. --%>
            <.clip_player
              :for={attachment <- Enum.filter(non_images, &video_attachment?/1)}
              id={"video-#{@msg.id}-#{attachment.id}"}
              src={video_src(attachment)}
              poster={video_poster(attachment)}
              download_url={attachment_url(attachment)}
              filename={attachment.filename}
              byte_size={attachment.byte_size || 0}
              duration={clip_duration(attachment)}
              aspect_style={video_aspect_style(attachment)}
            />
            <.file_card
              :for={attachment <- Enum.reject(non_images, &video_attachment?/1)}
              attachment={attachment}
              msg_id={@msg.id}
            />
          </div>

          <%!-- The refused-summon notice and the reaction row arrive while
               someone may be typing in this message's thread reply box
               (a refusal from the server, a reaction from anyone). Each
               lives in an always-rendered, box-less slot, so neither is
               ever a new sibling ahead of the thread: the DOM patch would
               re-append the thread after it and blur the reply field
               (rung 10 stage 5). --%>
          <div id={"refused-summon-slot-#{@msg.id}"} class="contents">
            <.refused_summon_notice
              :if={Map.has_key?(@refused_summons, @msg.id)}
              msg_id={@msg.id}
              names={Map.get(@refused_summons, @msg.id, [])}
              space_kind={@space_kind}
            />
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
          <div id={"reactions-slot-#{@msg.id}"} class="contents">
            <div
              :if={@msg.reactions != []}
              role="toolbar"
              aria-label="Message actions"
              class="reaction-row flex flex-wrap gap-1 mt-0.5"
            >
              <%!-- Reaction pills stay visible on read-only snapshots (they
                 are part of the frozen history) but stop toggling.

                 Redesign rung 9 stage 3 (masters `.react span`, direction
                 m1): NEUTRAL, never primary. Not mine is base-200 with the
                 edge border; mine is the raised base-300 with a
                 base-content outline. A tap toggles through `react`; a
                 long-press on a phone pushes `open_reactors`
                 (`ReactorPopover`), and desktop keeps the hover popover.
                 The phone hit area (44px) and the desktop hover fill are
                 app.css, media-gated. --%>
              <button
                :for={r <- @msg.reactions}
                id={"reaction-#{@msg.id}-#{r.emoji}"}
                type="button"
                data-role="reaction-pill"
                phx-hook="ReactorPopover"
                phx-click={if @read_only, do: nil, else: "react"}
                phx-value-message-id={@msg.id}
                phx-value-emoji={r.emoji}
                data-emoji={r.emoji}
                data-mine={r.reacted_by_me && "true"}
                data-reactors={Jason.encode!(r.reactors)}
                data-extra-count={r.extra_count}
                aria-label={reactor_aria_label(r)}
                aria-pressed={to_string(r.reacted_by_me)}
                class={[
                  "reaction-pill relative flex h-7 items-center gap-1 rounded-full border px-2 text-[13px] leading-none text-base-content tabular-nums transition-colors",
                  if(r.reacted_by_me,
                    do: "bg-base-300 border-base-content",
                    else: "bg-base-200 border-edge"
                  )
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
          </div>

          <%!-- Inline thread: indicator + expanded thread --%>
          <div :if={
            Map.has_key?(@thread_previews, @msg.id) or
              MapSet.member?(@expanded_threads, @msg.id)
          }>
            <%!-- Thread chip (collapsed state; masters `.thread-ind`,
                 direction m1): '↩ N replies · time' in subtle text, no
                 fill and no avatar. It TOGGLES; Reply in thread (the pill's
                 ↩ and the sheet row) only ever opens. --%>
            <button
              :if={not MapSet.member?(@expanded_threads, @msg.id)}
              type="button"
              phx-click="toggle_inline_thread"
              phx-value-message-id={@msg.id}
              class="thread-indicator"
              data-role="thread-chip"
            >
              {thread_chip_label(Map.get(@thread_previews, @msg.id, %{}))}
            </button>

            <%!-- Expanded thread --%>
            <div
              :if={MapSet.member?(@expanded_threads, @msg.id)}
              class="thread-replies"
              id={"inline-thread-#{@msg.id}"}
              phx-hook="InlineThread"
            >
              <%!-- The reply rows live in their own always-rendered,
                   box-less (`contents`) container, so a reply arriving
                   (yours after a send, or an agent's) is inserted INSIDE it
                   and the reply box's own siblings never change. Inserted
                   as the box's sibling, it made the DOM patch walk past the
                   box and re-append it after the new row: a moved field
                   blurs (measured on the dev rig, rung 10 stage 5: focus
                   lost ~90ms after a thread send). Ids on the rows, the
                   container and the box are their morph keys. --%>
              <div id={"inline-thread-replies-#{@msg.id}"} class="contents">
                <div
                  :for={tmsg <- Map.get(@inline_thread_messages, @msg.id, [])}
                  id={"inline-thread-reply-#{tmsg.id}"}
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
                      {Platform.Chat.ContentRenderer.render_message(Platform.Chat.human_content(tmsg))}
                    </div>
                    <.refused_summon_notice
                      :if={Map.has_key?(@refused_summons, tmsg.id)}
                      msg_id={tmsg.id}
                      names={Map.get(@refused_summons, tmsg.id, [])}
                      space_kind={@space_kind}
                    />
                  </div>
                </div>
              </div>

              <%!-- Thread composer — absent on read-only snapshots. The
                   reply box is the same chip field as the space composer
                   (redesign rung 10, stage 4): contenteditable, chips,
                   Enter sends, its own draft (`thread-draft:<id>`, apart
                   from the space's `chat-draft:<id>`). ComposeInput clears
                   it after a send (`data-clear-on-submit`): the reply
                   handler pushes no `compose_reset`. --%>
              <div
                :if={!@read_only}
                id={"inline-thread-composer-#{@msg.id}"}
                class="thread-composer"
              >
                <.form
                  for={%{}}
                  id={"inline-thread-compose-form-#{@msg.id}"}
                  phx-submit="send_inline_thread_message"
                  class="thread-composer-form"
                >
                  <input
                    type="hidden"
                    name="inline_thread_compose[message_id]"
                    value={@msg.id}
                  />
                  <%!-- The field's box. The @mention list (the space
                       composer's own `MentionList`) hangs from its top edge,
                       its width, and covers the thread above it: this
                       composer sits inside #message-list, so a list in flow
                       would push the box down and grow the scroller. The
                       anchoring is CSS (`.thread-field-box .mention-list`). --%>
                  <div class="thread-field-box">
                    <.mention_list
                      open={
                        @mention_source == "inline-thread-compose-form-#{@msg.id}" and
                          MentionList.open?(@mention_suggestions, @mention_query)
                      }
                      id={"inline-thread-mention-list-#{@msg.id}"}
                      suggestions={@mention_suggestions}
                      query={@mention_query}
                      field_id={"inline-thread-compose-#{@msg.id}"}
                    />
                    <%!-- The form value, written by ComposeInput on every
                         edit. `type="text"` with `hidden` (not
                         `type="hidden"`) for the reason the space composer's
                         value input gives. --%>
                    <input
                      type="text"
                      name="inline_thread_compose[text]"
                      id={"inline-thread-compose-value-#{@msg.id}"}
                      value=""
                      hidden
                      autocomplete="off"
                    />
                    <div
                      id={"inline-thread-compose-#{@msg.id}"}
                      class="thread-input"
                      contenteditable="true"
                      phx-hook="ComposeInput"
                      phx-update="ignore"
                      role="combobox"
                      aria-autocomplete="list"
                      aria-expanded="false"
                      aria-controls={"inline-thread-mention-list-#{@msg.id}"}
                      aria-multiline="true"
                      aria-label="Reply in thread"
                      enterkeyhint="send"
                      data-draft-key={"thread-draft:#{@msg.id}"}
                      data-placeholder="Reply in thread"
                      data-value-input={"inline-thread-compose-value-#{@msg.id}"}
                      data-clear-on-submit
                    ></div>
                  </div>
                  <%!-- Disabled until the field holds text other than spaces
                       (threads have no staged tray). The server cannot see
                       the field, so it renders Send disabled and
                       ComposeInput lights it from what is typed. --%>
                  <button
                    type="submit"
                    class="thread-send"
                    disabled
                    data-send-blocked={to_string(is_nil(@current_participant))}
                    data-staged="false"
                    aria-label="Send"
                  >
                    Send
                  </button>
                </.form>
              </div>

              <%!-- The footer collapse (masters `.thread-ind[data-thread=close]`). --%>
              <button
                type="button"
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                class="thread-collapse"
                data-role="thread-collapse"
              >
                collapse
              </button>
            </div>
          </div>
          <%!-- "Get someone's attention" (redesign rung 12): the added line
               after the text, thread, link card, images and reactions
               (masters `.attn`, mobile 383/921-927, desktop 199/776-781).
               Always-rendered box-less slot, after the thread, so it is
               never a new sibling ahead of a reply box. Adding attention
               never edits the message, so it never renders "(edited)". --%>
          <div id={"attention-slot-#{@msg.id}"} class="contents">
            <.attention_line
              :if={Map.get(@msg, :attention, []) != []}
              msg={@msg}
              current_participant={@current_participant}
            />
          </div>
          <%!-- "+@ add someone" (masters `.addat`, mobile 386-388/929-930,
               desktop 202-203/783): rendered on every own message, SHOWN only
               on the last row of #message-list while the newest messages are
               on screen (app.css `.message-add-attention`), so it moves to a
               newer own message, and leaves when anyone posts after it,
               without a server round trip. Its dashed border is --subtle, not
               the masters' edge hairline: edge is ~1.3:1 on the own and open
               bands and a control boundary owes 3:1 (stage 3 contrast guard). --%>
          <button
            :if={
              !@read_only and @current_participant != nil and
                @msg.participant_id == @current_participant.id and
                !MapSet.member?(@agent_participant_ids, @msg.participant_id)
            }
            type="button"
            data-role="message-add-attention"
            class="message-add-attention mt-1 ml-1.5 mb-1.5 h-6 lg:h-[22px] items-center gap-[3px] rounded-md lg:rounded-full border border-dashed border-subtle px-2 text-xs text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            aria-label="Get someone's attention on this message"
            title="Add someone to this message"
            phx-click="open_message_attention"
            phx-value-message-id={@msg.id}
          >
            +@ <span>add someone</span>
          </button>
        </div>
        <%!-- end message body --%>
      </div>
      <%!-- end inner flex row --%>
    </div>
    """
  end

  attr(:msg, :map, required: true)
  attr(:quick_emojis, :list, required: true)
  # An agent-authored top-level message (task 01a174f5 stage 2): the arrow is
  # 'Reply', a main-log reply through the composer chip (`start_reply`,
  # `ReplyHooks`), and focuses the composer. It opens no thread; 'Reply in
  # thread' stays a row in the actions sheet and popover.
  attr(:reply?, :boolean, default: false)

  # The tap pill (redesign rung 9, task 01a1557a-9406; masters `.m .acts`,
  # direction canvas 01a1666e node m3). Hidden until the row carries
  # `data-pill-open` (set by the MessageGestures hook on a tap) or, on
  # desktop, until the row is hovered or holds focus: app.css owns the
  # display rules. It replaces the desktop hover row, the left-gutter reply
  # and the dead long-press lift pill. The glyphs are literal by design; the
  # names are the aria-labels. Neutral surface, never primary.
  defp message_pill(assigns) do
    ~H"""
    <div
      data-role="message-pill"
      role="toolbar"
      aria-label="Message actions"
      class="message-pill absolute right-2 -top-4 lg:-top-[15px] z-10 items-center gap-0.5 p-0.5 bg-base-300 border border-edge rounded-full shadow-sm"
    >
      <button
        type="button"
        class="message-pill-btn relative inline-flex size-7 lg:size-[26px] items-center justify-center rounded-full text-sm leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="React with thumbs up"
        title="React with thumbs up"
        phx-click="react"
        phx-value-message-id={@msg.id}
        phx-value-emoji={List.first(@quick_emojis)}
      >
        <span aria-hidden="true">👍</span>
      </button>
      <button
        :if={@reply?}
        type="button"
        class="message-pill-btn relative inline-flex size-7 lg:size-[26px] items-center justify-center rounded-full text-sm leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="Reply"
        title="Reply"
        data-role="message-pill-reply"
        phx-click={
          Phoenix.LiveView.JS.push("start_reply", value: %{"message-id" => @msg.id})
          |> Phoenix.LiveView.JS.focus(to: "#compose_text")
        }
      >
        <span aria-hidden="true">↩</span>
      </button>
      <button
        :if={!@reply?}
        type="button"
        class="message-pill-btn relative inline-flex size-7 lg:size-[26px] items-center justify-center rounded-full text-sm leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="Reply in thread"
        title="Reply in thread"
        data-role="message-pill-thread"
        phx-click="open_inline_thread"
        phx-value-message-id={@msg.id}
      >
        <span aria-hidden="true">↩</span>
      </button>
      <%!-- Redesign rung 12: +@ sits between ↩ and ⋯ as in the masters'
           `.acts` (mobile 922, desktop 728); rung 9's ⧉ stays next to ⋯.
           Auto width, bold, text-xs (`.atplus`). --%>
      <button
        type="button"
        class="message-pill-btn relative inline-flex h-7 lg:h-[26px] min-w-7 lg:min-w-[26px] items-center justify-center rounded-full px-1.5 text-xs font-bold leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="Get someone's attention"
        title="Get someone's attention"
        data-role="message-pill-attention"
        phx-click="open_message_attention"
        phx-value-message-id={@msg.id}
      >
        <span aria-hidden="true">+@</span>
      </button>
      <button
        type="button"
        class="message-pill-btn relative inline-flex size-7 lg:size-[26px] items-center justify-center rounded-full text-sm leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="Copy"
        title="Copy"
        data-role="message-pill-copy"
        data-clipboard-text={Platform.Chat.human_content(@msg) || ""}
      >
        <span class="message-pill-copy-glyph" aria-hidden="true">⧉</span>
        <span class="message-pill-copy-check hero-check size-4" aria-hidden="true"></span>
      </button>
      <button
        type="button"
        class="message-pill-btn relative inline-flex size-7 lg:size-[26px] items-center justify-center rounded-full text-sm leading-none text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        aria-label="More actions"
        title="More actions"
        phx-click="open_message_actions"
        phx-value-id={@msg.id}
      >
        <span aria-hidden="true">⋯</span>
      </button>
    </div>
    """
  end

  attr(:msg, :map, required: true)
  attr(:current_participant, :any, default: nil)

  # The added line (redesign rung 12; masters `attnHTML`, mobile 1381,
  # desktop 729). One line per adder, in the order they first asked, each
  # worded for THIS viewer:
  #
  #   * the viewer asked on their own message: "→ @A, @B added · notified"
  #   * the viewer asked on someone else's: "you asked @A to look"
  #   * someone else asked: "<their name> asked @A to look" (not in canvas)
  #
  # Chips are @Name, semibold, on a primary tint with base-content text (the
  # masters' interactive text colour is replaced by palette rule R5). No undo
  # chip: undo is deferred (D6).
  #
  # The line is inline text, not a flex row: its words and chips then read
  # as one sentence, with real spaces, to a screen reader and to a copy, and
  # it still wraps between chips.
  defp attention_line(assigns) do
    viewer_id = assigns.current_participant && assigns.current_participant.id
    own? = viewer_id != nil and assigns.msg.participant_id == viewer_id

    groups =
      assigns.msg.attention
      |> Enum.group_by(& &1.added_by_participant_id)
      |> Enum.map(fn {adder_id, [first | _] = rows} ->
        %{
          adder_id: adder_id,
          first_at: first.inserted_at,
          parts:
            attention_parts(
              attention_wording(adder_id, first.added_by_display_name, viewer_id, own?),
              Enum.map(rows, & &1.display_name)
            )
        }
      end)
      |> Enum.sort_by(& &1.first_at, DateTime)

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div class="mt-1" data-role="message-attention-slot">
      <p
        :for={g <- @groups}
        data-role="message-attention"
        data-added-by={g.adder_id}
        class="ml-1.5 mb-1.5 text-sm leading-6 text-subtle"
      >
        <.attention_part :for={part <- g.parts} part={part} />
      </p>
    </div>
    """
  end

  defp attention_wording(adder_id, _name, viewer_id, true) when adder_id == viewer_id,
    do: :own

  defp attention_wording(adder_id, _name, viewer_id, _own?)
       when adder_id == viewer_id and not is_nil(viewer_id),
       do: :you

  defp attention_wording(_adder_id, name, _viewer_id, _own?), do: {:other, name || "Someone"}

  # The line as text and chip parts, the spaces in the text (whitespace
  # between parts in the markup collapses into them).
  defp attention_parts(wording, names) do
    # The comma rides inside the chip's part: a part boundary is a newline
    # in the markup, which would render as a space BEFORE the comma.
    last = length(names) - 1

    chips =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} -> {:chip, name, if(i < last, do: ", ", else: "")} end)

    case wording do
      :own -> [{:text, "→ "}] ++ chips ++ [{:text, " added · notified"}]
      :you -> [{:text, "you asked "}] ++ chips ++ [{:text, " to look"}]
      {:other, name} -> [{:text, "#{name} asked "}] ++ chips ++ [{:text, " to look"}]
    end
  end

  attr(:part, :any, required: true)

  defp attention_part(%{part: {:chip, name, comma}} = assigns) do
    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:comma, comma)
      |> assign(:class, "rounded-sm bg-primary/15 px-1.5 font-semibold text-base-content")

    ~H"""
    <span><span data-role="message-attention-chip" class={@class}>@{@name}</span>{@comma}</span>
    """
  end

  defp attention_part(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <span>{@text}</span>
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

  # ── Refused agent summon notice (task 01a0fd62 stage 2) ──────────────
  #
  # Design: Saru's canvas "Refused agent mention: author notice", candidate
  # (a). An inline, author-only, ephemeral notice under the author's own
  # message: no fill (the row's ground shows through), a 2px info-blue left
  # rule and icon as the only colour, the statement at full `text-base-content`
  # and the meta line at `/60` (the measured AA floor). `role="status"` is
  # polite on purpose; a permission explanation is not an alert.
  attr(:msg_id, :string, required: true)
  attr(:names, :list, required: true)
  attr(:space_kind, :string, default: "channel")

  defp refused_summon_notice(assigns) do
    assigns =
      assigns
      |> assign(:verb, if(length(assigns.names) == 1, do: "was", else: "were"))
      |> assign(:reason, refused_summon_reason(assigns.space_kind))

    ~H"""
    <div
      role="status"
      data-role="refused-summon-notice"
      data-refused-for={@msg_id}
      class="mt-1 flex items-start gap-1.5 border-l-2 border-info pl-2 text-xs text-base-content"
    >
      <span class="hero-information-circle size-3.5 shrink-0 text-info mt-px" aria-hidden="true">
      </span>
      <div class="min-w-0 flex-1">
        <p class="break-words">
          <.refused_names parts={refused_name_parts(@names)} /> {@verb} not added. {@reason}
        </p>
        <div class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-subtle">
          <span data-role="refused-summon-visibility" class="text-[11px]">Only you can see this</span>
          <span aria-hidden="true">·</span>
          <%!-- Task 01a0fd62 stage 3: the members panel is where admins are
               identifiable, so it is the next step. Channels only; the panel
               button exists only there. `details: "space"` (Burrow redesign
               22 stage 4): the desktop Members popover lives under the
               details panel's Members row, so the panel opens with it. --%>
          <button
            :if={@space_kind == "channel"}
            type="button"
            phx-click={Phoenix.LiveView.JS.push("members_open", value: %{details: "space"})}
            data-role="refused-summon-view-members"
            class="btn btn-ghost btn-xs rounded-field px-1 text-xs font-medium text-base-content max-sm:min-h-11 max-sm:min-w-11 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            View members
          </button>
          <span :if={@space_kind == "channel"} aria-hidden="true">·</span>
          <button
            type="button"
            phx-click="dismiss_refused_summon"
            phx-value-id={@msg_id}
            data-role="refused-summon-dismiss"
            class="btn btn-ghost btn-xs rounded-field px-1 text-xs font-medium text-base-content max-sm:min-h-11 max-sm:min-w-11 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Kept on ONE short line at low indent on purpose: `mix format` breaks a long
  # HEEx line between the tags, and the newline it inserts renders as a space
  # BEFORE each separator ("@a , @b"). The three-agent LiveView test pins it.
  attr(:parts, :list, required: true)

  defp refused_names(assigns) do
    ~H"""
    <span :for={{sep, name} <- @parts}>{sep}<span class="font-medium">@{name}</span></span>
    """
  end

  # "@a", "@a and @b", "@a, @b and @c": each name paired with the separator
  # that precedes it.
  defp refused_name_parts(names) do
    count = length(names)

    names
    |> Enum.with_index()
    |> Enum.map(fn
      {name, 0} -> {"", name}
      {name, idx} when idx == count - 1 -> {" and ", name}
      {name, _idx} -> {", ", name}
    end)
  end

  # Who can act, by space kind (canvas open question 5). Groups have no admin
  # row on main (`create_group` seats members), so their copy is accurate but
  # nobody can currently satisfy it; that is a follow-up, not this ticket.
  defp refused_summon_reason("execution"),
    do: "Only the task's sponsor can bring agents into this space."

  defp refused_summon_reason("channel"),
    do: "Only a channel admin can bring agents into this channel."

  defp refused_summon_reason(_kind), do: "Only an admin of this conversation can bring agents in."

  # The thread chip's copy (masters `.thread-ind`): '↩ 2 replies · 5m ago',
  # 'reply' at one, and no time until a reply carries one.
  defp thread_chip_label(preview) do
    count = Map.get(preview, :reply_count, 0)
    noun = if count == 1, do: "reply", else: "replies"

    case Map.get(preview, :last_reply_at) do
      nil -> "↩ #{count} #{noun}"
      at -> "↩ #{count} #{noun} · #{relative_time(at)}"
    end
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
