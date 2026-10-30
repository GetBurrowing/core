defmodule PlatformWeb.CalendarLive.Components do
  @moduledoc """
  Calendar v4 function components (task 01a18d9f stage 1). The spec is
  prototype `01a178d2-1759-7000-9308-91156fa39e67` version 4; each
  component cites the `app.js` / `index.html` rule it renders.

  Colours are main's semantic slots only (ground `base-200`, surface
  `base-100`, raised `base-300`, edge `border-edge`, muted `text-subtle`,
  accent `primary`). The chip kinds, grid lines, now line and today tint live
  in the `/* calendar v4 */` block of `app.css`.

  The desktop parts (`list_pane/1`, the desktop `cal_header/1`, `week_grid/1`)
  show at `lg`; the phone parts (`section_tabs/1`, `day_strip/1`, the
  single-day column) below it. The prototype switches at 899px; main's shell
  switches at Tailwind `lg` (1024px, `icon_rail.ex` `bottom-nav lg:hidden`).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias PlatformWeb.CalendarLive, as: Cal

  @primary_btn "inline-flex h-8 items-center gap-1.5 whitespace-nowrap rounded-full bg-primary px-3 text-xs font-semibold text-primary-content hover:brightness-110"
  @ghost_btn "inline-flex h-8 items-center gap-1.5 whitespace-nowrap rounded-full border border-subtle px-3 text-xs text-base-content hover:bg-base-300"
  @icon_btn "inline-flex size-[34px] shrink-0 items-center justify-center rounded-full text-subtle hover:bg-base-300 hover:text-base-content"

  def primary_btn, do: @primary_btn
  def ghost_btn, do: @ghost_btn
  def icon_btn, do: @icon_btn

  # ── list pane (index.html `.list`, app.js `renderList`) ────────────────

  attr(:mini_month, Date, required: true)
  attr(:cursor, Date, required: true)
  attr(:today, Date, required: true)
  attr(:view, :string, required: true)
  attr(:section, :atom, default: :calendar, values: [:calendar, :booking, :settings])
  attr(:booking_link_count, :integer, default: 0)
  attr(:calendars, :list, default: [])
  attr(:calendars_shown, :map, default: %{})

  @doc "The 270px desktop list pane: header, mini month, nav rows, calendar toggles."
  def list_pane(assigns) do
    ~H"""
    <section
      class="hidden w-[270px] shrink-0 min-h-0 flex-col overflow-hidden border-r border-edge bg-base-100 lg:flex"
      aria-label="Calendar navigation"
      data-role="calendar-list-pane"
    >
      <div class="flex h-[52px] shrink-0 items-center gap-1.5 border-b border-edge px-3">
        <h2 class="m-0 flex-1 text-[17px] font-[650]">Calendar</h2>
        <button id="calendar-new" type="button" phx-click="new" class={primary_btn()}>
          + New
        </button>
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto p-2">
        <.mini_month month={@mini_month} cursor={@cursor} today={@today} view={@view} />
        <.nav_row
          href={~p"/calendar"}
          current={@section == :calendar}
          icon="hero-calendar"
          label="Calendar"
          note="week and month"
        />
        <.nav_row
          href={~p"/calendar/booking"}
          current={@section == :booking}
          icon="hero-user-group"
          navigate
          label="Booking links"
          note={"#{@booking_link_count} #{if @booking_link_count == 1, do: "link", else: "links"}"}
        />
        <.nav_row
          href={~p"/calendar/settings"}
          current={@section == :settings}
          icon="hero-lock-closed"
          label="Calendar settings"
          note="feed · external · agents"
        />
        <div class="px-2 pb-1 pt-3 text-xs font-[650] uppercase tracking-[.08em] text-subtle">
          Calendars
        </div>
        <.legend_toggle
          :for={cal <- @calendars}
          cal={cal}
          shown={Cal.shown?(@calendars_shown, cal.key)}
        />
      </div>
    </section>
    """
  end

  attr(:href, :string, required: true)
  attr(:navigate, :boolean, default: false)
  attr(:current, :boolean, default: false)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:note, :string, required: true)

  defp nav_row(assigns) do
    ~H"""
    <.link
      patch={!@navigate && @href}
      navigate={@navigate && @href}
      class={[
        "relative flex w-full items-center gap-2 rounded-[var(--radius-field)] p-2 text-left text-[13px] hover:bg-base-300",
        @current && "bg-base-300"
      ]}
      aria-current={@current && "true"}
    >
      <.icon name={@icon} class="size-[18px] shrink-0" />
      <span class="min-w-0 flex-1">
        {@label}<small class="block text-xs text-subtle">{@note}</small>
      </span>
    </.link>
    """
  end

  attr(:cal, :map, required: true)
  attr(:shown, :boolean, required: true)

  defp legend_toggle(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@shown)}
      phx-click="toggle_calendar"
      phx-value-key={@cal.key}
      data-calendar-key={@cal.key}
      class="flex w-full items-center gap-2.5 rounded-[var(--radius-field)] px-2 py-1.5 text-left text-[13px] hover:bg-base-300"
    >
      <span class={[
        "inline-flex size-4 shrink-0 items-center justify-center rounded border-[1.5px]",
        @shown && "border-base-content bg-base-content text-base-200",
        !@shown && "border-subtle"
      ]}>
        <.icon :if={@shown} name="hero-check" class="size-3" />
      </span>
      <span class="min-w-0 flex-1">
        {@cal.label}<small class="block text-xs text-subtle">{@cal.note}</small>
      </span>
      <i class={"cal-sw cal-k-#{@cal.kind}"}></i>
    </button>
    """
  end

  # ── mini month (app.js `miniMonth`) ────────────────────────────────────

  attr(:month, Date, required: true)
  attr(:cursor, Date, required: true)
  attr(:today, Date, required: true)
  attr(:view, :string, required: true)

  def mini_month(assigns) do
    assigns =
      assign(assigns,
        weeks: assigns.month |> Cal.mini_days() |> Enum.chunk_every(7),
        week: Cal.week_days(assigns.cursor)
      )

    ~H"""
    <div class="px-1 pb-2 pt-1" data-role="calendar-mini-month">
      <div class="flex items-center px-1 pb-1 text-[13px] font-semibold">
        <span class="flex-1" data-role="calendar-mini-label">
          {Calendar.strftime(@month, "%B %Y")}
        </span>
        <button
          type="button"
          class={icon_btn()}
          phx-click="mini_month"
          phx-value-direction="previous"
          aria-label="Previous month"
        >
          <.icon name="hero-chevron-left" class="size-[18px]" />
        </button>
        <button
          type="button"
          class={icon_btn()}
          phx-click="mini_month"
          phx-value-direction="next"
          aria-label="Next month"
        >
          <.icon name="hero-chevron-right" class="size-[18px]" />
        </button>
      </div>
      <table class="w-full border-collapse text-center text-xs">
        <thead>
          <tr>
            <th :for={d <- ~w(M T W T F S S)} class="py-0.5 font-[550] text-subtle">{d}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={week <- @weeks}>
            <td :for={day <- week}>
              <button
                type="button"
                phx-click="goday"
                phx-value-date={Date.to_iso8601(day)}
                aria-label={Cal.day_label(day)}
                class={[
                  "size-7 rounded-full text-xs",
                  day == @today && "bg-primary font-bold text-primary-content",
                  day != @today && "hover:bg-base-300",
                  day != @today && day.month != @month.month && "text-subtle",
                  day != @today && day.month == @month.month && "text-base-content",
                  day != @today && @view == "week" && day in @week && "bg-base-300"
                ]}
              >
                {day.day}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ── header (app.js `headHTML`) ─────────────────────────────────────────

  attr(:view, :string, required: true)
  attr(:cursor, Date, required: true)
  attr(:sel_day, Date, required: true)
  attr(:zone, :string, required: true)

  @doc "The main pane header: one desktop row, two phone rows."
  def cal_header(assigns) do
    ~H"""
    <div
      class="hidden min-h-[52px] shrink-0 flex-wrap items-center gap-2 border-b border-edge px-4 lg:flex"
      data-role="calendar-header"
    >
      <.date_nav step="week" />
      <span class="whitespace-nowrap text-[13px] font-semibold" data-role="calendar-range">
        {Cal.range_label(@view, @cursor, @sel_day)}
      </span>
      <span class="rounded-[calc(var(--radius-field)-3px)] border border-edge px-1.5 py-px font-mono text-xs text-subtle">
        {@zone}
      </span>
      <span class="flex-1"></span>
      <.view_switch view={@view} />
      <button type="button" class={primary_btn()} phx-click="new" id="calendar-new-event">
        + New event
      </button>
    </div>
    <div class="shrink-0 lg:hidden" data-role="calendar-phone-header">
      <div class="flex min-h-[52px] items-center gap-1.5 border-b border-edge px-3 py-1.5">
        <h1 class="m-0 whitespace-nowrap text-[17px] font-[650]">Calendar</h1>
        <span class="flex-1"></span>
        <.view_switch view={@view} />
        <button
          type="button"
          class={icon_btn()}
          phx-click="new"
          phx-value-date={Date.to_iso8601(@sel_day)}
          aria-label="New event"
        >
          <.icon name="hero-plus" class="size-[18px]" />
        </button>
      </div>
      <div class="flex min-h-11 items-center gap-1.5 border-b border-edge px-3 py-1.5">
        <.date_nav step="day" />
        <span class="whitespace-nowrap text-[13px] font-semibold">
          {Cal.phone_range_label(@view, @cursor, @sel_day)}
        </span>
      </div>
    </div>
    """
  end

  attr(:step, :string, required: true)

  defp date_nav(assigns) do
    ~H"""
    <button
      type="button"
      class={icon_btn()}
      phx-click="navigate_date"
      phx-value-direction="previous"
      phx-value-step={@step}
      aria-label="Previous"
    >
      <.icon name="hero-chevron-left" class="size-[18px]" />
    </button>
    <button
      type="button"
      class={icon_btn()}
      phx-click="navigate_date"
      phx-value-direction="next"
      phx-value-step={@step}
      aria-label="Next"
    >
      <.icon name="hero-chevron-right" class="size-[18px]" />
    </button>
    <button type="button" class={ghost_btn()} phx-click="today">Today</button>
    """
  end

  attr(:view, :string, required: true)

  defp view_switch(assigns) do
    ~H"""
    <div
      class="inline-flex rounded-[var(--radius-field)] border border-edge bg-base-200 p-0.5"
      role="tablist"
      aria-label="Calendar view"
    >
      <.link
        :for={{value, label} <- [{"week", "Week"}, {"month", "Month"}]}
        patch={~p"/calendar?#{%{view: value}}"}
        role="tab"
        aria-selected={to_string(@view == value)}
        class={[
          "inline-flex h-[30px] items-center rounded-[calc(var(--radius-field)-2px)] px-2.5 text-xs",
          @view == value && "bg-base-100 text-base-content shadow-sm",
          @view != value && "text-subtle hover:text-base-content"
        ]}
      >
        {label}
      </.link>
    </div>
    """
  end

  # ── phone section tabs (app.js `.mnav`) ────────────────────────────────

  attr(:section, :atom, default: :calendar)

  def section_tabs(assigns) do
    ~H"""
    <nav
      class="flex shrink-0 gap-1.5 overflow-x-auto border-b border-edge px-3 py-2 [scrollbar-width:none] lg:hidden"
      aria-label="Calendar sections"
      data-role="calendar-section-tabs"
    >
      <.link
        :for={
          {key, label, href} <- [
            {:calendar, "Calendar", ~p"/calendar"},
            {:booking, "Booking links", ~p"/calendar/booking"},
            {:settings, "Settings", ~p"/calendar/settings"}
          ]
        }
        patch={key != :booking && href}
        navigate={key == :booking && href}
        aria-current={@section == key && "page"}
        class={[
          "inline-flex h-8 shrink-0 items-center whitespace-nowrap rounded-full border px-3 text-xs",
          @section == key && "border-subtle bg-base-300 text-base-content",
          @section != key && "border-edge text-subtle"
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  # ── legend (app.js `legendHTML`) ───────────────────────────────────────

  attr(:meetings_on, :boolean, required: true)

  def legend(assigns) do
    ~H"""
    <div
      class="flex flex-nowrap items-center gap-3 overflow-x-auto whitespace-nowrap border-b border-edge px-3 py-2 text-xs text-subtle [scrollbar-width:none] lg:flex-wrap lg:px-4"
      aria-label="Legend"
      data-role="calendar-legend"
    >
      <span class="inline-flex items-center gap-1.5">
        <i class="cal-sw cal-k-native"></i>Your events
      </span>
      <span :if={@meetings_on} class="inline-flex items-center gap-1.5" data-legend="meeting">
        <i class="cal-sw cal-k-meeting"></i>Meetings
      </span>
      <span class="inline-flex items-center gap-1.5">
        <i class="cal-sw cal-k-external"></i>External · read-only, blocks availability
      </span>
      <span class="inline-flex items-center gap-1.5">
        <i class="cal-sw cal-k-tentative"></i>Tentative agent hold
      </span>
    </div>
    """
  end

  # ── week grid (app.js `renderWeek`, index.html `.wk`) ──────────────────

  attr(:days, :list, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)
  attr(:today, Date, required: true)
  attr(:selected_id, :any, default: nil)

  @doc "The desktop week: sticky day header, 07–21 gutter, seven columns."
  def week_grid(assigns) do
    ~H"""
    <div class="hidden grid-cols-[56px_repeat(7,minmax(0,1fr))] lg:grid" data-role="calendar-week">
      <div class="sticky top-0 z-[4] border-b border-edge bg-base-200"></div>
      <div
        :for={day <- @days}
        class="sticky top-0 z-[4] border-b border-l border-edge bg-base-200 p-1.5 text-center"
        data-today={day == @today && "true"}
      >
        <small class="block text-xs uppercase tracking-[.1em] text-subtle">
          {Calendar.strftime(day, "%a")}
        </small>
        <b class={[
          "inline-flex size-[26px] items-center justify-center rounded-full text-xs font-semibold",
          day == @today && "bg-primary text-primary-content"
        ]}>
          {day.day}
        </b>
        <.all_day_chips entries={@entries} day={day} zone={@zone} />
      </div>
      <.gutter class="w-14 pr-2" />
      <.day_column
        :for={day <- @days}
        day={day}
        entries={@entries}
        zone={@zone}
        today={@today}
        selected_id={@selected_id}
        id_prefix="week"
      />
    </div>
    """
  end

  attr(:entries, :list, required: true)
  attr(:day, Date, required: true)
  attr(:zone, :string, required: true)

  # All-day events have no row in v4; PR #51 keeps them (Event.all_day), so
  # they sit under the date in the day header.
  defp all_day_chips(assigns) do
    assigns =
      assign(
        assigns,
        :all_day,
        assigns.entries |> Cal.entries_on(assigns.day, assigns.zone) |> Enum.filter(& &1.all_day)
      )

    ~H"""
    <button
      :for={entry <- @all_day}
      type="button"
      phx-click="select"
      phx-value-kind={entry.kind}
      phx-value-id={entry.id}
      data-kind={Cal.chip_kind(entry)}
      class={"cal-mchip mt-1 cal-k-#{Cal.chip_kind(entry)}"}
    >
      {Cal.chip_title(entry)}
    </button>
    """
  end

  attr(:class, :string, default: "")

  defp gutter(assigns) do
    {first, last} = Cal.hour_window()
    assigns = assign(assigns, hours: Enum.to_list(first..(last - 1)), first: first)

    ~H"""
    <div class="relative" aria-hidden="true">
      <div
        :for={hour <- @hours}
        class={["h-12 -translate-y-[7px] text-right font-mono text-xs text-subtle", @class]}
      >
        {if hour == @first, do: "", else: Cal.hm(hour * 60)}
      </div>
    </div>
    """
  end

  attr(:day, Date, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)
  attr(:today, Date, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:id_prefix, :string, required: true)

  @doc "One day column: 30-minute slot buttons, chips, the now line."
  def day_column(assigns) do
    {first, last} = Cal.hour_window()

    assigns =
      assign(assigns,
        slots: Enum.take_every((first * 60)..(last * 60 - 1), 30),
        chips: Cal.day_chips(assigns.entries, assigns.day, assigns.zone),
        first: first,
        now_top: assigns.day == assigns.today && Cal.now_top(assigns.zone)
      )

    ~H"""
    <div
      class={["cal-col", @day == @today && "cal-today"]}
      style={"height: #{Cal.grid_px()}px"}
      data-role="calendar-day-column"
      data-date={Date.to_iso8601(@day)}
    >
      <button
        :for={minute <- @slots}
        type="button"
        tabindex="-1"
        class="cal-slot"
        style={"top: #{(minute - @first * 60) / 60 * Cal.hour_px()}px"}
        phx-click="new_at"
        phx-value-date={Date.to_iso8601(@day)}
        phx-value-minute={minute}
        aria-label={"New event #{Cal.day_label(@day)} #{Cal.hm(minute)}"}
      >
      </button>
      <.event_chip
        :for={chip <- @chips}
        chip={chip}
        selected={@selected_id == chip.entry.id}
        id_prefix={@id_prefix}
      />
      <div :if={@now_top} class="cal-now" style={"top: #{@now_top}px"} data-role="calendar-now"></div>
    </div>
    """
  end

  attr(:chip, :map, required: true)
  attr(:selected, :boolean, default: false)
  attr(:id_prefix, :string, default: "chip")

  @doc "A positioned chip of one of the four kinds (cal.css `.ev`, `.k-*`)."
  def event_chip(assigns) do
    %{chip: chip} = assigns
    entry = chip.entry
    width = 100 / chip.lanes

    assigns =
      assign(assigns,
        entry: entry,
        kind: Cal.chip_kind(entry),
        live: Cal.live?(entry),
        range: "#{Cal.hm(chip.s)}–#{Cal.hm(min(chip.e, 1439))}",
        style:
          "top: #{chip.top}px; height: #{chip.height}px; " <>
            "left: calc(#{chip.lane * width}% + 3px); width: calc(#{width}% - 6px);",
        label: Cal.chip_label(entry, chip.date, chip.s, min(chip.e, 1439))
      )

    ~H"""
    <button
      type="button"
      id={"#{@id_prefix}-#{@chip.date}-#{@entry.kind}-#{@entry.id}-#{DateTime.to_unix(@entry.starts_at, :microsecond)}"}
      class={["cal-ev", "cal-k-#{@kind}", @live && "cal-live"]}
      style={@style}
      phx-click="select"
      phx-value-kind={@entry.kind}
      phx-value-id={@entry.id}
      aria-label={@label}
      aria-current={to_string(@selected)}
      data-kind={@kind}
    >
      <b>{Cal.chip_title(@entry)}</b>
      <small :if={!@chip.compact} data-role="chip-meta">
        <.chip_meta entry={@entry} kind={@kind} live={@live} range={@range} />
      </small>
    </button>
    """
  end

  attr(:entry, :map, required: true)
  attr(:kind, :string, required: true)
  attr(:live, :boolean, default: false)
  attr(:range, :string, required: true)

  # app.js `chipInner` meta line, verbatim.
  defp chip_meta(%{kind: "meeting"} = assigns) do
    ~H"""
    <i :if={@live} class="cal-pulse"></i>{if @live, do: "Live · "}<.icon
      name="hero-video-camera"
      class="cal-cam size-3 shrink-0"
    />Meeting · {@range}
    """
  end

  defp chip_meta(%{kind: "external"} = assigns) do
    ~H"""
    <.icon name="hero-lock-closed" class="size-3 shrink-0" />{Cal.external_label(@entry)} · {@range}
    """
  end

  defp chip_meta(%{kind: "tentative"} = assigns) do
    ~H"""
    Tentative · {@entry[:agent] || "Agent"} · needs OK
    """
  end

  defp chip_meta(assigns) do
    ~H"""
    <.icon :if={Cal.busy?(@entry)} name="hero-eye-slash" class="size-3 shrink-0" /><.icon
      :if={Cal.recurring?(@entry)}
      name="hero-arrow-path"
      class="size-3 shrink-0"
    />{@range}
    """
  end

  # ── phone: day strip + single-day column (app.js `renderWeek` on mob) ──

  attr(:sel_day, Date, required: true)
  attr(:today, Date, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)

  def day_strip(assigns) do
    assigns = assign(assigns, :days, Cal.week_days(assigns.sel_day))

    ~H"""
    <div
      class="sticky top-0 z-[5] flex border-b border-edge bg-base-200 px-2 pb-1 pt-2"
      role="tablist"
      aria-label="Days of the week"
      data-role="calendar-day-strip"
    >
      <button
        :for={day <- @days}
        type="button"
        role="tab"
        phx-click="select_day"
        phx-value-date={Date.to_iso8601(day)}
        aria-selected={to_string(day == @sel_day)}
        aria-label={"#{Cal.day_label(day)}, #{length(Cal.entries_on(@entries, day, @zone))} items"}
        class="flex flex-1 flex-col items-center gap-0.5 py-0.5 text-xs uppercase tracking-[.06em] text-subtle"
      >
        {String.first(Calendar.strftime(day, "%a"))}
        <b class={[
          "inline-flex size-8 items-center justify-center rounded-full text-[13px] font-semibold tracking-normal",
          day == @sel_day && "bg-primary text-primary-content",
          day != @sel_day && day == @today && "text-interactive",
          day != @sel_day && day != @today && "text-base-content"
        ]}>
          {day.day}
        </b>
      </button>
    </div>
    """
  end

  attr(:day, Date, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)
  attr(:today, Date, required: true)
  attr(:selected_id, :any, default: nil)

  @doc "The phone's single-day column: a 44px gutter and full-width chips."
  def phone_day(assigns) do
    ~H"""
    <div class="grid grid-cols-[44px_minmax(0,1fr)]" data-role="calendar-phone-day">
      <.gutter class="w-11 pr-2" />
      <.day_column
        day={@day}
        entries={@entries}
        zone={@zone}
        today={@today}
        selected_id={@selected_id}
        id_prefix="day"
      />
    </div>
    """
  end

  # ── month grid (app.js `renderMonth`, index.html `.mo`) ────────────────

  attr(:cursor, Date, required: true)
  attr(:today, Date, required: true)
  attr(:entries, :list, required: true)
  attr(:zone, :string, required: true)
  attr(:phone, :boolean, default: false)

  def month_grid(assigns) do
    days = Cal.month_days(assigns.cursor)

    assigns =
      assign(assigns,
        days: days,
        weeks: div(length(days), 7),
        max: if(assigns.phone, do: 6, else: 3),
        min_row: if(assigns.phone, do: 64, else: 112)
      )

    ~H"""
    <div
      class={[
        "grid grid-cols-7",
        @phone && "lg:hidden",
        !@phone && "hidden h-full lg:grid"
      ]}
      style={"grid-template-rows: auto repeat(#{@weeks}, minmax(#{@min_row}px, 1fr))"}
      data-role={if @phone, do: "calendar-month-phone", else: "calendar-month"}
    >
      <div
        :for={name <- ~w(Mon Tue Wed Thu Fri Sat Sun)}
        class="border-b border-edge px-2 py-1.5 text-xs uppercase tracking-[.1em] text-subtle"
      >
        {if @phone, do: String.first(name), else: name}
      </div>
      <div
        :for={day <- @days}
        role="button"
        tabindex="0"
        phx-click="goday"
        phx-value-date={Date.to_iso8601(day)}
        aria-label={"#{Cal.day_label(day)}, #{length(Cal.entries_on(@entries, day, @zone))} items"}
        class={[
          "cal-mcell flex min-w-0 flex-col gap-[3px] overflow-hidden border-b border-r border-edge p-1 text-left",
          day.month != @cursor.month && "cal-mcell-out"
        ]}
        data-date={Date.to_iso8601(day)}
      >
        <span class={[
          "inline-flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
          day == @today && "bg-primary text-primary-content",
          day != @today && day.month != @cursor.month && "text-subtle"
        ]}>
          {day.day}
        </span>
        <% list = Cal.entries_on(@entries, day, @zone) %>
        <div class={@phone && "flex flex-wrap gap-[3px] pl-1"}>
          <button
            :for={entry <- Enum.take(list, @max)}
            type="button"
            phx-click="select"
            phx-value-kind={entry.kind}
            phx-value-id={entry.id}
            data-kind={Cal.chip_kind(entry)}
            aria-label={month_chip_label(entry, day, @zone)}
            class={[
              if(@phone, do: "cal-dot", else: "cal-mchip mb-[3px]"),
              "cal-k-#{Cal.chip_kind(entry)}",
              Cal.live?(entry) && "cal-live"
            ]}
          >
            <span :if={!@phone} class="font-mono">{month_time(entry, day, @zone)}</span>
            <span :if={!@phone}>{Cal.chip_title(entry)}</span>
          </button>
        </div>
        <span :if={!@phone and length(list) > @max} class="pl-1.5 text-xs text-subtle">
          +{length(list) - @max} more
        </span>
      </div>
    </div>
    """
  end

  defp month_time(entry, day, zone) do
    {first, _} = Cal.day_minutes(entry, day, zone)
    Cal.hm(first)
  end

  defp month_chip_label(entry, day, zone) do
    {first, last} = Cal.day_minutes(entry, day, zone)
    Cal.chip_label(entry, day, first, min(last, 1439))
  end
end
