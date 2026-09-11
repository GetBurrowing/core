defmodule PlatformWeb.MeetingLiveMobileSheetsTest do
  @moduledoc """
  FE-17 stage 3 — below `lg` the call rail lives in a bottom sheet, and
  the SHUT sheet's handle carries the soonest candidate deadline.

  ## The trap these tests are written against

  A test that OPENS the sheet and then finds the countdown cannot fail for
  the defect this ticket exists to fix, which is that on a phone the
  30-second window was only drawn behind a closed surface. So the
  load-bearing tests here leave the sheet SHUT and read the deadline off
  the document as rendered.

  The desktop tests assert ABSENCE. A sheet that renders at every width
  passes "present at 390", and that is the tiny-dialog bug this codebase
  has already shipped once.

  Task: 01a07410 stage 3.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.GuestInvite
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.CallRailFrame

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mobile_sheets_#{n}@example.com",
        name: "Sheets Test User",
        oidc_sub: "oidc-mobile-sheets-#{n}"
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
        name: "Sheets Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Sheets Meeting #{n}",
        slug: "sheets-meeting-#{n}"
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

  # Armed `seconds` from now. A generous margin against the wall clock is
  # built into every assertion that reads the number back.
  defp armed_candidate!(meeting, seconds, attrs \\ %{}) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            transcript_chunk_id: Ecto.UUID.generate(),
            transcript_chunk_ids: [Ecto.UUID.generate()],
            state: :heard,
            outcome_kind: :task,
            acts_at: DateTime.add(DateTime.utc_now(), seconds, :second)
          },
          attrs
        )
      )

    candidate
  end

  defp mount(conn, meeting, query \\ "") do
    {:ok, view, html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true#{query}")
    {view, html}
  end

  # The `ViewportBreakpoint` hook's report, as the client would push it.
  defp report_viewport(view, below) do
    render_hook(view, "meeting_viewport", %{"below" => below})
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  defp attr(html, selector, name) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp text(html, selector) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  @sheet "#meeting-rail-sheet"
  @handle_row "#meeting-rail-sheet-handle[role='status']"
  @countdown "[data-role='meeting-sheet-handle-countdown']"

  setup %{conn: conn} do
    {conn, user} = authenticated_conn(conn)
    {:ok, conn: conn, user: user, meeting: meeting!(user)}
  end

  # ── (1) The shut sheet carries the deadline ───────────────────────────

  describe "the SHUT cards sheet with an armed candidate" do
    test "the document carries the remaining seconds on the handle without the sheet being opened",
         %{conn: conn, meeting: meeting} do
      candidate = armed_candidate!(meeting, 20)
      {view, _html} = mount(conn, meeting)

      html = report_viewport(view, true)

      # SHUT. This is the whole point: nothing below opens the sheet.
      assert attr(html, @sheet, "data-open") == ["false"]

      # The handle names the candidate and the server's deadline…
      assert attr(html, @countdown, "data-candidate-id") == [candidate.id]
      assert attr(html, @countdown, "data-acts-at") == [DateTime.to_iso8601(candidate.acts_at)]

      assert attr(html, @countdown, "data-warning-seconds") ==
               [Integer.to_string(Countdown.warning_seconds())]

      # …and the numeral is the server's remaining seconds, bare. Bounded
      # rather than exact: the wall clock moved between arming and render.
      remaining = html |> text("#{@countdown} [data-role='meeting-candidate-remaining']")
      assert remaining =~ ~r/^\d+$/
      assert String.to_integer(remaining) in 17..20

      # The drain is present and NOT in the warning state at 20s. Two-sided
      # with the test below, because "amber appears" passes on a handle
      # that is amber at every value.
      [fill_class] = attr(html, "#{@countdown} [data-role='meeting-candidate-drain']", "class")
      refute fill_class =~ "candidate-drain--warning"

      [numeral_class] =
        attr(html, "#{@countdown} [data-role='meeting-candidate-remaining']", "class")

      refute numeral_class =~ "candidate-count--warning"
      assert numeral_class =~ "sheet-handle__numeral"
    end

    test "inside the warning threshold the SHUT handle steps to the warning classes", %{
      conn: conn,
      meeting: meeting
    } do
      # Three seconds: inside `warning_seconds/0` (5) even after the wall
      # clock moves a little between arming and render.
      _candidate = armed_candidate!(meeting, 3)
      {view, _html} = mount(conn, meeting)

      html = report_viewport(view, true)

      assert attr(html, @sheet, "data-open") == ["false"]

      [fill_class] = attr(html, "#{@countdown} [data-role='meeting-candidate-drain']", "class")
      assert fill_class =~ "candidate-drain--warning"

      [numeral_class] =
        attr(html, "#{@countdown} [data-role='meeting-candidate-remaining']", "class")

      assert numeral_class =~ "candidate-count--warning"
    end

    test "the handle has its OWN heartbeat, because the rail's ticker only exists on the Canvas tab",
         %{conn: conn, meeting: meeting} do
      _candidate = armed_candidate!(meeting, 20)
      {view, _html} = mount(conn, meeting)

      # People tab, shut sheet: no candidate rail section is rendered, so
      # no `CandidateClock` exists to reach the handle from a wider root.
      # Stage 2's premise that one rail ticker drives the handle does not
      # hold here; the handle must tick itself.
      html = report_viewport(view, true)

      assert count(html, "[data-role='meeting-candidate-countdown-rail']") == 0
      assert attr(html, @countdown, "phx-hook") == ["SheetHandleClock"]
    end

    test "the shut sheet PEEKS only while a countdown is live", %{
      conn: conn,
      meeting: meeting
    } do
      {view, _html} = mount(conn, meeting)

      # No candidate: no peek, no handle, no spacer, and the bare grab bar
      # stays decorative — an empty sheet must be as invisible as any other.
      html = report_viewport(view, true)
      [class] = attr(html, @sheet, "class")
      refute class =~ "sheet-peek"
      assert count(html, @countdown) == 0
      assert count(html, "[data-role='meeting-sheet-peek-spacer']") == 0
      assert count(html, "#{@sheet} .sheet-handle[aria-hidden='true']") == 1

      # A candidate arrives (the board refetches on the broadcast).
      _candidate = armed_candidate!(meeting, 20)
      send(view.pid, {:candidate_event, %{meeting_id: meeting.id}})
      html = render(view)

      [class] = attr(html, @sheet, "class")
      assert class =~ "sheet-peek"
      assert count(html, @countdown) == 1

      # And the stage reserves the handle's height so the peek does not
      # paint over the control bar (measured at 390x844 before this
      # spacer existed). Same condition as the peek, both ways.
      assert count(html, "[data-role='meeting-sheet-peek-spacer']") == 1

      assert count(
               render_hook(view, "meeting_viewport", %{"below" => false}),
               "[data-role='meeting-sheet-peek-spacer']"
             ) == 0
    end
  end

  # ── (4) The accessible name states the deadline in words ──────────────

  describe "the handle's accessible name" do
    test "contains the remaining seconds, in words, on the role=status row", %{
      conn: conn,
      meeting: meeting
    } do
      candidate = armed_candidate!(meeting, 20)
      {view, _html} = mount(conn, meeting)

      html = report_viewport(view, true)

      [label] = attr(html, @handle_row, "aria-label")
      assert [_, n] = Regex.run(~r/^(\d+) seconds until a task is created$/, label)
      assert String.to_integer(n) in 17..20

      # The name is what the hook refreshes every second, from THIS
      # template — the same string, so the wording never changes under a
      # reader, only the number.
      assert attr(html, @countdown, "data-label-template") ==
               [CallRailFrame.label_template(candidate)]

      assert attr(html, @countdown, "data-label-target") == ["meeting-rail-sheet-handle"]

      # The visible parts are hidden from the accessibility tree: the row
      # is a live region and a digit re-announced every second is hostile.
      assert attr(html, "#{@countdown} [data-role='meeting-candidate-remaining']", "aria-hidden") ==
               ["true"]

      assert attr(html, "#{@countdown} .sheet-handle__track", "aria-hidden") == ["true"]
    end

    test "a canvas-kind candidate names a canvas, and one second is singular", %{
      meeting: _meeting
    } do
      assert CallRailFrame.accessible_name(%{outcome_kind: :artifact}, 12) ==
               "12 seconds until a canvas is created"

      assert CallRailFrame.accessible_name(%{outcome_kind: :task}, 1) ==
               "1 second until a task is created"

      assert CallRailFrame.accessible_name(%{outcome_kind: nil}, 4) ==
               "4 seconds until the soonest card acts"
    end

    test "when the sheet is OPEN the handle reverts to a plain grabber", %{
      conn: conn,
      meeting: meeting
    } do
      _candidate = armed_candidate!(meeting, 20)
      {view, _html} = mount(conn, meeting)
      _ = report_viewport(view, true)

      html = render_hook(view, "open_mobile_sheet", %{"sheet" => "cards"})

      assert attr(html, @sheet, "data-open") == ["true"]
      assert attr(html, @sheet, "data-sheet") == ["cards"]
      assert count(html, @countdown) == 0
      assert count(html, @handle_row) == 0
      assert count(html, "#{@sheet} .sheet-handle[aria-hidden='true']") == 1

      # The cards inside carry their own drains — the countdown did not
      # vanish, it moved to where the cards are.
      assert count(html, "#{@sheet} [data-role='meeting-candidate-countdown']") == 1
    end
  end

  # ── (2) Absent at desktop ─────────────────────────────────────────────

  describe "at a desktop viewport" do
    test "the sheet is ABSENT from the document and the rail is the in-flow column", %{
      conn: conn,
      meeting: meeting
    } do
      _candidate = armed_candidate!(meeting, 20)
      {view, html} = mount(conn, meeting)

      # Before any report — the default — and after an explicit "not below".
      for html <- [html, report_viewport(view, false)] do
        assert count(html, @sheet) == 0
        assert count(html, @countdown) == 0
        assert count(html, ".sheet-peek") == 0

        # ONE rail, in the column frame, hidden below `lg` and flex at it.
        assert count(html, "[data-pane='call-rail']") == 1
        assert attr(html, "[data-pane='call-rail']", "data-rail-frame") == ["column"]
        [class] = attr(html, "#meeting-call-rail-pane", "class")
        tokens = String.split(class)
        assert "hidden" in tokens
        assert "lg:flex" in tokens
        assert "lg:w-[312px]" in tokens
        # The retired right-drawer geometry is gone, not merely unused.
        refute "translate-x-full" in tokens
        refute "fixed" in tokens
      end
    end

    test "the sheet root ALSO carries the codebase's per-call-site width gate", %{
      conn: conn,
      meeting: meeting
    } do
      {view, _html} = mount(conn, meeting)
      html = report_viewport(view, true)

      # Belt and braces: the `:if` is the load-bearing gate, and the class
      # is the convention every other bottom sheet carries. Tokenised so
      # `lg:hidden` cannot be satisfied by `lg:hidden-something`.
      [class] = attr(html, @sheet, "class")
      assert "lg:hidden" in String.split(class)
    end
  end

  # ── (3) Present at 390 ────────────────────────────────────────────────

  describe "below lg" do
    test "the ONE rail moves inside the sheet — no second rail, no second chat mount", %{
      conn: conn,
      meeting: meeting
    } do
      {view, html} = mount(conn, meeting)

      assert count(html, "[id^='meeting-chat-panel']") == 1

      html = report_viewport(view, true)

      assert count(html, @sheet) == 1
      assert count(html, "[data-pane='call-rail']") == 1
      assert attr(html, "[data-pane='call-rail']", "data-rail-frame") == ["sheet"]
      assert count(html, "#{@sheet} #meeting-call-rail") == 1
      assert count(html, "#meeting-call-rail") == 1
      assert count(html, "[id^='meeting-chat-panel']") == 1
      assert count(html, "[data-role='meeting-transcript-wrap']") == 1

      # The sheet is `Sheet`, not a fourth bespoke overlay.
      assert attr(html, @sheet, "phx-hook") == ["Sheet"]
      assert attr(html, @sheet, "role") == ["dialog"]
      assert attr(html, @sheet, "data-on-close") == ["close_call_rail"]
    end

    test "cards, chat and invite are the three named states of the sheet", %{
      conn: conn,
      meeting: meeting
    } do
      {view, _html} = mount(conn, meeting)
      _ = report_viewport(view, true)

      for {sheet, tab, title} <- [
            {"cards", "canvas", "Cards"},
            {"chat", "chat", "Chat"},
            {"invite", "people", "People and invites"}
          ] do
        html = render_hook(view, "open_mobile_sheet", %{"sheet" => sheet})

        assert attr(html, @sheet, "data-open") == ["true"], "#{sheet} did not open"
        assert attr(html, @sheet, "data-sheet") == [sheet]
        assert attr(html, "#meeting-call-rail", "data-active-tab") == [tab]
        assert text(html, "#meeting-rail-sheet-title") == title
      end

      # The invite state is where the invite section lives.
      html = render_hook(view, "open_mobile_sheet", %{"sheet" => "invite"})
      assert count(html, "#{@sheet} [data-role='meeting-agent-invite']") == 1
    end

    test "the top-bar controls open the sheet, and its own close/backdrop shut it", %{
      conn: conn,
      meeting: meeting
    } do
      {view, _html} = mount(conn, meeting)
      _ = report_viewport(view, true)

      opened = view |> element("[data-role='call-rail-toggle']") |> render_click()
      assert attr(opened, @sheet, "data-open") == ["true"]
      assert attr(opened, @sheet, "data-sheet") == ["invite"]

      closed = view |> element("#{@sheet} .sheet-backdrop") |> render_click()
      assert attr(closed, @sheet, "data-open") == ["false"]

      opened = view |> element("[data-role='chat-panel-toggle']") |> render_click()
      assert attr(opened, @sheet, "data-open") == ["true"]
      assert attr(opened, @sheet, "data-sheet") == ["chat"]

      closed =
        view |> element("#{@sheet} .sheet-header button[aria-label='Close']") |> render_click()

      assert attr(closed, @sheet, "data-open") == ["false"]

      # `close_call_rail` closes; it never toggles a shut sheet open.
      assert attr(render_hook(view, "close_call_rail", %{}), @sheet, "data-open") == ["false"]
    end

    test "the guest surface gets the sheet too, with no shell chrome in the document", %{
      conn: conn
    } do
      n = System.unique_integer([:positive])

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Guest Sheets #{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Guest Sheets Meeting #{n}",
          slug: "guest-sheets-#{n}"
        })

      _candidate = armed_candidate!(meeting, 20)
      expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      token = GuestInvite.sign(meeting.slug, expires_at, "Jane Doe")

      # A guest is refused with the meeting-unavailable card when LiveKit
      # is not configured, and the test config leaves it unset — same
      # per-test toggle `meeting_live_guest_mount_test.exs` uses.
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

      {:ok, view, _html} =
        %{conn | host: "meet.localhost"} |> live("/#{meeting.slug}/#{token}")

      html = report_viewport(view, true)

      assert count(html, @sheet) == 1

      # The guest mount does not load the candidate board on first paint
      # (`seed_guest_shell_tree_assigns/2` predates the board and is not
      # this stage's to change); the broadcast that follows an arming does.
      # What THIS asserts is that the guest sheet carries the handle once
      # the board is populated.
      send(view.pid, {:candidate_event, %{meeting_id: meeting.id}})
      html = render(view)
      assert count(html, @countdown) == 1

      # The chrome-escape rule: a guest document never names the shell's
      # bottom nav. The peek offset lives in app.css for exactly this
      # reason.
      refute html =~ "bottom-nav"
    end
  end
end
