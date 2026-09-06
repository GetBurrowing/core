defmodule PlatformWeb.ChatLive.Partials.Composer do
  @moduledoc """
  The bottom half of the conversation pane — the archived banner, the
  message scroller, the streaming/typing indicators and the composer.

  Same split as `ChatLive.Partials`, `ChatLive.Partials.ExternalRail`,
  `ChatLive.Partials.Rail`, `ChatLive.Partials.MobileBrowser` and
  `ChatLive.Partials.Conversation` (ADR 0035): function components, no
  state, each taking a declared set of attrs. Extracted from
  `chat_live.html.heex` in task 01a0312e stage 6 as a PURE MOVE — every
  `id`, `phx-hook`, `phx-submit`, `phx-change`, `phx-click`, `data-*`,
  `name` and `style` sits on the element it sat on before.

  This is a SEPARATE FILE from `Partials.Conversation` only because that
  module was already past 900 lines when this region moved; the split is
  BY SECTION inside the one `Partials` namespace, not a parallel scheme.

  The regions, in template order:

    * `archived_banner/1` — `<div id="archived-banner">`, including the
      deletion-scheduled variant and the admin-only Cancel
    * `message_scroller/1` — `<div id="chat-message-scroller">`, the
      message list and both infinite-scroll sentinels
    * `streaming_replies/1` — the in-flight agent reply bubbles
    * `typing_indicator/1` — the agent-typing dots
    * `composer/1` — `<div class="... compose-input-area safe-area-bottom">`,
      the compose form, the always-present upload form and the
      no-participant error line

  ## NO COMPONENT HERE MAY ADD A WRAPPER ELEMENT

  `#chat-message-scroller` is the flex child of `#chat-drop-zone`, and the
  `min-h-0` on it is load-bearing (the comment inside `message_scroller/1`
  says why). **Any element interposed between the flex parent and this
  scroller breaks the chain even though every class string is intact** —
  the interposed div gets the default `min-height: auto`, the list stops
  shrinking, and with 80+ messages the composer and bottom-tab nav go off
  the bottom of the screen on iOS Safari / PWA standalone. That failure is
  invisible to a class-string diff and to every unit test in the suite.

  So each component here renders the MOVED element as its template root.
  A Phoenix function component emits exactly what its template emits, so
  `<.message_scroller ... />` produces `#chat-message-scroller` as a direct
  child of `#chat-drop-zone`, exactly as the inline markup did.
  `chat/composer_structure_test.exs` asserts that parent-child relation
  directly rather than trusting the attributes.

  ## THE COMPOSER IS STRUCTURALLY ABSENT ON ARCHIVED SPACES

  The `:if={@active_space && is_nil(@active_space.archived_at)}` gates on
  the two forms travelled WITH the markup. Hiding is affordance only — the
  context layer rejects the writes regardless — but the absence is
  deliberate and asserted, so the gate stays on the forms rather than
  being lifted to the call site.

  ## WHY `masked_space_name/2` IS WRAPPED, NOT QUALIFIED

  Same reason as `Partials.Conversation`: the composer placeholder sits on
  a line already close to the formatter's width, and a longer qualified
  call reflows the interpolation, which puts whitespace inside the
  attribute value. Same call text, same wrapping, no reflow.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.Partials, only: [upload_error_to_string: 1]
  import PlatformWeb.ChatLive.RenderHelpers, only: [composer_empty?: 1]
  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1, human_avatar: 1]
  import PlatformWeb.Components.ChatMessage, only: [chat_message: 1]
  import PlatformWeb.Components.EmptyState, only: [empty_state: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Chat
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.PresenceHooks

  attr(:active_space, :any, required: true)
  attr(:can_unarchive?, :boolean, required: true)
  attr(:can_cancel_deletion?, :boolean, required: true)

  @doc """
  The archived read-only banner. The `:if` on `@active_space.archived_at`
  travelled into the component with the markup, so the call site states no
  render condition of its own.
  """
  def archived_banner(assigns) do
    ~H"""
    <%!-- Archived read-only banner (task 019e95ea stage 2). Sits as a
         flex-shrink-0 sibling above the message scroller. The Unarchive
         button is gated on @can_unarchive? (computed server-side when
         :active_space is assigned) — affordance only, the context layer
         re-authorizes.

         Stage 4: when a deletion is scheduled the banner shows the purge
         date instead, with a Cancel button for Fabrikam admins only
         (@can_cancel_deletion?). Unarchive is hidden while deletion is
         pending — cancel first, then unarchive. Deletion-flagged channels
         are excluded from the sidebar's Archived section, so this banner
         is reached via direct URL; that's expected. --%>
    <div
      :if={@active_space && @active_space.archived_at}
      id="archived-banner"
      role="status"
      class="flex-shrink-0 flex items-center gap-3 border-b border-edge bg-base-200/60 px-5 py-2.5"
    >
      <%= if @active_space.deletion_scheduled_at do %>
        <span class="hero-trash size-4 flex-shrink-0 text-error"></span>
        <p class="flex-1 text-sm text-base-content/70">
          This channel is scheduled for permanent deletion on {Calendar.strftime(
            DateTime.add(
              @active_space.deletion_scheduled_at,
              Chat.space_retention_days(),
              :day
            ),
            "%B %-d, %Y"
          )} — it's read-only until then.
        </p>
        <button
          :if={@can_cancel_deletion?}
          type="button"
          phx-click="cancel_space_deletion"
          class="btn btn-outline btn-xs"
        >
          Cancel deletion
        </button>
      <% else %>
        <span class="hero-archive-box size-4 flex-shrink-0 text-base-content/60"></span>
        <p class="flex-1 text-sm text-base-content/70">
          This channel was archived on {Calendar.strftime(
            @active_space.archived_at,
            "%B %-d, %Y"
          )} — it's a read-only snapshot.
        </p>
        <button
          :if={@can_unarchive?}
          type="button"
          phx-click="unarchive_space"
          class="btn btn-outline btn-xs"
        >
          Unarchive
        </button>
      <% end %>
    </div>
    """
  end

  attr(:streams, :any, required: true)
  attr(:has_more_older, :boolean, required: true)
  attr(:loading_older, :boolean, required: true)
  attr(:newest_evicted?, :boolean, required: true)
  attr(:loading_newer, :boolean, required: true)
  attr(:anchor_message_id, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:current_participant, :any, required: true)
  attr(:agent_participant_ids, :any, required: true)
  attr(:agent_colors_map, :map, required: true)
  attr(:participants_map, :map, required: true)
  attr(:quick_emojis, :list, required: true)
  attr(:pinned_message_ids, :any, required: true)
  attr(:highlighted_message_id, :any, required: true)
  attr(:canvases_by_id, :map, required: true)
  attr(:attachments_map, :map, required: true)
  attr(:thread_previews, :any, required: true)
  attr(:expanded_threads, :any, required: true)
  attr(:inline_thread_messages, :any, required: true)
  attr(:mention_suggestions, :list, required: true)
  attr(:mention_source, :any, required: true)
  attr(:editing_message_id, :any, required: true)

  attr(:rendered_message_ids, :any,
    required: true,
    doc:
      "MapSet of the message ids currently in the `:messages` stream. Streams are write-only in the template, so this is the only way to ask whether the pane is empty."
  )

  @doc """
  The scrolling message viewport: both infinite-scroll sentinels and
  `#message-list`.

  The root of this template IS `#chat-message-scroller`. Do not wrap it —
  see the module doc.
  """
  def message_scroller(assigns) do
    ~H"""
    <%!-- min-h-0 is the load-bearing class here: without it, flex items
         default to `min-height: auto` which means the message list
         refuses to shrink below its intrinsic content height. With 80+
         messages that intrinsic height blows past the viewport and
         pushes the composer + bottom-tab nav off-screen on iOS Safari /
         PWA standalone. overscroll-contain stops rubber-band gestures
         from reaching the document scroller (defence-in-depth: app.css
         already has `overscroll-behavior: none` on body, but iOS WebKit
         respects the per-scroller setting more reliably than the
         ancestor chain). --%>
    <%!-- Outer scroll wrapper for infinite scroll (task 019e18fc Stage
         3). The sentinels live inside this wrapper as siblings of
         #message-list — that way they're inside the scroll viewport
         and the InfiniteScroll IntersectionObserver fires when the
         user scrolls them into view. #message-list itself becomes a
         non-scrolling flex column inside the wrapper. Overflow +
         overscroll moved from #message-list to here. --%>
    <div
      id="chat-message-scroller"
      data-scroll-container
      class="flex-1 min-h-0 overflow-y-auto overflow-x-hidden overscroll-contain bg-base-100 [overflow-anchor:none]"
    >
      <%!-- Top sentinel: fires `load_older_messages` when visible AND
           :has_more_older is true. --%>
      <div
        :if={@has_more_older}
        id="chat-scroll-sentinel-top"
        phx-hook="InfiniteScroll"
        data-direction="older"
        data-loading={if @loading_older, do: "true"}
        class="flex justify-center py-2 text-xs text-base-content/40"
      >
        <span :if={@loading_older} class="hero-arrow-path size-3 animate-spin"></span>
        <span :if={!@loading_older}>Loading older messages…</span>
      </div>

      <div
        id="message-list"
        class="px-5 py-4 flex flex-col space-y-1"
        phx-update="stream"
        phx-hook="ScrollToBottom"
        data-anchor-message-id={@anchor_message_id}
        data-space-id={@active_space && @active_space.id}
      >
        <.chat_message
          :for={{dom_id, msg} <- @streams.messages}
          :if={is_nil(msg.deleted_at)}
          dom_id={dom_id}
          msg={msg}
          current_participant={@current_participant}
          agent_participant_ids={@agent_participant_ids}
          agent_colors_map={@agent_colors_map}
          participants_map={@participants_map}
          quick_emojis={@quick_emojis}
          pinned_message_ids={@pinned_message_ids}
          highlighted_message_id={@highlighted_message_id}
          canvases_by_id={@canvases_by_id}
          attachments_map={@attachments_map}
          thread_previews={@thread_previews}
          expanded_threads={@expanded_threads}
          inline_thread_messages={@inline_thread_messages}
          mention_suggestions={@mention_suggestions}
          mention_source={@mention_source}
          editing_message_id={@editing_message_id}
          read_only={@active_space != nil && @active_space.archived_at != nil}
        />
      </div>

      <%!-- Zero-message empty state, per docs/design-system/03-voice.md
           §5.2. Without this a brand-new channel renders a literally blank
           pane — `#message-list` has zero children and the scroller's
           innerText is empty (E2E case 4, task 01a0312e).

           Gated on THREE things, all load-bearing:

             * `@active_space != nil` — distinguishes "loaded and empty"
               from "no space entered yet". `enter_space/3` runs
               synchronously in `handle_params/3`, so an active_space
               always implies the message window has been loaded; there is
               no async in-flight window where this would flash.
             * `MapSet.size(@rendered_message_ids) == 0` — the stream is
               write-only in the template, so this MapSet is the only
               readable count. It is maintained on every path that adds or
               removes a row (append, prepend, prune, delete), so a channel
               whose only messages are soft-deleted correctly reads as
               empty here too.
             * `archived_at == nil` — an archived channel already has
               `archived_banner/1` above the scroller explaining the
               read-only state, and its composer is suppressed. Stacking a
               "say something to get started" invitation on top of a
               channel nobody can post to is the defect this clause exists
               to prevent. --%>
      <.empty_state
        :if={
          @active_space != nil and @active_space.archived_at == nil and
            MapSet.size(@rendered_message_ids) == 0
        }
        variant={:conversational}
      >
        <:system_message>— no messages yet in #{@active_space.name} —</:system_message>
        <:body>
          This space is quiet. Connect your agent and @ them to plan and work in this space.
        </:body>
        <:chips label="+ Add an agent" event={JS.navigate(~p"/control")} />
      </.empty_state>

      <%!-- Bottom sentinel: fires `load_newer_messages` when visible AND
           :newest_evicted? is true. Only renders after the live tail
           has been evicted by a prepend (Stage 2's prune logic). --%>
      <div
        :if={@newest_evicted?}
        id="chat-scroll-sentinel-bottom"
        phx-hook="InfiniteScroll"
        data-direction="newer"
        data-loading={if @loading_newer, do: "true"}
        class="flex justify-center py-2 text-xs text-base-content/40"
      >
        <span :if={@loading_newer} class="hero-arrow-path size-3 animate-spin"></span>
        <span :if={!@loading_newer}>Loading newer messages…</span>
      </div>
    </div>
    """
  end

  attr(:streaming_replies, :map, required: true)
  attr(:agent_colors_map, :map, required: true)
  attr(:participants_map, :map, required: true)

  @doc """
  The in-flight agent reply bubbles — one per streaming chunk.
  """
  def streaming_replies(assigns) do
    ~H"""
    <%!-- Streaming reply bubbles --%>
    <div
      :for={{chunk_id, entry} <- @streaming_replies}
      :if={entry.text != nil and entry.text != ""}
      id={"streaming-#{chunk_id}"}
      class="flex-shrink-0 px-5 pb-2 msg-agent"
      style={
        "--agent-accent: #{Map.get(@agent_colors_map, entry.participant_id, Platform.Agents.ColorPalette.default_accent())};"
      }
    >
      <div class="flex items-start gap-2">
        <%!-- The face shown WHILE the agent is typing. It has to be the same
             avatar the settled message row draws, or the image would pop in
             only once the stream finishes and read as a rendering bug. --%>
        <.agent_avatar
          name={PresenceHooks.sender_name(@participants_map, entry.participant_id)}
          avatar_url={PresenceHooks.sender_avatar_url(@participants_map, entry.participant_id)}
          size="sm"
          class="msg-agent-avatar"
        />
        <div class="min-w-0 flex-1">
          <div class="text-xs font-medium mb-0.5 msg-agent-name">
            {PresenceHooks.sender_name(@participants_map, entry.participant_id)}
          </div>
          <div
            class="text-sm text-base-content/80 border-l-2 pl-3"
            style="border-color: color-mix(in oklch, var(--agent-accent, oklch(82% 0.12 207)) 30%, transparent);"
          >
            {entry.text}<span
              class="inline-block w-1.5 h-4 animate-pulse ml-0.5 align-middle rounded-sm"
              style="background: color-mix(in oklch, var(--agent-accent, oklch(82% 0.12 207)) 50%, transparent);"
            ></span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:agent_typing_pids, :any, required: true)
  attr(:streaming_replies, :map, required: true)
  attr(:participants_map, :map, required: true)

  @doc """
  The agent-typing dots. Suppressed while a stream is in flight — the
  bubble above already shows the agent is working.
  """
  def typing_indicator(assigns) do
    ~H"""
    <%!-- Typing indicator --%>
    <div
      :if={not MapSet.equal?(@agent_typing_pids, MapSet.new()) and @streaming_replies == %{}}
      class="flex-shrink-0 px-5 pb-1 flex items-center gap-2 text-xs text-base-content/50"
    >
      <span class="flex gap-0.5 items-center">
        <span
          class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
          style="animation-delay: 0ms"
        >
        </span>
        <span
          class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
          style="animation-delay: 150ms"
        >
        </span>
        <span
          class="inline-block size-1.5 rounded-full bg-base-content/40 animate-bounce"
          style="animation-delay: 300ms"
        >
        </span>
      </span>
      <span>
        {PresenceHooks.thinking_label(@agent_typing_pids, @participants_map)} is thinking…
      </span>
    </div>
    """
  end

  attr(:active_space, :any, required: true)
  attr(:compose_form, :any, required: true)
  attr(:current_participant, :any, required: true)
  attr(:uploads, :any, required: true)
  attr(:mention_suggestions, :list, required: true)
  attr(:mention_source, :any, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)

  @doc """
  The compose input area: the compose form with its @mention dropdown, the
  always-present upload submission form and the no-participant error line.

  The three masking attrs are declared because the textarea placeholder
  interpolates `masked_space_name/2`, which reads them through TOLERANT
  `assigns[...]` access — a missing declaration renders the REAL channel
  name into the placeholder with screen-share masking switched on, and
  every markup assertion still passes.
  """
  def composer(assigns) do
    ~H"""
    <div class="flex-shrink-0 compose-input-area safe-area-bottom">
      <%!-- Composer is structurally absent on archived spaces (task
           019e95ea stage 2) — hiding is affordance; the context layer
           rejects the writes regardless. --%>
      <.form
        :if={@active_space && is_nil(@active_space.archived_at)}
        for={@compose_form}
        id="compose-form"
        phx-hook="ButtonLoading"
        phx-submit="send_message"
        phx-change="compose_changed"
        class="flex flex-col gap-2"
      >
        <%!-- @mention autocomplete dropdown --%>
        <div
          :if={@mention_suggestions != [] && @mention_source == "compose-form"}
          class="relative"
        >
          <div class="absolute bottom-0 left-0 z-50 w-64 rounded-2xl border border-base-content/10 bg-base-100 shadow-lg overflow-hidden">
            <div class="py-1">
              <button
                :for={{suggestion, idx} <- Enum.with_index(@mention_suggestions)}
                type="button"
                data-mention-suggestion={if idx == 0, do: "first"}
                phx-click={
                  JS.dispatch("chat:insert-mention",
                    to: "##{@compose_form[:text].id}",
                    detail: %{name: suggestion.name}
                  )
                }
                class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-base-200 text-left transition-colors"
              >
                <%= cond do %>
                  <% suggestion.participant_type == "broadcast" -> %>
                    <div class="w-6 h-6 rounded-full bg-warning/15 text-warning flex items-center justify-center flex-shrink-0">
                      <span class="hero-megaphone size-4"></span>
                    </div>
                  <% suggestion.participant_type == "agent" -> %>
                    <%!-- The human branch below already showed a stored photo
                         here; the agent branch drew a letter, so picking who
                         to @mention showed faces for people and initials for
                         agents. `suggestion.avatar_url` was in hand the whole
                         time — the identity map fills it for agents too. --%>
                    <.agent_avatar
                      name={suggestion.name}
                      avatar_url={suggestion.avatar_url}
                      size="sm"
                      class="flex-shrink-0"
                    />
                  <% true -> %>
                    <.human_avatar
                      name={suggestion.name}
                      avatar_url={suggestion.avatar_url}
                      seed={suggestion.avatar_seed}
                      size="sm"
                      class="flex-shrink-0"
                    />
                <% end %>
                <span class="flex-1 min-w-0 truncate">
                  <span class="font-medium">{suggestion.name}</span>
                  <span
                    :if={suggestion.participant_type == "broadcast"}
                    class="block text-xs text-base-content/60 truncate"
                  >
                    Notify everyone in the channel
                  </span>
                </span>
                <span class={[
                  "rounded-full px-1.5 py-0.5 text-[10px] uppercase tracking-wider",
                  suggestion.participant_type == "broadcast" && "bg-warning/10 text-warning",
                  suggestion.participant_type == "agent" && "bg-primary/10 text-primary",
                  suggestion.participant_type == "user" && "bg-base-300 text-base-content/50"
                ]}>
                  {suggestion.participant_type}
                </span>
              </button>
            </div>
          </div>
        </div>

        <%!-- Pill-shaped compose bar --%>
        <div class="compose-pill-bar">
          <button
            type="button"
            id="compose-attach-button"
            phx-hook="UploadButton"
            phx-click="upload_dialog_open"
            class="compose-pill-attach cursor-pointer text-base-content/50 hover:bg-base-300/50 transition-colors"
            title="Attach files"
          >
            <span class="hero-plus size-5"></span>
          </button>

          <textarea
            name="compose[text]"
            id={@compose_form[:text].id}
            data-draft-key={if @active_space, do: "chat-draft:" <> @active_space.id, else: nil}
            placeholder={"Message ##{masked_space_name(assigns, (@active_space && @active_space.name) || "")}"}
            autocomplete="off"
            rows="1"
            class="flex-1 text-sm resize-none"
            style="line-height:1.5;padding:4px 0;min-height:28px;max-height:200px;overflow-y:auto;field-sizing:content"
            phx-hook="ComposeInput"
          >{Phoenix.HTML.Form.normalize_value("text", @compose_form[:text].value)}</textarea>

          <button
            type="submit"
            class="compose-pill-send"
            disabled={is_nil(@current_participant) or composer_empty?(@compose_form)}
            aria-label="Send message"
            title="Send"
          >
            <span class="hero-paper-airplane size-4 -rotate-45"></span>
          </button>
        </div>

        <p
          :for={error <- upload_errors(@uploads.attachments)}
          class="text-xs text-error"
        >
          {upload_error_to_string(error)}
        </p>

        <div :for={entry <- @uploads.attachments.entries}>
          <p
            :for={error <- upload_errors(@uploads.attachments, entry)}
            class="text-xs text-error"
          >
            {entry.client_name}: {upload_error_to_string(error)}
          </p>
        </div>
      </.form>

      <%!-- Always-present upload submission form. Lives OUTSIDE #compose-form
           (HTML forbids nested forms) so the modal's Send button + textarea
           can target it via the HTML5 `form="upload-send-form"` attribute.
           The form is rendered unconditionally so:
             (a) `inputEl.form` resolves on first paste (no chicken-and-egg
                 with `:if={entries != []}` form-rendering).
             (b) LiveView's `pushInput` → `pushFormSubmit` always finds the
                 form to serialize when the user submits.
           The hidden file input (`live_file_input`) is the form's only
           direct child; visible UI for caption + Send lives inside the
           modal panel and links back to this form via `form=...`. --%>
      <form
        :if={@active_space && is_nil(@active_space.archived_at)}
        id="upload-send-form"
        phx-hook="ButtonLoading"
        phx-submit="upload_send"
        phx-change="upload_caption_change"
        class="hidden"
      >
        <.live_file_input upload={@uploads.attachments} class="sr-only" />
      </form>

      <p :if={is_nil(@current_participant) && @active_space} class="mt-1 text-xs text-error">
        Unable to join space — messages are read-only.
      </p>
    </div>
    """
  end

  defp masked_space_name(assigns, name), do: ChatLive.masked_space_name(assigns, name)
end
