defmodule PlatformWeb.Inbox.InboxList do
  @moduledoc """
  The phone Inbox under More (redesign rung 14, task 01a1557a-ad2d stage 2;
  masters prototype 01a137f2 `master-mobile.html` v3 :26, :42-48, :111,
  :118-127, :596-604; Saru's Inbox canvas 01a15ec4 rev 2 and later).

  Renders `PlatformWeb.InboxLive`'s flat `:inbox_rows` stream. Below `lg` it
  is what /inbox shows. At `lg` and wider it is `display: none`, and the
  sectioned desktop surface is unchanged (rung 22 owns desktop).

  ## Rows are plain patch links

  Each row is `<.link patch={~p"/inbox?open=<id>"}>` with no `phx-click`. A
  bare-string `phx-click` on a live link throws
  `TypeError: this[kind] is not a function`, and a `JS.push` on a redirect
  link never reaches the server (both measured in rung 5). The open happens in
  `InboxLive.handle_params/3`, which runs `Inbox.open_item/2` and navigates,
  with `replace: true`, to the row's stored url.

  ## One row shape for every kind (Saru, canvas 01a15ec4 rev 2, D1)

    * **Author slot** (name line): the source. For a mention, the author from
      the message's snapshot (`Inbox.mention_authors/1`), then ` · ` and the
      space label (prototype :600, "Pixel · #design"). In a DM, where the space
      label is the author's own name, it reads "{author} · DM" (prototype
      :601). With no author, the space label alone. For a task or meeting row, the task or meeting title
      (`Inbox.source_titles/1`); with none, the row's own title.
    * **Body**: the excerpt or summary (`item.body`, else `item.title` when
      the title is not already in the author slot), two lines at most,
      `text-base-content` when unread and `text-subtle` when read.
    * **Meta line**: the kind word, `text-xs text-subtle`.

  ## Kind words (`kind_word/1`)

  The words live in ONE table, `PlatformWeb.Components.InboxItem`'s
  `@kind_labels`, as the `:short` form beside the desktop's `:long` label;
  `kind_word/1` delegates to `InboxItem.kind_label(kind, :short)` and keeps no
  map of its own.

  | kind key                 | word           |
  |--------------------------|----------------|
  | `chat_mention`           | Mention        |
  | `task_plan_review`       | Plan review    |
  | `review_request_pending` | Review         |
  | `meeting_starting`       | Starting now   |
  | `meeting_invited`        | Meeting invite |
  | `task_sponsor_assigned`  | Sponsor        |
  | `lifecycle_step_failed`  | Step failed    |
  | `briefing`               | Briefing       |
  | an extension's kind      | its declared `label` (`Platform.Extension` `inbox_kinds/0`) |
  | anything else            | the humanized key |

  Every kind word is `text-subtle`. "Step failed" alone carries colour, as a
  small `aria-hidden` dot in `bg-error` before the word (`kind_dot?/1`), sized
  like the unread dot: a meaningful non-text cue held at 3:1. Saru's rev 2
  painted the WORD in error; `--color-error` as text fails 4.5:1 on base-200
  or base-100 in five of the ten variants (stage 4's guard table), so the
  colour moved to the dot (coordinator ruling, option (a)). The word itself
  says "failed", so the dot is never the only carrier. "Reply" is never produced: no reply kind exists (D2), so a mention
  row always reads "Mention".

  ## States

  Row: default, pressed (`active:bg-base-100`), focus-visible, unread
  (trailing primary dot plus an sr-only "Unread"), read, and a 150ms fade on
  removal (none under reduced motion). There is NO `hover:` utility anywhere
  in this list (Saru `pal`; the phone-list rulings 01a15d7c, 01a15db1).

  Header action: ONE of "Undo" (while `@undo` is set), "Clear all" (rows and
  no undo) or nothing. Undo takes Clear all's place and stays until another
  action or leaving the screen; an sr-only status line announces the swap.

  Avatars and kind discs are `aria-hidden`: the author slot and kind word
  carry the same meaning in text. They are rendered here at the prototype's
  42px because `PlatformWeb.AvatarComponents` stops at 40px (`lg`), the same
  choice rung 6's chat list made.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Inbox.Item
  alias PlatformWeb.Components.InboxItem
  alias PlatformWeb.InboxLive

  attr :rows, :any, required: true, doc: "the `@streams.inbox_rows` stream"
  attr :row_count, :integer, required: true
  attr :undo, :any, default: nil
  attr :mention_authors, :map, default: %{}
  attr :mention_space_labels, :map, default: %{}
  attr :source_titles, :map, default: %{}
  attr :row_sheet, :any, default: nil, doc: "the item id the long-press sheet is open for"

  def inbox_list(assigns) do
    ~H"""
    <section
      id="inbox-phone"
      data-role="inbox-phone"
      class="lg:hidden flex h-full min-h-0 flex-col bg-base-200"
    >
      <header class="flex h-13 shrink-0 items-center gap-2.5 px-4">
        <button
          type="button"
          phx-click="open_more_sheet"
          aria-label="Back to More"
          data-role="inbox-back"
          class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-subtle focus-visible-ring"
        >
          <.icon name="hero-chevron-left" class="size-[22px]" />
        </button>
        <h1 class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content">Inbox</h1>
        <button
          :if={@undo}
          type="button"
          phx-click="undo_last"
          data-role="inbox-header-undo"
          class="inline-flex h-11 shrink-0 items-center rounded-field focus-visible-ring"
        >
          <span class={chip_class()}>Undo</span>
        </button>
        <button
          :if={!@undo and @row_count > 0}
          type="button"
          phx-click="clear_all"
          data-role="inbox-header-clear-all"
          class="inline-flex h-11 shrink-0 items-center rounded-field focus-visible-ring"
        >
          <span class={chip_class()}>Clear all</span>
        </button>
        <p role="status" class="sr-only" data-role="inbox-status">{@undo && @undo.message}</p>
      </header>
      <div
        class="min-h-0 flex-1 overflow-y-auto overscroll-contain clears-tab-bar"
        data-role="inbox-phone-list"
      >
        <p
          :if={@row_count == 0 and @undo != nil}
          data-role="inbox-phone-cleared"
          class="px-6 py-10 text-center text-sm text-subtle"
        >
          Inbox cleared.
        </p>
        <p
          :if={@row_count == 0 and @undo == nil}
          data-role="inbox-phone-empty"
          class="px-6 py-10 text-center text-sm text-subtle"
        >
          No mentions or replies yet.
        </p>
        <ul id="inbox-rows" role="list" phx-update="stream">
          <li
            :for={{dom_id, item} <- @rows}
            id={dom_id}
            class="relative"
            phx-remove={
              JS.hide(
                time: 150,
                transition:
                  {"transition-opacity duration-150 motion-reduce:transition-none", "opacity-100",
                   "opacity-0"}
              )
            }
          >
            <.row
              item={item}
              author={Map.get(@mention_authors, item.id)}
              source_title={Map.get(@source_titles, item.id)}
              space_label={space_label(item, @mention_space_labels)}
            />
            <%!-- The non-gesture path to the row sheet (Saru `states`): a
                 SIBLING of the row link, never inside it, so it is not part
                 of a live link and may carry a bare phx-click. --%>
            <button
              type="button"
              phx-click="open_row_sheet"
              phx-value-id={item.id}
              data-role="inbox-row-actions"
              aria-label={actions_label(item, Map.get(@mention_authors, item.id))}
              class="sr-only focus:not-sr-only focus:absolute focus:right-3 focus:top-1/2 focus:z-10 focus:inline-flex focus:min-h-11 focus:-translate-y-1/2 focus:items-center focus:rounded-field focus:border focus:border-edge focus:bg-base-100 focus:px-3 focus:text-sm focus:text-base-content focus-visible-ring"
            >
              Actions
            </button>
          </li>
        </ul>
      </div>
      <.row_sheet id={@row_sheet} />
    </section>
    """
  end

  attr :item, Item, required: true
  attr :author, :map, default: nil
  attr :source_title, :string, default: nil
  attr :space_label, :string, default: nil

  defp row(assigns) do
    author_slot =
      author_slot(assigns.item, assigns.author, assigns.space_label, assigns.source_title)

    assigns =
      assigns
      |> assign(:author_slot, author_slot)
      |> assign(:body, body(assigns.item, author_slot))
      |> assign(:unread?, is_nil(assigns.item.read_at))

    ~H"""
    <.link
      patch={~p"/inbox?open=#{@item.id}"}
      id={"inbox-row-link-#{@item.id}"}
      data-role="inbox-row"
      data-item-id={@item.id}
      data-item-kind={@item.kind}
      phx-hook="RowLongPress"
      data-long-press-event="open_row_sheet"
      data-long-press-id={@item.id}
      class="flex min-h-14 select-none items-center gap-3 rounded-box px-[18px] py-3 [-webkit-touch-callout:none] active:bg-base-100 focus-visible-ring"
    >
      <.avatar item={@item} author={@author} />
      <span class="min-w-0 flex-1">
        <span class="flex items-baseline gap-2">
          <b
            data-role="inbox-row-author"
            class="min-w-0 flex-1 truncate text-[15px] font-semibold text-base-content"
          >
            {@author_slot}
          </b>
          <time
            datetime={iso(@item.inserted_at)}
            class="shrink-0 whitespace-nowrap text-xs tabular-nums text-subtle"
          >
            {InboxItem.relative_time(@item.inserted_at)}
          </time>
        </span>
        <%!-- No `block` here: Tailwind emits `.block` after `.line-clamp-2`,
             so display: block would win and the clamp would not apply. --%>
        <span
          :if={@body}
          data-role="inbox-row-body"
          class={[
            "mt-0.5 line-clamp-2 break-words text-sm",
            if(@unread?, do: "text-base-content", else: "text-subtle")
          ]}
        >
          {@body}
        </span>
        <span
          data-role="inbox-row-kind"
          class="mt-0.5 flex items-center gap-1.5 text-xs text-subtle"
        >
          <span
            :if={kind_dot?(@item.kind)}
            class="size-2 shrink-0 rounded-full bg-error"
            aria-hidden="true"
            data-role="inbox-row-kind-dot"
          >
          </span>
          {kind_word(@item.kind)}
        </span>
      </span>
      <span
        :if={@unread?}
        class="size-2 shrink-0 rounded-full bg-primary"
        aria-hidden="true"
        data-role="inbox-row-unread-dot"
      >
      </span>
      <span :if={@unread?} class="sr-only">Unread</span>
    </.link>
    """
  end

  attr :item, Item, required: true
  attr :author, :map, default: nil

  defp avatar(%{author: %{name: _}} = assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role="inbox-row-avatar"
      data-avatar={if @author.agent?, do: "agent", else: "person"}
      class="flex size-[42px] shrink-0 items-center justify-center overflow-hidden rounded-full bg-base-300 text-[15px] font-semibold text-base-content"
    >
      <img
        :if={present?(@author.avatar_url)}
        src={@author.avatar_url}
        alt=""
        class="size-full object-cover"
        loading="lazy"
      />
      <span :if={!present?(@author.avatar_url)}>{initial(@author.name)}</span>
    </span>
    """
  end

  defp avatar(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role="inbox-row-avatar"
      data-avatar="kind"
      class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content"
    >
      <.icon name={InboxItem.kind_icon(@item.kind)} class="size-5" />
    </span>
    """
  end

  attr :id, :any, default: nil

  # The long-press sheet (prototype :1397, `stub('Notification', ...)`), with
  # Select cut (Saru `states`: it leads into multi-select, which is not
  # built). Dismiss is a button, so a bare phx-click is fine on it; Open is a
  # patch link with NO phx-click, and the sheet closes because
  # `InboxLive.handle_params/3` resets `@row_sheet`.
  defp row_sheet(assigns) do
    ~H"""
    <.sheet
      id="inbox-row-sheet"
      open={@id != nil}
      placement={:bottom}
      on_close="close_row_sheet"
      class="inbox-row-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Notification</:title>
      <div :if={@id} class="flex flex-col pb-2" data-role="inbox-row-sheet-list">
        <p class="px-4 pb-1 text-sm font-semibold text-base-content" aria-hidden="true">
          Notification
        </p>
        <button
          type="button"
          phx-click="dismiss"
          phx-value-id={@id}
          data-role="inbox-sheet-dismiss"
          class="flex min-h-11 w-full items-center gap-3 rounded-field px-4 py-2 text-left text-[15px] text-base-content active:bg-base-200 focus-visible-ring"
        >
          <span class="hero-check size-5 shrink-0 text-base-content" aria-hidden="true"></span>
          <span>Dismiss</span>
        </button>
        <.link
          patch={~p"/inbox?open=#{@id}"}
          data-role="inbox-sheet-open"
          class="flex min-h-11 w-full items-center gap-3 rounded-field px-4 py-2 text-[15px] text-base-content active:bg-base-200 focus-visible-ring"
        >
          <span class="hero-arrow-up-right size-5 shrink-0 text-base-content" aria-hidden="true">
          </span>
          <span>Open</span>
        </.link>
      </div>
    </.sheet>
    """
  end

  @doc """
  The Actions button's accessible name: the author's message for a mention
  with an author, else the row's kind word.
  """
  def actions_label(%Item{kind: "chat_mention"}, %{name: name}),
    do: "Actions for #{name}'s message"

  def actions_label(%Item{kind: kind}, _author), do: "Actions for #{kind_word(kind)}"

  @doc """
  The meta line's kind word for an inbox `kind` key (table in the moduledoc).
  Every key in `Platform.Inbox.Item.kinds/0` maps to a non-blank word.
  """
  @spec kind_word(String.t()) :: String.t()
  def kind_word(kind), do: InboxItem.kind_label(kind, :short)

  @doc """
  Whether the kind word carries the error dot: true for a failed lifecycle
  step only. The colour is on the dot, never on the word (see the moduledoc).
  """
  @spec kind_dot?(String.t()) :: boolean()
  def kind_dot?("lifecycle_step_failed"), do: true
  def kind_dot?(_kind), do: false

  @doc """
  The author slot's text: the source of the row (see the moduledoc).
  """
  def author_slot(%Item{kind: "chat_mention"}, %{name: name}, space, _title) do
    cond do
      # A DM's space label is the peer's name, which is the author: "Bea · Bea"
      # says nothing twice. The prototype writes "{name} · DM" (:601).
      space == name -> "#{name} · DM"
      present?(space) -> "#{name} · #{space}"
      true -> name
    end
  end

  def author_slot(%Item{kind: "chat_mention"} = item, _author, space, _title) do
    if present?(space), do: space, else: item.title
  end

  def author_slot(%Item{} = item, _author, _space, title) do
    if present?(title), do: title, else: item.title
  end

  # The excerpt or summary, never a repeat of what the author slot already says.
  defp body(%Item{body: body} = item, author_slot) do
    cond do
      present?(body) -> body
      present?(item.title) and item.title != author_slot -> item.title
      true -> nil
    end
  end

  defp space_label(%Item{kind: "chat_mention"} = item, labels),
    do: InboxLive.mention_space_label(item, labels)

  defp space_label(_item, _labels), do: nil

  defp chip_class,
    do:
      "inline-flex h-8 items-center rounded-field border border-edge bg-base-100 px-3.5 text-sm text-base-content"

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp initial(name) when is_binary(name) do
    name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
