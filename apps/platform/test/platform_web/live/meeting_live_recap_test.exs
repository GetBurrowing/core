defmodule PlatformWeb.MeetingLiveRecapTest do
  @moduledoc """
  FE-17 stage 6 — after LEAVING a call the viewer sees a recap: what the
  meeting was, how long it ran, who was in it, and what it produced. The
  recap now renders on desktop as well as at 390px (01a0691d, matching the
  prototype's `.after-screen`); the mobile takeover is unchanged and the
  desktop difference is a CSS-only centered `max-w-[880px]` panel.

  ## What the load-bearing tests are written against

    * The task-versus-canvas wording is read off the recap's OWN nodes
      (`call-recap-outcome-label`, `data-outcome-kind`), not off the
      document as a whole, because the candidate rail elsewhere in the
      same document already renders "Added to Canvas" and a whole-page
      `=~` would pass with the recap dropping every artifact outcome.
    * The empty state asserts a SENTENCE is present, not that a region
      is absent. A recap that rendered nothing for a call that produced
      nothing would pass an absence check and read as loading.

  Task: 01a07410 stage 6.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.{CompletionRun, Meeting, Participant, Room}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.CallRecap

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "recap_#{n}@example.com",
        name: "Recap Test User",
        oidc_sub: "oidc-recap-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp meeting!(user) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Recap Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Recap Meeting #{n}",
        slug: "recap-meeting-#{n}"
      })

    {:ok, _participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    meeting
  end

  defp candidate!(meeting, attrs) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            transcript_chunk_id: Ecto.UUID.generate(),
            transcript_chunk_ids: [Ecto.UUID.generate()],
            state: :heard,
            outcome_kind: :task
          },
          attrs
        )
      )

    candidate
  end

  defp mount(conn, meeting) do
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")
    view
  end

  # Report the phone viewport, then leave the call the way the client
  # does on RoomEvent.Disconnected. Returns the rendered document.
  defp leave_at_390(view) do
    render_hook(view, "meeting_viewport", %{"below" => true})
    render_hook(view, "meeting_left", %{})
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  defp attr(html, selector, name) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp texts(html, selector) do
    html
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  @recap "[data-role='call-recap']"
  @outcome "[data-role='call-recap-outcome']"
  @outcome_label "[data-role='call-recap-outcome-label']"
  @empty "[data-role='call-recap-empty']"

  setup %{conn: conn} do
    {conn, user} = authenticated_conn(conn)
    {:ok, conn: conn, user: user, meeting: meeting!(user)}
  end

  # ── What the call produced ────────────────────────────────────────────

  describe "a call that graduated two cards" do
    test "lists both, with the task-versus-canvas wording read off the recap's own rows",
         %{conn: conn, meeting: meeting} do
      task_id = Ecto.UUID.generate()
      canvas_id = Ecto.UUID.generate()

      task_card =
        candidate!(meeting, %{
          evidence_quote: "file the pricing objection",
          state: :acting,
          outcome_kind: :task,
          task_id: task_id
        })

      canvas_card =
        candidate!(meeting, %{
          evidence_quote: "sketch the new rail",
          state: :acting,
          outcome_kind: :artifact,
          canvas_id: canvas_id
        })

      html = conn |> mount(meeting) |> leave_at_390()

      assert count(html, @recap) == 1

      # Exactly the two rows, in board order, each naming what it became
      # with the words FE-11 put on the card — and the two answers are
      # different words, which is the whole distinction.
      assert attr(html, @outcome, "data-candidate-id") == [task_card.id, canvas_card.id]
      assert attr(html, @outcome, "data-outcome-kind") == ["TASK", "CANVAS"]
      assert texts(html, @outcome_label) == ["Added to Tasks", "Added to Canvas"]

      assert attr(html, "#{@outcome} [data-role='call-recap-outcome-link']", "href") ==
               ["/tasks/#{task_id}", "/canvases/#{canvas_id}"]

      # Both cards were produced, so the empty line must not also appear.
      assert count(html, @empty) == 0
    end

    test "an acting card with NO deliverable is not listed as produced",
         %{conn: conn, meeting: meeting} do
      candidate!(meeting, %{evidence_quote: "the mint that failed", state: :acting})

      landed =
        candidate!(meeting, %{
          evidence_quote: "the one that landed",
          state: :acting,
          task_id: Ecto.UUID.generate()
        })

      html = conn |> mount(meeting) |> leave_at_390()

      assert attr(html, @outcome, "data-candidate-id") == [landed.id]

      assert texts(html, "[data-role='call-recap-open']") == [
               "1 card was still open when you left."
             ]
    end
  end

  describe "a call that produced nothing" do
    test "says so in words rather than rendering a blank region", %{conn: conn, meeting: meeting} do
      html = conn |> mount(meeting) |> leave_at_390()

      assert count(html, @recap) == 1
      assert count(html, @outcome) == 0

      [line] = texts(html, @empty)
      assert line =~ "This call produced nothing"
      assert line =~ "nothing from it is still being captured"
    end
  end

  describe "a card closed without graduating" do
    test "renders its recorded reason rather than a blank", %{conn: conn, meeting: meeting} do
      vetoed =
        candidate!(meeting, %{
          evidence_quote: "rename the org",
          state: :closed,
          closed_reason: :vetoed
        })

      html = conn |> mount(meeting) |> leave_at_390()

      assert attr(html, "[data-role='call-recap-closed-card']", "data-candidate-id") == [
               vetoed.id
             ]

      assert texts(html, "[data-role='call-recap-closed-reason']") == ["Not taken up"]
      # Closed is not produced, and it is not nothing either.
      assert count(html, @outcome) == 0
      assert count(html, @empty) == 0
    end

    test "a closed row with no recorded reason says that, not an empty line" do
      assert CallRecap.closed_reason_line(%{closed_reason: nil}) == "Closed, reason not recorded"
    end
  end

  # ── The rest of the recap, and when it exists at all ──────────────────

  describe "the recap frame" do
    test "names the meeting, the duration and who was in it", %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)
      html = leave_at_390(view)

      assert texts(html, "[data-role='call-recap-name']") == [meeting.name]
      # Never started (`?no_autojoin=true`), so the honest answer is that
      # there is no start time — not a made-up zero.
      assert texts(html, "[data-role='call-recap-duration']") == ["Start time not recorded"]
      [roster] = texts(html, "[data-role='call-recap-roster']")
      assert roster =~ "Nobody else was recorded"
    end

    test "duration_label speaks in minutes and hours and never says 0 min" do
      t0 = ~U[2026-09-10 12:00:00Z]
      assert CallRecap.duration_label(nil, t0) == nil
      assert CallRecap.duration_label(t0, DateTime.add(t0, 40, :second)) == "Under a minute"
      assert CallRecap.duration_label(t0, DateTime.add(t0, 12 * 60, :second)) == "12 min"
      assert CallRecap.duration_label(t0, DateTime.add(t0, 60 * 60, :second)) == "1 hr"
      assert CallRecap.duration_label(t0, DateTime.add(t0, 65 * 60, :second)) == "1 hr 5 min"
    end

    test "is absent before leaving, and gone again after dismiss or rejoin",
         %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)

      html = render_hook(view, "meeting_viewport", %{"below" => true})
      assert count(html, @recap) == 0

      html = render_hook(view, "meeting_left", %{})
      assert count(html, @recap) == 1

      # Dismissing ends the visit on the Meetings index (task 01a18d0a
      # stage 3), so the recap is gone with the page.
      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               render_hook(view, "dismiss_call_recap", %{})
    end

    test "is rendered at a desktop viewport too (matches the prototype's .after-screen)",
         %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)
      render_hook(view, "meeting_viewport", %{"below" => false})
      html = render_hook(view, "meeting_left", %{})

      # The recap used to be gated on `@mobile_viewport?`; the sponsor
      # prototype shows it on desktop as well, so it renders on both
      # surfaces now. Its content is named the same as on mobile.
      assert count(html, @recap) == 1
      assert texts(html, "[data-role='call-recap-name']") == [meeting.name]

      # The desktop layout is CSS-only: the one panel node carries the
      # `lg:max-w-[880px]` centering that turns the mobile takeover into
      # the prototype's centered `.after-screen`, and the produced groups
      # sit in the `lg:grid-cols-2` two-column grid.
      assert count(html, "[data-role='call-recap-panel']") == 1
      [panel_class] = attr(html, "[data-role='call-recap-panel']", "class")
      assert panel_class =~ "lg:max-w-[880px]"

      # Dismiss still works from the desktop surface.
      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               render_hook(view, "dismiss_call_recap", %{})
    end

    test "on the shell surface the bottom padding clears the safe area and the bottom nav",
         %{conn: conn, meeting: meeting} do
      html = conn |> mount(meeting) |> leave_at_390()

      [class] = attr(html, @recap, "class")
      assert class =~ "env(safe-area-inset-bottom)"
      assert class =~ "var(--bottom-nav-height,0px)"
    end
  end

  # ── Leaving ends on the Meetings index (task 01a18d0a stage 3) ────────
  #
  # The after-action report stays up until its own close control is used,
  # then the visit ends on the canonical `/meetings` index. It never sends
  # the viewer back to the meeting they just left, and nothing navigates on
  # a timer.

  describe "closing the after-action report" do
    setup %{user: user} do
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn ->
        Application.put_env(:platform, :livekit, original)
        Platform.Meetings.State.broadcast_left(user.id)
      end)

      :ok
    end

    test "join, leave, read the report, close it: lands on /meetings and never returns",
         %{conn: conn, user: user, meeting: meeting} do
      # Another participant is in the call; this viewer leaving must not
      # take them out of it.
      other = other_user!()
      {:ok, _} = Meetings.join_for_user(meeting.chat_space_id, other.id, other.name)

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}")
      view |> element(~s([data-role="meeting-join"])) |> render_click()
      assert_push_event(view, "join-meeting", %{token: _})

      html = view |> element(~s([data-role="meeting-leave"])) |> render_click()
      assert count(html, @recap) == 1
      assert_push_event(view, "leave-meeting", %{})

      # The report is held until it is closed: no timer, no early redirect.
      Process.sleep(100)
      assert count(render(view), @recap) == 1

      view |> element(~s([data-role="call-recap-dismiss"])) |> render_click()
      assert {path, _flash} = assert_redirect(view)
      assert path == "/meetings"

      # The index renders, and is the index rather than the departed room.
      {:ok, index, _} = live(conn, path)
      refute has_element?(index, ~s([data-role="call-recap"]))
      refute has_element?(index, ~s([data-role="meeting-join"]))
      refute_redirected(index, "/meetings/#{meeting.slug}")

      # This viewer is out of the call; the other participant is still in.
      assert active?(meeting, other.id)
      refute active?(meeting, user.id)
      assert Platform.Meetings.State.get_for_user(user.id) == nil
      assert Repo.get!(Meeting, meeting.id).status == "live"
    end

    test "a redundant meeting_left keeps the first report and closes once",
         %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}")
      view |> element(~s([data-role="meeting-join"])) |> render_click()

      # The button's leave, then the client's RoomEvent.Disconnected
      # acknowledgement, then a stray duplicate of it.
      view |> element(~s([data-role="meeting-leave"])) |> render_click()
      first = :sys.get_state(view.pid).socket.assigns.call_recap
      assert %{left_at: %DateTime{}} = first

      render_hook(view, "meeting_left", %{})
      html = render_hook(view, "meeting_left", %{})

      assert count(html, @recap) == 1
      assert :sys.get_state(view.pid).socket.assigns.call_recap == first

      # Nothing has navigated yet.
      assert render(view) =~ ~s(data-role="call-recap")

      assert {:error, {:live_redirect, %{to: "/meetings"}}} =
               render_hook(view, "dismiss_call_recap", %{})
    end

    test "a close with no report showing does not navigate", %{conn: conn, meeting: meeting} do
      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}")

      html = render_hook(view, "dismiss_call_recap", %{})
      assert html =~ ~s(data-role="meeting-join")
      refute_redirected(view, "/meetings")
    end

    test "reopening the ended meeting after the report does not join or reopen its filed run",
         %{conn: conn, user: user, meeting: meeting} do
      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}")
      view |> element(~s([data-role="meeting-join"])) |> render_click()
      view |> element(~s([data-role="meeting-leave"])) |> render_click()
      view |> element(~s([data-role="call-recap-dismiss"])) |> render_click()
      assert_redirect(view, "/meetings")

      {:ok, ended} = Meetings.end_meeting(Repo.get!(Meeting, meeting.id))
      runs_before = Repo.all(from(r in CompletionRun, where: r.meeting_id == ^ended.id))

      {:ok, reopened, _html} = live(conn, "/meetings/#{meeting.slug}")
      render(reopened)

      assert has_element?(reopened, ~s([data-role="meeting-join"]))
      refute_push_event(reopened, "join-meeting", %{}, 50)
      refute :sys.get_state(reopened.pid).socket.assigns.in_meeting
      assert Repo.get!(Meeting, meeting.id).status == "ended"
      refute active?(meeting, user.id)
      assert Repo.all(from(r in CompletionRun, where: r.meeting_id == ^ended.id)) == runs_before
    end
  end

  defp other_user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "recap_other_#{n}@example.com",
        name: "Recap Other #{n}",
        oidc_sub: "oidc-recap-other-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp active?(meeting, user_id) do
    Repo.exists?(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.room_id,
        where:
          r.space_id == ^meeting.chat_space_id and p.user_id == ^user_id and
            is_nil(p.left_at)
      )
    )
  end
end
