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
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]
  import PlatformWeb.Components.ChatHelpers

  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.CanvasHooks

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
      data-date={@msg.inserted_at && DateTime.to_date(@msg.inserted_at) |> Date.to_iso8601()}
      data-message-id={@msg.id}
      data-is-own-message={
        if(@current_participant && @msg.participant_id == @current_participant.id,
          do: "true",
          else: "false"
        )
      }
      phx-hook="LongpressMenu"
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
        <div class="flex-1 border-t border-base-300"></div>
        <span class="text-[11px] uppercase tracking-widest text-base-content/40 font-semibold px-2">
          {format_day_label(@msg.day_label)}
        </span>
        <div class="flex-1 border-t border-base-300"></div>
      </div>

      <div class="flex gap-3 px-2 py-2 transition-all duration-200 ease-[cubic-bezier(0.16,1,0.3,1)] hover:bg-base-200/40 active:scale-[0.99] rounded-2xl">
        <%!-- Avatar circle (hidden when grouped with previous message via JS) --%>
        <div class="flex-shrink-0 mt-0.5 message-avatar">
          <%= if MapSet.member?(@agent_participant_ids, @msg.participant_id) do %>
            <div class="w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold select-none bg-base-300 text-primary msg-agent-avatar">
              {PresenceHooks.avatar_initial(@participants_map, @msg)}
            </div>
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
            <.local_time
              id={"message-time-#{@msg.id}"}
              timestamp={@msg.inserted_at}
              class="text-[10px] text-base-content/40"
            />
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
              class="text-[10px] text-base-content/40 hover:text-base-content/70 hover:underline transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100 rounded"
            >
              (edited)
            </button>

            <div class="ml-auto hidden group-hover:flex items-center gap-1">
              <button
                :for={emoji <- @quick_emojis}
                phx-click="react"
                phx-value-message-id={@msg.id}
                phx-value-emoji={emoji}
                title={"React with #{emoji}"}
                class="rounded px-1.5 py-0.5 text-sm hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                {emoji}
              </button>

              <button
                phx-click="open_reaction_picker"
                phx-value-message-id={@msg.id}
                title="More reactions"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-face-smile size-4"></span>
              </button>

              <button
                :if={present?(@msg.content)}
                phx-hook="CopyToClipboard"
                id={"copy-msg-#{@msg.id}"}
                data-clipboard-text={@msg.content}
                title="Copy message"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-clipboard-document-list size-4"></span>
              </button>

              <%!-- Edit affordance (task 019e0f29 Stage 4 — placed AFTER Copy
                 per the plan). Visible only on the current user's own
                 non-agent text messages (Policy 3 of the editable-messages
                 contract — agents cannot self-edit; humans cannot edit
                 agent messages). When `frozen_at` is set (Policy 2 — an
                 agent has begun work), render with disabled styling and
                 a tooltip; the phx-click is suppressed via :if-nil so the
                 click does nothing. Placeholder event name — Stage 5
                 connects it to the inline editor. --%>
              <button
                :if={
                  @current_participant && @msg.participant_id == @current_participant.id &&
                    @current_participant.participant_type == "user" &&
                    @msg.content_type == "text"
                }
                type="button"
                phx-click={if is_nil(@msg.frozen_at), do: "edit_message_clicked"}
                phx-value-message-id={@msg.id}
                aria-label="Edit message"
                aria-disabled={if @msg.frozen_at, do: "true"}
                title={edit_affordance_title(@msg, @participants_map)}
                class={[
                  "rounded px-1.5 py-0.5 text-xs text-base-content/50 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100",
                  if(@msg.frozen_at,
                    do: "opacity-50 cursor-not-allowed",
                    else: "hover:text-base-content hover:bg-base-300"
                  )
                ]}
              >
                <span class="hero-pencil-square size-4"></span>
              </button>

              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                title="Reply"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-chat-bubble-left-right size-4"></span>
              </button>

              <button
                phx-click="toggle_inline_thread"
                phx-value-message-id={@msg.id}
                title="Open thread"
                class="rounded px-1.5 py-0.5 text-xs text-base-content/40 hover:text-base-content/60 hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
              >
                <span class="hero-arrow-top-right-on-square size-4"></span>
              </button>

              <button
                phx-click="pin_toggle"
                phx-value-message-id={@msg.id}
                phx-value-space-id={@msg.space_id}
                title={if MapSet.member?(@pinned_message_ids, @msg.id), do: "Unpin", else: "Pin"}
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
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
                class="rounded px-1.5 py-0.5 text-xs text-base-content/50 hover:text-base-content hover:bg-base-300 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-1 focus-visible:ring-offset-base-100"
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
            class="flex items-center gap-1 text-[11px] text-base-content/60 hover:text-base-content/80 transition-colors mb-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 rounded"
          >
            <span class="hero-arrow-up-circle size-3.5"></span>
            <span>Correction to earlier message</span>
          </button>

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

          <div
            :if={@msg.reactions != []}
            class="reaction-row flex flex-wrap gap-1 mt-0.5"
          >
            <button
              :for={r <- @msg.reactions}
              id={"reaction-#{@msg.id}-#{r.emoji}"}
              phx-hook="ReactorPopover"
              phx-click="react"
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
                !r.reacted_by_me && "border-base-300 text-base-content/60"
              ]}
            >
              <span>{r.emoji}</span>
              <span>{r.count}</span>
            </button>

            <button
              class="reaction-add-btn flex items-center gap-1 rounded-full border border-dashed border-base-300 px-2 py-0.5 text-xs text-base-content/40 hover:bg-base-300 hover:text-base-content"
              aria-label="Add reaction"
              phx-click="open_reaction_picker"
              phx-value-message-id={@msg.id}
            >
              <span class="hero-plus size-4"></span>
            </button>
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
                <div
                  class={[
                    "msg-avatar",
                    if(MapSet.member?(@agent_participant_ids, tmsg.participant_id),
                      do: "ai",
                      else: "human"
                    )
                  ]}
                  style="width:28px;height:28px;font-size:10px"
                >
                  {PresenceHooks.avatar_initial(@participants_map, tmsg.participant_id)}
                </div>
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

              <%!-- Thread composer --%>
              <div class="thread-composer" style="flex-direction: column; align-items: stretch;">
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
                          <div class="w-6 h-6 rounded-full bg-primary text-primary-content flex items-center justify-center text-xs font-bold flex-shrink-0">
                            {(suggestion.display_name || "U")
                            |> String.trim()
                            |> String.first()
                            |> String.upcase()}
                          </div>
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
  defp format_timestamp(_), do: ""

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

  # Tooltip text for the Edit affordance on a message row. When the
  # message is frozen, surfaces the freezing-participant's display name
  # (per the editable-messages contract Section B.5 freezing_action
  # payload) so the user can see *who* is acting on the message.
  defp edit_affordance_title(%{frozen_at: nil}, _participants_map), do: "Edit message"

  defp edit_affordance_title(%{frozen_by_participant_id: nil}, _participants_map) do
    "An agent has begun work on this message — send a follow-up to revise."
  end

  defp edit_affordance_title(msg, participants_map) do
    base = "An agent has begun work on this message — send a follow-up to revise."

    case Map.get(participants_map, msg.frozen_by_participant_id) do
      %{display_name: name} when is_binary(name) and name != "" ->
        base <> " (started by #{name})"

      _ ->
        base
    end
  end
end
