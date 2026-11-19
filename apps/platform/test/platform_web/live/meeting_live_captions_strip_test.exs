defmodule PlatformWeb.MeetingLiveCaptionsStripTest do
  @moduledoc """
  Task 01a1eb27 stage 3: the docked captions strip.

  The caption bar used to be a `fixed … z-40` overlay that floated over the
  video and covered faces. It is now an in-flow row of
  `<main data-role="call-stage">`, directly above the stage controls, in
  every stage mode, so the stage body shrinks to make room. It carries the
  `#meeting-captions` hook host on the left and "just you" · "Transcript"
  on the right.

  `async: false` because the setup `put_env`s the global `:livekit` config
  so the auto-join reaches `:in_meeting=true` (the CC button is gated on it).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @shell_in_stage ~s([data-role="call-stage"] [data-role="meeting-captions-shell"])
  @shell ~s([data-role="meeting-captions-shell"])
  @pulse ~s([data-role="meeting-captions-pulse"])
  @toggle ~s([data-role="meeting-captions-toggle"])
  @modes ~w(gallery screen canvas whiteboard)

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "captions_strip_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-captions-strip-#{n}"
    })
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Captions Strip Space #{n}",
        slug: "captions-strip-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Captions Strip Project #{n}",
        slug: "captions-strip-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "captions-strip-#{n}",
        name: "Captions Strip",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    {meeting, space, room}
  end

  # The stage spec's shape: nil FKs, identity "meeting-transcriber".
  defp transcriber!(room, identity \\ "meeting-transcriber") do
    {:ok, row} = Meetings.upsert_live_participant(room, %{identity: identity, name: identity})
    row
  end

  defp viewer_conn(conn, space) do
    viewer = user!("Captions Viewer")

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: viewer.id,
        display_name: "Captions Viewer",
        joined_at: DateTime.utc_now()
      })

    init_test_session(conn, current_user_id: viewer.id)
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

  # `LazyHTML.query/2` descends the whole tree; never `filter/2`, which
  # matches only the fragment's root nodes and would read as "absent".
  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp shell_classes(html) do
    case html |> query(@shell) |> LazyHTML.attribute("class") do
      [class] -> String.split(class)
      other -> flunk("expected exactly one #{@shell}, got #{inspect(other)}")
    end
  end

  setup %{conn: conn} do
    put_livekit_env()
    {meeting, space, room} = meeting!()
    _transcriber = transcriber!(room)
    %{conn: viewer_conn(conn, space), meeting: meeting, space: space, room: room}
  end

  test "with captions on, the strip is docked inside call-stage in every stage mode", %{
    conn: conn,
    meeting: meeting
  } do
    view = joined_view(conn, meeting)
    view |> element(@toggle) |> render_click()

    for mode <- @modes do
      html = render_click(view, "set_stage_mode", %{"mode" => mode})

      assert :sys.get_state(view.pid).socket.assigns.current_stage_mode ==
               String.to_existing_atom(mode)

      assert has_element?(view, @shell_in_stage), "no docked strip in #{mode}"
      assert has_element?(view, ~s(#{@shell}[data-stage-mode="#{mode}"]))

      # In flow, not an overlay: no positioning or stacking classes at all.
      classes = shell_classes(html)
      refute "fixed" in classes, "#{mode}: #{inspect(classes)}"
      refute "z-40" in classes, "#{mode}: #{inspect(classes)}"
      refute "absolute" in classes, "#{mode}: #{inspect(classes)}"

      refute Enum.any?(classes, &String.starts_with?(&1, "bottom-")),
             "#{mode}: #{inspect(classes)}"

      refute Enum.any?(classes, &(&1 =~ "safe-area-inset-bottom")), "#{mode}: #{inspect(classes)}"

      # Tokens: base-200 ground, edge border, never primary/error/viewer.
      assert "bg-base-200" in classes
      assert "border-edge" in classes
      assert "shrink-0" in classes
      refute Enum.any?(classes, &(&1 =~ ~r/primary|error|viewer/))

      # The hook host stays the stable `phx-update="ignore"` child.
      assert has_element?(
               view,
               ~s(#{@shell_in_stage} #meeting-captions[phx-hook="MeetingCaptions"][phx-update="ignore"][aria-live="polite"])
             )

      # Right side: "just you" in subtle, and the Transcript link.
      assert has_element?(
               view,
               ~s(#{@shell} [data-role="meeting-captions-just-you"].text-subtle),
               "just you"
             )

      assert has_element?(
               view,
               ~s(#{@shell} a[data-role="meeting-captions-transcript-link"][href$="?tab=transcript"]),
               "Transcript"
             )
    end
  end

  test "the strip sits directly above the stage controls, inside the same column", %{
    conn: conn,
    meeting: meeting
  } do
    view = joined_view(conn, meeting)
    view |> element(@toggle) |> render_click()

    # `+` is the adjacent-sibling combinator: the controls immediately
    # follow the strip. The one element allowed between them is the device
    # panel's hook root (task 01a1f4c5): a `display: contents` wrapper whose
    # only in-flow child is the device-switched notice slot, empty (and
    # sr-only) unless a device was just lost, so the strip still sits
    # directly on the controls.
    assert has_element?(
             view,
             ~s([data-role="call-stage"] > [data-role="meeting-captions-shell"] + [data-role="meeting-devices"].contents + [data-role="meeting-stage-controls"])
           )
  end

  test "the Transcript link opens the rail's Transcript tab", %{conn: conn, meeting: meeting} do
    view = joined_view(conn, meeting)
    view |> element(@toggle) |> render_click()

    view |> element(~s([data-role="meeting-captions-transcript-link"])) |> render_click()
    assert_patch(view, ~p"/meetings/#{meeting.slug}?tab=transcript")
    assert :sys.get_state(view.pid).socket.assigns.active_meeting_tab == "transcript"
  end

  test "with captions off the strip is absent while the pulse is still present", %{
    conn: conn,
    meeting: meeting
  } do
    view = joined_view(conn, meeting)

    refute has_element?(view, @shell)
    assert has_element?(view, @pulse)

    view |> element(@toggle) |> render_click()
    assert has_element?(view, @shell_in_stage)

    view |> element(@toggle) |> render_click()
    refute has_element?(view, @shell)
    assert has_element?(view, @pulse)
  end
end
