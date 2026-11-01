defmodule PlatformWeb.MeetingLive.ListComponents do
  @moduledoc """
  The `/meetings` list view rebuilt to prototype `01a178d2` v4 (`app.js`
  `meetingsList` / `renderMeetings`; task 01a18d9f stage 4): a list pane of
  meeting cards in Live now / Upcoming / Past, a detail pane on desktop and
  a pushed detail on the phone (`?meeting=<id>`, so back works), and the
  `+ New meeting` modal.

  Rows read only what the Meetings and Chat contexts already store: the
  meeting's own chat space (its name, participants and host), its
  transcripts (summary and segments) and its ready recordings.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias PlatformWeb.CalendarLive.Components, as: Cal

  @sections [{:live, "Live now"}, {:upcoming, "Upcoming"}, {:ended, "Past"}]

  # ── data ───────────────────────────────────────────────────────────────

  @doc "Row data for every meeting in `grouped`, in v4 order, keyed by section."
  def rows(grouped, zone, now \\ DateTime.utc_now()) do
    grouped = lapsed_to_past(grouped, now)

    meetings = Enum.flat_map(@sections, fn {key, _} -> Map.get(grouped, key, []) end)
    space_ids = meetings |> Enum.map(& &1.chat_space_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    ids = Enum.map(meetings, & &1.id)

    spaces =
      if space_ids == [],
        do: %{},
        else:
          Repo.all(
            from(s in Platform.Chat.Space, where: s.id in ^space_ids, select: {s.id, s.name})
          )
          |> Map.new()

    people =
      if space_ids == [],
        do: %{},
        else:
          Repo.all(
            from(p in Platform.Chat.Participant,
              where: p.space_id in ^space_ids,
              order_by: [asc: p.joined_at],
              select: {p.space_id, p.id, p.display_name}
            )
          )
          |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    transcripts =
      if ids == [],
        do: %{},
        else:
          Repo.all(
            from(t in Platform.Meetings.Transcript,
              where: t.meeting_id in ^ids,
              order_by: [asc: t.inserted_at],
              select: {t.meeting_id, t.summary, t.segments}
            )
          )
          |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    recordings =
      if space_ids == [],
        do: %{},
        else:
          Repo.all(
            from(r in Platform.Meetings.Recording,
              where: r.space_id in ^space_ids and r.status == "ready",
              order_by: [desc: r.inserted_at],
              select: {r.space_id, r.file_url, r.duration_seconds}
            )
          )
          |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    Map.new(@sections, fn {key, _} ->
      list = Map.get(grouped, key, [])

      list =
        case key do
          :upcoming -> Enum.sort_by(list, &sort_at/1, DateTime)
          _ -> Enum.sort_by(list, &sort_at/1, {:desc, DateTime})
        end

      {key,
       Enum.map(list, fn meeting ->
         members = Map.get(people, meeting.chat_space_id, [])

         host =
           Enum.find_value(members, fn {id, name} -> id == meeting.host_participant_id && name end)

         rows = Map.get(transcripts, meeting.id, [])

         summary =
           rows |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in [nil, ""])) |> List.last()

         segments = Enum.flat_map(rows, &(elem(&1, 1) || []))

         %{
           meeting: meeting,
           section: key,
           space: (name = spaces[meeting.chat_space_id]) && "#" <> name,
           people: members |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1),
           host: host,
           when: when_label(meeting, zone),
           date: meeting.scheduled_start_at && local_date(meeting.scheduled_start_at, zone),
           summary: summary,
           segments: segments,
           recording: recordings |> Map.get(meeting.chat_space_id, []) |> List.first()
         }
       end)}
    end)
  end

  # v4 sections by time: a still-`scheduled` meeting whose window has
  # closed is Past, not Upcoming (`group_meetings_by_status/1` buckets by
  # status only, and a meeting nobody started keeps `scheduled`).
  defp lapsed_to_past(grouped, now) do
    {lapsed, upcoming} =
      grouped
      |> Map.get(:upcoming, [])
      |> Enum.split_with(fn m ->
        match?(%DateTime{}, m.scheduled_end_at) and
          DateTime.compare(m.scheduled_end_at, now) == :lt
      end)

    grouped
    |> Map.put(:upcoming, upcoming)
    |> Map.update(:ended, lapsed, &(&1 ++ lapsed))
  end

  defp sort_at(meeting),
    do: meeting.scheduled_start_at || meeting.started_at || meeting.inserted_at

  defp local_date(at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  # `Mon 26 Oct · 10:30–11:15`
  defp when_label(%{scheduled_start_at: %DateTime{} = first} = meeting, zone) do
    local = DateTime.shift_zone!(first, zone)

    tail =
      case meeting.scheduled_end_at do
        %DateTime{} = last ->
          "–" <> (last |> DateTime.shift_zone!(zone) |> Calendar.strftime("%H:%M"))

        _ ->
          ""
      end

    Calendar.strftime(local, "%a %-d %b · %H:%M") <> tail
  end

  defp when_label(%{started_at: %DateTime{} = at}, zone),
    do: at |> DateTime.shift_zone!(zone) |> Calendar.strftime("%a %-d %b · %H:%M")

  defp when_label(_, _), do: nil

  def find_row(rows, id) do
    rows |> Map.values() |> List.flatten() |> Enum.find(&(&1.meeting.id == id))
  end

  # ── list pane ──────────────────────────────────────────────────────────

  attr(:rows, :map, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:empty?, :boolean, default: false)
  attr(:external?, :boolean, default: false)

  def list_pane(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <section
      class={["mt-list-pane clears-tab-bar", @selected_id && "max-lg:hidden"]}
      aria-label="Meetings"
      data-role="meetings-list-pane"
    >
      <div :if={@empty?} data-empty-state="meetings-index" class="px-2 pb-2 pt-3 text-left">
        <h2 class="m-0 text-base font-semibold" data-role="meetings-index-empty-heading">
          No meetings yet.
        </h2>
        <p
          :if={@external?}
          data-viewer="external"
          data-role="meetings-index-empty-note"
          class="m-0 text-sm text-subtle"
        >
          You'll see a meeting here once you've been invited.
        </p>
        <p
          :if={!@external?}
          data-viewer="internal"
          data-role="meetings-index-empty-note"
          class="m-0 text-sm text-subtle"
        >
          Meetings for your organisation will appear here.
        </p>
      </div>
      <div :for={{key, label} <- @sections} data-section={key}>
        <h3 class="mt-section-label">{label}</h3>
        <p :if={@rows[key] == []} class="m-0 px-2 text-[13px] text-subtle">No meetings</p>
        <.link
          :for={row <- @rows[key]}
          patch={~p"/meetings?#{%{meeting: row.meeting.id}}"}
          id={"workspace-meeting-#{row.meeting.id}"}
          class="mt-row"
          aria-current={to_string(row.meeting.id == @selected_id)}
          data-role="workspace-meeting"
          data-meeting-id={row.meeting.id}
          data-meeting-status={row.meeting.status}
        >
          <span class="mt-kind">
            {row.space || "Meeting"}<span :if={key == :live}> · </span>
            <b
              :if={key == :live}
              class="cal-pill cal-pill-ok"
            >
              Live
            </b>
          </span>
          <strong>{row.meeting.name}</strong>
          <span :if={row.when}>{row.when}</span>
          <small :if={row.people != []}>{Enum.join(row.people, ", ")}</small>
          <small :if={key == :ended and artifacts(row) != []}>
            {Enum.join(artifacts(row), " · ")}
          </small>
        </.link>
      </div>
    </section>
    """
  end

  defp artifacts(row) do
    [
      {row.summary, "Summary"},
      {row.recording, "Recording"},
      {row.segments != [] || nil, "Transcript"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # ── detail ─────────────────────────────────────────────────────────────

  attr(:row, :map, default: nil)
  attr(:zone, :string, required: true)
  attr(:tab, :string, default: "summary")
  attr(:calendar?, :boolean, default: true)

  def detail(assigns) do
    ~H"""
    <section
      class={["mt-detail clears-tab-bar", !@row && "max-lg:hidden"]}
      data-role="meetings-detail"
    >
      <div :if={!@row} class="cal-page">
        <h2>Your meeting spaces</h2>
        <%!-- v4 `<p class="muted">`: 14px with the browser's 1em block margin. --%>
        <p class="my-[1em] text-sm text-subtle">Select a live, upcoming, or past meeting.</p>
      </div>
      <div :if={@row} class="cal-page" data-meeting-id={@row.meeting.id}>
        <.link
          patch={~p"/meetings"}
          class={[Cal.ghost_btn(), "self-start !min-h-11 lg:hidden"]}
          data-role="meetings-back"
        >
          ‹ Meetings
        </.link>
        <div class="mt-kind">
          {section_label(@row.section)} · {@row.space || "Meeting"}
        </div>
        <h2>{@row.meeting.name}</h2>
        <div :if={@row.when} class="cal-sub">{@row.when} · {@zone}</div>
        <div class="cal-panel">
          <h3>People</h3>
          <p>
            {if @row.people == [], do: "No one has joined yet.", else: Enum.join(@row.people, ", ")}
          </p>
          <p :if={@row.host}>Hosted by {@row.host}</p>
        </div>
        <div class="cal-segs">
          <.link
            :if={@row.section != :ended}
            navigate={~p"/meetings/#{@row.meeting.slug}"}
            class={[Cal.primary_btn(), "max-lg:!h-11"]}
            data-role="meetings-detail-open"
          >
            {if @row.section == :live, do: "Join now", else: "Open meeting room"}
          </.link>
          <.link
            :if={@calendar? and @row.date}
            navigate={"/calendar?" <> URI.encode_query(%{date: Date.to_iso8601(@row.date), select: @row.meeting.id})}
            class={[Cal.ghost_btn(), "max-lg:!h-11"]}
          >
            View in Calendar
          </.link>
        </div>
        <%= if @row.section == :ended do %>
          <div class="cal-segs" role="tablist" aria-label="Meeting records">
            <button
              :for={
                {value, label} <- [
                  {"summary", "Summary"},
                  {"recording", "Recording"},
                  {"transcript", "Transcript"}
                ]
              }
              type="button"
              role="tab"
              class="cal-seg mt-tab"
              aria-selected={to_string(@tab == value)}
              aria-pressed={to_string(@tab == value)}
              phx-click="meetings_list_tab"
              phx-value-tab={value}
            >
              {label}
            </button>
          </div>
          <div class="cal-panel" role="tabpanel" data-tab={@tab}>
            <%= case @tab do %>
              <% "recording" -> %>
                <h3>Recording</h3>
                <p :if={!@row.recording}>No recording was saved for this meeting.</p>
                <p :if={@row.recording}>
                  <a
                    href={elem(@row.recording, 0)}
                    class="text-interactive underline"
                    target="_blank"
                    rel="noopener"
                  >
                    Open the recording
                  </a>
                </p>
              <% "transcript" -> %>
                <h3>Transcript</h3>
                <p :if={@row.segments == []}>
                  No transcript was saved for this meeting.
                </p>
                <p :for={segment <- @row.segments} class="!text-base-content">
                  <b>{segment["speaker_name"] || segment["participant_identity"] || "Someone"}:</b>
                  {segment["text"]}
                </p>
              <% _ -> %>
                <h3>Summary</h3>
                <p :if={!@row.summary}>No summary was saved for this meeting.</p>
                <p :if={@row.summary} class="!text-base-content">
                  <span class="whitespace-pre-line">{@row.summary}</span>
                </p>
            <% end %>
          </div>
        <% else %>
          <div class="cal-panel">
            <h3>Meeting space</h3>
            <p>
              Use this room for the conversation. After the meeting, return here for its summary, recording, transcript, and briefing.
            </p>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  defp section_label(:live), do: "Live now"
  defp section_label(:upcoming), do: "Upcoming"
  defp section_label(_), do: "Past"

  # ── + New meeting (app.js `ds.newMeeting`) ─────────────────────────────

  attr(:projects, :list, default: [])
  attr(:project_id, :any, default: nil)
  attr(:error, :string, default: nil)

  def new_room_modal(assigns) do
    ~H"""
    <div class="cal-modal-scrim" data-role="meetings-new-room">
      <.focus_wrap
        id="meetings-new-room-modal"
        class="cal-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="meetings-new-room-title"
        phx-click-away="close_new_room"
        phx-window-keydown="close_new_room"
        phx-key="Escape"
      >
        <h2 id="meetings-new-room-title">New meeting</h2>
        <form id="meetings-new-room-form" phx-submit="start_room">
          <label class="cal-field">
            Name<input
              name="title"
              required
              maxlength="120"
              placeholder="Team catch-up"
              class="cal-input"
              phx-mounted={Phoenix.LiveView.JS.focus()}
            />
          </label>
          <label class="cal-field">
            Space<select name="project_id" class="cal-input">
              <option
                :for={project <- @projects}
                value={project.id}
                selected={project.id == @project_id}
              >
                {project.name}
              </option>
            </select>
          </label>
          <p class="my-[1em] text-sm text-subtle" data-role="new-room-hint">
            Start a room now, or schedule one from Calendar → New → Meeting.
          </p>
          <p :if={@error} class="cal-err" role="alert">{@error}</p>
          <div class="cal-ft">
            <button type="button" class={Cal.ghost_btn()} phx-click="close_new_room">Cancel</button>
            <button type="submit" class={Cal.primary_btn()}>Start meeting</button>
          </div>
        </form>
      </.focus_wrap>
    </div>
    """
  end
end
