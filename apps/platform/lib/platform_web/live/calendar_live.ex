defmodule PlatformWeb.CalendarLive do
  use PlatformWeb, :live_view
  import Ecto.Query, only: [from: 2]
  import PlatformWeb.CalendarLive.Components

  alias Platform.Calendar, as: Events
  alias Platform.Calendar.Authoring
  alias PlatformWeb.CalendarLive.Editor
  alias PlatformWeb.MeetingLive.CalendarWindow
  alias PlatformWeb.MeetingLive.LiveInvites
  alias PlatformWeb.TimeEntry

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
     |> assign(:selected, nil)
     |> assign(:meeting_cancel_state, :idle)
     |> assign(:meeting_delete_state, :idle)
     |> assign(:projects, [])
     |> assign(feed_url: nil, feed_old: nil, feed_modal: false, feed_exists?: false)
     |> assign(ext_error: nil, ext_url: nil, ext_label: nil)
     |> assign(calendar_grants: [], agent_choices: [], agent_rows: [])
     |> assign(:grant_form, agent_grant_form(nil, nil))
     |> LiveInvites.seed()
     |> Editor.seed()}
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

    socket = socket |> assign(:view, view) |> reload()

    # `?select=<id>` opens that entry's details (the Inbox consent card's
    # "See it on the calendar" lands here with the hold's id).
    socket =
      case params["select"] do
        id when is_binary(id) and id != "" -> select_entry(socket, nil, id, nil)
        _ -> socket
      end

    socket =
      cond do
        socket.assigns.live_action == :settings -> load_settings(socket, nil)
        # `?new=1`: the list pane's "+ New" on /calendar/booking. With
        # `date` and `start` (task 01a1986e) it opens on that day and time;
        # either one that does not parse falls back to today / 14:00.
        params["new"] == "1" -> new_event_at(socket, new_day(params, socket), new_minute(params))
        true -> socket
      end

    {:noreply, socket}
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

  # ── Calendar settings: agents (v4 `Agents with calendar access`) ────────

  def handle_event("choose_grant_agent", %{"grant" => %{"agent_id" => id}}, socket) do
    grants = Map.get(socket.assigns, :calendar_grants, [])

    {:noreply,
     assign(socket, :grant_form, agent_grant_form(Enum.find(grants, &(&1.agent_id == id)), id))}
  end

  def handle_event("grant_agent", %{"grant" => attrs}, socket) do
    case Platform.Calendar.AgentAccess.grant(owner_scope(socket), attrs["agent_id"], attrs) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> load_settings(grant.agent_id)
         |> put_flash(:info, "#{agent_name(socket, grant.agent_id)}’s calendar access saved")}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't save agent access.")}
    end
  end

  # Revoking also removes any hold the agent is still waiting on (PR #51
  # AgentAccess.revoke/2).
  def handle_event("revoke_agent", %{"id" => id}, socket) do
    case Platform.Calendar.AgentAccess.revoke(owner_scope(socket), id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_settings(id)
         |> reload()
         |> put_flash(:info, "#{agent_name(socket, id)}’s calendar access revoked")}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't revoke agent access.")}
    end
  end

  # "Grant again" restores the grant's own permissions (revoke keeps them).
  def handle_event("grant_again", %{"id" => id}, socket) do
    grant = Enum.find(socket.assigns.calendar_grants, &(&1.agent_id == id))

    attrs =
      case grant do
        nil -> %{read: true}
        g -> Map.take(g, ~w(read read_private create move preapprove)a)
      end

    attrs = if Enum.any?(Map.values(attrs)), do: attrs, else: %{read: true}

    case Platform.Calendar.AgentAccess.grant(owner_scope(socket), id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_settings(id)
         |> put_flash(:info, "#{agent_name(socket, id)} can read your calendar again")}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't grant agent access.")}
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

  def handle_event("new_event", _, socket),
    do: {:noreply, new_event_at(socket, socket.assigns.today, 14 * 60)}

  # A range dragged on the week grid (calendar_selection.js): the editor
  # opens on it and NOTHING is saved; Create event is the only write. The
  # hook sends local minutes in the viewer's zone on one day; anything out
  # of range, reversed or empty is normalized or refused here as well.
  def handle_event("select_range", %{"date" => date} = params, socket) do
    with {:ok, date} <- Date.from_iso8601(to_string(date)),
         {a, ""} <- Integer.parse(to_string(params["start"])),
         {b, ""} <- Integer.parse(to_string(params["end"])),
         {start, finish} <- normalize_range(a, b) do
      {:noreply, socket |> Editor.open_new(date, start, finish)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Details (app.js `renderDetails`): a chip opens its entry; `start` picks
  # the occurrence of a recurring event.
  def handle_event("select", %{"id" => id, "kind" => kind} = params, socket)
      when kind in ~w(event meeting external) do
    # The invite control is scoped to ONE meeting: a half-typed query must
    # not carry over to another entry (MeetingLive's `select_meeting`).
    socket =
      socket
      |> LiveInvites.seed()
      |> assign(:meeting_cancel_state, :idle)
      |> assign(:meeting_delete_state, :idle)
      |> select_entry(kind, id, params["start"])

    if socket.assigns.selected,
      do: {:noreply, socket},
      else: {:noreply, put_flash(socket, :error, "Event is no longer available.")}
  end

  def handle_event("select", _, socket), do: {:noreply, socket}

  def handle_event("close_details", _, socket), do: {:noreply, close_details(socket)}

  # Escape closes the editor first, then the details (app.js keydown). This
  # is the ONE Escape binding: the editor's X, Cancel and backdrop push
  # `close_editor`, and nothing else listens for Escape, so a keypress
  # closes exactly one layer.
  def handle_event("escape", _, %{assigns: %{editor: %{}}} = socket),
    do: {:noreply, Editor.seed(socket)}

  # Escape while the Cancel meeting inset is open collapses the inset only,
  # not the details (task 01a19e7f stage 4).
  def handle_event("escape", _, %{assigns: %{meeting_cancel_state: state}} = socket)
      when state in [:confirming, :error],
      do: {:noreply, assign(socket, :meeting_cancel_state, :idle)}

  # Same for the Delete inset (task 01a1b281 stage 4).
  def handle_event("escape", _, %{assigns: %{meeting_delete_state: state}} = socket)
      when state in [:confirming, :error],
      do: {:noreply, assign(socket, :meeting_delete_state, :idle)}

  def handle_event("escape", _, socket), do: {:noreply, close_details(socket)}

  def handle_event("close_editor", _, socket), do: {:noreply, Editor.seed(socket)}

  # ── Live invites in the meeting details (task 01a19e7b stage 2) ─────────
  #
  # The same handlers as MeetingLive's detail panel, shared through
  # `LiveInvites`. The meeting is never a client value: it is the entry the
  # open details were built from, out of the viewer-scoped `visible_entries`
  # (already filtered by `:meetings_on`), so a forged event with nothing
  # selected raises and writes nothing. No host gate is added or removed:
  # MeetingLive applies none either.
  #
  # After a write the details rebuild from `meeting_invites` so this socket
  # shows the new row at once. `Meetings.invite_*` broadcast nothing, so
  # another open window catches up only on its 60s `:calendar_tick` reload.
  def handle_event("meeting_invite_add_people", _params, socket) do
    _meeting = selected_meeting!(socket)
    {:noreply, LiveInvites.open(socket)}
  end

  def handle_event("meeting_invite_search", %{"value" => query}, socket),
    do: {:noreply, LiveInvites.search(socket, selected_meeting!(socket), query)}

  def handle_event("meeting_invite_commit", %{"value" => value}, socket) do
    meeting = selected_meeting!(socket)

    case LiveInvites.commit(socket, meeting, value, socket.assigns.current_user_record.id) do
      {:staged, socket} -> {:reply, %{staged: true}, refresh_selected(socket)}
      {:noop, socket} -> {:noreply, socket}
    end
  end

  def handle_event("meeting_invite_stage", %{"kind" => _} = params, socket) do
    meeting = selected_meeting!(socket)
    inviter_id = socket.assigns.current_user_record.id

    {:noreply, socket |> LiveInvites.stage(meeting, params, inviter_id) |> refresh_selected()}
  end

  # ── Cancel meeting in the details (task 01a19e7f stage 4) ────────────────
  #
  # `PlatformWeb.Components.Meetings.CancelMeeting`'s events, as on
  # /meetings. The meeting is never a client value: it is the entry the open
  # details were built from (`selected.entry.meeting`, out of the
  # viewer-scoped `visible_entries`), whatever the payload says. The rule is
  # enforced again by `Meetings.cancel_meeting_for_user/2`.
  def handle_event("cancel_meeting_open", _params, socket) do
    case socket.assigns.selected do
      %{kind: "meeting", can_cancel: true} ->
        {:noreply, assign(socket, :meeting_cancel_state, :confirming)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_meeting_keep", _params, socket) do
    case socket.assigns.meeting_cancel_state do
      :working -> {:noreply, socket}
      _ -> {:noreply, assign(socket, :meeting_cancel_state, :idle)}
    end
  end

  def handle_event("cancel_meeting_confirm", _params, socket) do
    case {socket.assigns.selected, socket.assigns.meeting_cancel_state} do
      {_selected, :working} ->
        {:noreply, socket}

      {%{kind: "meeting", entry: %{meeting: %{id: id}}}, _state} ->
        viewer = socket.assigns.current_user_record

        {:noreply,
         socket
         |> assign(:meeting_cancel_state, :working)
         |> start_async(:cancel_meeting, fn ->
           Platform.Meetings.cancel_meeting_for_user(id, viewer)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Delete meeting in the details (task 01a1b281 stage 4) ────────────────
  #
  # `PlatformWeb.Components.Meetings.DeleteMeeting`'s events, under the
  # cancel row's rule: the meeting is the entry the open details were built
  # from, never a payload value, and `Meetings.delete_meeting_for_user/2`
  # reloads it through the viewer scope and re-checks the rule.
  def handle_event("delete_meeting_open", _params, socket) do
    case socket.assigns.selected do
      %{kind: "meeting", can_delete: true} ->
        {:noreply, assign(socket, :meeting_delete_state, :confirming)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_meeting_keep", _params, socket) do
    case socket.assigns.meeting_delete_state do
      :working -> {:noreply, socket}
      _ -> {:noreply, assign(socket, :meeting_delete_state, :idle)}
    end
  end

  def handle_event("delete_meeting_confirm", _params, socket) do
    case {socket.assigns.selected, socket.assigns.meeting_delete_state} do
      {_selected, :working} ->
        {:noreply, socket}

      {%{kind: "meeting", can_delete: true, entry: %{meeting: %{id: id}}}, _state} ->
        viewer = socket.assigns.current_user_record

        {:noreply,
         socket
         |> assign(:meeting_delete_state, :working)
         |> start_async(:delete_meeting, fn ->
           Platform.Meetings.delete_meeting_for_user(id, viewer)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Edit on a meeting's details (task 01a1b281 stage 3, absorbed) ────────
  #
  # Opens the ONE Calendar editor (task 01a1b8a5 stage 2) on the entry the
  # open details were built from, never a payload id. `Authoring.load_draft/2`
  # loads it through the viewer scope with `Meetings.can_edit_meeting?/3`,
  # and the editor re-checks that on every later event.
  def handle_event("meeting_edit_open", _params, socket) do
    case socket.assigns.selected do
      %{kind: "meeting", entry: %{meeting: %{id: id}}} ->
        {_, socket} = Editor.open_existing(socket, {:meeting, id})
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # The editor's staged-people events: the same names and the same
  # `InviteeStaging` as the /meetings Edit meeting form.
  def handle_event("meeting_edit_" <> _ = event, params, socket),
    do: Editor.people(socket, event, params)

  # One guest row's link expiry, and a new link for a lapsed row (task
  # 01a19ea6), under the same rule as staging: the meeting is the open
  # selection, and `LiveInvites` checks the invite id against it.
  def handle_event("meeting_invite_expiry", %{"choice" => _} = params, socket) do
    meeting = selected_meeting!(socket)

    {:noreply, socket |> LiveInvites.set_expiry(meeting, params) |> refresh_selected()}
  end

  def handle_event("meeting_invite_renew", %{"id" => _, "choice" => _} = params, socket) do
    meeting = selected_meeting!(socket)
    inviter_id = socket.assigns.current_user_record.id

    {:noreply, socket |> LiveInvites.renew(meeting, params, inviter_id) |> refresh_selected()}
  end

  # Approve / Revert on a tentative hold: the same AgentAccess.handle/4 the
  # Inbox consent card calls, keyed by the hold's consent.
  def handle_event("consent", %{"verb" => verb}, socket) when verb in ~w(approve revert) do
    with %{kind: "tentative", id: hold_id} <- socket.assigns.selected,
         {:ok, _} <- handle_consent(socket, hold_id, verb) do
      flash = if verb == "approve", do: "Approved", else: "Reverted · hold removed"
      {:noreply, socket |> put_flash(:info, flash) |> reload()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "This hold was already handled.") |> reload()}
    end
  end

  # ── Calendar settings: external calendars ───────────────────────────────

  # v4 accepts https:// and webcal:// (app.js `#ext-add`); PR #51 stores
  # HTTPS, so webcal:// is rewritten to https:// before it is saved.
  def handle_event("add_external", %{"url" => url} = params, socket) do
    url = String.trim(url)
    label = String.trim(params["label"] || "")
    error = "Paste an iCal link that starts with https:// or webcal://"

    if Regex.match?(~r{\A(https?|webcal)://\S+\z}i, url) do
      count = length(socket.assigns.external_subscriptions)
      label = if label == "", do: "Calendar #{count + 1}", else: label
      https = Regex.replace(~r{\Awebcal://}i, url, "https://")

      case Platform.Calendar.Subscriptions.create(socket.assigns.access_scope, %{
             name: label,
             url: https
           }) do
        {:ok, sub} ->
          scope = socket.assigns.access_scope

          {:noreply,
           socket
           |> assign(ext_error: nil, ext_label: nil, ext_url: nil)
           |> start_async({:external_added, sub.id, label}, fn ->
             Platform.Calendar.Subscriptions.refresh(scope, sub.id)
           end)
           |> reload()}

        _ ->
          {:noreply, assign(socket, ext_error: error, ext_url: url, ext_label: label)}
      end
    else
      {:noreply, assign(socket, ext_error: error, ext_url: url, ext_label: label)}
    end
  end

  def handle_event("remove_external", %{"id" => id}, socket) do
    sub = Enum.find(socket.assigns.external_subscriptions, &(&1.id == id))

    case Platform.Calendar.Subscriptions.delete(socket.assigns.access_scope, id) do
      {:ok, _} -> {:noreply, socket |> reload() |> put_flash(:info, "#{sub && sub.name} removed")}
      _ -> {:noreply, put_flash(socket, :error, "Calendar is no longer available.")}
    end
  end

  def handle_event(
        "edit",
        _,
        %{assigns: %{selected: %{kind: "native", owner?: true, id: id}}} = socket
      ) do
    case Editor.open_existing(socket, {:event, id}) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, put_flash(socket, :error, "Event is no longer available.")}
    end
  end

  def handle_event("edit", _, socket), do: {:noreply, socket}

  def handle_event("event_change", %{"event" => params}, socket),
    do: Editor.change(socket, params)

  # Create event / Save: `Calendar.Authoring.save/3`, the one boundary for
  # a native event and its call record. The v4 messages still come first.
  def handle_event("save", %{"event" => params}, socket) do
    new? = match?(%{editor: %{new?: true}}, socket.assigns)

    case Editor.save(socket, params) do
      {:saved, result, socket} ->
        {:noreply, socket |> after_save(result, new?) |> reload_selected(result)}

      other ->
        other
    end
  end

  def handle_event("save", _, socket), do: {:noreply, socket}

  # Delete from the editor (Edit event footer) or the details footer; v4
  # deletes straight away and toasts `Event deleted`. Both go through
  # `Calendar.Authoring.delete/2`, so a call record is deleted only under
  # Meetings' lifecycle rule.
  def handle_event("delete", _, %{assigns: %{editor: %{}}} = socket) do
    case Editor.delete(socket) do
      {:deleted, socket} -> {:noreply, deleted(socket)}
      {:error, socket} -> {:noreply, put_flash(socket, :error, "You cannot delete this event.")}
    end
  end

  def handle_event("delete", _, socket) do
    scope = socket.assigns.access_scope

    with %{kind: "native", owner?: true, id: id} <- socket.assigns.selected,
         {:ok, draft} <- Authoring.load_draft(scope, {:event, id}),
         {:ok, _} <- Authoring.delete(scope, draft) do
      {:noreply, deleted(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot delete this event.")}
    end
  end

  # ── Calendar settings: private iCal feed ────────────────────────────────

  # v4 `Revoke` (and the at-rest `Make a new URL`) open the confirm modal.
  def handle_event("confirm_rotate", _, socket), do: {:noreply, assign(socket, :feed_modal, true)}

  def handle_event("cancel_rotate", _, socket), do: {:noreply, assign(socket, :feed_modal, false)}

  # Revoke and make a new URL: Calendar.rotate_feed/1 replaces the hash, so
  # the old URL stops working at once. Only a URL shown this session has a
  # known prefix (FeedToken stores the hash).
  def handle_event("rotate_feed", _, socket) do
    old =
      case socket.assigns.feed_url do
        url when is_binary(url) -> url |> String.split("/") |> List.last() |> String.slice(0, 5)
        _ -> "•••••"
      end

    case Events.rotate_feed(socket.assigns.access_scope) do
      {:ok, token} ->
        url = PlatformWeb.Endpoint.url() <> "/calendar/feed/" <> token

        {:noreply,
         socket
         |> assign(
           feed_url: url,
           feed_modal: false,
           feed_old: if(socket.assigns.feed_exists?, do: old),
           feed_exists?: true
         )
         |> put_flash(:info, "Feed URL revoked · new URL ready")}

      _ ->
        {:noreply,
         socket
         |> assign(:feed_modal, false)
         |> put_flash(:error, "Could not create a subscription link.")}
    end
  end

  def handle_event("copied", _, socket),
    do: {:noreply, put_flash(socket, :info, "Copied to clipboard")}

  @impl true
  def handle_info(:calendar_tick, socket) do
    Process.send_after(self(), :calendar_tick, 60_000)
    {:noreply, reload(socket)}
  end

  def handle_info(_, socket), do: {:noreply, reload(socket)}

  @impl true
  # A deleted meeting leaves the window, so the details close with it; the
  # reload redraws the grid for this viewer and the broadcast does it for
  # every other open calendar.
  def handle_async(:delete_meeting, result, socket) do
    socket =
      case result do
        {:ok, {:ok, _meeting}} ->
          socket |> close_details() |> reload()

        {:ok, {:error, reason}} when reason in [:forbidden, :not_found, :not_deletable] ->
          socket
          |> assign(:meeting_delete_state, :idle)
          |> put_flash(:error, "You can't delete this meeting.")

        _other ->
          assign(socket, :meeting_delete_state, :error)
      end

    {:noreply, socket}
  end

  def handle_async(:cancel_meeting, result, socket) do
    socket =
      case result do
        {:ok, {:ok, _meeting}} ->
          socket |> assign(:meeting_cancel_state, :idle) |> reload()

        {:ok, {:error, reason}} when reason in [:forbidden, :not_found] ->
          socket
          |> assign(:meeting_cancel_state, :idle)
          |> put_flash(:error, "You can't cancel this meeting.")

        _other ->
          assign(socket, :meeting_cancel_state, :error)
      end

    {:noreply, socket}
  end

  def handle_async({:external_added, _id, label}, result, socket) do
    flash =
      case result do
        {:ok, {:ok, %{snapshot: rows}}} when is_list(rows) ->
          "#{label} added · #{length(rows)} events imported, read-only"

        _ ->
          "#{label} added"
      end

    {:noreply, socket |> reload() |> put_flash(:info, flash)}
  end

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
    # `:keep`: a cancelled meeting stays on the grid in its slot, struck
    # through (task 01a19e7f stage 4). Only this caller asks for it.
    entries = Events.list_entries(scope, from, to, time_zone: zone, cancelled_meetings: :keep)
    agents = hold_agents(entries, socket.assigns.current_user_record)

    visible =
      entries
      |> Enum.filter(&shown?(socket.assigns.calendars_shown, calendar_key(&1)))
      |> Enum.reject(&(&1.kind == :meeting and not socket.assigns.meetings_on))
      |> Enum.map(&Map.put(&1, :agent, Map.get(agents, &1.id)))

    socket
    |> assign(
      today: today(zone),
      external_subscriptions: subscriptions,
      booking_link_count: length(Platform.Calendar.BookingLinks.list(scope)),
      entries: entries,
      visible_entries: visible,
      calendars: calendar_rows(socket.assigns, subscriptions),
      spaces: Platform.Calendar.list_spaces(scope),
      projects: Platform.Tasks.list_projects_for_user(socket.assigns.current_user_record)
    )
    |> refresh_selected()
  end

  # The open details follow the data: a PubSub change or a tick rebuilds
  # them, and an entry that left the window (deleted, reverted, hidden)
  # closes them.
  defp refresh_selected(%{assigns: %{selected: %{entry: entry}}} = socket) do
    select_entry(
      socket,
      Atom.to_string(entry.kind),
      entry.id,
      Integer.to_string(DateTime.to_unix(entry.starts_at))
    )
  end

  defp refresh_selected(socket), do: socket

  defp close_details(socket),
    do:
      socket
      |> assign(:selected, nil)
      |> assign(:meeting_cancel_state, :idle)
      |> assign(:meeting_delete_state, :idle)
      |> LiveInvites.seed()

  defp selected_meeting!(%{assigns: %{selected: %{kind: "meeting", entry: %{meeting: meeting}}}}),
    do: meeting

  defp selected_meeting!(_socket),
    do: raise(ArgumentError, "cannot invite: no meeting is selected in the details")

  defp select_entry(socket, kind, id, start) do
    candidates =
      Enum.filter(
        socket.assigns.visible_entries,
        &(&1.id == id and (is_nil(kind) or Atom.to_string(&1.kind) == kind))
      )

    entry =
      Enum.find(candidates, &(Integer.to_string(DateTime.to_unix(&1.starts_at)) == start)) ||
        List.first(candidates)

    assign(socket, :selected, entry && detail(socket.assigns, entry))
  end

  # Everything the details panel prints for one entry (app.js
  # `renderDetails`), resolved once here so the component stays markup.
  defp detail(assigns, entry) do
    %{zone: zone, current_user_record: user} = assigns
    date = entry.starts_at |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    {first, last} = day_minutes(entry, date, zone)
    kind = chip_kind(entry)

    base = %{
      id: entry.id,
      kind: kind,
      entry: entry,
      title: chip_title(entry),
      date: date,
      when:
        if(entry.all_day,
          do: "#{day_label(date)} · All day",
          else: "#{day_label(date)} · #{hm(first)}–#{hm(min(last, 1439))}"
        )
    }

    case kind do
      k when k in ["native", "tentative"] ->
        event = entry.event
        owner? = user && event.owner_id == user.id

        Map.merge(base, %{
          owner?: owner?,
          busy?: event.visibility == "busy",
          notes: event.description,
          recurrence: recurrence_label(event),
          calendar: if(owner?, do: (user && user.name) || "You"),
          agent: entry[:agent] || "an agent"
        })

      "meeting" ->
        # The viewer's zone rides along for the guest rows' expiry line
        # (task 01a19ea6 stage 2), the same zone `when` above is printed in.
        base
        |> Map.merge(meeting_info(entry.meeting))
        |> Map.merge(meeting_cancel_info(entry.meeting, user))
        |> Map.put(:time_zone, zone)

      "external" ->
        Map.merge(base, %{
          calendar: entry.subscription || "External calendar",
          stale: entry[:stale]
        })
    end
  end

  # The meeting's space and host, read from the chat rows the Meetings
  # context keeps for it. Invitees come from `meeting_invites` (revoked rows
  # excluded), not chat participation: an invited member who has not joined
  # the space, and every guest, are invited all the same.
  defp meeting_info(meeting) do
    space = meeting.chat_space_id && Platform.Chat.get_space(meeting.chat_space_id)

    people =
      if space,
        do: Platform.Chat.list_participants(space.id),
        else: []

    host =
      Enum.find(people, &(&1.id == meeting.host_participant_id)) ||
        (meeting.host_participant_id && Platform.Chat.get_participant(meeting.host_participant_id))

    %{
      live?: meeting.status == "live",
      slug: meeting.slug,
      meeting_id: meeting.id,
      space: space && "#" <> space.name,
      host: host && host.display_name,
      # MeetingLive's own rows. No ring states: CalendarLive does not
      # subscribe to ring reports.
      invite_entries: PlatformWeb.MeetingLive.detail_invite_rows(meeting)
    }
  end

  # The Cancel control's inputs (task 01a19e7f stage 4), kept apart from
  # `meeting_info/1`, which the live-invite work owns. `can_cancel` is the
  # permission rule AND a cancellable status, so the row disappears with the
  # cancellation that ended it; `audience` is the notifier's own count.
  defp meeting_cancel_info(meeting, user) do
    can_cancel =
      Platform.Meetings.cancellable_status?(meeting) and
        Platform.Meetings.can_cancel_meeting?(meeting, user)

    audience = if can_cancel, do: Platform.Meetings.cancellation_audience_count(meeting), else: 0

    %{
      cancelled?: meeting.status == "cancelled",
      can_cancel: can_cancel,
      # Edit (task 01a1b281 stage 3): drawn only for this.
      can_edit: Platform.Meetings.can_edit_meeting?(meeting, user),
      # Delete (stage 4): cancelled, ended, or scheduled with its time past.
      can_delete: Platform.Meetings.can_delete_meeting?(meeting, user),
      audience: audience
    }
  end

  defp handle_consent(socket, hold_id, verb) do
    owner_id = socket.assigns.current_user_record.id

    consent =
      Platform.Repo.one(
        from(c in Platform.Calendar.Consent,
          where: c.hold_id == ^hold_id and c.owner_id == ^owner_id,
          order_by: [desc: c.inserted_at],
          limit: 1
        )
      )

    with %Platform.Calendar.Consent{} <- consent,
         %Platform.Memory.Briefing{} = briefing <-
           Platform.Repo.get(Platform.Memory.Briefing, consent.briefing_id) do
      Platform.Calendar.AgentAccess.handle(
        briefing,
        "calendar:" <> consent.id,
        verb,
        socket.assigns.access_scope
      )
    else
      _ -> {:error, :not_found}
    end
  end

  defp after_save(socket, %{undelivered: undelivered, failed: failed}, new?) do
    flash = if new?, do: "Event created", else: "Event saved"

    case length(undelivered) + length(failed) do
      0 -> put_flash(socket, :info, flash)
      n -> put_flash(socket, :error, "#{flash}, but #{n} invite(s) could not be sent.")
    end
  end

  # v4 opens the saved event's details (app.js `#f-save` sets S.sel): the
  # native row for its owner, the call record for a legacy meeting.
  defp reload_selected(socket, %{event: %{id: id} = event}) do
    socket
    |> put_day(local_date(event, socket.assigns.zone))
    |> reload()
    |> select_entry("event", id, nil)
  end

  defp reload_selected(socket, %{meeting: %{id: id, scheduled_start_at: %DateTime{} = at}}) do
    date = at |> DateTime.shift_zone!(socket.assigns.zone) |> DateTime.to_date()
    socket |> put_day(date) |> reload() |> select_entry("meeting", id, nil)
  end

  defp reload_selected(socket, _result), do: reload(socket)

  defp local_date(%{all_day: true, start_date: %Date{} = date}, _zone), do: date

  defp local_date(%{starts_at: at, time_zone: zone}, _viewer_zone),
    do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp deleted(socket),
    do:
      socket
      |> Editor.seed()
      |> assign(:selected, nil)
      |> put_flash(:info, "Event deleted")
      |> reload()

  @doc """
  A dragged range as `{start, end}` local minutes: reversed order is
  swapped, the day is clamped to 0..1440 and an empty range gets the
  slot click's 30 minutes. `:error` for a range that has no minute in
  the day.
  """
  def normalize_range(a, b) when is_integer(a) and is_integer(b) do
    {first, last} = {min(a, b), max(a, b)}
    first = first |> max(0) |> min(1439)
    last = last |> max(0) |> min(1440)

    cond do
      last <= first -> {first, min(first + 30, 1440)}
      true -> {first, last}
    end
  end

  def normalize_range(_, _), do: :error

  # The scope Calendar's owner-only contexts expect, rebuilt from the user row
  # as PR #51's agent-access handlers did.
  defp owner_scope(socket),
    do:
      Platform.Access.Scope.for_user(
        Platform.Accounts.get_user(socket.assigns.current_user_record.id)
      )

  # v4 settings panels: the agents (grants plus the agent rows they name)
  # and whether a feed URL exists (FeedToken stores only its hash).
  defp load_settings(socket, agent_id) do
    scope = owner_scope(socket)
    user_id = socket.assigns.current_user_record.id
    choices = Platform.Calendar.AgentAccess.agents(scope)
    grants = Platform.Calendar.AgentAccess.list(scope)
    ids = Enum.map(grants, & &1.agent_id)

    agents =
      Platform.Repo.all(from(a in Platform.Agents.Agent, where: a.id in ^ids))
      |> Map.new(&{&1.id, &1})

    rows =
      grants
      |> Enum.filter(&Map.has_key?(agents, &1.agent_id))
      |> Enum.sort_by(&agents[&1.agent_id].name)
      |> Enum.map(&%{grant: &1, agent: agents[&1.agent_id]})

    agent_id = agent_id || (List.first(choices) && List.first(choices).id)

    assign(socket,
      agent_choices: choices,
      calendar_grants: grants,
      agent_rows: rows,
      grant_form: agent_grant_form(Enum.find(grants, &(&1.agent_id == agent_id)), agent_id),
      feed_exists?:
        Platform.Repo.exists?(
          from(f in Platform.Calendar.FeedToken, where: f.owner_id == ^user_id)
        )
    )
  end

  defp agent_name(socket, id) do
    Enum.find_value(socket.assigns.agent_choices, "The agent", &(&1.id == id && &1.name))
  end

  defp put_cursor(socket, date),
    do: assign(socket, cursor: date, mini_month: Date.beginning_of_month(date))

  defp put_day(socket, date), do: socket |> assign(:sel_day, date) |> put_cursor(date)

  defp today(zone), do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp new_day(params, socket) do
    case Date.from_iso8601(params["date"] || "") do
      {:ok, date} -> date
      _ -> socket.assigns.today
    end
  end

  defp new_minute(params) do
    case TimeEntry.parse(params["start"]) do
      {:ok, %Time{hour: hour, minute: minute}} -> hour * 60 + minute
      _ -> 14 * 60
    end
  end

  defp new_event_at(socket, date, minute),
    do: Editor.open_new(socket, date, minute, min(minute + 30, 1440))

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

  @doc """
  The list pane's Calendars rows (native, Meetings when on, one per external
  subscription). Shared with `BookingSettingsLive`, whose list pane is the
  same (task 01a18d9f stage 3). `assigns` needs `current_user_record` and
  `meetings_on`.
  """
  def calendar_rows(assigns, subscriptions) do
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

  def where_options(spaces, projects),
    do:
      [{"Only you", "private"}] ++
        Enum.map(spaces, &{"#" <> &1.name, "space:" <> &1.id}) ++
        Enum.map(projects, &{&1.name, "project:" <> &1.id})

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

  @doc "A meeting entry that was called off (task 01a19e7f stage 4)."
  def cancelled?(%{kind: :meeting, meeting: %{status: "cancelled"}}), do: true
  def cancelled?(_), do: false

  @doc "The title a chip shows: the hold's own title, never the list prefix."
  def chip_title(%{kind: :event, event: %{title: title}}) when is_binary(title), do: title
  def chip_title(%{title: title}), do: title || ""

  @doc "`Mon 26 Oct`, the prototype's `dateLabel`."
  def day_label(date), do: Calendar.strftime(date, "%a %-d %b")

  def hm(minute), do: pad(div(minute, 60)) <> ":" <> pad(rem(minute, 60))
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  The details' recurrence line (app.js `recLabel`): `Every day`, `Weekly on
  Tuesday`, `Monthly on day 26`; a PR #51 custom rule reads `Every 2 weeks,
  3 times` or `…, until Mon 30 Nov`. nil when the event does not repeat.
  """
  def recurrence_label(%{recurrence: rule} = event) do
    case Platform.Calendar.Recurrence.parse(rule) do
      {:ok, %{frequency: freq, interval: interval, count: count, until: until}} ->
        local = event.starts_at && DateTime.shift_zone!(event.starts_at, event.time_zone)

        base =
          case {freq, interval} do
            {"DAILY", 1} -> "Every day"
            {"WEEKLY", 1} when not is_nil(local) -> "Weekly on " <> Calendar.strftime(local, "%A")
            {"WEEKLY", 1} -> "Weekly"
            {"MONTHLY", 1} when not is_nil(local) -> "Monthly on day #{local.day}"
            {"MONTHLY", 1} -> "Monthly"
            {"DAILY", n} -> "Every #{n} days"
            {"WEEKLY", n} -> "Every #{n} weeks"
            {"MONTHLY", n} -> "Every #{n} months"
          end

        base <>
          if(count, do: ", #{count} times", else: "") <>
          if(until, do: ", until #{day_label(until)}", else: "")

      _ ->
        nil
    end
  end

  def recurrence_label(_), do: nil

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

      Map.merge(chip, %{
        lanes: lanes,
        top: top,
        height: height,
        compact: height < 34,
        # `lanes` is the DAY's lane count, so it says nothing about this
        # block: a block that overlaps nothing still gets 1/lanes of the
        # column. `overlapped` is per block (task 01a19e7f stage 5).
        overlapped: overlaps_another?(chip, placed)
      })
    end)
  end

  defp overlaps_another?(chip, placed) do
    Enum.any?(placed, fn other ->
      other != chip and other.s < chip.e and chip.s < other.e
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
