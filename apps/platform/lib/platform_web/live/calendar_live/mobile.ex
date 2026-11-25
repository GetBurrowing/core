defmodule PlatformWeb.CalendarLive.Mobile do
  @moduledoc """
  The phone calendar (canvas 01a2111c, "Calendar on a phone"), below `lg`:
  two rows of controls (about 108px), then the agenda or the Day view.

  Row 1 is the month button, Agenda | Day, Today (only while today is off
  screen), the "N▾" calendar selector and the one [+]. Row 2 is the week
  strip, which follows the agenda. The month pushes open in place under the
  rows. The selector opens a bottom sheet with the calendar toggles and the
  Calendar pages (Booking links, Settings, Past events) the phone section
  chips used to carry.

  Sizes are rem so they grow with the text size; the Day view's hour rows
  are px because the server positions its chips in px.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes
  alias Phoenix.LiveView.JS

  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  import PlatformWeb.CalendarLive.Components,
    only: [event_chip: 1, legend_toggle: 1]

  alias PlatformWeb.CalendarLive.Components

  import PlatformWeb.Components.Meetings.CancelMeeting, only: [cancelled_chip: 1]

  alias PlatformWeb.CalendarLive, as: Cal
  alias PlatformWeb.CalendarLive.Agenda

  @seg "inline-flex h-8 items-center whitespace-nowrap rounded-full px-2 text-xs font-medium"
  @round "inline-flex size-9 shrink-0 items-center justify-center rounded-full"

  defp seg_btn, do: @seg
  defp round_btn, do: @round

  # ── controls: row 1 and the week strip ────────────────────────────────

  attr(:view, :string, required: true)
  attr(:focus, Date, required: true)
  attr(:sel_day, Date, required: true)
  attr(:today, Date, required: true)
  attr(:show_today, :boolean, required: true)
  attr(:shown_count, :integer, required: true)
  attr(:month_open, :boolean, required: true)
  attr(:busy, :map, required: true, doc: "date => calendar entry count")
  attr(:ext, :map, default: %{}, doc: "date => %{count, label} of extension items")
  attr(:week_start, :integer, default: 1, doc: "1 = Monday … 7 = Sunday")

  def controls(assigns) do
    anchor = if assigns.view == "day", do: assigns.sel_day, else: assigns.focus

    assigns =
      assign(assigns,
        anchor: anchor,
        days: Agenda.week_days(anchor, assigns.week_start),
        letters: Agenda.weekday_letters(assigns.week_start)
      )

    ~H"""
    <%!-- `overflow-hidden`: in the low-space rule (canvas 01a2111c review A,
         `CalendarPhoneLayout`) the strip slides up under row 1, which
         always stays. --%>
    <div
      class="shrink-0 overflow-hidden border-b border-edge bg-base-100 lg:hidden"
      data-role="m-controls"
      id="m-controls"
    >
      <div
        class="relative z-[1] flex min-h-11 flex-wrap items-center gap-1 bg-base-100 px-1.5 py-0.5"
        data-role="m-row1"
      >
        <div class="flex shrink-0 items-center" data-role="m-date-group">
          <button
            :if={@view == "day"}
            type="button"
            class={[round_btn(), "!size-7 text-base-content hover:bg-base-200"]}
            phx-click="m_step"
            phx-value-direction="previous"
            aria-label="Previous day"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </button>
          <%!-- Agenda: "Nov 2026 ▾". Day view: the day ("Tue 24") between
               its ‹ ›, without the chevron so row 1 still fits 375px with
               Today showing; the month is one tap away either way. --%>
          <button
            type="button"
            id="m-month-button"
            phx-click="m_month_toggle"
            aria-expanded={to_string(@month_open)}
            aria-controls="m-month"
            aria-label={@view == "day" && "#{Cal.day_label(@sel_day)}, show month"}
            class="inline-flex h-8 shrink-0 items-center gap-0.5 whitespace-nowrap rounded-[var(--radius-field)] bg-base-200 px-1.5 text-sm font-semibold hover:bg-base-300"
            data-role="m-month-button"
          >
            <span :if={@view == "day"}>{Calendar.strftime(@sel_day, "%a %-d")}</span>
            <span :if={@view != "day"}>{Calendar.strftime(@anchor, "%b %Y")}</span>
            <.icon
              :if={@view != "day"}
              name="hero-chevron-down"
              class={["size-3.5 transition-transform", @month_open && "rotate-180"]}
            />
          </button>
          <button
            :if={@view == "day"}
            type="button"
            class={[round_btn(), "!size-7 text-base-content hover:bg-base-200"]}
            phx-click="m_step"
            phx-value-direction="next"
            aria-label="Next day"
          >
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
        <div class="ms-auto flex flex-wrap items-center justify-end gap-1">
          <div
            class="inline-flex shrink-0 rounded-full border border-edge bg-base-200 p-0.5"
            role="tablist"
            aria-label="Calendar view"
            data-role="m-view-switch"
          >
            <button
              :for={{value, label} <- [{"agenda", "Agenda"}, {"day", "Day"}]}
              type="button"
              role="tab"
              phx-click="m_view"
              phx-value-view={value}
              aria-selected={to_string(@view == value)}
              data-view={value}
              class={[
                seg_btn(),
                @view == value && "bg-base-100 text-base-content shadow-sm",
                @view != value && "text-subtle hover:text-base-content"
              ]}
            >
              {label}
            </button>
          </div>
          <button
            :if={@show_today}
            type="button"
            phx-click="m_today"
            data-role="m-today"
            class="inline-flex h-8 shrink-0 items-center whitespace-nowrap rounded-full border border-subtle px-2 text-xs font-medium hover:bg-base-200"
          >
            Today
          </button>
          <button
            type="button"
            phx-click="m_sheet_open"
            aria-haspopup="dialog"
            aria-controls="m-calendars-sheet"
            aria-label={"#{@shown_count} #{if @shown_count == 1, do: "calendar", else: "calendars"} shown"}
            data-role="m-calendars-button"
            class="inline-flex h-8 shrink-0 items-center gap-0.5 whitespace-nowrap rounded-full border border-edge px-1.5 text-xs font-semibold hover:bg-base-200"
          >
            {@shown_count}<.icon name="hero-chevron-down" class="size-3.5" />
          </button>
          <button
            type="button"
            phx-click="m_create_open"
            aria-label="New event"
            aria-haspopup="dialog"
            data-role="m-new"
            class={[round_btn(), "bg-primary text-primary-content hover:brightness-110"]}
          >
            <.icon name="hero-plus" class="size-5" />
          </button>
        </div>
      </div>
      <div
        id="m-strip"
        phx-hook="CalendarSwipe"
        data-swipe-event="m_strip_step"
        class="flex touch-pan-y px-1 pb-1 transition-[margin-top] duration-150 motion-reduce:transition-none"
        role="group"
        aria-label={"Week of #{Cal.day_label(hd(@days))}"}
        data-role="calendar-day-strip"
        data-week={Date.to_iso8601(hd(@days))}
      >
        <button
          :for={{day, letter} <- Enum.zip(@days, @letters)}
          type="button"
          phx-click="m_pick"
          phx-value-date={Date.to_iso8601(day)}
          aria-label={strip_label(day, @today, @busy, @ext)}
          aria-current={day == @today && "date"}
          aria-pressed={@view == "day" && to_string(day == @sel_day)}
          data-date={Date.to_iso8601(day)}
          class="flex min-h-11 min-w-0 flex-1 flex-col items-center gap-0.5 rounded-box py-0.5 hover:bg-base-200"
        >
          <span class="text-xs font-medium text-secondary" aria-hidden="true">{letter}</span>
          <span
            class={[
              "inline-flex size-7 items-center justify-center rounded-full text-sm font-semibold",
              day == @today && "bg-base-content text-base-100",
              day != @today && "text-base-content",
              @view == "day" && day == @sel_day && day != @today &&
                "ring-2 ring-base-content ring-inset"
            ]}
            aria-hidden="true"
          >
            {day.day}
          </span>
          <.cell_marks day={day} busy={@busy} ext={@ext} dot="size-1.5" />
        </button>
      </div>
    </div>
    """
  end

  # "Wed 25 Nov, today, 2 events, 3 Social items" (review: the Social count
  # is in the cell's name, since the marker is not a separate target).
  defp strip_label(day, today, busy, ext) do
    n = Map.get(busy, day, 0)

    [
      Cal.day_label(day),
      day == today && "today",
      n > 0 && "#{n} #{if n == 1, do: "event", else: "events"}",
      ext[day] && ext[day].label
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  attr(:day, Date, required: true)
  attr(:busy, :map, required: true)
  attr(:ext, :map, required: true)
  attr(:dot, :string, required: true)

  # The dot (calendar events) and, beside it, the extension count marker: an
  # 11px `secondary` figure in a row of the dot's own height, so a cell with
  # a count is no taller than one without. Not a target of its own: the cell
  # picks the date; the agenda day header carries the chip.
  defp cell_marks(assigns) do
    ~H"""
    <span class={["flex items-center justify-center gap-0.5", @dot]} aria-hidden="true">
      <span
        class={["shrink-0 rounded-full", @dot, Map.get(@busy, @day, 0) > 0 && "bg-secondary"]}
        data-role={Map.get(@busy, @day, 0) > 0 && "m-strip-dot"}
      >
      </span>
      <span
        :if={@ext[@day]}
        class="text-[11px] font-semibold leading-none tabular-nums text-secondary"
        data-role="calendar-extension-count"
        data-date={Date.to_iso8601(@day)}
        aria-label={@ext[@day].label}
      >
        {@ext[@day].count}
      </span>
    </span>
    """
  end

  # ── the month, pushed open in place ────────────────────────────────────

  attr(:month, Date, required: true)
  attr(:today, Date, required: true)
  attr(:selected, Date, required: true)
  attr(:busy, :map, required: true)
  attr(:ext, :map, default: %{})
  attr(:week_start, :integer, default: 1)

  @doc """
  The month. Portrait at default text: pushed open in place under the
  controls, uncapped. In landscape or at 150%+ text `CalendarPhoneLayout`
  marks the page `data-month-sheet` and app.css lifts it into a bottom
  sheet over a scrim (review C); picking a date closes it either way.
  """
  def month(assigns) do
    assigns =
      assign(assigns,
        weeks: assigns.month |> Agenda.month_days(assigns.week_start) |> Enum.chunk_every(7),
        letters: Agenda.weekday_letters(assigns.week_start)
      )

    ~H"""
    <div class="m-month-scrim lg:hidden" phx-click="m_month_toggle" aria-hidden="true"></div>
    <div
      id="m-month"
      class="m-month shrink-0 border-b border-edge bg-base-100 px-2 pb-2 lg:hidden"
      data-role="m-month"
      aria-label="Month"
    >
      <div class="flex items-center px-1 py-1">
        <span class="flex-1 text-sm font-semibold" data-role="m-month-label">
          {Calendar.strftime(@month, "%B %Y")}
        </span>
        <button
          type="button"
          class={[round_btn(), "hover:bg-base-200"]}
          phx-click="m_month_nav"
          phx-value-direction="previous"
          aria-label="Previous month"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <button
          type="button"
          class={[round_btn(), "hover:bg-base-200"]}
          phx-click="m_month_nav"
          phx-value-direction="next"
          aria-label="Next month"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
      <div class="grid grid-cols-7 text-center" role="grid" aria-label="Month">
        <span
          :for={d <- @letters}
          class="py-0.5 text-xs font-medium text-secondary"
          aria-hidden="true"
        >
          {d}
        </span>
        <%= for week <- @weeks, day <- week do %>
          <button
            type="button"
            phx-click="m_pick"
            phx-value-date={Date.to_iso8601(day)}
            aria-label={strip_label(day, @today, @busy, @ext)}
            aria-current={day == @today && "date"}
            data-date={Date.to_iso8601(day)}
            class="flex min-h-10 flex-col items-center justify-center gap-0.5 rounded-box hover:bg-base-200"
          >
            <span class={[
              "inline-flex size-7 items-center justify-center rounded-full text-sm",
              day == @today && "bg-base-content font-semibold text-base-100",
              day != @today && day.month != @month.month && "text-subtle",
              day != @today && day == @selected && "ring-2 ring-base-content ring-inset"
            ]}>
              {day.day}
            </span>
            <.cell_marks day={day} busy={@busy} ext={@ext} dot="size-1" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ── agenda rows (one stream item each) ─────────────────────────────────

  attr(:id, :string, required: true)
  attr(:row, :map, required: true)
  attr(:day_entries, :list, default: [])

  def agenda_row(%{row: %{type: :empty}} = assigns) do
    ~H"""
    <section
      id={@id}
      data-role="m-agenda-row"
      data-type="empty"
      data-from={Date.to_iso8601(@row.from)}
      data-to={Date.to_iso8601(@row.to)}
    >
      <p
        class="flex flex-wrap gap-x-1.5 border-b border-edge px-4 py-2.5 text-sm text-subtle"
        data-ending={@row[:ending?] && "true"}
      >
        <span class="font-semibold text-base-content">
          {if @row[:ending?],
            do: "After " <> Calendar.strftime(Date.add(@row.from, -1), "%a %-d %b"),
            else: Agenda.range_label(@row.from, @row.to)}
        </span>
        <span>· No events</span>
      </p>
    </section>
    """
  end

  def agenda_row(%{row: %{type: :connect}} = assigns) do
    ~H"""
    <section
      id={@id}
      data-role="m-agenda-row"
      data-type="connect"
      data-from={Date.to_iso8601(@row.from)}
      data-to={Date.to_iso8601(@row.to)}
    >
      <div class="m-3 rounded-box border border-edge bg-base-200 p-4" data-role="m-agenda-connect">
        <p class="font-semibold">Connect a calendar</p>
        <p class="mt-1 text-sm text-subtle">
          Add another calendar's iCal link and its events show up here, read-only.
        </p>
        <.link
          patch={~p"/calendar/settings"}
          class="mt-3 inline-flex h-9 items-center rounded-full border border-subtle px-3 text-sm font-medium hover:bg-base-300"
        >
          Connect a calendar
        </.link>
      </div>
    </section>
    """
  end

  def agenda_row(assigns) do
    ~H"""
    <section
      id={@id}
      data-role="m-agenda-row"
      data-type="day"
      data-from={Date.to_iso8601(@row.date)}
      data-to={Date.to_iso8601(@row.date)}
      data-today={@row.today? && "true"}
      aria-labelledby={"#{@id}-h"}
    >
      <div
        class="sticky top-0 z-[2] flex items-center gap-2 border-b border-edge bg-base-100 px-4 py-1.5"
        data-role="m-agenda-day-header"
      >
        <h2 id={"#{@id}-h"} class="shrink-0 text-sm font-semibold">
          {Calendar.strftime(@row.date, "%a %-d %b")}{if @row.today?, do: " · Today"}
        </h2>
        <.ext_chips day={@row.date} day_entries={@day_entries} placement="agenda-phone" />
      </div>
      <div :if={@row.pinned != []} class="flex flex-col pt-1" data-role="m-agenda-pinned">
        <.agenda_item
          :for={p <- @row.pinned}
          entry={p.entry}
          date={@row.date}
          time="All day"
          sub={p.span}
        />
      </div>
      <p :if={@row.empty?} class="px-4 py-2.5 text-sm text-subtle" data-role="m-agenda-none">
        {if @row[:ext_only?], do: "No calendar events", else: "No events"}
      </p>
      <div :if={@row.timed != []} class="flex flex-col pb-1">
        <.agenda_item
          :for={t <- @row.timed}
          entry={t.entry}
          date={@row.date}
          time={Cal.hm(t.s)}
          sub={"#{Cal.hm(t.s)}–#{Cal.hm(min(t.e, 1439))}"}
          tz={t.tz}
        />
      </div>
    </section>
    """
  end

  attr(:entry, :map, required: true)
  attr(:date, Date, required: true)
  attr(:time, :string, required: true)
  attr(:sub, :string, default: nil)
  attr(:tz, :string, default: nil)

  defp agenda_item(assigns) do
    assigns =
      assign(assigns,
        kind: Cal.chip_kind(assigns.entry),
        cancelled: Cal.cancelled?(assigns.entry),
        live: Cal.live?(assigns.entry)
      )

    ~H"""
    <button
      type="button"
      phx-click="select"
      phx-value-kind={@entry.kind}
      phx-value-id={@entry.id}
      phx-value-start={DateTime.to_unix(@entry.starts_at)}
      data-role="m-agenda-item"
      data-kind={@kind}
      class="flex w-full items-stretch gap-3 px-4 py-1.5 text-left hover:bg-base-200"
    >
      <span class="min-w-[3.25rem] shrink-0 whitespace-nowrap pt-px text-sm tabular-nums text-secondary">
        {@time}
      </span>
      <span
        class={["cal-bar w-1 shrink-0 rounded-full", "cal-k-#{@kind}", @live && "cal-live"]}
        aria-hidden="true"
      >
      </span>
      <span class="min-w-0 flex-1">
        <span class={[
          "line-clamp-2 text-sm font-medium text-base-content",
          @cancelled && "line-through"
        ]}>
          {Cal.chip_title(@entry)}
        </span>
        <span class="flex flex-wrap items-center gap-x-1.5 text-xs text-secondary">
          <span :if={@sub} class="whitespace-nowrap">{@sub}</span>
          <span :if={@kind == "external"}>{Cal.external_label(@entry)}</span>
          <span :if={@kind == "tentative"}>Tentative · needs OK</span>
          <span :if={@live} class="font-semibold">Live</span>
          <.cancelled_chip :if={@cancelled} />
        </span>
      </span>
      <span
        :if={@tz}
        class="h-fit shrink-0 whitespace-nowrap rounded border border-secondary px-1 text-xs text-secondary"
        data-role="m-tz"
      >
        {@tz}
      </span>
    </button>
    """
  end

  attr(:day, Date, required: true)
  attr(:day_entries, :list, default: [])
  attr(:placement, :string, required: true)

  # The extension chips for a day ("Social · 3"), as on the desktop week
  # header: the same `calendar_day_open` event, ids, data-role and data-date.
  # The date beside them is shrink-0; a chip truncates first. Never orange.
  defp ext_chips(assigns) do
    ~H"""
    <span class="flex min-w-0 flex-1 justify-end gap-1.5">
      <button
        :for={entry <- @day_entries}
        :if={entry.day == @day and entry.items != []}
        type="button"
        phx-click="calendar_day_open"
        phx-value-key={entry.key}
        phx-value-date={Date.to_iso8601(@day)}
        phx-value-placement={@placement}
        id={Components.day_chip_id(@placement, entry.key, @day)}
        data-role="calendar-extension-chip"
        data-date={Date.to_iso8601(@day)}
        aria-label={entry.aria}
        class="cal-mchip !w-auto min-w-0 max-w-full rounded-full border border-edge bg-base-200 !px-2 font-medium"
      >
        {entry.label} · {length(entry.items)}
      </button>
    </span>
    """
  end

  # ── Day view ───────────────────────────────────────────────────────────

  attr(:day, Date, required: true)
  attr(:today, Date, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:day_entries, :list, default: [])

  def day_view(assigns) do
    %{entries: entries, day: day, zone: zone} = assigns
    layout = Agenda.day_layout(entries, day, zone)

    assigns =
      assign(assigns,
        layout: layout,
        pinned:
          entries
          |> Cal.entries_on(day, zone)
          |> Enum.filter(&Agenda.pinned?(&1, zone))
          |> Enum.map(&%{entry: &1, span: Agenda.span_label(&1, day, zone)}),
        now: day == assigns.today && Agenda.now_hours(zone)
      )

    ~H"""
    <div
      id="m-day"
      phx-hook="CalendarDay"
      data-swipe-event="m_step"
      data-day={Date.to_iso8601(@day)}
      data-role="m-day"
      aria-live="off"
      class="m-day clears-tab-bar relative min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain bg-base-100 lg:hidden"
    >
      <div
        :if={@pinned != [] or Enum.any?(@day_entries, &(&1.day == @day and &1.items != []))}
        class="sticky top-0 z-[6] border-b border-edge bg-base-100 py-1"
        data-role="m-day-pinned"
      >
        <.agenda_item
          :for={p <- @pinned}
          entry={p.entry}
          date={@day}
          time="All day"
          sub={p.span}
        />
        <div class="flex px-4 pb-1">
          <.ext_chips day={@day} day_entries={@day_entries} placement="day-phone" />
        </div>
      </div>
      <p
        :if={@layout.chips == [] and @pinned == []}
        class="border-b border-edge px-4 py-2.5 text-sm text-subtle"
        data-role="m-day-none"
      >
        No events
      </p>
      <div class="grid grid-cols-[3rem_minmax(0,1fr)]">
        <div aria-hidden="true">
          <div
            :for={hour <- 0..23}
            class="relative h-[var(--m-hour)] pr-1.5 text-right text-xs tabular-nums text-secondary"
            data-hour={hour}
          >
            <span :if={hour > 0} class="relative -top-2">{Cal.hm(hour * 60)}</span>
          </div>
        </div>
        <div
          class="m-day-col relative"
          style="height: calc(var(--m-hour) * 24)"
          data-role="m-day-column"
          data-date={Date.to_iso8601(@day)}
        >
          <button
            :for={minute <- Enum.take_every(0..1439, 30)}
            type="button"
            tabindex="-1"
            class="cal-slot"
            style={"top: calc(var(--m-hour) * #{minute / 60}); height: calc(var(--m-hour) / 2)"}
            phx-click="new_at"
            phx-value-date={Date.to_iso8601(@day)}
            phx-value-minute={minute}
            aria-label={"New event #{Cal.day_label(@day)} #{Cal.hm(minute)}"}
          >
          </button>
          <.event_chip
            :for={chip <- @layout.chips}
            chip={Map.put(chip, :date, @day)}
            selected={@selected_id == chip.entry.id}
            id_prefix="m-day"
            style={chip_style(chip)}
            label={chip_label(chip, @day)}
          />
          <div
            :for={more <- @layout.more}
            class="absolute right-1 z-[5]"
            style={"top: calc(var(--m-hour) * #{more.hour} + 2px)"}
          >
            <button
              type="button"
              id={"#{more.id}-btn"}
              class="inline-flex h-6 items-center rounded-full border border-edge bg-base-100 px-2 text-xs font-semibold shadow-sm"
              phx-click={
                JS.toggle(to: "##{more.id}")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
              aria-expanded="false"
              aria-controls={more.id}
              aria-label={"#{length(more.entries)} more events"}
              data-role="m-day-more"
            >
              +{length(more.entries)}
            </button>
            <div
              id={more.id}
              class="absolute right-0 top-7 hidden w-56 rounded-box border border-edge bg-base-100 p-1 shadow-lg"
              data-role="m-day-more-list"
            >
              <.agenda_item
                :for={entry <- more.entries}
                entry={entry}
                date={@day}
                time={entry |> Cal.day_minutes(@day, @zone) |> elem(0) |> Cal.hm()}
              />
            </div>
          </div>
          <div
            :if={@now}
            class="pointer-events-none absolute inset-x-0 z-[4] h-[2px] bg-base-content"
            style={"top: calc(var(--m-hour) * #{@now})"}
            data-role="m-now"
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Hour rows are `--m-hour` tall (48px, growing with the text size to a
  # 96px cap: app.css `.m-day`), so blocks are placed in hours, not px.
  defp chip_style(chip) do
    width = 100 / chip.lanes

    "top: calc(var(--m-hour) * #{chip.s / 60}); " <>
      "height: max(22px, calc(var(--m-hour) * #{(chip.e - chip.s) / 60} - 2px)); " <>
      "left: calc(#{chip.lane * width}% + 3px); width: calc(#{width}% - 6px);"
  end

  # No visual tag on a Day view block (review D): its zone is in the label.
  defp chip_label(chip, day) do
    label = Cal.chip_label(chip.entry, day, chip.s, min(chip.e, 1439))
    if chip.tz, do: label <> ", times in your zone, event set in " <> chip.tz, else: label
  end

  # ── the calendar selector's bottom sheet ───────────────────────────────

  attr(:open, :boolean, required: true)
  attr(:calendars, :list, required: true)
  attr(:calendars_shown, :map, required: true)
  attr(:meetings_on, :boolean, default: false)

  def calendars_sheet(assigns) do
    ~H"""
    <.sheet id="m-calendars-sheet" open={@open} on_close="m_sheet_close" class="lg:hidden">
      <:title>Calendars</:title>
      <section data-sheet-section="calendars" aria-labelledby="m-sheet-calendars">
        <h3
          id="m-sheet-calendars"
          class="px-2 pb-1 pt-1 text-xs font-semibold uppercase tracking-[.08em] text-subtle"
        >
          Shown on your calendar
        </h3>
        <.legend_toggle
          :for={cal <- @calendars}
          cal={cal}
          shown={Cal.shown?(@calendars_shown, cal.key)}
        />
      </section>
      <%!-- People seam (canvas 01a2111c §2, review H). "People" (other
           people's calendars) and "Booking links" (schedules to browse) go
           here as their own `data-sheet-section`s once that question is
           answered. Not built on purpose. This sheet is filters only: the
           calendar pages are in the "Calendar ▾" title menu. --%>
      <div data-sheet-seam="people" hidden></div>
    </.sheet>
    """
  end

  # ── the "Calendar ▾" title menu (review H) ─────────────────────────────

  attr(:open, :boolean, required: true)
  attr(:view, :string, required: true)
  attr(:section, :atom, default: :calendar)

  @doc """
  The phone top bar's "Calendar ▾" menu: the calendar pages (Booking links,
  Calendar settings, Past events). When row 1 would need a third line at
  large text, `CalendarPhoneLayout` marks the page `data-row1-compact`:
  Agenda | Day leaves row 1 and shows here instead (app.css).
  """
  def title_menu(assigns) do
    ~H"""
    <div
      :if={@open}
      class="fixed inset-0 z-[62] lg:hidden"
      phx-click="m_menu_close"
      aria-hidden="true"
    >
    </div>
    <nav
      :if={@open}
      id="m-title-menu"
      class="fixed left-2 top-[calc(2.75rem+env(safe-area-inset-top))] z-[63] w-64 max-w-[calc(100vw-1rem)] rounded-box border border-edge bg-base-100 p-1.5 shadow-lg lg:hidden"
      aria-label="Calendar pages"
      data-role="m-title-menu"
    >
      <div :if={@section == :calendar} class="m-menu-views" data-role="m-menu-views">
        <p class="px-2 pb-1 pt-1 text-xs font-semibold uppercase tracking-[.08em] text-subtle">
          View
        </p>
        <button
          :for={{value, label} <- [{"agenda", "Agenda"}, {"day", "Day"}]}
          type="button"
          phx-click="m_view"
          phx-value-view={value}
          aria-pressed={to_string(@view == value)}
          data-view={value}
          class="flex min-h-11 w-full items-center gap-2.5 rounded-[var(--radius-field)] px-2 text-left text-sm hover:bg-base-300"
        >
          <.icon
            name={if value == "agenda", do: "hero-list-bullet", else: "hero-calendar"}
            class="size-[18px] shrink-0 text-subtle"
          />
          <span class="flex-1">{label}</span>
          <.icon :if={@view == value} name="hero-check" class="size-4" />
        </button>
        <div class="my-1 border-t border-edge"></div>
      </div>
      <.sheet_link href={~p"/calendar"} icon="hero-calendar-days" label="Calendar" />
      <.sheet_link href={~p"/calendar/booking"} navigate icon="hero-user-group" label="Booking links" />
      <.sheet_link href={~p"/calendar/settings"} icon="hero-lock-closed" label="Calendar settings" />
      <.sheet_link
        href={~p"/calendar?#{%{past: 1}}"}
        icon="hero-archive-box"
        label="Past events"
        past
      />
    </nav>
    """
  end

  attr(:href, :string, required: true)
  attr(:navigate, :boolean, default: false)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:past, :boolean, default: false)

  defp sheet_link(assigns) do
    ~H"""
    <.link
      patch={!@navigate && @href}
      navigate={@navigate && @href}
      data-past-events={@past && "open"}
      class="flex min-h-11 w-full items-center gap-2.5 rounded-[var(--radius-field)] px-2 text-left text-sm hover:bg-base-300"
    >
      <.icon name={@icon} class="size-[18px] shrink-0 text-subtle" />
      <span class="flex-1">{@label}</span>
      <.icon name="hero-chevron-right" class="size-4 text-subtle" />
    </.link>
    """
  end
end
