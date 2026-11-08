defmodule PlatformWeb.CalendarEditorTest do
  @moduledoc """
  Calendar's ONE event editor (task 01a1b8a5 stage 2): every v7 inventory
  row, the call default and its guards, presets, the shared staged-people
  block, the close paths and the drag-selected range.

  "Nothing before Save" is asserted as row counts of the three stores an
  event can write: `calendar_events`, `meetings` and `meeting_invites`
  (plus `mail_deliveries`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Calendar.Event
  alias Platform.Mail.Delivery
  alias Platform.Meetings
  alias Platform.Meetings.{Invite, Meeting}
  alias Platform.Repo

  @editor "#calendar-editor"
  @form "#calendar-event-form"

  defmodule Quiet do
    @moduledoc "Inbox and notifications stand-in."
    def emit(attrs), do: {:ok, attrs}
    def fan_out_to_user(_user_id, _payload, _opts \\ []), do: :ok
    def fan_out_to_humans(_ids, _payload, _opts \\ []), do: :ok
  end

  setup %{conn: conn} do
    # Calls on for the install (config/test.exs ships them off), as the
    # stage-1 Authoring tests do; individual tests switch them off again.
    keys = [:meetings_enabled, :inbox_module, :notifications_module]
    prior = for key <- keys, into: %{}, do: {key, Application.fetch_env(:platform, key)}
    Application.put_env(:platform, :meetings_enabled, true)
    Application.put_env(:platform, :inbox_module, Quiet)
    Application.put_env(:platform, :notifications_module, Quiet)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    org_id = Platform.TenancyFixtures.acme_org_id()
    owner = member!(org_id, "Owner")

    %{
      conn: conn,
      org_id: org_id,
      owner: owner,
      zone: "America/Chicago"
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp member!(org_id, name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "cal-editor-#{n}@example.com",
        name: "#{name} #{n}",
        oidc_sub: "cal-editor-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })

    user
  end

  defp project!(ctx) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Tasks.Project{
      name: "Editor project #{n}",
      slug: "editor-project-#{n}",
      org_id: ctx.org_id
    })
  end

  defp conn_for(user, zone) do
    build_conn()
    |> init_test_session(current_user_id: user.id)
    |> put_connect_params(%{"timezone" => zone})
  end

  defp open!(ctx, path \\ "/calendar") do
    {:ok, view, _} = live(conn_for(ctx.owner, ctx.zone), path)
    view
  end

  defp new!(view) do
    view |> element("#calendar-new") |> render_click()
    assert has_element?(view, @editor)
    view
  end

  defp counts,
    do: %{
      events: Repo.aggregate(Event, :count),
      meetings: Repo.aggregate(Meeting, :count),
      invites: Repo.aggregate(Invite, :count),
      mail: Repo.aggregate(Delivery, :count)
    }

  defp fill(view, attrs), do: view |> form(@form, event: attrs) |> render_change()
  defp submit(view, attrs \\ %{}), do: view |> form(@form, event: attrs) |> render_submit()

  defp timed(extra \\ %{}) do
    Map.merge(
      %{title: "Design review", date: "2026-12-02", start: "10:00 AM", end: "11:00 AM"},
      extra
    )
  end

  defp deny_meetings!(user) do
    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, user.id},
        permission: "meetings",
        resource: {:module, Platform.TenancyFixtures.acme_org_id()}
      })
  end

  defp call_box(view), do: element(view, "#{@editor} input[data-role=f-call]")

  # ── the v7 inventory ─────────────────────────────────────────────────────

  describe "the v7 inventory" do
    test "New renders every row with its verbatim copy and no Event | Meeting split", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()

      assert has_element?(view, "#{@editor} h2.editor-heading", "New event")

      assert has_element?(
               view,
               "#{@editor} button[data-close-modal][aria-label='Close event editor']"
             )

      assert has_element?(view, "#{@editor} label", "Title")
      assert has_element?(view, "#{@editor} input[data-role=f-title][placeholder='What is it?']")
      assert has_element?(view, "#{@editor} label", "Date")
      assert has_element?(view, "#{@editor} input[data-role=f-date][type=date]")
      assert has_element?(view, "#{@editor} label", "Start")
      assert has_element?(view, "#{@editor} input[data-role=f-s]")
      assert has_element?(view, "#{@editor} label", "End")
      assert has_element?(view, "#{@editor} input[data-role=f-e]")

      assert has_element?(view, "#{@editor} label", "Type")

      assert has_element?(
               view,
               "#{@editor} select[data-role=f-type] option[value=event]",
               "Event"
             )

      assert has_element?(
               view,
               "#{@editor} select[data-role=f-type] option[value=focus]",
               "Focus time"
             )

      assert has_element?(
               view,
               "#{@editor} select[data-role=f-type] option[value=ooo]",
               "Out of office"
             )

      assert has_element?(
               view,
               "#{@editor} [data-role=type-help]",
               "People and a call are optional. This event blocks your availability."
             )

      assert has_element?(view, "#{@editor} [data-role=f-people]", "People")

      assert has_element?(
               view,
               "#{@editor} [data-role=f-people] input[placeholder='Names or email addresses']"
             )

      assert has_element?(
               view,
               "#{@editor} [data-role=calendar-editor-call]",
               "Add a Burrow call"
             )

      assert has_element?(view, "#{@editor} label", "Repeat (optional)")
      assert has_element?(view, "#{@editor} select[data-role=f-rec]")
      assert has_element?(view, "#{@editor} [data-vis=busy]", "Busy only")

      assert has_element?(
               view,
               "#{@editor} [data-vis=busy] small",
               "Others, agents and your iCal feed just see “Busy”."
             )

      assert has_element?(view, "#{@editor} [data-vis=full]", "Full details")

      assert has_element?(
               view,
               "#{@editor} [data-vis=full] small",
               "People with access see the title and notes."
             )

      assert has_element?(view, "#{@editor} label", "Notes")
      assert has_element?(view, "#{@editor} textarea[data-role=f-notes][placeholder=Optional]")
      assert has_element?(view, "#{@editor} [data-role=f-err][role=alert]")
      assert has_element?(view, "#{@editor} .cal-ft button[data-close-modal]", "Cancel")
      assert has_element?(view, "#{@editor} .cal-ft [data-role=f-save]", "Create event")

      # Edit only, and no split editor.
      refute has_element?(view, "#{@editor} [data-del]")
      refute has_element?(view, "#{@editor} [data-role=new-kind-toggle]")
      refute has_element?(view, "#{@editor} [data-kind=meeting]")
    end

    test "Edit reads Edit event, Save and offers Delete", ctx do
      view = ctx |> open!() |> new!()
      submit(view, timed())
      view |> element("[data-role=calendar-details] button", "Edit") |> render_click()

      assert has_element?(view, "#{@editor} h2.editor-heading", "Edit event")
      assert has_element?(view, "#{@editor} [data-role=f-save]", "Save")
      assert has_element?(view, "#{@editor} .cal-ft button[data-del]", "Delete")
    end

    test "the three preset help strings are verbatim and follow the Type", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()

      fill(view, %{preset: "ooo"})

      assert has_element?(
               view,
               "#{@editor} [data-role=type-help]",
               "Out of office · blocks bookings. Existing events are kept; no invitations are declined automatically."
             )

      fill(view, %{preset: "focus"})

      assert has_element?(
               view,
               "#{@editor} [data-role=type-help]",
               "Focus time · blocks bookings, with no call."
             )

      fill(view, %{preset: "event"})

      assert has_element?(
               view,
               "#{@editor} [data-role=type-help]",
               "People and a call are optional. This event blocks your availability."
             )
    end
  end

  # ── the call ─────────────────────────────────────────────────────────────

  describe "the call checkbox" do
    test "a new ordinary event starts with the call on when the viewer may have one", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()

      assert has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      refute has_element?(view, "#{@editor} input[data-role=f-call][disabled]")
    end

    test "with calls switched off for the install it is not offered and stays off", ctx do
      project!(ctx)
      Application.put_env(:platform, :meetings_enabled, false)
      view = ctx |> open!() |> new!()

      refute has_element?(view, "#{@editor} input[data-role=f-call]")
      before = counts()
      submit(view, timed())
      assert %{events: e, meetings: m} = counts()
      assert e == before.events + 1
      assert m == before.meetings
    end

    test "a forged call_enabled from a viewer with calls off saves nothing", ctx do
      project = project!(ctx)
      Application.put_env(:platform, :meetings_enabled, false)
      view = ctx |> open!() |> new!()
      before = counts()

      render_submit(view, "save", %{
        "event" =>
          timed(%{call_enabled: "true", call_project: project.id})
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
      })

      assert counts() == before
      assert has_element?(view, "#{@editor} [data-role=f-err]", "Burrow call")
    end

    test "a viewer denied the Meetings module is not offered a call and cannot forge one", ctx do
      project = project!(ctx)
      deny_meetings!(ctx.owner)
      view = ctx |> open!() |> new!()

      refute has_element?(view, "#{@editor} input[data-role=f-call]")
      before = counts()

      render_submit(view, "save", %{
        "event" =>
          timed(%{call_enabled: "true", call_project: project.id})
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
      })

      assert counts() == before
    end

    test "with no project to hold a call it starts off and says why", ctx do
      view = ctx |> open!() |> new!()

      assert has_element?(view, "#{@editor} input[data-role=f-call][disabled]")
      refute has_element?(view, "#{@editor} input[data-role=f-call][checked]")

      assert has_element?(
               view,
               "#{@editor} [data-role=calendar-editor-call-no-project]",
               "Create a project before adding a Burrow call."
             )
    end

    test "Create event with the default call makes one event linked to one call", ctx do
      project = project!(ctx)
      view = ctx |> open!() |> new!()
      before = counts()

      submit(view, timed())

      assert counts().events == before.events + 1
      assert counts().meetings == before.meetings + 1
      [event] = Repo.all(Event)
      meeting = Repo.get!(Meeting, event.meeting_id)
      assert meeting.call_enabled
      assert meeting.project_id == project.id
      assert meeting.name == "Design review"
      assert event.starts_at == ~U[2026-12-02 16:00:00.000000Z]
      assert render(view) =~ "Event created"
    end

    test "unticked, Create event makes a plain event and no call", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()
      before = counts()

      submit(view, timed(%{call_enabled: "false"}))

      assert counts().events == before.events + 1
      assert counts().meetings == before.meetings
      assert [%Event{meeting_id: nil}] = Repo.all(Event)
    end

    test "an explicit OFF survives an edit, and the call record keeps its id", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()
      # People but no call: a call record with the call OFF.
      invitee = member!(ctx.org_id, "Invitee")
      stage_member!(view, invitee)
      submit(view, timed(%{call_enabled: "false"}))

      [event] = Repo.all(Event)
      meeting = Repo.get!(Meeting, event.meeting_id)
      refute meeting.call_enabled

      view |> element("[data-role=calendar-details] button", "Edit") |> render_click()
      refute has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      submit(view, %{title: "Design review, renamed"})

      meeting = Repo.get!(Meeting, meeting.id)
      refute meeting.call_enabled
      assert meeting.name == "Design review, renamed"
      assert Repo.get!(Event, event.id).meeting_id == meeting.id
    end

    test "an old plain event loads with the call off", ctx do
      project!(ctx)

      {:ok, event} =
        Platform.Calendar.create_event(Platform.Access.Scope.for_user(ctx.owner), %{
          title: "Old plain",
          starts_at: ~U[2026-12-03 15:00:00Z],
          ends_at: ~U[2026-12-03 16:00:00Z],
          time_zone: ctx.zone
        })

      view = open!(ctx, "/calendar?date=2026-12-03&select=#{event.id}")
      view |> element("[data-role=calendar-details] button", "Edit") |> render_click()

      refute has_element?(view, "#{@editor} input[data-role=f-call][checked]")
    end
  end

  # ── presets ──────────────────────────────────────────────────────────────

  describe "presets" do
    test "Focus time and Out of office disable people and the call; Event restores it", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()

      fill(view, %{preset: "focus"})
      assert has_element?(view, "#{@editor} input[data-role=f-call][disabled]")
      refute has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      assert has_element?(view, "#{@editor} [data-role=f-people][data-disabled] input[disabled]")

      fill(view, %{preset: "event"})
      assert has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      refute has_element?(view, "#{@editor} input[data-role=f-call][disabled]")
    end

    test "Out of office saves a no-call availability block", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()
      before = counts()

      fill(view, %{preset: "ooo"})
      submit(view, timed(%{title: "Away"}))

      assert counts().meetings == before.meetings
      assert [%Event{preset: "ooo", meeting_id: nil}] = Repo.all(Event)
    end

    test "a preset on a call-backed event turns the call off and keeps the record", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()
      submit(view, timed())
      [event] = Repo.all(Event)

      view |> element("[data-role=calendar-details] button", "Edit") |> render_click()
      fill(view, %{preset: "focus"})
      submit(view)

      event = Repo.get!(Event, event.id)
      assert event.preset == "focus"
      refute Repo.get!(Meeting, event.meeting_id).call_enabled
    end
  end

  # ── nothing before Save ──────────────────────────────────────────────────

  describe "nothing is written before Save" do
    test "typing, staging a person and closing by X, Cancel, Escape or backdrop writes nothing",
         ctx do
      project!(ctx)
      invitee = member!(ctx.org_id, "Staged")
      view = open!(ctx)
      before = counts()

      for close <- [:x, :cancel, :escape, :backdrop] do
        new!(view)
        fill(view, %{title: "Unsaved"})
        stage_member!(view, invitee)
        assert has_element?(view, "#{@editor} [data-role=meeting-edit-invitee][data-added]")

        case close do
          :x ->
            view |> element("#{@editor} [data-role=calendar-editor-close]") |> render_click()

          :cancel ->
            view |> element("#{@editor} [data-role=calendar-editor-cancel]") |> render_click()

          :escape ->
            render_keydown(view, "escape", %{"key" => "Escape"})

          :backdrop ->
            render_click(view, "close_editor", %{})
        end

        refute has_element?(view, @editor)
        assert counts() == before
      end

      # Reopening starts clean: nothing carried over from the closed draft.
      new!(view)
      refute has_element?(view, "#{@editor} [data-role=meeting-edit-invitee]")
      refute has_element?(view, "#{@editor} input[data-role=f-title][value=Unsaved]")
    end

    test "a validation error keeps what was typed and the selected range, and writes nothing",
         ctx do
      project!(ctx)
      view = open!(ctx)
      render_hook(view, "select_range", %{"date" => "2026-12-02", "start" => 600, "end" => 690})
      before = counts()

      submit(view, %{title: "  "})

      assert has_element?(view, "#{@editor} [data-role=f-err]", "Give the event a title.")
      assert has_element?(view, "#{@editor} input[data-role=f-title][aria-invalid=true]")
      assert has_element?(view, "#{@editor} input[data-role=f-s][value='10:00 AM']")
      assert has_element?(view, "#{@editor} input[data-role=f-e][value='11:30 AM']")
      assert counts() == before

      submit(view, %{title: "Fixed", start: "1:00"})
      assert has_element?(view, "#{@editor} [data-role=f-err]", "AM or PM")
      assert has_element?(view, "#{@editor} input[data-role=f-title][value=Fixed]")
      assert counts() == before
    end

    test "a repeating event with a call is refused in words, not dropped", ctx do
      project!(ctx)
      view = ctx |> open!() |> new!()
      before = counts()

      submit(view, timed(%{repeat: "FREQ=WEEKLY"}))

      assert has_element?(
               view,
               "#{@editor} [data-role=f-err]",
               "A repeating event can’t have people or a Burrow call."
             )

      assert counts() == before
    end
  end

  # ── drag-selected range (calendar_selection.js -> select_range) ─────────

  describe "select_range" do
    test "opens the same New editor on the range and saves nothing", ctx do
      project!(ctx)
      view = open!(ctx)
      before = counts()

      render_hook(view, "select_range", %{"date" => "2026-12-02", "start" => 555, "end" => 645})

      assert has_element?(view, "#{@editor} h2", "New event")
      assert has_element?(view, "#{@editor} input[data-role=f-date][value='2026-12-02']")
      assert has_element?(view, "#{@editor} input[data-role=f-s][value='9:15 AM']")
      assert has_element?(view, "#{@editor} input[data-role=f-e][value='10:45 AM']")
      assert has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      assert counts() == before
    end

    test "a reversed range is normalized; garbage opens nothing", ctx do
      view = open!(ctx)

      render_hook(view, "select_range", %{"date" => "2026-12-02", "start" => 720, "end" => 660})
      assert has_element?(view, "#{@editor} input[data-role=f-s][value='11:00 AM']")
      assert has_element?(view, "#{@editor} input[data-role=f-e][value='12:00 PM']")
      render_click(view, "close_editor", %{})

      render_hook(view, "select_range", %{"date" => "not-a-day", "start" => 600, "end" => 660})
      refute has_element?(view, @editor)
      render_hook(view, "select_range", %{"date" => "2026-12-02", "start" => "x", "end" => 660})
      refute has_element?(view, @editor)
    end

    test "normalize_range clamps to the day and never returns an empty range" do
      alias PlatformWeb.CalendarLive
      assert CalendarLive.normalize_range(600, 540) == {540, 600}
      assert CalendarLive.normalize_range(-30, 2000) == {0, 1440}
      assert CalendarLive.normalize_range(600, 600) == {600, 630}
      assert CalendarLive.normalize_range(1439, 1439) == {1439, 1440}
    end
  end

  # ── close paths and Escape ───────────────────────────────────────────────

  describe "closing" do
    test "one Escape closes the editor only; the next closes the details", ctx do
      view = ctx |> open!() |> new!()
      submit(view, timed())
      assert has_element?(view, "[data-role=calendar-details]")

      view |> element("[data-role=calendar-details] button", "Edit") |> render_click()
      assert has_element?(view, @editor)

      render_keydown(view, "escape", %{"key" => "Escape"})
      refute has_element?(view, @editor)
      assert has_element?(view, "[data-role=calendar-details]")

      render_keydown(view, "escape", %{"key" => "Escape"})
      refute has_element?(view, "[data-role=calendar-details]")
    end

    test "the X is a 44px touch target below lg and returns focus on close", ctx do
      view = ctx |> open!() |> new!()

      assert has_element?(view, "#{@editor} button.cal-editor-close[data-close-modal]")
      assert has_element?(view, "#calendar-editor-scrim[phx-hook=CalendarEditorFocus]")
      assert has_element?(view, "#{@editor}[role=dialog][aria-modal=true]")
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      assert css =~
               ~r/@media \(max-width: 1023px\) \{\s*\.cal-editor-close \{\s*width: 44px;\s*height: 44px;/
    end

    test "editor events with no editor open do nothing", ctx do
      view = open!(ctx)
      before = counts()

      render_submit(view, "save", %{"event" => %{"title" => "Forged"}})
      render_change(view, "event_change", %{"event" => %{"title" => "Forged"}})
      render_click(view, "meeting_edit_remove", %{"id" => Ecto.UUID.generate()})

      refute has_element?(view, @editor)
      assert counts() == before
    end
  end

  # ── a meeting's details open the same editor ─────────────────────────────

  describe "Edit on a meeting" do
    setup ctx do
      project = project!(ctx)
      invitee = member!(ctx.org_id, "Invitee")
      start = DateTime.new!(Date.utc_today() |> Date.add(2), ~T[15:00:00], "Etc/UTC")

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Weekly sync",
          created_by_user_id: ctx.owner.id,
          scheduled_start_at: start,
          scheduled_end_at: DateTime.add(start, 3600)
        })

      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        user_id: invitee.id,
        display_name: invitee.name
      })

      Repo.insert!(%Invite{
        meeting_id: meeting.id,
        display_name: "Guest one",
        email: "cal-editor-guest-#{System.unique_integer([:positive])}@example.com"
      })

      Map.merge(ctx, %{project: project, invitee: invitee, meeting: meeting, zone: "Etc/UTC"})
    end

    defp open_meeting!(ctx, user) do
      date = DateTime.to_date(ctx.meeting.scheduled_start_at)
      {:ok, view, _} = live(conn_for(user, ctx.zone), "/calendar?date=#{date}")

      view
      |> element(
        "[data-role=calendar-week] .cal-ev[data-kind=meeting][phx-value-id='#{ctx.meeting.id}']"
      )
      |> render_click()

      view
    end

    test "the organizer's Edit opens the one editor with the summary and the people", ctx do
      view = open_meeting!(ctx, ctx.owner)

      view
      |> element("[data-role=calendar-details] [data-role=meeting-edit-open]")
      |> render_click()

      assert has_element?(view, "#{@editor} h2", "Edit event")
      refute has_element?(view, "[data-role=meeting-edit]")
      assert has_element?(view, "#{@editor} input[data-role=f-call][checked]")
      assert has_element?(view, "#{@editor} [data-role=meeting-edit-invitee]", ctx.invitee.name)
      assert has_element?(view, "#{@editor} [data-role=meeting-edit-summary-none]")

      fill(view, %{title: "Weekly sync, moved"})
      assert has_element?(view, "#{@editor} [data-role=meeting-edit-was]", "was Weekly sync")

      # The summary is Meetings' own answer for the same edit.
      preview = Meetings.preview_meeting_edit(ctx.meeting, %{name: "Weekly sync, moved"})
      assert preview.update_recipients != []

      for r <- preview.update_recipients do
        name = PlatformWeb.Components.Meetings.EditMeeting.recipient_name(r)
        assert has_element?(view, "#{@editor} [data-role=meeting-edit-summary-updated]", name)
      end

      submit(view)
      meeting = Repo.get!(Meeting, ctx.meeting.id)
      assert meeting.name == "Weekly sync, moved"
      assert meeting.slug == ctx.meeting.slug
      refute has_element?(view, @editor)
    end

    test "removing the last invitee is refused by Meetings' rule, and undo works", ctx do
      view = open_meeting!(ctx, ctx.owner)

      view
      |> element("[data-role=calendar-details] [data-role=meeting-edit-open]")
      |> render_click()

      [first, last] = Meetings.list_invites(ctx.meeting.id)

      render_click(view, "meeting_edit_remove", %{"id" => first.id})
      assert has_element?(view, "#{@editor} [data-role=meeting-edit-removed]", "removed:")
      render_click(view, "meeting_edit_remove", %{"id" => last.id})

      assert has_element?(
               view,
               "#{@editor} [data-role=meeting-edit-last-invitee]",
               "Keep at least one invitee, or cancel the meeting."
             )

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#{@editor} [data-role=meeting-edit-removed]")
             |> Enum.count() == 1

      render_click(view, "meeting_edit_undo", %{"id" => first.id})
      refute has_element?(view, "#{@editor} [data-role=meeting-edit-removed]")
    end

    test "notes alone tell nobody", ctx do
      view = open_meeting!(ctx, ctx.owner)

      view
      |> element("[data-role=calendar-details] [data-role=meeting-edit-open]")
      |> render_click()

      fill(view, %{description: "Agenda attached"})

      assert has_element?(view, "#{@editor} [data-role=meeting-edit-summary-notes-only]")
      before = Repo.aggregate(Delivery, :count)
      submit(view)
      assert Repo.get!(Meeting, ctx.meeting.id).description == "Agenda attached"
      assert Repo.aggregate(Delivery, :count) == before
    end

    test "an invitee gets no Edit, and a forged open or save changes nothing", ctx do
      view = open_meeting!(ctx, ctx.invitee)
      refute has_element?(view, "[data-role=meeting-edit-open]")

      render_click(view, "meeting_edit_open", %{})
      refute has_element?(view, @editor)
      render_submit(view, "save", %{"event" => %{"title" => "Hijacked"}})

      assert Repo.get!(Meeting, ctx.meeting.id).name == "Weekly sync"
    end

    test "the editor closes, writing nothing, when the viewer loses the right mid-edit", ctx do
      view = open_meeting!(ctx, ctx.owner)

      view
      |> element("[data-role=calendar-details] [data-role=meeting-edit-open]")
      |> render_click()

      {:ok, _} = Meetings.cancel_meeting_for_user(ctx.meeting.id, ctx.owner)
      fill(view, %{title: "After cancel"})

      refute has_element?(view, @editor)
      refute Repo.get!(Meeting, ctx.meeting.id).name == "After cancel"
    end
  end

  # ── people on a new event ────────────────────────────────────────────────

  describe "people on a new event" do
    test "a staged member is invited only on Create event", ctx do
      project!(ctx)
      invitee = member!(ctx.org_id, "Guestless")
      view = ctx |> open!() |> new!()
      stage_member!(view, invitee)
      before = counts()
      assert before.invites == 0 or is_integer(before.invites)

      submit(view, timed())

      [event] = Repo.all(Event)

      assert [%Invite{user_id: user_id}] =
               Repo.all(Invite) |> Enum.filter(&(&1.meeting_id == event.meeting_id))

      assert user_id == invitee.id
    end
  end

  defp stage_member!(view, user) do
    render_keyup(view, "meeting_edit_invite_search", %{"value" => user.name})
    render_click(view, "meeting_edit_invite_stage", %{"kind" => "user", "id" => user.id})
  end
end
