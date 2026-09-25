defmodule PlatformWeb.ChatLive.Partials.MessageContext do
  @moduledoc """
  The "What this message is answering" panel for agent messages (task
  01a0d8de stage 3), and the two frames it renders in: a non-modal popover
  anchored under the message header on desktop, and a bottom sheet on
  mobile. State lives in `PlatformWeb.ChatLive.MessageContextHooks`; these
  are function components with no state of their own.

  Design direction: canvas "Design direction: agent message context
  (01a0d8de)". The panel answers in the order a person asks: what the agent
  says it is answering, then the message itself one click away, then a
  generated summary only when nothing better exists.

  ## Untrusted text

  The agent's context line, the answered message's preview and the
  generated summary are all rendered through HEEx interpolation ONLY: no
  `raw/1`, no markdown, no mention or URL linkification. The context line
  was already mention-escaped when it was stored (`Platform.Chat.ReplyContext`)
  and the summary when it was generated (`Platform.Chat.ContextSummary`);
  escaping HTML is this module's job and interpolation is how it is done.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import PlatformWeb.Components.ChatMessage, only: [local_time: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  # Two lines of `text-sm` at the panel's 22rem width hold roughly 80
  # characters (measured on the dev rig: a 107-character line was clamped),
  # so past this "Show more" is offered. The stored context is capped at 200.
  @show_more_at 80

  attr(:message_context, :any, required: true)
  attr(:mobile?, :boolean, default: false)

  @doc """
  The viewport reporter plus whichever frame is open. Exactly one frame is
  rendered: the popover when `mobile?` is false, the sheet when true.
  """
  def message_context_overlay(assigns) do
    ~H"""
    <%!-- Which side of `lg` the viewport is on. The chat's own mobile
         layout switches at `lg`, so the panel's frame does too. --%>
    <div
      id="message-context-viewport-host"
      phx-hook="ViewportBreakpoint"
      data-breakpoint="1024"
      data-event="message_context_viewport"
      class="hidden"
    >
    </div>

    <div
      :if={@message_context && !@mobile?}
      id="message-context-popover"
      role="dialog"
      aria-labelledby="message-context-popover-title"
      tabindex="-1"
      phx-hook="MessageContextPopover"
      phx-window-keydown="close_message_context"
      phx-key="Escape"
      data-role="message-context-popover"
      data-anchor-message-id={@message_context.message_id}
      class="fixed left-1/2 top-24 z-40 w-[calc(100vw-1rem)] max-w-[22rem] -translate-x-1/2 rounded-box border border-edge bg-base-100 p-4 shadow-lg focus:outline-none"
    >
      <div class="mb-3 flex items-start justify-between gap-2">
        <h2 id="message-context-popover-title" class="text-sm font-semibold text-base-content">
          What this message is answering
        </h2>
        <button
          type="button"
          phx-click="close_message_context"
          aria-label="Close"
          class="-m-1 rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <span class="hero-x-mark size-4" aria-hidden="true"></span>
        </button>
      </div>
      <.message_context_panel context={@message_context} id_prefix="message-context-popover" />
    </div>

    <.sheet
      :if={@message_context && @mobile?}
      id="message-context-sheet"
      open={true}
      placement={:bottom}
      on_close="close_message_context"
      data-role="message-context-sheet"
    >
      <:title>What this message is answering</:title>
      <div class="px-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
        <.message_context_panel context={@message_context} id_prefix="message-context-sheet" />
      </div>
    </.sheet>
    """
  end

  attr(:context, :map, required: true)
  attr(:id_prefix, :string, required: true)

  @doc "The panel body, shared by the popover and the sheet."
  def message_context_panel(assigns) do
    assigns =
      assign(
        assigns,
        :show_more?,
        is_binary(assigns.context.agent_context) and
          String.length(assigns.context.agent_context) > @show_more_at
      )

    ~H"""
    <div
      class="flex flex-col gap-4"
      data-role="message-context-panel"
      data-context-message-id={@context.message_id}
    >
      <section :if={@context.agent_context} data-role="message-context-agent">
        <p class="message-context-label text-xs">From the agent</p>
        <p
          id={"#{@id_prefix}-agent-text"}
          data-role="message-context-agent-text"
          class="mt-1 line-clamp-2 break-words text-sm text-base-content"
        >
          {@context.agent_context}
        </p>
        <button
          :if={@show_more?}
          type="button"
          phx-click={
            JS.remove_class("line-clamp-2", to: "##{@id_prefix}-agent-text")
            |> JS.hide()
          }
          class="mt-1 rounded text-xs text-base-content/60 hover:text-base-content hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          Show more
        </button>
      </section>

      <section :if={@context.reply_to} data-role="message-context-reply-to">
        <p class="message-context-label text-xs">Replying to</p>
        <%= case @context.reply_to do %>
          <% %{status: :visible} = reply -> %>
            <div class="mt-1 border-l-2 border-edge pl-3">
              <p class="message-context-label flex items-baseline gap-1.5 text-xs">
                <span class="truncate font-medium" data-role="message-context-reply-author">
                  {reply.author}
                </span>
                <span aria-hidden="true">·</span>
                <.local_time
                  id={"#{@id_prefix}-reply-time"}
                  timestamp={reply.at}
                  class="shrink-0"
                />
              </p>
              <p
                data-role="message-context-reply-preview"
                class="mt-0.5 line-clamp-2 break-words text-sm text-base-content/80"
              >
                {reply.preview}
              </p>
              <button
                type="button"
                data-role="message-context-jump"
                phx-click="jump_to_answered_message"
                phx-value-message-id={reply.message_id}
                class="mt-1 inline-flex min-h-11 items-center gap-1 rounded text-xs font-medium text-base-content/70 hover:text-base-content hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring lg:min-h-0"
              >
                Jump to message <span class="hero-arrow-right size-3" aria-hidden="true"></span>
              </button>
            </div>
          <% _ -> %>
            <p data-role="message-context-no-access" class="mt-1 text-sm text-base-content/70">
              Replying to a message you don't have access to
            </p>
        <% end %>
      </section>

      <section :if={@context.summary} data-role="message-context-generated">
        <span class="badge badge-info badge-sm">Generated summary</span>
        <%= case @context.summary do %>
          <% :loading -> %>
            <div
              data-role="message-context-summary-loading"
              class="mt-2 flex flex-col gap-1.5"
              aria-busy="true"
              aria-label="Generating summary"
            >
              <div class="skeleton h-3 w-full"></div>
              <div class="skeleton h-3 w-11/12"></div>
              <div class="skeleton h-3 w-2/3"></div>
            </div>
          <% {:ok, result} -> %>
            <p
              data-role="message-context-summary"
              data-source-message-ids={Enum.join(result.source_message_ids, ",")}
              class="mt-2 break-words text-sm text-base-content"
            >
              <span :for={line <- String.split(result.text, "\n")} class="block">{line}</span>
            </p>
          <% {:error, :not_configured} -> %>
            <p
              data-role="message-context-summary-unavailable"
              class="mt-2 text-sm text-base-content/70"
            >
              Summaries are not available on this install.
            </p>
          <% {:error, :no_history} -> %>
            <p data-role="message-context-summary-empty" class="mt-2 text-sm text-base-content/70">
              There are no earlier messages you can see to summarise.
            </p>
          <% {:error, _reason} -> %>
            <div data-role="message-context-summary-error" class="mt-2 flex items-center gap-3">
              <p class="text-sm text-error">The summary could not be generated.</p>
              <button
                type="button"
                data-role="message-context-retry"
                phx-click="retry_message_context"
                class="btn btn-ghost btn-xs min-h-11 lg:min-h-0"
              >
                Retry
              </button>
            </div>
        <% end %>
        <%!-- Says what a summary was made from, so only where there is one
             (or one on the way): not beside an error or an unavailable note. --%>
        <p
          :if={@context.summary == :loading or match?({:ok, _}, @context.summary)}
          data-role="message-context-summary-source"
          class="message-context-label mt-2 text-xs"
        >
          Summarised by Suite from the messages before this one that you can see.
        </p>
      </section>
    </div>
    """
  end
end
