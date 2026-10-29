defmodule PlatformWeb.Components.MeetingBriefingRow do
  @moduledoc """
  A concluded meeting's briefing row in the Inbox list (task 01a1694a
  stage 4).

  One `Platform.Inbox.Item` of kind `meeting_briefing` per attendee per
  meeting (`source_id` is the `meeting_briefings` id, `url` is
  `/inbox/meeting/<meeting_id>`). The row opens the briefing in the detail
  pane; opening marks it read and it STAYS listed (`meeting_briefing` is in
  `Platform.Inbox.action_kinds/0`).

  ## Logic and markup are separate

  `assigns_for/2` is a pure function from the Inbox row plus the briefing's
  live counts (`Platform.Meetings.MeetingBriefings.view/2`) to every slot
  the row shows. `meeting_briefing_row/1` only paints them, mirroring
  `PlatformWeb.Components.BriefingRow`, so a later list renderer (redesign
  rung 14's phone list) can call `assigns_for/2` and change only markup.

  ## Copy

    * kind: "Meeting";
    * title: the meeting's name;
    * receipt line: "<N> items · <K> open", or "All resolved";
    * time: when the meeting ended, in the viewer's zone.

  ## Skin

  BriefingRow's: the `rounded-2xl border border-edge bg-base-100` card, the
  unread dot with an `sr-only` "Unread", secondary text in `text-subtle`,
  and hover and the selected bar at `lg` and up only.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Inbox.Item
  alias PlatformWeb.InboxLive.MeetingBriefingCopy, as: Copy

  @doc """
  Every slot of the row, as plain data.

  Options:

    * `:counts` — `%{total, open}` from `MeetingBriefings.view/2`
      (default zero);
    * `:ended_at` — when the meeting ended;
    * `:time_zone` — the viewer's IANA zone;
    * `:selected` — whether this row's briefing is open in the pane;
    * `:open_finding_kinds` — the kinds of the synthesis findings open in
      the viewer's `view/2` (task 01a16974 stage 5), for the row's finding
      hint. Only findings the viewer can see reach here.
  """
  @spec assigns_for(Item.t(), keyword()) :: map()
  def assigns_for(%Item{} = item, opts \\ []) do
    counts = Map.merge(%{total: 0, open: 0}, Keyword.get(opts, :counts) || %{})

    %{
      id: item.id,
      dom_id: "inbox-meeting-briefing-#{item.id}",
      kind: Copy.kind_label(),
      title: item.title,
      meeting_id: meeting_id(item.url),
      url: item.url,
      summary: Copy.receipt_line(counts),
      time: Copy.ended(Keyword.get(opts, :ended_at), Keyword.get(opts, :time_zone)),
      unread?: is_nil(item.read_at),
      selected?: Keyword.get(opts, :selected, false) == true,
      finding: Copy.row_finding(Keyword.get(opts, :open_finding_kinds) || []),
      counts: counts
    }
  end

  @doc "The meeting id in a row url `/inbox/meeting/<id>`, else nil."
  @spec meeting_id(String.t() | nil) :: String.t() | nil
  def meeting_id("/inbox/meeting/" <> id), do: if(Platform.UUID.valid?(id), do: id)
  def meeting_id(_url), do: nil

  # ── Markup ─────────────────────────────────────────────────────────────

  attr(:row, :map, required: true, doc: "The map `assigns_for/2` returns.")
  attr(:patch, :string, required: true, doc: "Where the row patches to (keeps the filter).")

  def meeting_briefing_row(assigns) do
    ~H"""
    <li
      id={@row.dom_id}
      class={[
        "group relative flex items-stretch gap-1 rounded-2xl border border-edge transition-colors lg:hover:border-base-content/20",
        if(@row.selected?, do: "bg-base-100 lg:bg-base-300", else: "bg-base-100")
      ]}
      data-role="inbox-meeting-briefing-row"
      data-item-id={@row.id}
      data-meeting-id={@row.meeting_id}
      data-selected={to_string(@row.selected?)}
    >
      <span
        :if={@row.selected?}
        class="absolute inset-y-0 left-0 hidden w-1 rounded-l-2xl bg-primary lg:block"
        aria-hidden="true"
      >
      </span>
      <.link
        patch={@patch}
        class="flex min-w-0 flex-1 items-start gap-3 rounded-2xl py-3 pl-4 pr-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
        data-role="inbox-meeting-briefing-open"
        aria-current={if(@row.selected?, do: "page")}
      >
        <span
          class="flex size-9 shrink-0 items-center justify-center rounded-xl bg-primary text-primary-content"
          aria-hidden="true"
        >
          <.icon name="hero-video-camera" class="size-5" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="flex flex-wrap items-center gap-2">
            <span
              class="text-xs font-medium uppercase tracking-wide text-subtle"
              data-role="inbox-meeting-briefing-kind"
            >
              {@row.kind}
            </span>
            <span
              :if={@row.unread?}
              class="ml-auto size-2 shrink-0 rounded-full bg-primary"
              data-role="inbox-meeting-briefing-unread-dot"
              aria-hidden="true"
            >
            </span>
            <span :if={@row.unread?} class="sr-only">Unread</span>
          </span>

          <span
            class={[
              "mt-1 block truncate text-sm text-base-content",
              if(@row.unread?, do: "font-semibold", else: "font-normal")
            ]}
            data-role="inbox-meeting-briefing-title"
          >
            {@row.title}
          </span>

          <span class="mt-0.5 block text-sm text-subtle" data-role="inbox-meeting-briefing-summary">
            {@row.summary}
          </span>

          <span
            :if={@row[:finding]}
            class="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-base-content"
            data-role="inbox-meeting-briefing-finding"
          >
            <.icon name="hero-arrows-right-left" class="size-3.5 shrink-0 text-interactive" />
            {@row.finding}
          </span>

          <span class="mt-1 block text-xs text-subtle" data-role="inbox-meeting-briefing-time">
            {@row.time}
          </span>
        </span>
      </.link>

      <button
        type="button"
        phx-click="dismiss_meeting_briefing"
        phx-value-id={@row.id}
        class="m-1 flex size-11 shrink-0 items-center justify-center self-center rounded-full text-subtle opacity-100 transition lg:m-2 lg:size-8 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 lg:opacity-0 lg:hover:bg-error/10 lg:hover:text-error lg:group-hover:opacity-100 lg:group-focus-within:opacity-100"
        data-role="inbox-meeting-briefing-dismiss"
        aria-label="Dismiss meeting briefing"
        title="Dismiss"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </li>
    """
  end
end
