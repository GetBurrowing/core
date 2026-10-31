defmodule PlatformWeb.BookingSettingsLive do
  @moduledoc """
  `/calendar/booking`: the owner's booking links, rebuilt to prototype
  `01a178d2` v4 (`app.js` `renderBooking`, task 01a18d9f stage 3).

  The stage-1 list pane and phone section tabs frame a link-card column and
  an editor panel. Every control saves straight away through
  `Platform.Calendar.BookingLinks.update/3`, as the prototype's controls do;
  "Next open slots" reads `BookingLinks.preview/4` over the next 14 days.

  PR #51's policy fields that v4 has no control for stay reachable and are
  declared deviations: the bookable date range, the meeting project, revoke,
  and the recent-bookings receipts.
  """
  use PlatformWeb, :live_view

  import PlatformWeb.CalendarLive.Components

  alias Platform.Calendar.{BookingLink, BookingLinks}
  alias PlatformWeb.CalendarLive, as: Cal
  alias PlatformWeb.MeetingLive.CalendarWindow

  @lengths [15, 30, 45, 60, 90]
  @buffers [0, 5, 10, 15, 30]
  @notices [{120, "2 hours"}, {240, "4 hours"}, {1440, "1 day"}, {2880, "2 days"}]
  @seg_choices %{
    "duration_minutes" => @lengths,
    "buffer_before_minutes" => @buffers,
    "buffer_after_minutes" => @buffers,
    "minimum_notice_minutes" => Enum.map(@notices, &elem(&1, 0))
  }
  @weekdays [{1, "Mon", "Monday"}, {2, "Tue", "Tuesday"}, {3, "Wed", "Wednesday"}] ++
              [{4, "Thu", "Thursday"}, {5, "Fri", "Friday"}, {6, "Sat", "Saturday"}] ++
              [{7, "Sun", "Sunday"}]

  @impl true
  def mount(_params, _session, socket) do
    zone = CalendarWindow.resolve_time_zone(get_connect_params(socket)["timezone"]) || "Etc/UTC"
    scope = socket.assigns.access_scope
    today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    meetings_on =
      Platform.Meetings.Config.enabled?() and Platform.Access.can?(scope, "meetings.join") and
        Platform.Access.module_access?(scope, :meetings)

    projects =
      socket.assigns.current_user_record
      |> Platform.Tasks.list_projects_for_user()
      |> Enum.filter(&is_nil(&1.archived_at))

    socket =
      socket
      |> assign(
        page_title: "Booking links",
        zone: zone,
        today: today,
        mini_month: Date.beginning_of_month(today),
        calendars_shown: %{},
        meetings_on: meetings_on,
        projects: projects,
        selected: nil
      )
      |> reload()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    links = socket.assigns.links

    selected =
      Enum.find(links, &(&1.id == params["link"])) || current(socket) || List.first(links)

    {:noreply, socket |> assign(:selected, selected && selected.id) |> load_preview()}
  end

  # ── list pane (shared with CalendarLive) ────────────────────────────────

  @impl true
  def handle_event("mini_month", %{"direction" => direction}, socket) do
    month = socket.assigns.mini_month

    month =
      if direction == "previous",
        do: month |> Date.add(-1) |> Date.beginning_of_month(),
        else: Date.add(month, Date.days_in_month(month))

    {:noreply, assign(socket, :mini_month, month)}
  end

  def handle_event("goday", %{"date" => date}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/calendar?#{%{date: date}}")}

  def handle_event("new", _, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/calendar?#{%{new: 1}}")}

  def handle_event("toggle_calendar", %{"key" => key}, socket) do
    shown = socket.assigns.calendars_shown
    {:noreply, assign(socket, :calendars_shown, Map.put(shown, key, not Cal.shown?(shown, key)))}
  end

  # ── links ───────────────────────────────────────────────────────────────

  def handle_event("select_link", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/calendar/booking?#{%{link: id}}")}

  # app.js `ds.newLink`: an untitled 30-minute link, Mon–Fri 09:00–17:00,
  # 4 hours' notice. PR #51 also needs a zone and a bookable range.
  def handle_event("new_link", _, socket) do
    today = socket.assigns.today

    attrs = %{
      "title" => "Untitled link",
      "time_zone" => socket.assigns.zone,
      "duration_minutes" => 30,
      "buffer_before_minutes" => 0,
      "buffer_after_minutes" => 0,
      "minimum_notice_minutes" => 240,
      "start_date" => today,
      "end_date" => Date.add(today, 365),
      "windows" => for(day <- 1..5, do: window(day, "09:00", "17:00")),
      "create_meeting" => false
    }

    case BookingLinks.create(socket.assigns.access_scope, attrs) do
      {:ok, link} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Link created")
         |> push_patch(to: ~p"/calendar/booking?#{%{link: link.id}}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not create a booking link.")}
    end
  end

  def handle_event("rename", %{"title" => title}, socket) do
    title = String.trim(title)
    save(socket, %{"title" => if(title == "", do: "Untitled link", else: title)})
  end

  # The seg buttons carry `phx-value-minutes`, never `phx-value-value`: the
  # browser's click payload sets `value` to the button's own `.value` ("" on
  # a <button> without the attribute), which overwrote `phx-value-value` and
  # made every Length / Buffer / Minimum notice click a silent no-op. A
  # missing, empty or unoffered value is reported, never ignored.
  def handle_event("set", %{"field" => field} = params, socket)
      when is_map_key(@seg_choices, field) do
    with value when is_binary(value) <- params["minutes"],
         {minutes, ""} <- Integer.parse(value),
         true <- minutes in Map.fetch!(@seg_choices, field) do
      save(socket, %{field => minutes})
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "#{seg_label(field)}: that choice is not one of the options.")}
    end
  end

  def handle_event("dates", %{"start_date" => first, "end_date" => last}, socket),
    do: save(socket, %{"start_date" => first, "end_date" => last})

  def handle_event("project", %{"project_id" => id}, socket),
    do: save(socket, %{"project_id" => if(id == "", do: nil, else: id)})

  # The meeting option's switch (app.js `ds.meet`).
  def handle_event("meet", _, socket) do
    with %BookingLink{} = link <- selected_link(socket) do
      on = not link.create_meeting
      attrs = %{"create_meeting" => on}

      attrs =
        if on and is_nil(link.project_id),
          do:
            Map.put(
              attrs,
              "project_id",
              socket.assigns.projects |> List.first() |> then(&(&1 && &1.id))
            ),
          else: attrs

      flash =
        if on,
          do: "Bookings will create a Burrow meeting",
          else: "Bookings will be calendar-only"

      save(socket, attrs, flash)
    else
      _ -> {:noreply, socket}
    end
  end

  # Weekday switch (app.js `ds.wday`): off drops the day's windows; on adds
  # 09:00–17:00.
  def handle_event("wday", %{"day" => day}, socket) do
    with_windows(socket, day, fn
      [] -> [{"09:00", "17:00"}]
      _ -> []
    end)
  end

  # app.js `ds.wadd`: an hour after the last window, two hours long, inside
  # 06:00–22:00.
  def handle_event("wadd", %{"day" => day}, socket) do
    with_windows(socket, day, fn windows ->
      last_end =
        case List.last(windows) do
          {_, finish} -> minutes(finish)
          nil -> 9 * 60
        end

      first = min(last_end + 60, 21 * 60)
      windows ++ [{Cal.hm(first), Cal.hm(min(first + 120, 22 * 60))}]
    end)
  end

  def handle_event("wdel", %{"day" => day, "index" => index}, socket) do
    index = String.to_integer(index)
    with_windows(socket, day, &List.delete_at(&1, index))
  end

  # A window chip's start/end selects (app.js `t.dataset.wr`): an end at or
  # before the start moves to start + 30 minutes.
  def handle_event("wr", %{"day" => day, "index" => index} = params, socket) do
    index = String.to_integer(index)

    with_windows(socket, day, fn windows ->
      List.update_at(windows, index, fn _ ->
        first = minutes(params["start"])
        last = minutes(params["end"])
        last = if last <= first, do: min(first + 30, 22 * 60), else: last
        {Cal.hm(first), Cal.hm(last)}
      end)
    end)
  end

  def handle_event("copied", _, socket),
    do: {:noreply, put_flash(socket, :info, "Copied to clipboard")}

  def handle_event("revoke", _, socket) do
    with %BookingLink{id: id} <- selected_link(socket),
         {:ok, _} <- BookingLinks.revoke(socket.assigns.access_scope, id) do
      {:noreply,
       socket
       |> assign(:selected, nil)
       |> reload()
       |> put_flash(:info, "Link revoked")
       |> push_patch(to: ~p"/calendar/booking")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not revoke this link.")}
    end
  end

  defp with_windows(socket, day, fun) do
    with %BookingLink{} = link <- selected_link(socket),
         {day, ""} when day in 1..7 <- Integer.parse(day) do
      windows =
        for {weekday, _, _} <- @weekdays,
            {first, last} <-
              if(weekday == day,
                do: fun.(day_windows(link, weekday)),
                else: day_windows(link, weekday)
              ),
            do: window(weekday, first, last)

      save(socket, %{"windows" => windows})
    else
      _ -> {:noreply, socket}
    end
  end

  defp save(socket, attrs, flash \\ nil) do
    with %BookingLink{id: id} <- selected_link(socket),
         {:ok, _} <- BookingLinks.update(socket.assigns.access_scope, id, attrs) do
      socket = socket |> reload() |> load_preview()
      {:noreply, if(flash, do: put_flash(socket, :info, flash), else: socket)}
    else
      {:error, %Ecto.Changeset{errors: errors}} ->
        message =
          if Keyword.has_key?(errors, :windows),
            do: "A link needs at least one availability window.",
            else:
              Enum.map_join(errors, "; ", fn {field, {msg, _}} -> "#{humanize(field)} #{msg}" end)

        {:noreply, socket |> reload() |> put_flash(:error, message)}

      _ ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:error, "Could not save this link. Check Meetings is on for its project.")}
    end
  end

  defp seg_label("duration_minutes"), do: "Length"
  defp seg_label("buffer_before_minutes"), do: "Buffer before"
  defp seg_label("buffer_after_minutes"), do: "Buffer after"
  defp seg_label("minimum_notice_minutes"), do: "Minimum notice"

  defp humanize(field),
    do: field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp reload(socket) do
    scope = socket.assigns.access_scope
    links = scope |> BookingLinks.list() |> Enum.filter(&is_nil(&1.revoked_at)) |> Enum.reverse()
    receipts = BookingLinks.receipts(scope)

    slugs =
      for receipt <- receipts,
          receipt.meeting_id,
          {:ok, meeting} <- [
            Platform.Meetings.get_meeting_for_user(
              socket.assigns.current_user_record,
              receipt.meeting_id
            )
          ],
          into: %{},
          do: {receipt.meeting_id, meeting.slug}

    assign(socket,
      links: links,
      receipts: receipts,
      meeting_slugs: slugs,
      booking_link_count: length(links),
      calendars: Cal.calendar_rows(socket.assigns, Platform.Calendar.Subscriptions.list(scope))
    )
  end

  defp load_preview(socket) do
    preview =
      case selected_link(socket) do
        %BookingLink{} = link ->
          from = DateTime.utc_now() |> DateTime.shift_zone!(link.time_zone) |> DateTime.to_date()

          case BookingLinks.preview(socket.assigns.access_scope, link.id, from, 14) do
            {:ok, slots} ->
              slots
              |> Enum.map(&DateTime.shift_zone!(&1.starts_at, link.time_zone))
              |> Enum.chunk_by(&DateTime.to_date/1)
              |> Enum.take(3)
              |> Enum.map(
                &{DateTime.to_date(hd(&1)),
                 Enum.map(&1, fn at -> Calendar.strftime(at, "%H:%M") end)}
              )

            _ ->
              :unknown
          end

        _ ->
          []
      end

    assign(socket, :preview, preview)
  end

  defp current(socket), do: Enum.find(socket.assigns.links, &(&1.id == socket.assigns.selected))
  defp selected_link(socket), do: current(socket)

  defp window(day, first, last), do: %{"weekday" => day, "start" => first, "end" => last}

  defp minutes(<<h::binary-size(2), ":", m::binary-size(2)>>),
    do: String.to_integer(h) * 60 + String.to_integer(m)

  defp minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  @doc false
  def day_windows(%BookingLink{windows: windows}, weekday) do
    windows
    |> Enum.filter(&(&1["weekday"] == weekday))
    |> Enum.sort_by(& &1["start"])
    |> Enum.map(&{&1["start"], &1["end"]})
  end

  @doc "`30 min · 5 days a week · with Burrow meeting` (app.js link card)."
  def summary(%BookingLink{} = link, meetings_on) do
    days = link.windows |> Enum.map(& &1["weekday"]) |> Enum.uniq() |> length()

    "#{link.duration_minutes} min · #{days} #{if days == 1, do: "day", else: "days"} a week" <>
      if(meetings_on and link.create_meeting, do: " · with Burrow meeting", else: "")
  end

  # 06:00–22:00 in 30-minute steps (app.js `timeOpts`), plus the current
  # value when a PR #51 window sits off that grid.
  defp time_options(selected) do
    grid = for m <- Enum.take_every((6 * 60)..(22 * 60), 30), do: Cal.hm(m)
    if selected in grid, do: grid, else: Enum.sort([selected | grid])
  end

  defp public_url(link), do: PlatformWeb.Endpoint.url() <> "/book/" <> link.token

  defp short_url(link),
    do: String.replace(public_url(link), ~r{^https?://}, "")

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        link: Enum.find(assigns.links, &(&1.id == assigns.selected)),
        lengths: @lengths,
        buffers: @buffers,
        notices: @notices,
        weekdays: @weekdays
      )

    ~H"""
    <div class="flex h-full min-h-0 bg-base-200 text-base-content" data-page="calendar-booking">
      <.list_pane
        mini_month={@mini_month}
        cursor={@today}
        today={@today}
        view="week"
        section={:booking}
        booking_link_count={@booking_link_count}
        calendars={@calendars}
        calendars_shown={@calendars_shown}
      />
      <section class="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-base-200">
        <div class="cal-mainhead">
          <h1>Booking links</h1>
        </div>
        <.section_tabs section={:booking} />
        <div class="clears-tab-bar min-h-0 flex-1 overflow-y-auto">
          <div class="cal-page cal-page-wide" data-role="booking-links">
            <h2>Booking links</h2>
            <div class="cal-sub">People outside Burrow pick a time; it lands on your calendar.</div>
            <div class="cal-links">
              <div class="flex flex-col gap-2">
                <button
                  :for={link <- @links}
                  type="button"
                  class="cal-linkcard"
                  phx-click="select_link"
                  phx-value-id={link.id}
                  aria-current={to_string(link.id == @selected)}
                  data-link={link.id}
                >
                  <b>{link.title}</b>
                  <small>{summary(link, @meetings_on)}</small>
                  <small class="font-mono">/book/{link.token}</small>
                </button>
                <button type="button" class={[ghost_btn(), "self-start"]} phx-click="new_link">
                  <.icon name="hero-plus" class="size-[18px]" />New link
                </button>
              </div>
              <div :if={@link} class="cal-panel flex flex-col gap-3" data-role="booking-editor">
                <div class="cal-formgrid2">
                  <form phx-change="rename" phx-submit="rename" class="cal-field">
                    <label for="booking-link-title">Name</label>
                    <input
                      id="booking-link-title"
                      name="title"
                      value={@link.title}
                      maxlength="120"
                      class="cal-input"
                      phx-debounce="blur"
                    />
                  </form>
                  <div class="cal-field">
                    Public link
                    <div class="cal-feed">
                      <code>{short_url(@link)}</code>
                      <button
                        id={"booking-copy-#{@link.id}"}
                        type="button"
                        class={ghost_btn()}
                        phx-hook="CopyToClipboard"
                        data-clipboard-text={public_url(@link)}
                        phx-click="copied"
                      >
                        <.icon name="hero-document-duplicate" class="size-3.5" />Copy
                      </button>
                    </div>
                  </div>
                </div>
                <a
                  href={~p"/book/#{@link.token}"}
                  target="_blank"
                  rel="noopener"
                  class={[primary_btn(), "self-start"]}
                >
                  Open public booking page<.icon
                    name="hero-arrow-top-right-on-square"
                    class="size-3.5"
                  />
                </a>
                <div class="cal-field">
                  Length
                  <div class="cal-segs">
                    <button
                      :for={m <- @lengths}
                      type="button"
                      class="cal-seg"
                      phx-click="set"
                      phx-value-field="duration_minutes"
                      phx-value-minutes={m}
                      aria-pressed={to_string(@link.duration_minutes == m)}
                    >
                      {m} min
                    </button>
                  </div>
                </div>
                <div class="cal-field">
                  Availability windows
                  <span class="cal-hint">
                    When people can book. Your events, meetings and external calendars still block time inside these.
                  </span>
                  <div>
                    <div :for={{day, short, long} <- @weekdays} class="cal-winrow" data-day={day}>
                      <span class="font-semibold text-base-content">{short}</span>
                      <button
                        type="button"
                        class="cal-switch"
                        role="switch"
                        aria-checked={to_string(day_windows(@link, day) != [])}
                        aria-label={"#{long} available"}
                        phx-click="wday"
                        phx-value-day={day}
                      >
                      </button>
                      <div class="cal-wins">
                        <%= if day_windows(@link, day) == [] do %>
                          <span class="cal-hint">Unavailable</span>
                        <% else %>
                          <form
                            :for={{{first, last}, index} <- Enum.with_index(day_windows(@link, day))}
                            class="cal-win"
                            phx-change="wr"
                            id={"booking-win-#{day}-#{index}"}
                          >
                            <input type="hidden" name="day" value={day} />
                            <input type="hidden" name="index" value={index} />
                            <select name="start" aria-label={"#{short} window #{index + 1} start"}>
                              <option
                                :for={t <- time_options(first)}
                                value={t}
                                selected={t == first}
                              >
                                {t}
                              </option>
                            </select>–<select
                              name="end"
                              aria-label={"#{short} window #{index + 1} end"}
                            ><option
                                :for={t <- time_options(last)}
                                value={t}
                                selected={t == last}
                              >{t}</option></select>
                            <button
                              type="button"
                              aria-label="Remove window"
                              phx-click="wdel"
                              phx-value-day={day}
                              phx-value-index={index}
                            >
                              <.icon name="hero-x-mark" class="size-3" />
                            </button>
                          </form>
                          <button
                            type="button"
                            class={[ghost_btn(), "!h-[30px]"]}
                            phx-click="wadd"
                            phx-value-day={day}
                          >
                            <.icon name="hero-plus" class="size-3.5" />Window
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
                <div class="cal-formgrid2">
                  <div
                    :for={
                      {field, label} <- [
                        {"buffer_before_minutes", "Buffer before"},
                        {"buffer_after_minutes", "Buffer after"}
                      ]
                    }
                    class="cal-field"
                  >
                    {label}
                    <div class="cal-segs">
                      <button
                        :for={m <- @buffers}
                        type="button"
                        class="cal-seg"
                        phx-click="set"
                        phx-value-field={field}
                        phx-value-minutes={m}
                        aria-pressed={to_string(Map.get(@link, String.to_existing_atom(field)) == m)}
                      >
                        {if m == 0, do: "None", else: "#{m} min"}
                      </button>
                    </div>
                  </div>
                </div>
                <div class="cal-field">
                  Minimum notice
                  <div class="cal-segs">
                    <button
                      :for={{m, label} <- @notices}
                      type="button"
                      class="cal-seg"
                      phx-click="set"
                      phx-value-field="minimum_notice_minutes"
                      phx-value-minutes={m}
                      aria-pressed={to_string(@link.minimum_notice_minutes == m)}
                    >
                      {label}
                    </button>
                  </div>
                </div>
                <div :if={@meetings_on} class="cal-meetopt" data-role="booking-meeting-option">
                  <div class="flex items-center gap-3">
                    <span class="min-w-0 flex-1">
                      <b>Also create a Burrow meeting</b>
                      <span class="cal-hint block !text-xs">
                        Each booking gets its own meeting room. The guest is emailed an invite, so the booking page asks for an email.
                      </span>
                    </span>
                    <button
                      type="button"
                      class="cal-switch"
                      role="switch"
                      aria-checked={to_string(@link.create_meeting)}
                      aria-label="Also create a Burrow meeting"
                      phx-click="meet"
                    >
                    </button>
                  </div>
                  <form :if={@link.create_meeting} phx-change="project" class="cal-field mt-3">
                    <label for="booking-link-project">Meeting project</label>
                    <select id="booking-link-project" name="project_id" class="cal-input">
                      <option value="">Choose a project</option>
                      <option
                        :for={project <- @projects}
                        value={project.id}
                        selected={project.id == @link.project_id}
                      >
                        {project.name}
                      </option>
                    </select>
                  </form>
                </div>
                <form phx-change="dates" class="cal-formgrid2" id="booking-link-dates">
                  <label class="cal-field">
                    Bookable from<input
                      type="date"
                      name="start_date"
                      value={@link.start_date}
                      class="cal-input"
                    />
                  </label>
                  <label class="cal-field">
                    Until<input type="date" name="end_date" value={@link.end_date} class="cal-input" />
                  </label>
                </form>
                <div class="cal-field" data-role="booking-preview">
                  Next open slots (what a guest sees)
                  <%= case @preview do %>
                    <% :unknown -> %>
                      <span class="cal-hint">
                        Availability can’t be confirmed until every external calendar has refreshed.
                      </span>
                    <% [] -> %>
                      <span class="cal-hint">
                        No open slots in the next two weeks. Widen a window.
                      </span>
                    <% rows -> %>
                      <div :for={{date, times} <- rows} class="mt-1 flex items-center gap-2.5">
                        <span class="w-[84px] shrink-0 text-base-content">{Cal.day_label(date)}</span>
                        <div class="cal-slots">
                          <span :for={t <- Enum.take(times, 6)}>{t}</span>
                          <span :if={length(times) > 6} class="!border-0 text-subtle">
                            +{length(times) - 6}
                          </span>
                        </div>
                      </div>
                  <% end %>
                </div>
                <div>
                  <button
                    type="button"
                    class={[ghost_btn(), "cal-danger-btn"]}
                    phx-click="revoke"
                    data-confirm="Revoke this booking link? Its URL stops working."
                  >
                    Revoke link
                  </button>
                </div>
              </div>
            </div>
            <section
              :if={@receipts != []}
              class="cal-panel flex flex-col gap-2"
              aria-label="Booking receipts"
            >
              <h3>Recent bookings</h3>
              <div :for={receipt <- @receipts} class="cal-setrow">
                <span class="min-w-0 flex-1">
                  {receipt.name}
                  <small>{Calendar.strftime(receipt.starts_at, "%b %d, %Y %H:%M UTC")}</small>
                  <small :if={receipt.delivery_error} role="alert" class="!text-error">
                    Guest email delivery failed. Contact the guest to confirm their booking.
                  </small>
                </span>
                <.link
                  :if={@meeting_slugs[receipt.meeting_id]}
                  navigate={~p"/meetings/#{@meeting_slugs[receipt.meeting_id]}"}
                  class={ghost_btn()}
                >
                  Open meeting
                </.link>
              </div>
            </section>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
