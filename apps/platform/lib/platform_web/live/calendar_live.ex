defmodule PlatformWeb.CalendarLive do
  use PlatformWeb, :live_view
  import PlatformWeb.Components.Sheet

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

    {:ok,
     socket
     |> assign(:page_title, "Calendar")
     |> assign(:zone, zone)
     |> assign(:anchor, DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date())
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
    view = if params["view"] in ~w(week month agenda), do: params["view"], else: "week"
    {:noreply, socket |> assign(:view, view) |> reload()}
  end

  @impl true
  def handle_event("navigate_date", %{"direction" => direction}, socket) do
    sign = if direction == "previous", do: -1, else: 1

    anchor =
      if socket.assigns.view == "month",
        do: shift_month(socket.assigns.anchor, sign),
        else: Date.add(socket.assigns.anchor, sign * 7)

    {:noreply, socket |> assign(:anchor, anchor) |> reload()}
  end

  def handle_event("today", _, socket) do
    today = DateTime.utc_now() |> DateTime.shift_zone!(socket.assigns.zone) |> DateTime.to_date()
    {:noreply, socket |> assign(:anchor, today) |> reload()}
  end

  def handle_event("new", _, socket), do: {:noreply, assign(socket, :sheet, :choose)}

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

  defp reload(socket) do
    anchor = socket.assigns.anchor
    first = if socket.assigns.view == "month", do: Date.beginning_of_month(anchor), else: anchor
    {from, _} = CalendarWindow.week_bounds(first, socket.assigns.zone)
    days = if socket.assigns.view == "month", do: 42, else: 7
    first_date = Date.beginning_of_week(first)
    last = Date.add(first_date, days)
    {to, _} = CalendarWindow.day_bounds(last, socket.assigns.zone)
    entries = Events.list_entries(socket.assigns.access_scope, from, to)
    now = DateTime.utc_now()
    next = Enum.find(entries, &(DateTime.compare(&1.ends_at || &1.starts_at, now) == :gt))
    spaces = Platform.Chat.list_spaces(scope: socket.assigns.access_scope)
    projects = Platform.Tasks.list_projects_for_user(socket.assigns.current_user_record)

    assign(socket,
      entries: entries,
      days: Enum.map(0..(days - 1), &Date.add(first_date, &1)),
      up_next: next,
      spaces: spaces,
      projects: projects
    )
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

  def date_label(date), do: Calendar.strftime(date, "%A %-d %B")
  def time_label(at, zone), do: at |> DateTime.shift_zone!(zone) |> Calendar.strftime("%H:%M")

  def entries_on(entries, date, zone),
    do:
      Enum.filter(entries, fn entry ->
        {from, to} = CalendarWindow.day_bounds(date, zone)

        DateTime.compare(entry.starts_at, to) == :lt and
          DateTime.compare(entry.ends_at || entry.starts_at, from) == :gt
      end)

  def joinable?(%{kind: :meeting, meeting: meeting, starts_at: at}),
    do:
      meeting.status == "live" or
        (meeting.status == "scheduled" and
           abs(DateTime.diff(at, DateTime.utc_now(), :second)) <= 600)

  def joinable?(_), do: false
  def cancelled?(%{kind: :meeting, meeting: %{status: "cancelled"}}), do: true
  def cancelled?(_), do: false
  def scope_label(%{kind: :meeting}, _, _), do: "Meeting"

  def scope_label(%{event: %{space_id: id}}, spaces, _) when not is_nil(id),
    do: "#" <> (Enum.find(spaces, &(&1.id == id)) || %{name: "Space"}).name

  def scope_label(%{event: %{project_id: id}}, _, projects) when not is_nil(id),
    do: (Enum.find(projects, &(&1.id == id)) || %{name: "Project"}).name

  def scope_label(_, _, _), do: "Only you"

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

  def scope_style(entry) do
    id =
      case entry do
        %{event: event} -> event.space_id || event.project_id || event.owner_id
        %{meeting: meeting} -> meeting.project_id || meeting.id
      end

    slot =
      Enum.at(~w(teal green amber orange blue purple pink red cyan lime), :erlang.phash2(id, 10))

    "border-left-color: var(--ag-#{slot});"
  end

  def countdown(at) do
    minutes = div(DateTime.diff(at, DateTime.utc_now()), 60)

    cond do
      minutes <= 0 -> "Now"
      minutes < 60 -> "in #{minutes} min"
      minutes < 1440 -> "in #{div(minutes, 60)} hr"
      true -> "in #{div(minutes, 1440)} days"
    end
  end

  def day_blocks(entries, date, zone) do
    {from, to} = CalendarWindow.day_bounds(date, zone)

    entries_on(entries, date, zone)
    |> Enum.reject(& &1.all_day)
    |> Enum.flat_map(fn entry ->
      first = if DateTime.compare(entry.starts_at, from) == :lt, do: from, else: entry.starts_at
      last = entry.ends_at || DateTime.add(first, 1800)
      last = if DateTime.compare(last, to) == :gt, do: to, else: last

      projection = %Platform.Meetings.Meeting{
        status: "scheduled",
        scheduled_start_at: first,
        scheduled_end_at: last
      }

      case CalendarWindow.place(projection, date, zone, {0, 24}) do
        {:ok, placement} -> [{entry, placement}]
        _ -> []
      end
    end)
    |> CalendarWindow.assign_lanes()
  end

  def block_style(pos),
    do:
      "top: #{pos.top}%; height: #{min(pos.height, 100 - pos.top)}%; left: #{pos.left}%; width: #{pos.width}%;"

  def now_style(date, zone) do
    now = DateTime.shift_zone!(DateTime.utc_now(), zone)

    if DateTime.to_date(now) == date,
      do: "top: #{(now.hour * 60 + now.minute) / 1440 * 100}%;",
      else: nil
  end

  defp shift_month(date, sign) do
    base = Date.beginning_of_month(date)

    if sign == 1,
      do: Date.add(base, Date.days_in_month(base)),
      else: Date.add(base, -1) |> Date.beginning_of_month()
  end
end
