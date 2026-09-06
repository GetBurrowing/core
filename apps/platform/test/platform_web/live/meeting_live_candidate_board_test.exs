defmodule PlatformWeb.MeetingLiveCandidateBoardTest do
  @moduledoc """
  The live meeting task board (task 01a03f4e-78b1).

  Every assertion here goes through a MOUNTED LiveView on the real
  route, never through a bare component render: the claim the ticket
  makes is about what a participant sees on the meeting page, and a
  component that renders correctly while nothing passes it the right
  assigns is the failure this whole board replaces.

  ## The trap these tests are written against

  Asserting that an element renders proves nothing about whether it
  renders the RIGHT thing. The rail this board replaces would have
  passed "a card appears" — it appeared, as a list row, identical for
  every candidate. So every test below does two things:

    * asserts on a VALUE — this candidate's quote under this
      candidate's id, this stage's slug on this stage's card — rather
      than on presence, and
    * carries a case that must NOT render it: a second candidate in a
      different state, a card from a different meeting, a closed card
      that must not be in the live list.

  A single-card fixture cannot distinguish "renders the candidate" from
  "renders a candidate", so where the distinction matters the fixture
  has two.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "candidate_board_#{n}@example.com",
        name: "Board Test User",
        oidc_sub: "oidc-candidate-board-#{n}"
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
        name: "Board Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Board Meeting #{n}",
        slug: "board-meeting-#{n}"
      })

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {meeting, participant}
  end

  # `acts_at` is passed EXPLICITLY on every fixture, including as `nil`.
  # `Candidates.create/1` otherwise arms the row from the meeting's
  # automation mode, so a test that meant "this card is in review mode"
  # would silently get an armed one and pass for the wrong reason.
  defp candidate!(meeting, attrs) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            transcript_chunk_id: Ecto.UUID.generate(),
            transcript_chunk_ids: [Ecto.UUID.generate()],
            state: :heard,
            acts_at: nil
          },
          attrs
        )
      )

    candidate
  end

  defp mount_board(conn, meeting) do
    {:ok, view, html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")
    {view, html}
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp cards(html), do: html |> doc() |> LazyHTML.query("[data-role='meeting-candidate-card']")

  defp card(html, %MeetingCandidate{id: id}) do
    html
    |> doc()
    |> LazyHTML.query("[data-role='meeting-candidate-card'][data-candidate-id='#{id}']")
  end

  defp closed_card(html, %MeetingCandidate{id: id}) do
    html
    |> doc()
    |> LazyHTML.query("[data-role='meeting-candidate-closed-card'][data-candidate-id='#{id}']")
  end

  # The rail's own markup, so a `refute ... =~` is a statement about
  # THIS component and cannot be defeated (or accidentally satisfied) by
  # a string somewhere else on a large meeting page.
  defp rail_html(html) do
    html
    |> doc()
    |> LazyHTML.query("[data-role='meeting-candidate-countdown-rail']")
    |> LazyHTML.to_html()
  end

  defp attr(nodes, name), do: nodes |> LazyHTML.attribute(name) |> List.first()

  defp text_of(nodes, selector) do
    nodes |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp present?(nodes, selector), do: nodes |> LazyHTML.query(selector) |> Enum.any?()

  setup %{conn: conn} do
    {conn, user} = authenticated_conn(conn)
    {meeting, participant} = meeting!(user)
    %{conn: conn, user: user, meeting: meeting, participant: participant}
  end

  # ── 1. Cards, one per live candidate, each carrying its OWN text ──────

  describe "the board renders a card per live candidate" do
    test "three candidates, three cards, each with its own quote under its own id",
         %{conn: conn, meeting: meeting, user: user} do
      heard = candidate!(meeting, %{evidence_quote: "we should add a CSV export"})

      forming =
        candidate!(meeting, %{
          evidence_quote: "somebody rewrite the pricing copy",
          state: :thinking,
          classified_intent: "action_item"
        })

      shaping =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item",
          assigned_agent_slug: "octavius"
        })

      # A card in ANOTHER meeting, which must not reach this board. Its
      # quote is deliberately unlike the three above so a substring
      # match cannot pass by accident.
      {other, _} = meeting!(user)
      _theirs = candidate!(other, %{evidence_quote: "book the offsite venue"})

      # DB positive control BEFORE rendering: if this is not 3, a
      # count of 3 in the DOM would be measuring the wrong thing.
      assert length(Candidates.list_for_meeting(meeting.id)) == 3

      {_view, html} = mount_board(conn, meeting)

      assert length(LazyHTML.attribute(cards(html), "data-candidate-id")) == 3

      # Each quote under its OWN card, not merely somewhere on the page.
      # Read from the QUOTE element at every state — the title now
      # carries the classified intent, and the verbatim span is the one
      # thing every card shows (task 01a05b14 stage 4).
      assert present?(card(html, heard), "[data-role='meeting-candidate-skeleton']")

      assert text_of(card(html, forming), "[data-role='meeting-candidate-quote']") ==
               "somebody rewrite the pricing copy"

      assert text_of(card(html, shaping), "[data-role='meeting-candidate-quote']") ==
               "rotate the staging secrets"

      # The refutation. Its control is on the SAME helper — `rail_html/1`
      # returns "" for a rail that did not render, and a `refute` against
      # "" passes for every string in the world.
      assert rail_html(html) =~ "rotate the staging secrets"
      refute rail_html(html) =~ "book the offsite venue"
    end
  end

  # ── 2. Stage styling: the cards DIFFER ────────────────────────────────

  describe "stage styling" do
    test "each card carries its own stage slug and class, and two stages differ",
         %{conn: conn, meeting: meeting} do
      heard = candidate!(meeting, %{evidence_quote: "we should add a CSV export"})

      shaping =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item"
        })

      {_view, html} = mount_board(conn, meeting)

      heard_node = card(html, heard)
      shaping_node = card(html, shaping)

      assert attr(heard_node, "data-stage") == "heard"
      assert attr(shaping_node, "data-stage") == "taking-shape"

      # The whole point of the stage axis: a reader can sort the rail
      # without reading it. Asserting each slug in isolation would pass
      # under a renderer that emitted a constant, so assert they are
      # DIFFERENT and that the class follows the slug.
      refute attr(heard_node, "data-stage") == attr(shaping_node, "data-stage")
      assert attr(shaping_node, "class") =~ "candidate-card--taking-shape"
      refute attr(heard_node, "class") =~ "candidate-card--taking-shape"
    end
  end

  # ── 3. Display copy is a mapping, never a column read ─────────────────

  describe "display copy" do
    test "the stored vocabulary never reaches the DOM", %{conn: conn, meeting: meeting} do
      _shaping =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item"
        })

      _vetoed =
        candidate!(meeting, %{
          evidence_quote: "try that link again",
          state: :closed,
          closed_reason: :vetoed,
          closed_note: "Saru already owns this"
        })

      {_view, html} = mount_board(conn, meeting)
      rail = rail_html(html)

      # The two words that must not be said out loud. Their control is
      # the pair of positive assertions below — the cards that WOULD
      # have carried them are on the page and rendering.
      refute rail =~ "shaping"
      refute rail =~ "vetoed"

      # The control is now the DISPLAY SLUG rather than the stage label:
      # the numbered `3 · taking shape` line came off the card in task
      # 01a05b14 stage 4, and the slug is the surviving place a
      # `:shaping` row's vocabulary is mapped on its way to the DOM. It
      # still diverges from the stored word, which is what keeps the
      # refute above from going vacuous.
      assert rail =~ "taking-shape"
      assert rail =~ "Not taken up"
    end

    test "every enum member has display copy, and none of it is the stored string" do
      for state <- MeetingCandidate.states() do
        label = CandidateDisplay.stage_label(state)
        slug = CandidateDisplay.slug(state)

        assert is_binary(label) and label != ""
        assert is_binary(slug) and slug != ""
      end

      # The one member whose display form MUST diverge — if this ever
      # becomes equal, the mapping has been quietly replaced by
      # `to_string/1` and the refutes above go vacuous.
      assert CandidateDisplay.slug(:shaping) != "shaping"
      refute CandidateDisplay.stage_label(:shaping) =~ "shaping"

      for reason <- MeetingCandidate.closed_reasons() do
        assert is_binary(CandidateDisplay.closed_reason_label(reason))
        assert is_binary(CandidateDisplay.closed_reason_slug(reason))
      end

      assert CandidateDisplay.closed_reason_slug(:vetoed) != "vetoed"
      refute CandidateDisplay.closed_reason_label(:vetoed) =~ "vetoed"
    end
  end

  # ── 4. Closed cards keep their reason and leave the live list ─────────

  describe "the Closed section" do
    test "a closed card is PRESENT, carries its reason, and is not in the live list",
         %{conn: conn, meeting: meeting} do
      open = candidate!(meeting, %{evidence_quote: "we should add a CSV export"})

      closed =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :closed,
          closed_reason: :duplicate,
          closed_note: "Already on the backlog — 01a03f57"
        })

      {_view, html} = mount_board(conn, meeting)

      closed_section =
        html |> doc() |> LazyHTML.query("[data-role='meeting-candidates-closed']")

      # PRESENT — this is the assertion that guards the "closed means
      # hidden" failure the previous rail actually had.
      assert closed_section
             |> LazyHTML.query("[data-candidate-id='#{closed.id}']")
             |> LazyHTML.attribute("data-candidate-id") == [closed.id]

      # ...with its reason retained, both halves: the mapped label and
      # the note that makes it checkable.
      reason = text_of(closed_card(html, closed), "[data-role='meeting-candidate-closed-reason']")
      assert reason =~ "Already on the backlog"
      assert reason =~ "01a03f57"

      # The open card is NOT in the closed section, and the closed card
      # is NOT in the live list. Either one alone would pass under a
      # renderer that put everything in one bucket.
      assert closed_section |> LazyHTML.query("[data-candidate-id='#{open.id}']") |> Enum.empty?()
      assert card(html, closed) |> Enum.empty?()
      refute card(html, open) |> Enum.empty?()
    end

    test "the disclosure keeps every reason in the DOM while collapsed",
         %{conn: conn, meeting: meeting} do
      closed =
        candidate!(meeting, %{
          evidence_quote: "try that link again",
          state: :closed,
          closed_reason: :retracted,
          closed_note: "no, never mind"
        })

      {_view, html} = mount_board(conn, meeting)

      summary =
        html
        |> doc()
        |> LazyHTML.query("[data-role='meeting-candidates-closed-summary']")
        |> LazyHTML.text()
        |> String.trim()

      assert summary == "1 closed"

      # Collapse is a display affordance, not a retention policy: the
      # `<details>` is closed on first paint and the reason is in the
      # document anyway. A renderer that only emitted closed cards when
      # expanded would fail here.
      refute html |> doc() |> LazyHTML.query("details[open]") |> Enum.any?()

      assert text_of(closed_card(html, closed), "[data-role='meeting-candidate-closed-reason']") =~
               "no, never mind"
    end
  end

  # ── 5. Avatar and byline ──────────────────────────────────────────────

  describe "byline and avatar" do
    test "a shaping card names its SPEAKER and assigns separately; an unclassified card shows a skeleton and no byline",
         %{conn: conn, meeting: meeting} do
      shaping =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item",
          speaker: "Harper Parker",
          assigned_agent_slug: "octavius"
        })

      skeleton = candidate!(meeting, %{evidence_quote: "we should add a CSV export"})

      {_view, html} = mount_board(conn, meeting)

      # The byline names WHO SPOKE. It used to name the ASSIGNED AGENT,
      # which credited a verbatim quote to somebody who was not in the
      # room; the assignee now has its own trailing segment.
      assert text_of(card(html, shaping), "[data-role='meeting-candidate-byline']") ==
               "Harper Parker"

      assert text_of(card(html, shaping), "[data-role='meeting-candidate-assignment']") =~
               "@octavius · drafting"

      # The card that has NOT been classified shows no face and no
      # name — the mockup's "a byline would be a claim the card cannot
      # back up". Its control is the assertion above: bylines render on
      # this page.
      skeleton_node = card(html, skeleton)

      assert skeleton_node
             |> LazyHTML.query("[data-role='meeting-candidate-skeleton']")
             |> Enum.any?()

      assert skeleton_node
             |> LazyHTML.query("[data-role='meeting-candidate-byline']")
             |> Enum.empty?()

      # ...and the classified card is NOT a skeleton, which is what
      # makes `presentation/1` a decision rather than a constant.
      assert card(html, shaping)
             |> LazyHTML.query("[data-role='meeting-candidate-skeleton']")
             |> Enum.empty?()
    end
  end

  describe "when it was said" do
    # The target screen commits to it in as many words: "Cards land as
    # they're made, and say who made them AND WHEN." Before this the
    # byline said who and never when, so a card thirty seconds old and
    # one sitting there ten minutes read identically.
    #
    # Both directions in one test. Asserting only that a time appears
    # would pass against a byline that printed a constant; asserting
    # only its absence would pass against one that never printed a time
    # at all — which is the bug.
    test "a card with an utterance time says how long ago; one without says nothing",
         %{conn: conn, meeting: meeting} do
      recent =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item",
          speaker: "Harper Parker",
          assigned_agent_slug: "octavius",
          last_utterance_at: DateTime.utc_now()
        })

      older =
        candidate!(meeting, %{
          evidence_quote: "and send the SOC2 pack",
          state: :shaping,
          classified_intent: "action_item",
          speaker: "Rowan Ellis",
          assigned_agent_slug: "mycroft",
          last_utterance_at: DateTime.add(DateTime.utc_now(), -12 * 60, :second)
        })

      timeless =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          state: :shaping,
          classified_intent: "action_item",
          speaker: "Saru Vance",
          assigned_agent_slug: "saru"
        })

      {_view, html} = mount_board(conn, meeting)

      assert text_of(card(html, recent), "[data-role='meeting-candidate-byline']") ==
               "Harper Parker · just now"

      # A DIFFERENT time, not a constant — the assertion the "just now"
      # above cannot make on its own.
      assert text_of(card(html, older), "[data-role='meeting-candidate-byline']") ==
               "Rowan Ellis · 12m ago"

      # And a card with no utterance timestamp does not grow an empty
      # separator or a fabricated time.
      assert text_of(card(html, timeless), "[data-role='meeting-candidate-byline']") ==
               "Saru Vance"
    end
  end

  describe "what the card produced" do
    # `✓ Added to Tasks`, drawn from a stored id.
    #
    # The control is the `:acting` card with NO `task_id`: `graduate/2`
    # can fail against an archived project and leave the row acting with
    # no deliverable, which its own docs call "the truthful reading of
    # what happened". A label keyed on `state` would announce a task
    # that was never created — so the test drives both rows at the same
    # state and asserts they render differently.
    test "a card with a task id says so; an acting card with no id claims nothing",
         %{conn: conn, meeting: meeting} do
      landed =
        candidate!(meeting, %{
          evidence_quote: "file the pricing objection",
          state: :acting,
          classified_intent: "action_item",
          task_id: Ecto.UUID.generate()
        })

      failed_mint =
        candidate!(meeting, %{
          evidence_quote: "file the other one",
          state: :acting,
          classified_intent: "action_item"
        })

      {_view, html} = mount_board(conn, meeting)

      assert text_of(card(html, landed), "[data-role='meeting-candidate-outcome']") =~
               "Added to Tasks"

      assert card(html, failed_mint)
             |> LazyHTML.query("[data-role='meeting-candidate-outcome']")
             |> Enum.empty?()

      # Same state on both rows, so the difference above is the ID and
      # nothing else.
      assert landed.state == failed_mint.state
    end

    test "a canvas outcome names the canvas, not Tasks", %{conn: conn, meeting: meeting} do
      canvas_card =
        candidate!(meeting, %{
          evidence_quote: "sketch the new rail",
          state: :acting,
          classified_intent: "visual_adjust",
          outcome_kind: :artifact,
          canvas_id: Ecto.UUID.generate()
        })

      {_view, html} = mount_board(conn, meeting)

      outcome = text_of(card(html, canvas_card), "[data-role='meeting-candidate-outcome']")

      assert outcome =~ "Added to Canvas"
      refute outcome =~ "Tasks"
    end
  end

  # ── 6. The countdown carries a real, per-card deadline ────────────────

  describe "the countdown" do
    test "each card renders ITS OWN deadline and remaining, not a shared constant",
         %{conn: conn, meeting: meeting} do
      now = DateTime.utc_now()

      near =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          acts_at: DateTime.add(now, 5, :second)
        })

      far =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          acts_at: DateTime.add(now, 25, :second)
        })

      {_view, html} = mount_board(conn, meeting)

      near_foot = LazyHTML.query(card(html, near), "[data-role='meeting-candidate-countdown']")
      far_foot = LazyHTML.query(card(html, far), "[data-role='meeting-candidate-countdown']")

      # The deadline the client hook ticks against is the server's own
      # `acts_at`, verbatim — not a duration the client would re-derive.
      assert attr(near_foot, "data-acts-at") ==
               DateTime.to_iso8601(Repo.reload!(near).acts_at)

      assert attr(near_foot, "data-total-seconds") ==
               to_string(Countdown.countdown_seconds())

      near_remaining =
        near_foot
        |> LazyHTML.query("[data-role='meeting-candidate-remaining']")
        |> attr("data-remaining")
        |> String.to_integer()

      far_remaining =
        far_foot
        |> LazyHTML.query("[data-role='meeting-candidate-remaining']")
        |> attr("data-remaining")
        |> String.to_integer()

      # Bracketed rather than exact — the clock moves between the
      # fixture and the render — but the two cards must DIFFER. A
      # hardcoded "30", or one deadline reused for every card, passes a
      # single-card test and fails this one.
      assert near_remaining in 0..6
      assert far_remaining in 20..26
      assert far_remaining > near_remaining
    end

    test "ONE ticker: the hook is on the RAIL, and on none of the cards",
         %{conn: conn, meeting: meeting} do
      # The JS suite counts `setInterval` calls and proves the hook opens
      # one timer per mount. It cannot see this file, so it cannot tell
      # how many times the hook is MOUNTED — that is decided here, by
      # which element carries `phx-hook`. Put the attribute back on
      # `.candidate-foot` and every JS assertion still passes while the
      # browser runs one interval per armed card again.
      now = DateTime.utc_now()

      for quote <- [
            "we should add a CSV export",
            "rotate the staging secrets",
            "book the offsite venue"
          ] do
        candidate!(meeting, %{
          evidence_quote: quote,
          acts_at: DateTime.add(now, 20, :second)
        })
      end

      {_view, html} = mount_board(conn, meeting)
      rail = html |> doc() |> LazyHTML.query("[data-role='meeting-candidate-countdown-rail']")
      feet = LazyHTML.query(rail, "[data-role='meeting-candidate-countdown']")

      # Positive control FIRST. Three armed cards have to actually be on
      # the page, or "no hook on the cards" is true because there are no
      # cards and this test measures nothing.
      assert length(LazyHTML.attribute(feet, "data-acts-at")) == 3

      # The ticker is on the section, once.
      assert attr(rail, "phx-hook") == "CandidateClock"

      # And it has a DOM id, without which LiveView never runs the hook at
      # all — a silent failure that looks exactly like a working page with
      # a frozen number.
      assert attr(rail, "id") not in [nil, ""]

      # Zero hooks below it. A count, not a spot check: three armed cards
      # and an empty list is the assertion, so a hook left on one card
      # fails it.
      assert LazyHTML.attribute(feet, "phx-hook") == []
    end

    test "THE LADDER: three cards at different remainings render three different bars",
         %{conn: conn, meeting: meeting} do
      # The reason this ticket is one ticket and not one card's polish.
      # Every armed card drains at the same rate, so several open at once
      # form a ladder of bar lengths, and the ladder is the concurrency
      # picture. One card cannot show it, and neither can a test that
      # renders one card.
      now = DateTime.utc_now()

      cards =
        for {quote, secs} <- [
              {"we should add a CSV export", 3},
              {"rotate the staging secrets", 15},
              {"book the offsite venue", 28}
            ] do
          candidate!(meeting, %{evidence_quote: quote, acts_at: DateTime.add(now, secs, :second)})
        end

      {_view, html} = mount_board(conn, meeting)

      widths =
        for c <- cards do
          html
          |> card(c)
          |> LazyHTML.query("[data-role='meeting-candidate-drain']")
          |> attr("style")
        end

      # Positive control: three bars actually rendered. Without it,
      # "they differ" is a claim about a list of three nils.
      assert Enum.all?(widths, &is_binary/1)
      assert length(Enum.uniq(widths)) == 3

      parsed =
        Enum.map(widths, fn "width: " <> pct ->
          pct |> String.trim_trailing("%") |> String.to_float()
        end)

      # ASCENDING, matching ascending remaining. A bar wired to the
      # elapsed fraction would render three different widths in exactly
      # the wrong order and pass "they differ".
      assert parsed == Enum.sort(parsed)

      # And only the card inside the threshold is stepped to amber, on the
      # real route rather than in a component render.
      [urgent, mid, far] = cards

      assert card(html, urgent)
             |> LazyHTML.query("[data-role='meeting-candidate-drain']")
             |> attr("class") =~ "candidate-drain--warning"

      for calm <- [mid, far] do
        refute card(html, calm)
               |> LazyHTML.query("[data-role='meeting-candidate-drain']")
               |> attr("class") =~ "candidate-drain--warning"
      end
    end

    test "a disarmed card renders no countdown and no stop button",
         %{conn: conn, meeting: meeting} do
      armed =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          acts_at: DateTime.add(DateTime.utc_now(), 20, :second)
        })

      disarmed = candidate!(meeting, %{evidence_quote: "rotate the staging secrets"})

      {_view, html} = mount_board(conn, meeting)

      # The control: a countdown DOES render on this page.
      assert card(html, armed)
             |> LazyHTML.query("[data-role='meeting-candidate-countdown']")
             |> Enum.any?()

      assert card(html, disarmed)
             |> LazyHTML.query("[data-role='meeting-candidate-countdown']")
             |> Enum.empty?()

      assert card(html, disarmed)
             |> LazyHTML.query("[data-role='meeting-candidate-stop']")
             |> Enum.empty?()
    end
  end

  # ── 7. Review mode and act mode are exclusive, and both reachable ─────

  describe "review mode versus act mode" do
    test "a card with no deadline offers the human gate; an armed card offers stop",
         %{conn: conn, meeting: meeting} do
      review =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item"
        })

      acting =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          state: :shaping,
          classified_intent: "action_item",
          acts_at: DateTime.add(DateTime.utc_now(), 20, :second)
        })

      {view, html} = mount_board(conn, meeting)

      # Review mode: both buttons, no stop.
      assert has_element?(
               view,
               "[data-role=meeting-candidate-approve][data-candidate-id='#{review.id}']"
             )

      assert has_element?(
               view,
               "[data-role=meeting-candidate-decline][data-candidate-id='#{review.id}']"
             )

      assert card(html, review)
             |> LazyHTML.query("[data-role='meeting-candidate-stop']")
             |> Enum.empty?()

      # Act mode: stop, and NEITHER review button. The two fixtures are
      # the same state and differ only in `acts_at`, so this pair
      # isolates the one thing that decides the mode.
      assert has_element?(
               view,
               "[data-role=meeting-candidate-stop][data-candidate-id='#{acting.id}']"
             )

      assert card(html, acting)
             |> LazyHTML.query("[data-role='meeting-candidate-approve']")
             |> Enum.empty?()
    end

    test "Go ahead and Not now write DIFFERENT rows", %{conn: conn, meeting: meeting} do
      approved =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          state: :shaping,
          classified_intent: "action_item"
        })

      declined =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          state: :shaping,
          classified_intent: "action_item"
        })

      {view, _html} = mount_board(conn, meeting)

      view
      |> element("[data-role=meeting-candidate-approve][data-candidate-id='#{approved.id}']")
      |> render_click()

      view
      |> element("[data-role=meeting-candidate-decline][data-candidate-id='#{declined.id}']")
      |> render_click()

      approved_row = Repo.reload!(approved)
      declined_row = Repo.reload!(declined)

      # Read out of the DATABASE, because the claim is that a click in
      # a participant's browser minted a deliverable on the server.
      assert is_binary(approved_row.task_id)
      assert approved_row.closed_reason == :done
      assert approved_row.disposition == :accepted

      # The divergence. A handler that closed on BOTH paths, or
      # graduated on both, passes a single-sided test and fails here.
      assert is_nil(declined_row.task_id)
      assert declined_row.closed_reason == :dismissed
      refute declined_row.closed_reason == approved_row.closed_reason
    end
  end

  # ── 8. The activity log is the event stream, not a script ─────────────

  describe "the activity log" do
    test "a card shows the gates that ran and no others", %{conn: conn, meeting: meeting} do
      # `create/1` emits exactly one `:heard` event. The second card
      # gets a real second write on top of it, so the two cards have
      # genuinely different histories.
      quiet = candidate!(meeting, %{evidence_quote: "we should add a CSV export"})

      busy =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          classified_intent: "action_item"
        })

      {:ok, _} =
        CandidateEvents.record(busy, :classified, %{"classified_intent" => "action_item"})

      assert CandidateEvents.kinds_for_candidate(quiet.id) == [:heard]
      assert CandidateEvents.kinds_for_candidate(busy.id) == [:heard, :classified]

      {_view, html} = mount_board(conn, meeting)

      quiet_kinds = log_kinds(card(html, quiet))
      busy_kinds = log_kinds(card(html, busy))

      # The rendered log matches the WRITES, per card. A hardcoded
      # three-line log — the "progress bar that lies" the ticket names —
      # would give both cards the same lines and fail both assertions.
      assert quiet_kinds == ["heard"]
      assert busy_kinds == ["heard", "classified"]
      refute quiet_kinds == busy_kinds

      # And the lines are the mapped copy, not the kind atom.
      assert text_of(card(html, busy), "[data-role='meeting-candidate-log']") =~
               "Worked out what it is"
    end
  end

  # ── The rail's order, on the real route (task 01a0740e stage 4) ───────

  describe "rail order and the pointer freeze" do
    defp rail_order(html) do
      html |> cards() |> LazyHTML.attribute("data-candidate-id")
    end

    # THE WHOLE CHAIN, in one test, because every link in it is silent
    # when it breaks. `candidate_rail/1`'s own tests prove the sort; what
    # they cannot prove is that `CallShell.call_rail/1` forwards the
    # `order` attr, that `MeetingLive` seeds and clears the assign, or
    # that the two events the hook pushes are handled at all. An
    # unforwarded attr renders a perfectly correct rail — it just never
    # freezes, and nothing anywhere says so.
    test "cards read soonest-to-fire first, and a hovered rail holds its order",
         %{conn: conn, meeting: meeting} do
      now = DateTime.utc_now()

      # Created NEAR first, FAR second, so arrival order and deadline
      # order disagree from the outset and "the sort ran" is not
      # satisfiable by the insertion sequence.
      near =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          acts_at: DateTime.add(now, 20, :second)
        })

      far =
        candidate!(meeting, %{
          evidence_quote: "book the offsite venue",
          acts_at: DateTime.add(now, 25, :second)
        })

      {view, html} = mount_board(conn, meeting)

      assert rail_order(html) == [near.id, far.id]

      # A pointer arrives. The freeze captures what is on screen; with
      # nothing yet changed this render is the CONTROL — it says the
      # captured order is the displayed one and not, say, an empty list
      # that would silently render nothing.
      frozen = render_hook(view, "candidate_rail_freeze", %{})
      assert rail_order(frozen) == [near.id, far.id]

      # Now the thing the freeze exists for: a card arrives that would
      # otherwise jump to the top, under a cursor already on its way to
      # `Stop`.
      soonest =
        candidate!(meeting, %{
          evidence_quote: "we should add a CSV export",
          acts_at: DateTime.add(now, 2, :second)
        })

      send(view.pid, {:candidate_event, %{meeting_id: meeting.id}})
      held = render(view)

      # Held, and APPENDED rather than hidden. A frozen rail that dropped
      # new cards would hide the very card most likely to fire next.
      assert rail_order(held) == [near.id, far.id, soonest.id]

      # The pointer leaves and the truth reasserts. This is the load-
      # bearing half: without it, "the order did not change" is equally
      # satisfied by a rail that never sorts at all.
      thawed = render_hook(view, "candidate_rail_thaw", %{})
      assert rail_order(thawed) == [soonest.id, near.id, far.id]
    end

    test "an unarmed card sits below every armed one on the route",
         %{conn: conn, meeting: meeting} do
      now = DateTime.utc_now()

      # Created FIRST and left at `:heard`, so arrival order and stage
      # order both put it on top. Only the deadline rule moves it down.
      review =
        candidate!(meeting, %{
          evidence_quote: "maybe we redo the pricing page",
          classified_intent: "action_item",
          acts_at: nil
        })

      armed =
        candidate!(meeting, %{
          evidence_quote: "rotate the staging secrets",
          acts_at: DateTime.add(now, 12, :second)
        })

      {_view, html} = mount_board(conn, meeting)

      assert rail_order(html) == [armed.id, review.id]
    end
  end

  defp log_kinds(node) do
    node
    |> LazyHTML.query("[data-role='meeting-candidate-log-line']")
    |> LazyHTML.attribute("data-event-kind")
  end
end
