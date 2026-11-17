defmodule PlatformWeb.MeetingLiveCaptionsPulseTest do
  @moduledoc """
  Task 01a1eb27 stage 1: "captions off with a pulse".

  The transcriber is auto-dispatched by LiveKit at room creation, so the CC
  button cannot start or stop it. It only tells the truth about it: a
  `bg-info` pulse dot, `[data-role=meeting-captions-pulse]`, shown iff a
  transcriber row is active, whether the viewer's captions are on or off.
  `:transcription_started_at` is the earliest `joined_at` among the active
  transcriber rows and clears to nil with the pill when the row leaves.

  `async: false` because the setup `put_env`s the global `:livekit` config
  so the auto-join reaches `:in_meeting=true` (the CC button is gated on it).
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.Accounts.User
  alias Platform.Meetings.{Meeting, Participant}
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @pulse ~s([data-role="meeting-captions-pulse"])
  @toggle ~s([data-role="meeting-captions-toggle"])

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "captions_pulse_#{n}@example.com",
      name: name,
      oidc_sub: "oidc-captions-pulse-#{n}"
    })
  end

  defp meeting! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Captions Pulse Space #{n}",
        slug: "captions-pulse-space-#{n}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Captions Pulse Project #{n}",
        slug: "captions-pulse-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "captions-pulse-#{n}",
        name: "Captions Pulse",
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

  defp set_joined_at!(%Participant{id: id}, %DateTime{} = at) do
    from(p in Participant, where: p.id == ^id) |> Repo.update_all(set: [joined_at: at])
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

  defp attr(html, selector, name) do
    case html |> query(selector) |> LazyHTML.attribute(name) do
      [value] -> value
      other -> flunk("expected exactly one #{selector}, got #{inspect(other)}")
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  setup %{conn: conn} do
    put_livekit_env()
    {meeting, space, room} = meeting!()
    %{conn: viewer_conn(conn, space), meeting: meeting, space: space, room: room}
  end

  # ── (a) present: pulse shows with captions OFF and survives toggles ─────

  describe "with an active transcriber row" do
    setup %{room: room} do
      %{transcriber: transcriber!(room)}
    end

    test "(a) the pulse shows with captions off and stays through two toggles", %{
      conn: conn,
      meeting: meeting
    } do
      view = joined_view(conn, meeting)
      html = render(view)

      assert attr(html, @toggle, "data-active") == "false"
      assert has_element?(view, @pulse)

      # The dot is the canvas's `info` state, a decorative icon, and breathes
      # only under motion-safe (solid under reduced motion).
      classes = html |> attr(@pulse, "class") |> String.split()
      assert "bg-info" in classes
      assert "motion-safe:animate-pulse" in classes
      refute "animate-pulse" in classes
      refute Enum.any?(classes, &(&1 =~ ~r/primary|error/))
      assert attr(html, @pulse, "aria-hidden") == "true"

      # Screen readers learn the state from the label instead.
      assert attr(html, @toggle, "aria-label") == "Show captions (meeting is being transcribed)"
      assert attr(html, @toggle, "title") == "Show captions (meeting is being transcribed)"

      html = view |> element(@toggle) |> render_click()
      assert attr(html, @toggle, "data-active") == "true"
      assert attr(html, @toggle, "aria-pressed") == "true"
      assert attr(html, @toggle, "aria-label") == "Hide captions (meeting is being transcribed)"
      assert has_element?(view, @pulse)

      html = view |> element(@toggle) |> render_click()
      assert attr(html, @toggle, "data-active") == "false"
      assert has_element?(view, @pulse)
      assert assigns(view).transcriber_present? == true
    end

    test "(c) the pulse disappears and started_at clears when the row leaves", %{
      conn: conn,
      meeting: meeting,
      room: room
    } do
      view = joined_view(conn, meeting)
      assert has_element?(view, @pulse)
      assert %DateTime{} = assigns(view).transcription_started_at

      Meetings.mark_live_participant_left(room, %{
        identity: "meeting-transcriber",
        name: "meeting-transcriber"
      })

      send(view.pid, {:meeting_presence_update, %{}})
      html = render(view)

      refute has_element?(view, @pulse)
      assert assigns(view).transcriber_present? == false
      assert assigns(view).transcription_started_at == nil
      assert attr(html, @toggle, "aria-label") == "Show captions"
    end
  end

  # ── (b) absent ──────────────────────────────────────────────────────────

  test "(b) without a transcriber row there is no pulse and the label is unchanged", %{
    conn: conn,
    meeting: meeting
  } do
    view = joined_view(conn, meeting)
    html = render(view)

    assert has_element?(view, @toggle)
    refute has_element?(view, @pulse)
    assert assigns(view).transcription_started_at == nil
    assert attr(html, @toggle, "aria-label") == "Show captions"
    assert attr(html, @toggle, "title") == "Show captions"

    view |> element(@toggle) |> render_click()
    refute has_element?(view, @pulse)
  end

  # ── (d) Meetings.transcription_started_at/1 ─────────────────────────────

  describe "Meetings.transcription_started_at/1" do
    test "(d) is the earliest joined_at among ACTIVE transcriber rows only", %{
      space: space,
      room: room
    } do
      assert Meetings.transcription_started_at(space.id) == nil

      t0 = ~U[2026-11-17 09:00:00.000000Z]

      # A human who joined first never counts: they have a user FK.
      human = user!("Early Human")

      {:ok, human_row} =
        Meetings.upsert_live_participant(room, %{identity: "user:#{human.id}", name: "Early"})

      set_joined_at!(human_row, DateTime.add(t0, -600, :second))

      # A transcriber that joined even earlier but has LEFT never counts.
      gone = transcriber!(room, "transcriber:space-gone")
      set_joined_at!(gone, DateTime.add(t0, -300, :second))
      Meetings.mark_live_participant_left(room, %{identity: "transcriber:space-gone", name: "x"})

      later = transcriber!(room, "meeting-transcriber")
      set_joined_at!(later, DateTime.add(t0, 120, :second))
      earliest = transcriber!(room, "transcriber:space-#{space.id}")
      set_joined_at!(earliest, t0)

      assert DateTime.compare(Meetings.transcription_started_at(space.id), t0) == :eq
    end

    test "is nil for a non-binary space id and for an empty row list" do
      assert Meetings.transcription_started_at(nil) == nil
      assert Meetings.earliest_joined_at([]) == nil
    end
  end
end
