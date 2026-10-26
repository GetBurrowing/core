defmodule PlatformWeb.ChatLive.Partials.MessageContext do
  @moduledoc """
  The 'Answering' panel for agent messages (task 01a0d8de stage 3; re-skinned
  in redesign rung 9 stage 2 per direction canvas 01a1666e node m2 and the
  masters' 'Answering' stub), and the two frames it renders in: a non-modal
  popover anchored under the message header on desktop, and a bottom sheet on
  mobile. One content component, `message_context_panel/1`, renders both.
  State lives in `PlatformWeb.ChatLive.MessageContextHooks`; these are
  function components with no state of their own.

  The full text is shown: the stored context is capped at 200 characters, so
  the old "Show more" clamp was dropped.

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

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.Components.ReplyQuote, only: [reply_quote: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

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
        <h2 id="message-context-popover-title" class="text-base font-semibold text-base-content">
          Answering
        </h2>
        <button
          type="button"
          phx-click="close_message_context"
          aria-label="Close"
          class="-m-1 rounded p-1 text-subtle lg:hover:bg-base-200 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <.icon name="hero-x-mark" class="size-4" />
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
      handle_close
      swipe_dismiss
    >
      <:title>Answering</:title>
      <div class="px-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
        <p class="pb-3 text-base font-semibold text-base-content" aria-hidden="true">Answering</p>
        <.message_context_panel context={@message_context} id_prefix="message-context-sheet" />
      </div>
    </.sheet>
    """
  end

  attr(:context, :map, required: true)
  attr(:id_prefix, :string, required: true)

  @doc """
  The panel body, shared by the popover and the sheet: the lead line naming
  the agent in its accent, the quoted message it answers, the agent's own
  context line, the generated summary when there is one, and the two
  buttons, 'Jump to message' and 'Retry summary'. Neutral fills only.
  """
  def message_context_panel(assigns) do
    context = assigns.context

    assigns =
      assigns
      |> assign(:agent_name, Map.get(context, :agent_name) || "The agent")
      |> assign(:agent_slot, Map.get(context, :agent_slot))
      |> assign(
        :nothing?,
        context.agent_context == nil and context.reply_to == nil and context.summary == nil
      )
      |> assign(
        :retry?,
        context.summary != :loading and context.summary != {:error, :not_configured}
      )

    ~H"""
    <div
      class="flex flex-col gap-3 text-[15px] text-base-content"
      data-role="message-context-panel"
      data-context-message-id={@context.message_id}
    >
      <p data-role="message-context-lead" class="break-words">
        <span
          data-agent-slot={@agent_slot}
          data-role="message-context-agent-name"
          class="message-context-agent-name font-semibold"
        >
          {@agent_name}
        </span>
        was answering:
      </p>

      <%!-- The shared reply quote (task 01a174f5 stage 3). The panel keeps
           its own 'Jump to message' button below, so the block is not one. --%>
      <section :if={@context.reply_to} data-role="message-context-reply-to">
        <.reply_quote
          quote={@context.reply_to}
          role="message-context-reply-quote"
          part="message-context-reply"
          time_id={"#{@id_prefix}-reply-time"}
          clamp={false}
        />
      </section>

      <section :if={@context.agent_context} data-role="message-context-agent">
        <p id={"#{@id_prefix}-agent-text"} data-role="message-context-agent-text" class="break-words">
          {@context.agent_context}
        </p>
        <p class="mt-0.5 text-[13px] text-subtle">agent context</p>
      </section>

      <p :if={@nothing?} data-role="message-context-none" class="text-subtle">
        Summary not generated yet
      </p>

      <section :if={@context.summary} data-role="message-context-generated">
        <p class="mb-0.5 text-[13px] text-subtle">Generated summary</p>
        <%= case @context.summary do %>
          <% :loading -> %>
            <p
              data-role="message-context-summary-loading"
              aria-busy="true"
              class="text-subtle"
            >
              Summarising…
            </p>
          <% {:ok, result} -> %>
            <p
              data-role="message-context-summary"
              data-source-message-ids={Enum.join(result.source_message_ids, ",")}
              class="break-words"
            >
              <span :for={line <- String.split(result.text, "\n")} class="block">{line}</span>
            </p>
          <% {:error, :not_configured} -> %>
            <p data-role="message-context-summary-unavailable">
              Summaries are not available on this install.
            </p>
          <% {:error, :no_history} -> %>
            <p data-role="message-context-summary-empty">
              There are no earlier messages you can see to summarise.
            </p>
          <% {:error, _reason} -> %>
            <p data-role="message-context-summary-error" class="flex items-center gap-2">
              <.icon name="hero-exclamation-circle" class="size-5 shrink-0 bg-error" />
              The summary could not be generated.
            </p>
        <% end %>
        <%!-- Says what a summary was made from, so only where there is one
             (or one on the way): not beside an error or an unavailable note. --%>
        <p
          :if={@context.summary == :loading or match?({:ok, _}, @context.summary)}
          data-role="message-context-summary-source"
          class="mt-1 text-[13px] text-subtle"
        >
          Summarised by Burrow from the messages before this one that you can see.
        </p>
      </section>

      <div class="flex flex-wrap gap-2">
        <button
          :if={match?(%{status: :visible}, @context.reply_to)}
          type="button"
          data-role="message-context-jump"
          phx-click="jump_to_answered_message"
          phx-value-message-id={@context.reply_to.message_id}
          class="inline-flex min-h-11 items-center gap-2 rounded-box bg-base-200 px-3 text-base-content active:bg-base-300 lg:min-h-9 lg:hover:bg-base-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <.icon name="hero-arrow-up" class="size-4 text-subtle" /> Jump to message
        </button>
        <button
          :if={@retry?}
          type="button"
          data-role="message-context-retry"
          phx-click="retry_message_context"
          class="inline-flex min-h-11 items-center gap-2 rounded-box bg-base-200 px-3 text-base-content active:bg-base-300 lg:min-h-9 lg:hover:bg-base-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          <.icon name="hero-arrow-path" class="size-4 text-subtle" /> Retry summary
        </button>
      </div>
    </div>
    """
  end
end
