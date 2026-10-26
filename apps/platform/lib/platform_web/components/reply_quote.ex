defmodule PlatformWeb.Components.ReplyQuote do
  @moduledoc """
  The reply quote: the ONE block that shows which message another one
  answers (task 01a174f5 stage 3, design canvas 01a174f6). Lifted from redesign
  rung 9's 'Answering' block (`Partials.MessageContext`,
  `message-context-reply-to`) and used by all three places that quote:

    * the main-log row (`PlatformWeb.Components.ChatMessage`), for a
      top-level message whose `metadata["reply_to_message_id"]` resolves;
    * the composer's 'Replying to <author>' chip (`Partials.Composer`);
    * the 'Answering' panel (`Partials.MessageContext`).

  ## Paint (brand slots only)

    * fill `base-200`, opaque, inside the `base-100` log;
    * a 2px leading bar in the QUOTED author's colour: the agent accent
      (`--ag`, pointed at the slot by `data-agent-slot` on the block) when
      quoting an agent, `base-300` when quoting a person or when nothing of
      the target may be shown. The bar is `aria-hidden` decoration; no text
      ever sits on the accent;
    * the author `base-content` semibold 13px; the excerpt `text-subtle`
      13px, clamped to two lines (`clamp`); `preview_class/1` keeps any
      display utility off a clamped excerpt.

  ## States (`QuotedMessage.resolve/2`)

    * `:visible` — author and excerpt. With `jump`, the block is a button
      that fires `jump_to_answered_message` with `variant` "quote" (the
      neutral flash, `.chat-message-jump-quote`);
    * `:no_access` — "Replying to a message you don't have access to", the
      panel's existing wording. Never a button;
    * `:deleted` — "Original message deleted" in `text-subtle` italics.
      Never a button.

  ONE LEVEL ONLY: the block renders the target's own text and never the
  target's quote, so a quote never contains a quote.

  Untrusted text (author, excerpt) is rendered through HEEx interpolation
  only.
  """

  use Phoenix.Component

  attr(:quote, :map, required: true, doc: "a `QuotedMessage` state")
  attr(:role, :string, default: "reply-quote", doc: "the block's `data-role`")
  attr(:part, :string, default: "reply-quote", doc: "prefix of the parts' `data-role`s")
  attr(:jump, :boolean, default: false, doc: "a visible quote is a jump button")
  attr(:lead, :string, default: nil, doc: "words before the author, e.g. \"Replying to\"")
  attr(:time_id, :string, default: nil, doc: "renders the target's time when set")
  attr(:clamp, :boolean, default: true, doc: "clamp the excerpt to two lines")
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:action, doc: "a trailing control, e.g. the composer chip's x")

  def reply_quote(assigns) do
    quote = assigns.quote
    visible? = match?(%{status: :visible}, quote)
    slot = if visible?, do: Map.get(quote, :agent_slot)

    assigns =
      assigns
      |> assign(:visible?, visible?)
      |> assign(:slot, slot)
      |> assign(:button?, visible? and assigns.jump)
      |> assign(:status, Map.get(quote, :status, :no_access))
      |> assign(
        :box_class,
        [
          "flex w-full items-stretch gap-2.5 rounded-box bg-base-200 py-1.5 pl-2 text-left",
          if(assigns.action == [], do: "pr-3", else: "pr-0.5"),
          assigns.class
        ]
      )

    ~H"""
    <button
      :if={@button?}
      type="button"
      data-role={@role}
      data-quote-status="visible"
      data-quote-target={@quote.message_id}
      data-agent-slot={@slot}
      phx-click="jump_to_answered_message"
      phx-value-message-id={@quote.message_id}
      phx-value-variant="quote"
      class={[
        @box_class,
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      ]}
      {@rest}
    >
      <.bar part={@part} agent_slot={@slot} />
      <.body
        quote={@quote}
        status={@status}
        part={@part}
        lead={@lead}
        time_id={@time_id}
        clamp={@clamp}
      />
      {render_slot(@action)}
    </button>
    <div
      :if={!@button?}
      data-role={@role}
      data-quote-status={to_string(@status)}
      data-quote-target={@visible? && @quote.message_id}
      data-agent-slot={@slot}
      class={@box_class}
      {@rest}
    >
      <.bar part={@part} agent_slot={@slot} />
      <.body
        quote={@quote}
        status={@status}
        part={@part}
        lead={@lead}
        time_id={@time_id}
        clamp={@clamp}
      />
      {render_slot(@action)}
    </div>
    """
  end

  # A display utility next to `line-clamp-2` overrides the clamp's
  # `display: -webkit-box` (Tailwind emits both at the same specificity and
  # `block` comes later), so the excerpt runs to its full height. The gate on
  # stage 3 measured exactly that: `block` beside the clamp, four lines.
  @display_utilities ~w(block inline inline-block flex inline-flex grid inline-grid contents table hidden)

  @doc """
  The excerpt's class list. Clamped: `line-clamp-2` and NO display utility,
  so the computed display is `-webkit-box`. Unclamped (the Answering panel,
  stage 3 deviation 3): `block`, the full text.

  Raises if the clamped list ever carries a display utility.
  """
  @spec preview_class(boolean()) :: [String.t()]
  def preview_class(clamp?) do
    base = ~w(mt-0.5 break-words text-[13px] text-subtle)
    classes = if clamp?, do: base ++ ["line-clamp-2"], else: base ++ ["block"]

    if clamp? and Enum.any?(classes, &(&1 in @display_utilities)) do
      raise ArgumentError,
            "reply quote excerpt: a display utility beside line-clamp-2 defeats the clamp: " <>
              inspect(classes)
    end

    classes
  end

  @doc false
  def display_utilities, do: @display_utilities

  attr(:part, :string, required: true)
  attr(:agent_slot, :string, default: nil)

  defp bar(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role={"#{@part}-bar"}
      class={[
        "w-0.5 shrink-0 self-stretch rounded-full",
        if(@agent_slot, do: "bg-(--ag)", else: "bg-base-300")
      ]}
    >
    </span>
    """
  end

  attr(:quote, :map, required: true)
  attr(:status, :atom, required: true)
  attr(:part, :string, required: true)
  attr(:lead, :string, default: nil)
  attr(:time_id, :string, default: nil)
  attr(:clamp, :boolean, default: true)

  defp body(assigns) do
    ~H"""
    <span class="block min-w-0 flex-1">
      <%= case @status do %>
        <% :visible -> %>
          <span
            data-role={"#{@part}-lead"}
            class="flex items-baseline gap-1.5 text-[13px] text-subtle"
          >
            <span class="truncate">
              <span :if={@lead}>{@lead}</span>
              <span data-role={"#{@part}-author"} class="font-semibold text-base-content">
                {@quote.author}
              </span>
            </span>
            <span :if={@time_id && Map.get(@quote, :at)} aria-hidden="true">·</span>
            <PlatformWeb.Components.ChatMessage.local_time
              :if={@time_id && Map.get(@quote, :at)}
              id={@time_id}
              timestamp={@quote.at}
              class="shrink-0"
            />
          </span>
          <span
            :if={Map.get(@quote, :preview, "") != ""}
            data-role={"#{@part}-preview"}
            class={preview_class(@clamp)}
          >
            {@quote.preview}
          </span>
        <% :deleted -> %>
          <span data-role={"#{@part}-deleted"} class="block text-[13px] italic text-subtle">
            Original message deleted
          </span>
        <% _ -> %>
          <span data-role={"#{@part}-no-access"} class="block text-[13px] text-subtle">
            Replying to a message you don't have access to
          </span>
      <% end %>
    </span>
    """
  end
end
