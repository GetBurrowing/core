defmodule PlatformWeb.MeetingLiveRecapTest do
  @moduledoc """
  FE-17 stage 6 — after LEAVING a call at 390px the viewer sees a recap:
  what the meeting was, how long it ran, who was in it, and what it
  produced.

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

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
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
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
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
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
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

      html = render_hook(view, "dismiss_call_recap", %{})
      assert count(html, @recap) == 0
    end

    test "is not rendered at a desktop viewport", %{conn: conn, meeting: meeting} do
      view = mount(conn, meeting)
      render_hook(view, "meeting_viewport", %{"below" => false})
      html = render_hook(view, "meeting_left", %{})

      assert count(html, @recap) == 0
    end

    test "on the shell surface the bottom padding clears the safe area and the bottom nav",
         %{conn: conn, meeting: meeting} do
      html = conn |> mount(meeting) |> leave_at_390()

      [class] = attr(html, @recap, "class")
      assert class =~ "env(safe-area-inset-bottom)"
      assert class =~ "var(--bottom-nav-height,0px)"
    end
  end
end
