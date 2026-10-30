defmodule PlatformWeb.CalendarLive do
  use PlatformWeb, :live_view
  import Ecto.Query, only: [from: 2]
  import PlatformWeb.Components.Sheet
  import PlatformWeb.CalendarLive.Components

  alias Platform.Calendar, as: Events
  alias Platform.Calendar.Event
  alias PlatformWeb.MeetingLive.CalendarWindow

  @impl true
  def mount(_params, _session, socket) do
    zone = CalendarWindow.resolve_time_zone(get_connect_params(socket)["timezone"]) || "Etc/UTC"

    if connected?(socket) do
      Events.subscribe(socket.assigns.access_scope)

      Platform.Tasks.list_projects_for_user(socket.assigns.current_user_record)
      |> Enum.each(&Platform.Meetings.subscribe_to_project_meetings(&1.id))

      Process.send_after(self(), :calendar_tick, 60_000)
    end

    today = today(zone)

    {:ok,
     socket
     |> assign(:page_title, "Calendar")
     |> assign(:zone, zone)
     |> assign(:today, today)
     |> assign(:cursor, today)
     |> assign(:sel_day, today)
     |> assign(:mini_month, Date.beginning_of_month(today))
     |> assign(:calendars_shown, %{})
     |> assign(
       :meetings_on,
       Platform.Access.module_access?(socket.assigns.access_scope, :meetings)
     )
     |> assign(:view, "week")
     |> assign(:sheet, nil)
     |> assign(:selected, nil)
     |> assign(:feed_url, nil)
     |> assign(:confirm_rotate, false)
     |> assign(:error, nil)
     |> assign(:form, to_form(%{}, as: :event))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    view = if params["view"] in ~w(week month), do: params["view"], else: "week"

    socket =
      case Date.from_iso8601(params["date"] || "") do
        {:ok, date} -> put_day(socket, date)
        _ -> socket
      end

    # Week and Month share one cursor: Month starts at the selected day's
    # month, Week returns to the selected day (prototype v4 app.js `ds.cv`).
    socket =
      cond do
        view == socket.assigns.view -> socket
        view == "month" -> put_cursor(socket, Date.beginning_of_month(socket.assigns.sel_day))
        true -> put_cursor(socket, socket.assigns.sel_day)
      end

    {:noreply, socket |> assign(:view, view) |> reload()}
  end

  @impl true
  def handle_event("navigate_date", %{"direction" => direction} = params, socket) do
    sign = if direction == "previous", do: -1, else: 1
    %{view: view, cursor: cursor, sel_day: sel_day} = socket.assigns

    socket =
      cond do
        view == "month" ->
          put_cursor(socket, shift_month(cursor, sign))

        # The phone steps one day; the desktop steps a week and selects its
        # Monday (prototype v4 app.js `navStep`).
        params["step"] == "day" ->
          day = Date.add(sel_day, sign)
          socket |> assign(:sel_day, day) |> put_cursor(day)

        true ->
          next = Date.add(cursor, sign * 7)
          socket |> put_cursor(next) |> assign(:sel_day, Date.beginning_of_week(next))
      end

    {:noreply, reload(socket)}
  end

  def handle_event("today", _, socket) do
    today = today(socket.assigns.zone)
    {:noreply, socket |> assign(:today, today) |> put_day(today) |> reload()}
  end

  # A phone day-strip tap: the single-day column follows, the week stays.
  def handle_event("select_day", %{"date" => value}, socket) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:noreply, socket |> put_day(date) |> reload()}
      _ -> {:noreply, socket}
    end
  end

  # A mini-month day or a month cell: open that day's week.
  def handle_event("goday", %{"date" => value}, socket) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        socket = put_day(socket, date)

        if socket.assigns.view == "month",
          do: {:noreply, push_patch(socket, to: ~p"/calendar?#{%{view: "week"}}")},
          else: {:noreply, reload(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("mini_month", %{"direction" => direction}, socket) do
    sign = if direction == "previous", do: -1, else: 1
    {:noreply, assign(socket, :mini_month, shift_month(socket.assigns.mini_month, sign))}
  end

  def handle_event("toggle_calendar", %{"key" => key}, socket) do
    shown = socket.assigns.calendars_shown

    {:noreply,
     socket |> assign(:calendars_shown, Map.put(shown, key, not shown?(shown, key))) |> reload()}
  end

  def handle_event("new_at", %{"date" => date, "minute" => minute}, socket) do
    with {:ok, date} <- Date.from_iso8601(date),
         {minute, ""} when minute in 0..1439 <- Integer.parse(minute) do
      {:noreply, new_event_at(socket, date, minute)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("agent_access", _, socket) do
    scope =
      Platform.Access.Scope.for_user(
        Platform.Accounts.get_user(socket.assigns.current_user_record.id)
      )

    choices = Platform.Calendar.AgentAccess.agents(scope)
    grants = Platform.Calendar.AgentAccess.list(scope)

    agent_id =
      case choices do
        [agent | _] -> agent.id
        _ -> nil
      end

    {:noreply,
     assign(socket,
       sheet: :agent_access,
       agent_choices: choices,
       calendar_grants: grants,
       grant_form: agent_grant_form(Enum.find(grants, &(&1.agent_id == agent_id)), agent_id),
       error: nil
     )}
  end

  def handle_event("choose_grant_agent", %{"grant" => %{"agent_id" => id}}, socket) do
    grants = Map.get(socket.assigns, :calendar_grants, [])

    {:noreply,
     assign(socket, :grant_form, agent_grant_form(Enum.find(grants, &(&1.agent_id == id)), id))}
  end

  def handle_event("grant_agent", %{"grant" => attrs}, socket) do
    scope =
      Platform.Access.Scope.for_user(
        Platform.Accounts.get_user(socket.assigns.current_user_record.id)
      )

    case Platform.Calendar.AgentAccess.grant(scope, attrs["agent_id"], attrs) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(
           calendar_grants: Platform.Calendar.AgentAccess.list(scope),
           grant_form: agent_grant_form(grant, grant.agent_id),
           error: nil
         )}

      _ ->
        {:noreply, assign(socket, :error, "Couldn't save agent access.")}
    end
  end

  def handle_event("revoke_agent", %{"id" => id}, socket) do
    scope =
      Platform.Access.Scope.for_user(
        Platform.Accounts.get_user(socket.assigns.current_user_record.id)
      )

    case Platform.Calendar.AgentAccess.revoke(scope, id) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(
           calendar_grants: Platform.Calendar.AgentAccess.list(scope),
           grant_form: agent_grant_form(grant, id),
           error: nil
         )
         |> reload()}

      _ ->
        {:noreply, assign(socket, :error, "Couldn't revoke agent access.")}
    end
  end

  # "+ New" / "+ New event": the editor preset to 14:00 (prototype v4
  # app.js `ds.newEv`), on the phone's selected day when one is passed.
  def handle_event("new", params, socket) do
    day =
      case Date.from_iso8601(params["date"] || "") do
        {:ok, date} -> date
        _ -> socket.assigns.today
      end

    {:noreply, new_event_at(socket, day, 14 * 60)}
  end

  def handle_event("new_event", _, socket) do
    {:noreply, event_form(socket, %Event{time_zone: socket.assigns.zone})}
  end

  def handle_event("close_sheet", _, socket),
    do: {:noreply, assign(socket, sheet: nil, selected: nil, error: nil)}

  def handle_event("select", %{"id" => id, "kind" => "event"}, socket) do
    case Events.get_event(socket.assigns.access_scope, id) do
      {:ok, event} -> {:noreply, assign(socket, selected: event, sheet: :detail)}
      _ -> {:noreply, put_flash(socket, :error, "Event is no longer available.")}
    end
  end

  def handle_event("select", %{"id" => id, "kind" => "meeting"}, socket) do
    entry = Enum.find(socket.assigns.entries, &(&1.kind == :meeting and &1.id == id))
    {:noreply, assign(socket, selected: entry, sheet: if(entry, do: :meeting, else: nil))}
  end

  def handle_event("select", %{"id" => id, "kind" => "external"}, socket) do
    entry = Enum.find(socket.assigns.entries, &(&1.kind == :external and &1.id == id))
    {:noreply, assign(socket, selected: entry, sheet: if(entry, do: :external, else: nil))}
  end

  def handle_event("add_external", %{"subscription" => attrs}, socket) do
    case Platform.Calendar.Subscriptions.create(socket.assigns.access_scope, attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Calendar added. Refresh runs shortly.") |> reload()}

      _ ->
        {:noreply, assign(socket, :error, "Enter a name and a valid HTTPS calendar URL.")}
    end
  end

  def handle_event("refresh_external", %{"id" => id}, socket) do
    scope = socket.assigns.access_scope
    # A supervised task keeps the sheet responsive; the context rechecks ownership.
    start_async(socket, {:external_refresh, id}, fn ->
      Platform.Calendar.Subscriptions.refresh(scope, id)
    end)
    |> then(&{:noreply, &1})
  end

  def handle_event("remove_external", %{"id" => id}, socket) do
    case Platform.Calendar.Subscriptions.delete(socket.assigns.access_scope, id) do
      {:ok, _} -> {:noreply, reload(socket)}
      _ -> {:noreply, assign(socket, :error, "Calendar is no longer available.")}
    end
  end

  def handle_event("edit", _, %{assigns: %{selected: %Event{} = event}} = socket) do
    {:noreply, event_form(socket, event)}
  end

  def handle_event("event_change", %{"event" => params}, socket),
    do:
      {:noreply,
       assign(socket, :form, to_form(Map.merge(socket.assigns.form.params, params), as: :event))}

  def handle_event("save", %{"event" => params}, socket) do
    params = Map.merge(socket.assigns.form.params, params)
    attrs = parse_event(params)

    result =
      if socket.assigns.selected && socket.assigns.selected.id do
        Events.update_event(socket.assigns.access_scope, socket.assigns.selected.id, attrs)
      else
        Events.create_event(socket.assigns.access_scope, attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> assign(sheet: nil, selected: nil, error: nil) |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)

        message =
          Enum.map_join(errors, ". ", fn {field, messages} ->
            "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
          end)

        {:noreply, assign(socket, form: to_form(params, as: :event), error: message)}

      _ ->
        {:noreply, assign(socket, :error, "You cannot save this event.")}
    end
  end

  def handle_event("delete", _, %{assigns: %{selected: %Event{}}} = socket) do
    case Events.delete_event(socket.assigns.access_scope, socket.assigns.selected.id) do
      {:ok, _} -> {:noreply, socket |> assign(sheet: nil, selected: nil) |> reload()}
      _ -> {:noreply, assign(socket, :error, "You cannot delete this event.")}
    end
  end

  def handle_event("delete", _, socket),
    do: {:noreply, put_flash(socket, :error, "Select an event first.")}

  def handle_event("subscribe", _, socket), do: {:noreply, assign(socket, :sheet, :subscribe)}

  def handle_event("confirm_rotate", _, socket),
    do: {:noreply, assign(socket, :confirm_rotate, true)}

  def handle_event("rotate_feed", _, socket) do
    case Events.rotate_feed(socket.assigns.access_scope) do
      {:ok, token} ->
        url = PlatformWeb.Endpoint.url() <> "/calendar/feed/" <> token
        {:noreply, assign(socket, feed_url: url, confirm_rotate: false)}

      _ ->
        {:noreply, assign(socket, :error, "Could not create a subscription link.")}
    end
  end

  def handle_event("revoke_feed", _, socket) do
    :ok = Events.revoke_feed(socket.assigns.access_scope)
    {:noreply, assign(socket, feed_url: nil, confirm_rotate: false)}
  end

  @impl true
  def handle_info(:calendar_tick, socket) do
    Process.send_after(self(), :calendar_tick, 60_000)
    {:noreply, reload(socket)}
  end

  def handle_info(_, socket), do: {:noreply, reload(socket)}

  @impl true
  def handle_async({:external_refresh, _id}, _result, socket), do: {:noreply, reload(socket)}

  # The grid's visible window: the cursor's week, or the month grid around
  # the cursor (whole weeks, Monday first). Entries are loaded once for it.
  defp reload(socket) do
    %{access_scope: scope, zone: zone, view: view, cursor: cursor} = socket.assigns

    subscriptions = Platform.Calendar.Subscriptions.list(scope)

    {first, last} =
      if view == "month" do
        days = month_days(cursor)
        {List.first(days), List.last(days)}
      else
        monday = Date.beginning_of_week(cursor)
        {monday, Date.add(monday, 6)}
      end

    {from, _} = CalendarWindow.day_bounds(first, zone)
    {_, to} = CalendarWindow.day_bounds(last, zone)
    entries = Events.list_entries(scope, from, to, time_zone: zone)
    agents = hold_agents(entries, socket.assigns.current_user_record)

    visible =
      entries
      |> Enum.filter(&shown?(socket.assigns.calendars_shown, calendar_key(&1)))
      |> Enum.reject(&(&1.kind == :meeting and not socket.assigns.meetings_on))
      |> Enum.map(&Map.put(&1, :agent, Map.get(agents, &1.id)))

    assign(socket,
      today: today(zone),
      external_subscriptions: subscriptions,
      booking_link_count: length(Platform.Calendar.BookingLinks.list(scope)),
      entries: entries,
      visible_entries: visible,
      calendars: calendars(socket.assigns, subscriptions),
      spaces: Platform.Calendar.list_spaces(scope),
      projects: Platform.Tasks.list_projects_for_user(socket.assigns.current_user_record)
    )
  end

  defp put_cursor(socket, date),
    do: assign(socket, cursor: date, mini_month: Date.beginning_of_month(date))

  defp put_day(socket, date), do: socket |> assign(:sel_day, date) |> put_cursor(date)

  defp today(zone), do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp new_event_at(socket, date, minute) do
    zone = socket.assigns.zone

    start =
      case DateTime.new(date, Time.new!(div(minute, 60), rem(minute, 60), 0), zone) do
        {:ok, at} -> at
        # A slot inside a DST change takes the instant either side of it.
        {:ambiguous, first, _} -> first
        {:gap, _, after_gap} -> after_gap
      end

    event_form(socket, %Event{
      time_zone: zone,
      starts_at: start,
      ends_at: DateTime.add(start, 3600)
    })
  end

  # The agent behind each pending hold, for the tentative chip's
  # "Tentative · <Agent> · needs OK" line. Read-only; PR #51's consent rows
  # are the record of who proposed the hold.
  defp hold_agents(entries, %{id: owner_id}) do
    ids = for %{kind: :event, event: %{tentative: true, id: id}} <- entries, do: id

    if ids == [] do
      %{}
    else
      Platform.Repo.all(
        from(c in Platform.Calendar.Consent,
          join: a in Platform.Agents.Agent,
          on: a.id == c.agent_id,
          where: c.hold_id in ^ids and c.owner_id == ^owner_id,
          select: {c.hold_id, a.name}
        )
      )
      |> Map.new()
    end
  end

  defp hold_agents(_, _), do: %{}

  defp calendars(assigns, subscriptions) do
    native = %{
      key: "native",
      label: (assigns.current_user_record && assigns.current_user_record.name) || "You",
      note: "your Burrow calendar",
      kind: "native"
    }

    meetings = %{
      key: "meetings",
      label: "Meetings",
      note: "Burrow meetings you are invited to",
      kind: "meeting"
    }

    external =
      Enum.map(
        subscriptions,
        &%{key: "ext:" <> &1.id, label: &1.name, note: "read-only · iCal", kind: "external"}
      )

    [native] ++ if(assigns.meetings_on, do: [meetings], else: []) ++ external
  end

  defp event_form(socket, event) do
    rule =
      case Platform.Calendar.Recurrence.parse(event.recurrence) do
        {:ok, %{} = rule} -> rule
        _ -> %{frequency: "WEEKLY", interval: 1, count: nil, until: nil}
      end

    attrs = %{
      "title" => event.title || "",
      "description" => event.description || "",
      "time_zone" => event.time_zone,
      "all_day" => event.all_day,
      "starts_at" => local_input(event.starts_at, event.time_zone),
      "ends_at" => local_input(event.ends_at, event.time_zone),
      "start_date" => event.start_date,
      "end_date" => if(event.end_date, do: Date.add(event.end_date, -1)),
      "visibility" => event.visibility || "details",
      "recurrence" => event.recurrence || "",
      "custom_frequency" => rule.frequency,
      "custom_interval" => rule.interval,
      "custom_count" => rule.count,
      "custom_until" => rule.until,
      "repeat" =>
        if(event.recurrence in [nil, "", "FREQ=DAILY", "FREQ=WEEKLY", "FREQ=MONTHLY"],
          do: event.recurrence || "",
          else: "custom"
        ),
      "where" =>
        cond do
          event.space_id -> "space:" <> event.space_id
          event.project_id -> "project:" <> event.project_id
          true -> "private"
        end
    }

    assign(socket, sheet: :edit, selected: event, form: to_form(attrs, as: :event), error: nil)
  end

  defp parse_event(params) do
    zone = params["time_zone"] || "Etc/UTC"
    attrs = Map.drop(params, ["where", "repeat"])

    attrs =
      Map.put(
        attrs,
        "recurrence",
        if(params["repeat"] == "custom", do: custom_rule(params), else: params["repeat"])
      )

    attrs =
      if params["all_day"] in [true, "true"] do
        case Date.from_iso8601(params["end_date"] || "") do
          {:ok, date} -> Map.put(attrs, "end_date", Date.add(date, 1))
          _ -> attrs
        end
      else
        attrs
      end

    attrs =
      Enum.reduce(~w(starts_at ends_at), attrs, fn key, acc ->
        Map.put(acc, key, parse_local(params[key], zone))
      end)

    attrs = Map.merge(attrs, %{"space_id" => nil, "project_id" => nil})

    case String.split(params["where"] || "private", ":", parts: 2) do
      ["space", id] -> Map.put(attrs, "space_id", id)
      ["project", id] -> Map.put(attrs, "project_id", id)
      _ -> attrs
    end
  end

  defp custom_rule(params) do
    base = "FREQ=#{params["custom_frequency"]};INTERVAL=#{params["custom_interval"]}"

    base =
      if params["custom_count"] not in [nil, ""],
        do: base <> ";COUNT=#{params["custom_count"]}",
        else: base

    if params["custom_until"] not in [nil, ""],
      do: base <> ";UNTIL=" <> String.replace(params["custom_until"], "-", ""),
      else: base
  end

  defp parse_local(value, zone) when is_binary(value) do
    with {:ok, naive} <-
           NaiveDateTime.from_iso8601(value <> if(byte_size(value) == 16, do: ":00", else: "")),
         {:ok, at} <- DateTime.from_naive(naive, zone) do
      DateTime.shift_zone!(at, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp parse_local(_, _), do: nil
  defp local_input(nil, _), do: ""

  defp local_input(at, zone),
    do: at |> DateTime.shift_zone!(zone) |> Calendar.strftime("%Y-%m-%dT%H:%M")

  def time_label(at, zone), do: at |> DateTime.shift_zone!(zone) |> Calendar.strftime("%H:%M")

  def where_options(spaces, projects),
    do:
      [{"Only you", "private"}] ++
        Enum.map(spaces, &{"#" <> &1.name, "space:" <> &1.id}) ++
        Enum.map(projects, &{&1.name, "project:" <> &1.id})

  def visibility_label(value, spaces, projects) do
    case List.keyfind(where_options(spaces, projects), value, 1) do
      {"Only you", _} -> "Visible only to you"
      {name, _} -> "Visible to members of #{name}"
      _ -> "Choose where this event belongs"
    end
  end

  # ── Calendar v4 data (prototype 01a178d2 v4, app.js) ──────────────────

  @first_hour 7
  @last_hour 21
  @hour_px 48

  @doc "The week grid's hour window, 07:00 to 21:00 (app.js `H0`/`H1`)."
  def hour_window, do: {@first_hour, @last_hour}
  def hour_px, do: @hour_px
  def grid_px, do: (@last_hour - @first_hour) * @hour_px

  @doc "Which calendar row an entry belongs to; the toggles key on this."
  def calendar_key(%{kind: :meeting}), do: "meetings"

  def calendar_key(%{kind: :external, id: id}),
    do: "ext:" <> (id |> String.split(":", parts: 2) |> hd())

  def calendar_key(_), do: "native"

  def shown?(shown, key), do: Map.get(shown, key, true)

  @doc "The chip kind: native, meeting, external or tentative."
  def chip_kind(%{kind: :event, event: %{tentative: true}}), do: "tentative"
  def chip_kind(%{kind: :event}), do: "native"
  def chip_kind(%{kind: :meeting}), do: "meeting"
  def chip_kind(%{kind: :external}), do: "external"

  def live?(%{kind: :meeting, meeting: %{status: "live"}}), do: true
  def live?(_), do: false

  @doc "The title a chip shows: the hold's own title, never the list prefix."
  def chip_title(%{kind: :event, event: %{title: title}}) when is_binary(title), do: title
  def chip_title(%{title: title}), do: title || ""

  @doc "`Mon 26 Oct`, the prototype's `dateLabel`."
  def day_label(date), do: Calendar.strftime(date, "%a %-d %b")

  def hm(minute), do: pad(div(minute, 60)) <> ":" <> pad(rem(minute, 60))
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  An entry's local minutes on `date`, clipped to that day: `{start, end}`
  with end up to 1440. A missing end reads as 30 minutes.
  """
  def day_minutes(entry, date, zone) do
    {from, to} = CalendarWindow.day_bounds(date, zone)
    ends_at = entry.ends_at || DateTime.add(entry.starts_at, 1800)

    first =
      if DateTime.compare(entry.starts_at, from) == :gt,
        do: local_minute(entry.starts_at, zone),
        else: 0

    last =
      if DateTime.compare(ends_at, to) == :lt,
        do: local_minute(ends_at, zone),
        else: 1440

    {first, max(last, first)}
  end

  defp local_minute(at, zone) do
    local = DateTime.shift_zone!(at, zone)
    local.hour * 60 + local.minute
  end

  @doc "Entries that overlap `date` in `zone`."
  def entries_on(entries, date, zone) do
    {from, to} = CalendarWindow.day_bounds(date, zone)

    Enum.filter(entries, fn entry ->
      DateTime.compare(entry.starts_at, to) == :lt and
        DateTime.compare(entry.ends_at || DateTime.add(entry.starts_at, 1800), from) == :gt
    end)
  end

  @doc """
  The timed chips of one day column, laid out like app.js `dayColumn`:
  px offsets from 07:00 at 48px an hour, at least 22px tall, compact
  (title only) under 34px, and overlap lanes side by side. Every chip in a
  day shares the day's lane count, as `lanes()` does.
  """
  def day_chips(entries, date, zone) do
    window_start = @first_hour * 60
    window_end = @last_hour * 60

    placed =
      entries_on(entries, date, zone)
      |> Enum.reject(& &1.all_day)
      |> Enum.map(fn entry ->
        {first, last} = day_minutes(entry, date, zone)
        %{entry: entry, date: date, s: first, e: last}
      end)
      |> Enum.sort_by(&{&1.s, -&1.e})

    {placed, columns} =
      Enum.map_reduce(placed, [], fn chip, columns ->
        case Enum.find_index(columns, &(&1 <= chip.s)) do
          nil -> {Map.put(chip, :lane, length(columns)), columns ++ [chip.e]}
          lane -> {Map.put(chip, :lane, lane), List.replace_at(columns, lane, chip.e)}
        end
      end)

    lanes = max(length(columns), 1)

    Enum.map(placed, fn chip ->
      top_min = chip.s |> max(window_start) |> min(window_end)
      top = min((top_min - window_start) / 60 * @hour_px, grid_px() - 22)
      height = max(22, (min(chip.e, window_end) - top_min) / 60 * @hour_px - 2)
      Map.merge(chip, %{lanes: lanes, top: top, height: height, compact: height < 34})
    end)
  end

  @doc "The now line's px offset in today's column, or nil outside 07–21."
  def now_top(zone) do
    minute = local_minute(DateTime.utc_now(), zone)

    if minute >= @first_hour * 60 and minute < @last_hour * 60,
      do: (minute - @first_hour * 60) / 60 * @hour_px,
      else: nil
  end

  @doc "The chip's aria-label (app.js `chipLabel`)."
  def chip_label(entry, date, first, last) do
    kind =
      case chip_kind(entry) do
        "meeting" -> "Meeting"
        "external" -> "External, read-only"
        "tentative" -> "Tentative hold by " <> (entry[:agent] || "an agent")
        _ -> "Event"
      end

    "#{kind}: #{chip_title(entry)}, #{day_label(date)} #{hm(first)} to #{hm(last)}"
  end

  @doc "The external calendar's label up to ` (`, as app.js `chipInner`."
  def external_label(%{subscription: name}) when is_binary(name),
    do: name |> String.split(" (", parts: 2) |> hd()

  def external_label(_), do: ""

  def busy?(%{kind: :event, event: %{visibility: "busy"}}), do: true
  def busy?(_), do: false

  def recurring?(%{kind: :event, event: %{recurrence: rule}}) when rule not in [nil, ""],
    do: true

  def recurring?(_), do: false

  @doc "The month grid's dates: whole weeks from the Monday on or before the 1st."
  def month_days(date) do
    first = Date.beginning_of_month(date)
    start = Date.beginning_of_week(first)
    last = Date.end_of_month(first)
    weeks = div(Date.diff(last, start), 7) + 1
    Enum.map(0..(weeks * 7 - 1), &Date.add(start, &1))
  end

  @doc "The mini month's 6 weeks (app.js `miniMonth`)."
  def mini_days(month) do
    start = month |> Date.beginning_of_month() |> Date.beginning_of_week()
    Enum.map(0..41, &Date.add(start, &1))
  end

  def week_days(date) do
    monday = Date.beginning_of_week(date)
    Enum.map(0..6, &Date.add(monday, &1))
  end

  @doc "`Oct 26 – Nov 1, 2026` (cross-month) or `Oct 5 – 11, 2026`."
  def range_label("month", cursor, _), do: Calendar.strftime(cursor, "%B %Y")

  def range_label(_, cursor, _) do
    monday = Date.beginning_of_week(cursor)
    sunday = Date.add(monday, 6)

    tail =
      if sunday.month != monday.month,
        do: Calendar.strftime(sunday, "%b %-d"),
        else: Integer.to_string(sunday.day)

    "#{Calendar.strftime(monday, "%b %-d")} – #{tail}, #{sunday.year}"
  end

  def phone_range_label("month", cursor, _), do: Calendar.strftime(cursor, "%B %Y")
  def phone_range_label(_, _, sel_day), do: Calendar.strftime(sel_day, "%B %Y")

  defp shift_month(date, sign) do
    base = Date.beginning_of_month(date)

    if sign == 1,
      do: Date.add(base, Date.days_in_month(base)),
      else: Date.add(base, -1) |> Date.beginning_of_month()
  end

  defp agent_grant_form(grant, agent_id) do
    fields =
      for field <- ~w(read read_private create move preapprove)a, into: %{} do
        {Atom.to_string(field),
         not is_nil(grant) and is_nil(grant.revoked_at) and Map.get(grant, field, false)}
      end

    to_form(Map.put(fields, "agent_id", agent_id), as: :grant)
  end
end
