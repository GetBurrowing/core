defmodule PlatformWeb.Components.ThreadActivityRow do
  @moduledoc """
  The main log's thread-activity row and its overflow summary (task 01a174f5,
  design canvas 01a175ca): structure from stage 2, paint from stage 3.

  The paint: 13px throughout; `↳` and "new replies to" in `text-subtle`; the
  count the only emphasis (`text-base-content font-semibold tabular-nums`);
  the excerpt `text-base-content` regular in STRAIGHT double quotes (the
  canvas palette table's rule; its sketch's curly quotes lose); no ground at
  rest, `active:bg-base-200` pressed, `lg:hover:bg-base-200` only; a 44px
  (`min-h-11`) target below lg. The label and avatar are `shrink-0` and the
  excerpt is the `min-w-0 truncate` part, so a narrow phone keeps the count.
  It is not a message: no time, no reactions, no menu, no gesture hook.
  Contrast: `test/platform/design/thread_activity_row_contrast_guard_test.exs`.

  Rendered by `PlatformWeb.ChatLive.Partials.Composer.message_scroller/1`
  below `#message-list`; the state is `PlatformWeb.ChatLive.ThreadActivityHooks`'.

  ## `row/1`

  The whole row is the tap target: `space_sheet_open_thread` with the
  PARENT's id, the same event the space sheet's Threads rows fire, so a
  parent outside the loaded window takes the existing anchored jump.

  Announced as a LINK, as the canvas asks: `role="link"`, `tabindex="0"`
  and Enter (`phx-keydown` + `phx-key="Enter"`) firing the same event. Not
  an `<a href>`: the action is a server event that may scroll in place and
  has no URL of its own in the in-window case, and an `<a>` whose href is
  never followed is the mislabelled control the canvas wants to avoid.

  ## `summary/1`

  "1 more thread with new replies" / "N more threads with new replies",
  ABOVE the rows. Opens the space's Threads list: the phone space sheet
  below lg, the details panel at lg, the same breakpoint the conversation
  header switches on (`lg:hidden` title button / `hidden lg:flex` main head
  in `Partials.Conversation`).
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1, human_avatar: 1]

  alias Phoenix.LiveView.JS

  # Every row and the summary share this box (stage 3, canvas 01a175ca).
  #
  # THE INDENT, measured from chat_message.ex rather than guessed: the region
  # is a sibling of `#message-list` inside `#chat-message-scroller`, so its
  # left edge is the scroller's. A human message row puts its avatar at
  # `#message-list` `px-5` (20px) + `.message-row-inner` `px-2` (8px) = 28px,
  # the avatar is `size-8` (32px, "md"), and the body column follows after
  # the row's `gap-3` (12px): 28 + 32 + 12 = 72px. Here `px-7` (28px) puts the
  # glyph cell (`w-8`, 32px) exactly on the avatar column and `gap-3` starts
  # the label at 72px, the body text column.
  #
  # 13px throughout; no ground at rest (the log's base-100 shows through);
  # `active:bg-base-200` across the full row; hover only at lg. No
  # transition: a row that moves to the bottom just appears there.
  @row_box "min-h-11 w-full min-w-0 cursor-pointer select-none items-center gap-3 px-7 text-left text-[13px] leading-5 active:bg-base-200 lg:min-h-8 lg:hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-focus-ring"

  # Display is NOT in the box: the summary's two buttons are `flex lg:hidden`
  # and `hidden lg:flex`, and an unprefixed `flex` beside `hidden` would be
  # decided by stylesheet order.
  # The hanging glyph: centred in the avatar column.
  @glyph "w-8 shrink-0 text-center text-subtle"

  attr(:dom_id, :string, required: true)
  attr(:row, :map, required: true)

  @doc "One active thread: '↳ N new replies to \"excerpt\"' and the latest replier."
  def row(assigns) do
    assigns = assign(assigns, row_box: @row_box, glyph: @glyph)

    ~H"""
    <div
      id={@dom_id}
      role="link"
      tabindex="0"
      data-role="thread-activity-row"
      data-thread-id={@row.thread_id}
      phx-click="space_sheet_open_thread"
      phx-keydown="space_sheet_open_thread"
      phx-key="Enter"
      phx-value-message-id={@row.parent_message_id}
      aria-label={aria_label(@row)}
      class={["flex", @row_box]}
    >
      <span class={@glyph} data-role="thread-activity-glyph" aria-hidden="true">↳</span>
      <span class="flex min-w-0 flex-1 items-center gap-1.5" aria-hidden="true">
        <span
          class="shrink-0 whitespace-nowrap text-subtle"
          data-role="thread-activity-count"
          phx-no-format
        ><span class="font-semibold tabular-nums text-base-content" data-role="thread-activity-number">{@row.new_count}</span> {reply_phrase(@row.new_count)} to</span>
        <span
          class="min-w-0 truncate text-base-content"
          data-role="thread-activity-excerpt"
          phx-no-format
        >"{@row.excerpt}"</span>
        <span
          class="shrink-0"
          data-role="thread-activity-avatar"
          data-agent-slot={@row.replier_agent? && @row[:replier_agent_slot]}
        >
          <.agent_avatar
            :if={@row.replier_agent?}
            name={@row.replier_name}
            title={@row.replier_name}
            avatar_url={@row.replier_avatar_url}
            size="xs"
            class="msg-agent-avatar"
          />
          <.human_avatar
            :if={!@row.replier_agent?}
            name={@row.replier_name}
            title={@row.replier_name}
            avatar_url={@row.replier_avatar_url}
            seed={@row.replier_avatar_seed}
            size="xs"
          />
        </span>
      </span>
    </div>
    """
  end

  attr(:overflow, :integer, required: true)

  @doc "The threads above the row cap, collapsed into one line that opens the Threads list."
  def summary(assigns) do
    assigns = assign(assigns, row_box: @row_box, glyph: @glyph)

    ~H"""
    <div :if={@overflow > 0} id="thread-activity-summary" data-role="thread-activity-summary">
      <button
        type="button"
        class={["flex lg:hidden", @row_box]}
        phx-click={
          JS.push("open_space_sheet") |> JS.push("space_sheet_page", value: %{page: "threads"})
        }
      >
        <.summary_body overflow={@overflow} glyph={@glyph} />
      </button>
      <button
        type="button"
        class={["hidden lg:flex", @row_box]}
        phx-click={JS.push("details_open", value: %{page: "threads"})}
      >
        <.summary_body overflow={@overflow} glyph={@glyph} />
      </button>
    </div>
    """
  end

  attr(:overflow, :integer, required: true)
  attr(:glyph, :string, required: true)

  defp summary_body(assigns) do
    ~H"""
    <span class={@glyph} aria-hidden="true">↳</span>
    <span class="min-w-0 truncate text-subtle" data-role="thread-activity-summary-label" phx-no-format><span class="font-semibold tabular-nums text-base-content" data-role="thread-activity-number">{@overflow}</span> {summary_phrase(@overflow)}</span>
    """
  end

  defp reply_phrase(1), do: "new reply"
  defp reply_phrase(_), do: "new replies"

  defp summary_phrase(1), do: "more thread with new replies"
  defp summary_phrase(_), do: "more threads with new replies"

  defp aria_label(row) do
    replies = if row.new_count == 1, do: "1 new reply", else: "#{row.new_count} new replies"
    "#{replies} in thread: #{row.excerpt}. Latest from #{row.replier_name}."
  end
end
