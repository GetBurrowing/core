defmodule PlatformWeb.MeetingLiveCaptionsMenuTest do
  @moduledoc """
  Task 01a1eb27 stage 2: the CC chevron menu.

  The CC button still toggles captions in one click. The chevron beside it
  opens two labelled rows: "Captions (just for you)", a switch on the
  existing `toggle_captions_meeting` event, and "Transcription (for the
  meeting record)", read-only state for EVERY viewer because nobody can start
  or stop the transcriber. Desktop renders a dropdown; phones render the same
  rows inside `#meeting-captions-sheet`.

  `async: false` because the setup `put_env`s the global `:livekit` config so
  the auto-join reaches `:in_meeting=true` (the CC slot is gated on it).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @chevron ~s([data-role="meeting-captions-menu-toggle"])
  @menu ~s([data-role="meeting-captions-menu"])
  @captions_row ~s([data-role="meeting-captions-menu"] [data-role="meeting-captions-row"])
  @transcription_row ~s([data-role="meeting-captions-menu"] [data-role="meeting-transcription-row"])
  @switch ~s([data-role="meeting-captions-row"] input[role="switch"])
  @started_at ~s([data-role="meeting-transcription-started-at"])
  @toggle ~s([data-role="meeting-captions-toggle"])
  @pulse ~s([data-role="meeting-captions-pulse"])

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "captions_menu_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-captions-menu-#{n}"
    })
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Captions Menu Space #{n}",
        slug: "captions-menu-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Captions Menu Project #{n}",
        slug: "captions-menu-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "captions-menu-#{n}",
        name: "Captions Menu",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  defp transcriber!(room) do
    {:ok, row} =
      Meetings.upsert_live_participant(room, %{
        identity: "meeting-transcriber",
        name: "meeting-transcriber"
      })

    row
  end

  defp viewer!(space, name) do
    viewer = user!(name)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: viewer.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    {viewer, participant}
  end

  defp put_livekit_env do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp joined_view(conn, meeting) do
    {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
    view |> element(~s([data-role="meeting-join"])) |> render_click()
    assert_push_event(view, "join-meeting", %{token: _, url: _, room_name: _})
    view
  end

  defp open_menu(view), do: view |> element(@chevron) |> render_click()

  # `LazyHTML.query/2` descends the whole tree; never `filter/2`, which
  # matches only the fragment's root nodes and would read as "absent".
  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp text(html, selector) do
    html
    |> query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup %{conn: conn} do
    put_livekit_env()
    {meeting, space, room} = meeting!()
    {viewer, _participant} = viewer!(space, "Captions Viewer")

    %{
      conn: init_test_session(conn, current_user_id: viewer.id),
      meeting: meeting,
      space: space,
      room: room
    }
  end

  # ── Opening the menu ────────────────────────────────────────────────────

  describe "with an active transcriber row" do
    setup %{room: room}, do: %{transcriber: transcriber!(room)}

    test "the chevron opens a menu with both rows and the verbatim labels", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)

      assert has_element?(view, ~s(#{@chevron}[aria-haspopup="menu"][aria-expanded="false"]))
      refute has_element?(view, @menu)

      html = open_menu(view)

      assert has_element?(view, ~s(#{@chevron}[aria-expanded="true"]))
      assert has_element?(view, @menu)
      refute has_element?(view, "#meeting-captions-sheet")
      assert has_element?(view, @captions_row, "Captions (just for you)")

      assert has_element?(
               view,
               @captions_row,
               "Only you see captions. Turning them off doesn't stop transcription."
             )

      assert has_element?(view, ~s(#{@transcription_row}[data-readonly="true"]))
      assert has_element?(view, @transcription_row, "Transcription (for the meeting record)")

      assert has_element?(
               view,
               @transcription_row,
               "Visible to: everyone who can open this meeting"
             )

      # The menu surface is the binding token set, never a translucent
      # base-content or an action/alarm colour.
      [menu_class] = html |> query(@menu) |> LazyHTML.attribute("class")
      assert "bg-base-100" in String.split(menu_class)
      assert "border-edge" in String.split(menu_class)
      refute menu_class =~ ~r/primary|error|text-base-content\//

      # The CC button still toggles captions in one click, menu or not.
      view |> element(@toggle) |> render_click()
      assert has_element?(view, ~s(#{@toggle}[data-active="true"]))

      # Close event (Escape / click-away / backdrop all fire it).
      render_click(view, "close_captions_menu", %{})
      refute has_element?(view, @menu)
    end

    test "the transcription row reads On with a mono started-at timestamp", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)
      html = open_menu(view)

      assert has_element?(view, @transcription_row, "On · started automatically")
      assert has_element?(view, "#{@transcription_row} #{@started_at}")

      started = assigns(view).transcription_started_at
      assert %DateTime{} = started

      [datetime] = html |> query(@started_at) |> LazyHTML.attribute("datetime")
      assert datetime == DateTime.to_iso8601(started)
      assert text(html, @started_at) == Calendar.strftime(started, "%H:%M")

      [class] = html |> query(@started_at) |> LazyHTML.attribute("class")
      assert "font-mono" in String.split(class)
      refute has_element?(view, @transcription_row, "Off")
    end

    test "toggling the Captions row flips the CC button and persists, pulse untouched", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)
      open_menu(view)

      assert has_element?(view, ~s(#{@switch}[aria-checked="false"]))
      assert has_element?(view, ~s(#{@toggle}[data-active="false"]))

      view |> element(@switch) |> render_click()

      assert has_element?(view, ~s(#{@toggle}[data-active="true"]))
      assert has_element?(view, ~s(#{@switch}[aria-checked="true"]))
      assert_push_event(view, "meeting_captions_persist", %{visible: true})
      assert has_element?(view, @pulse)
      assert assigns(view).transcriber_present? == true

      view |> element(@switch) |> render_click()

      assert has_element?(view, ~s(#{@toggle}[data-active="false"]))
      assert_push_event(view, "meeting_captions_persist", %{visible: false})
      assert has_element?(view, @pulse)
      assert assigns(view).transcriber_present? == true
    end

    test "the transcription row has no button, input or phx-click for a non-host", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)
      open_menu(view)

      assert_transcription_row_read_only(view)
    end

    test "the transcription row has no button, input or phx-click for the host", %{
      conn: conn,
      meeting: meeting,
      space: space
    } do
      {host, host_participant} = viewer!(space, "Captions Host")

      meeting
      |> Ecto.Changeset.change(host_participant_id: host_participant.id)
      |> Repo.update!()

      view = joined_view(init_test_session(conn, current_user_id: host.id), meeting)

      assert PlatformWeb.MeetingLive.host?(
               assigns(view).current_participant,
               assigns(view).meeting
             )

      open_menu(view)

      assert_transcription_row_read_only(view)
    end

    test "on phones the menu renders inside #meeting-captions-sheet", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)
      render_hook(view, "meeting_viewport", %{"below" => true})

      assert has_element?(view, ~s(#meeting-captions-sheet[data-open="false"]))
      open_menu(view)

      assert has_element?(view, ~s(#meeting-captions-sheet[data-open="true"]))
      assert has_element?(view, "#meeting-captions-sheet #{@captions_row}")
      assert has_element?(view, "#meeting-captions-sheet #{@transcription_row}")
      assert has_element?(view, "#meeting-captions-sheet #{@started_at}")

      # Exactly one menu: the desktop dropdown is not rendered on a phone.
      html = render(view)
      assert html |> query(@menu) |> Enum.count() == 1

      render_click(view, "close_captions_menu", %{})
      assert has_element?(view, ~s(#meeting-captions-sheet[data-open="false"]))
    end
  end

  test "without a transcriber the transcription row reads Off", %{conn: conn, meeting: meeting} do
    view = joined_view(conn, meeting)
    open_menu(view)

    assert has_element?(view, @transcription_row, "Off")
    refute has_element?(view, @transcription_row, "On · started automatically")
    refute has_element?(view, @started_at)
    assert_transcription_row_read_only(view)
  end

  defp assert_transcription_row_read_only(view) do
    assert has_element?(view, @transcription_row)
    refute has_element?(view, "#{@transcription_row} button")
    refute has_element?(view, "#{@transcription_row} input")
    refute has_element?(view, "#{@transcription_row} [phx-click]")
    refute has_element?(view, "#{@transcription_row}[phx-click]")
  end
end
