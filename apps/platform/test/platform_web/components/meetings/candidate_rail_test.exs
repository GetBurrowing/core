defmodule PlatformWeb.Components.Meetings.CandidateRailTest do
  @moduledoc """
  The four card states the approved canvas draws, asserted one per test
  (task 01a05b14 stage 4).

  ## Every state here is a claim the DATA can back

  That is the organising rule, and it is why these are four separate
  tests rather than one walk over a fixture list. Each state is keyed on
  a different stored condition, and the point of the test is that the
  card renders when THAT condition holds and not when it does not:

    * FORMING — `classified_intent` is nil. Not `state == :heard`:
      `reconcile/2` writes the intent onto the row without advancing
      `state`, so there is a real window in which a `:heard` card is
      already classified and must not shimmer.
    * NEW — `speaker` is set. The byline names WHO SPOKE, and a nil
      speaker renders NOTHING, because falling back to the assignee
      credits a verbatim quote to an agent who was not in the room.
    * ACTIONED — `task_id` is non-nil. Observed, not inferred from
      `state == :acting`, which `graduate/2` can leave behind with no
      deliverable.
    * UNASSIGNED — the word, never `@null`. `IntentClassifier` stores
      the SENTINEL STRING `"null"` in `target_role`, which is truthy, so
      the old `|| "unassigned"` fallback was unreachable dead code.

  Every one of them carries a NEGATIVE case in the same test, because
  "the label rendered" is satisfied by a card that renders it always.

  These render the component directly rather than through a mounted
  LiveView on purpose: `meeting_live_candidate_board_test.exs` already
  owns the "a participant on the real route sees this" claim (and now
  names the Canvas pane with `?tab=canvas`), and these are about the
  mapping from a row's columns to its markup, which a component render
  isolates.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Meetings.Countdown
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.MeetingCandidateEvent
  alias PlatformWeb.Components.Meetings.CandidateDisplay
  alias PlatformWeb.Components.Meetings.CandidateRail

  @now ~U[2026-09-01 12:00:00.000000Z]

  # Structs, not bare maps: a map typo (`:speakr`) would silently answer
  # nil through `Map.get/2` and the test would pass on the wrong reading.
  # `MeetingCandidate` rejects an unknown key at compile time.
  defp candidate(attrs) do
    struct!(
      %MeetingCandidate{
        id: Ecto.UUID.generate(),
        evidence_quote: "we should rotate the staging secrets",
        state: :shaping,
        classified_intent: "action_item",
        transcript_chunk_ids: [Ecto.UUID.generate()],
        acts_at: nil,
        inserted_at: @now
      },
      attrs
    )
  end

  defp rail(candidates) do
    render_component(&CandidateRail.candidate_rail/1,
      candidates: candidates,
      closed: [],
      events: %{},
      now: @now
    )
  end

  defp node(html, %MeetingCandidate{id: id}) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='meeting-candidate-card'][data-candidate-id='#{id}']")
  end

  defp text_of(nodes, selector) do
    nodes |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp present?(nodes, selector), do: nodes |> LazyHTML.query(selector) |> Enum.any?()

  # The order of a card's own children, by data-role, ignoring anything
  # unlabelled. Indexes rather than a regex over the HTML so a nested
  # element cannot satisfy an ordering claim about siblings.
  defp roles(html, candidate) do
    html
    |> node(candidate)
    |> LazyHTML.query("[data-role]")
    |> LazyHTML.attribute("data-role")
  end

  # ── Commit-window helpers (task 01a0740e stage 3) ──
  #
  # `armed/1` puts a card exactly `secs` from firing. `rail/1` passes
  # `now: @now`, so `remaining` is that number and not "about" it, and
  # every commit-window assertion is exact rather than bracketed.
  defp armed(secs), do: candidate(%{acts_at: DateTime.add(@now, secs, :second)})

  defp foot(html, candidate) do
    LazyHTML.query(node(html, candidate), "[data-role='meeting-candidate-countdown']")
  end

  defp classes(html, candidate, selector) do
    html
    |> node(candidate)
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> Enum.join(" ")
  end

  defp drain_width(html, candidate) do
    html
    |> node(candidate)
    |> LazyHTML.query("[data-role='meeting-candidate-drain']")
    |> LazyHTML.attribute("style")
    |> List.first()
  end

  defp index_of(roles, role), do: Enum.find_index(roles, &(&1 == role))

  # ── Rail-order helpers (task 01a0740e stage 4) ──
  #
  # `rail/2` is `rail/1` plus the FROZEN `order` attr. `rail_order/1`
  # reads the OPEN cards' ids in document order — the actual sequence a
  # participant sees. Deliberately keyed on `meeting-candidate-card`, so
  # the Closed disclosure (`meeting-candidate-closed-card`, sorted by
  # `closed_at` and untouched by this stage) cannot pad the list.
  defp rail(candidates, order) do
    render_component(&CandidateRail.candidate_rail/1,
      candidates: candidates,
      closed: [],
      events: %{},
      now: @now,
      order: order
    )
  end

  defp rail_order(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='meeting-candidate-card']")
    |> LazyHTML.attribute("data-candidate-id")
  end

  # The rail with a stop's ten-second undo stashed on the socket that
  # made it (task 01a0740e stage 5).
  defp rail(candidates, order, undo) do
    render_component(&CandidateRail.candidate_rail/1,
      candidates: candidates,
      closed: [],
      events: %{},
      now: @now,
      order: order,
      undo: undo
    )
  end

  # Every ROW the rail draws, live cards and spent rows alike, in
  # document order. `rail_order/1` above sees only cards on purpose —
  # this is the query that can catch a spent row appended below the list
  # instead of placed in the slot its card held.
  defp row_order(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "[data-role='meeting-candidate-card'], [data-role='meeting-candidate-spent']"
    )
    |> LazyHTML.attribute("data-candidate-id")
  end

  defp spent_node(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='meeting-candidate-spent']")
  end

  defp ids(candidates), do: Enum.map(candidates, & &1.id)

  # Armed `secs` from firing and inserted `arrived` seconds into the
  # meeting. Two axes, set independently, because every test below turns
  # on the two DISAGREEING.
  defp armed(secs, arrived) do
    candidate(%{
      state: :acting,
      acts_at: DateTime.add(@now, secs, :second),
      inserted_at: DateTime.add(@now, arrived, :second)
    })
  end

  # ── 1. FORMING ────────────────────────────────────────────────────────

  describe "FORMING" do
    test "an unclassified card shimmers and shows the verbatim fragment; a classified one does not" do
      forming =
        candidate(%{
          state: :heard,
          classified_intent: nil,
          evidence_quote: "somebody should rewrite the pricing copy"
        })

      # THE CONTROL, and the whole reason the predicate is not `state`:
      # same state, intent already written by `reconcile/2`.
      classified =
        candidate(%{
          state: :heard,
          classified_intent: "action_item",
          evidence_quote: "and rotate the staging secrets"
        })

      html = rail([forming, classified])

      assert CandidateRail.presentation(forming) == :skeleton
      assert CandidateRail.presentation(classified) == :forming

      assert present?(node(html, forming), "[data-role='meeting-candidate-skeleton']")

      # The fragment that TRIGGERED it, verbatim, on the shimmering card
      # itself — a state with no quote is one nobody can defend.
      assert text_of(node(html, forming), "[data-role='meeting-candidate-quote']") ==
               "somebody should rewrite the pricing copy"

      refute present?(node(html, classified), "[data-role='meeting-candidate-skeleton']")

      # The classified card carries its verbatim span too — in the QUOTE
      # element, which every non-skeleton card now has as well. Its
      # title is the classified intent, a different claim in a different
      # element (task 01a05b14 stage 4).
      assert text_of(node(html, classified), "[data-role='meeting-candidate-quote']") ==
               "and rotate the staging secrets"

      assert text_of(node(html, classified), "[data-role='meeting-candidate-title']") ==
               "Action item"
    end
  end

  # ── 2. NEW ────────────────────────────────────────────────────────────

  describe "NEW" do
    test "the byline names WHO SPOKE, and the assignment is a separate segment" do
      spoken =
        candidate(%{
          speaker: "Harper Parker",
          assigned_agent_slug: "octavius",
          last_utterance_at: DateTime.add(@now, -120, :second)
        })

      html = rail([spoken])
      card = node(html, spoken)

      assert text_of(card, "[data-role='meeting-candidate-byline']") == "Harper Parker · 2m ago"

      # The assignee is NOT in the byline. This is the defect: reading
      # the assigned agent as the author of a verbatim quote.
      refute text_of(card, "[data-role='meeting-candidate-byline']") =~ "octavius"

      assert text_of(card, "[data-role='meeting-candidate-assignment']") =~ "@octavius"
    end

    test "an UNATTRIBUTED card renders no byline at all — no placeholder, no assignee" do
      unattributed = candidate(%{speaker: nil, assigned_agent_slug: "octavius"})

      # `""` is what the classifier answers for an unknown speaker; it
      # must read the same as nil rather than as an empty byline.
      blank = candidate(%{speaker: "   ", assigned_agent_slug: "mycroft"})

      html = rail([unattributed, blank])

      refute present?(node(html, unattributed), "[data-role='meeting-candidate-byline']")
      refute present?(node(html, blank), "[data-role='meeting-candidate-byline']")

      # ...and the control: the element is not simply missing from the
      # component. A card WITH a speaker still has one.
      spoken = candidate(%{speaker: "Harper Parker"})

      assert present?(
               node(rail([spoken]), spoken),
               "[data-role='meeting-candidate-byline']"
             )
    end
  end

  # ── 3. ACTIONED ───────────────────────────────────────────────────────

  describe "ACTIONED" do
    test "'Added to Tasks' only once a task row exists — both cards at the same state" do
      landed = candidate(%{state: :acting, task_id: Ecto.UUID.generate()})

      # `graduate/2` failed against an archived project: acting, no
      # deliverable. A label keyed on `state` announces a task that was
      # never created.
      empty_handed = candidate(%{state: :acting, task_id: nil, canvas_id: nil})

      html = rail([landed, empty_handed])

      assert text_of(node(html, landed), "[data-role='meeting-candidate-outcome']") =~
               "Added to Tasks"

      refute present?(node(html, empty_handed), "[data-role='meeting-candidate-outcome']")

      # Scoped to the card, so this cannot be satisfied by the other
      # card's label elsewhere in the rail.
      refute node(html, empty_handed) |> LazyHTML.to_html() =~ "Added to Tasks"
    end
  end

  # ── 4. UNASSIGNED ─────────────────────────────────────────────────────

  describe "UNASSIGNED" do
    test "the WORD, never the '@null' sentinel and never a bare '@unassigned'" do
      # `IntentClassifier` stores the sentinel STRING "null", not a real
      # nil, and a non-empty binary is truthy — which is what made the
      # old `|| "unassigned"` term unreachable.
      unrouted = candidate(%{assigned_agent_slug: nil, target_role: "null"})
      missing = candidate(%{assigned_agent_slug: nil, target_role: nil})
      routed = candidate(%{assigned_agent_slug: nil, target_role: "triage_officer"})

      html = rail([unrouted, missing, routed])

      assert text_of(node(html, unrouted), "[data-role='meeting-candidate-assignment']") =~
               "unassigned"

      assert text_of(node(html, missing), "[data-role='meeting-candidate-assignment']") =~
               "unassigned"

      # A ROLE is a role, not an at-mention of a person who does not
      # exist — the control that says "unassigned" above is a mapping
      # rather than a constant.
      assert text_of(node(html, routed), "[data-role='meeting-candidate-assignment']") =~
               "Triage officer"

      refute html =~ "@null"
      refute html =~ "@unassigned"
      refute html =~ "@triage_officer"
    end
  end

  # ── 5. THE DRAWING'S READING ORDER ────────────────────────

  # Four separate presentation claims, each with its own negative case.
  #
  # They are POSITIONAL and STRUCTURAL rather than "the string is
  # somewhere in the card", on purpose: the defect being fixed here was
  # never a missing element. `meeting-candidate-assignment` rendered on
  # every card before this stage and still does. What was wrong was
  # WHERE it sat — directly under the verbatim quote, where a reader
  # takes it for the attribution. A presence assertion cannot fail on
  # that, so these read DOM INDEXES.
  describe "the card reads in the drawing's order" do
    test "the assignment is the last WRITTEN line — below the quote, not above it" do
      card =
        candidate(%{
          speaker: "Harper Parker",
          assigned_agent_slug: "octavius",
          last_utterance_at: DateTime.add(@now, -120, :second)
        })

      roles = roles(rail([card]), card)

      # All four present, so the ordering below is about position and
      # not about an element that quietly failed to render.
      for role <- ~w(meeting-candidate-title meeting-candidate-byline
                     meeting-candidate-quote meeting-candidate-assignment) do
        assert index_of(roles, role), "#{role} did not render at all"
      end

      # what it is → who said it → the words → who will action it.
      assert index_of(roles, "meeting-candidate-title") <
               index_of(roles, "meeting-candidate-byline")

      assert index_of(roles, "meeting-candidate-byline") <
               index_of(roles, "meeting-candidate-quote")

      # THE ONE THAT WAS WRONG. Before this stage the assignment sat
      # immediately under the title and above the quote.
      assert index_of(roles, "meeting-candidate-quote") <
               index_of(roles, "meeting-candidate-assignment")

      # ...and nothing WRITTEN follows it. The review controls do, and
      # that is the ruling: they are a live approval gate the drawing
      # never had a reason to include, kept and moved BELOW the
      # assignment rather than deleted to match a static picture.
      after_assignment = Enum.drop(roles, index_of(roles, "meeting-candidate-assignment") + 1)

      assert after_assignment == [
               "meeting-candidate-chips",
               "meeting-candidate-utterances",
               "meeting-candidate-ask",
               "meeting-candidate-review",
               "meeting-candidate-decline",
               "meeting-candidate-approve"
             ]
    end

    test "quote and assignment CO-OCCUR on every card that has both to show" do
      # The measured defect this closes: before this stage the two
      # elements never appeared on the same card. The quote lived only
      # in the skeleton branch, which renders no assignment, and the
      # forming/full branch printed the verbatim span as its TITLE.
      forming = candidate(%{state: :heard, classified_intent: "action_item"})
      full = candidate(%{state: :shaping})
      acting = candidate(%{state: :acting, acts_at: DateTime.add(@now, 20, :second)})

      html = rail([forming, full, acting])

      for card <- [forming, full, acting] do
        roles = roles(html, card)

        assert index_of(roles, "meeting-candidate-quote") <
                 index_of(roles, "meeting-candidate-assignment")
      end

      # THE NEGATIVE CASE. A card nobody has classified yet routes
      # nowhere, so it shows the words and NO assignment — the element
      # is absent rather than saying "unassigned" about a card the
      # system has not looked at.
      skeleton = candidate(%{state: :heard, classified_intent: nil})
      skeleton_roles = roles(rail([skeleton]), skeleton)

      assert index_of(skeleton_roles, "meeting-candidate-quote")
      refute index_of(skeleton_roles, "meeting-candidate-assignment")
    end

    test "a still-forming card is DASHED; a settled one is not" do
      forming = candidate(%{state: :heard, classified_intent: nil})
      settled = candidate(%{state: :shaping})

      html = rail([forming, settled])

      assert node(html, forming) |> LazyHTML.attribute("class") |> List.first() =~
               "candidate-card--forming"

      refute node(html, settled) |> LazyHTML.attribute("class") |> List.first() =~
               "candidate-card--forming"
    end

    test "the stage-machine label is gone from every card" do
      cards = [
        candidate(%{state: :heard, classified_intent: nil}),
        candidate(%{state: :thinking}),
        candidate(%{state: :shaping}),
        candidate(%{state: :acting})
      ]

      html = rail(cards)

      # Not on any card, and not as the words either — `1 · heard` was
      # a fact about our pipeline, not about the card.
      refute present?(LazyHTML.from_fragment(html), "[data-role='meeting-candidate-stage']")
      refute html =~ "taking shape"
    end

    test "the forming sentence names a REAL agent, or says nothing at all" do
      named = candidate(%{state: :heard, classified_intent: nil, assigned_agent_slug: "octavius"})
      anonymous = candidate(%{state: :heard, classified_intent: nil, assigned_agent_slug: nil})
      blank = candidate(%{state: :heard, classified_intent: nil, assigned_agent_slug: "  "})

      html = rail([named, anonymous, blank])

      assert text_of(node(html, named), "[data-role='meeting-candidate-forming']") =~
               "octavius is forming a card"

      # No placeholder actor. Same rule as the unattributed byline: a
      # card cannot name somebody it does not know.
      refute present?(node(html, anonymous), "[data-role='meeting-candidate-forming']")
      refute present?(node(html, blank), "[data-role='meeting-candidate-forming']")
      refute html =~ "someone is forming"

      # ...and it is not on a card that has finished forming.
      settled = candidate(%{state: :shaping, assigned_agent_slug: "octavius"})
      refute present?(node(rail([settled]), settled), "[data-role='meeting-candidate-forming']")
    end
  end

  # ── The standing invariant ────────────────────────────────────────────

  describe "the stored vocabulary never reaches the DOM" do
    test "not as text, not as a class, not as a data- attribute" do
      shaping = candidate(%{state: :shaping})

      html = rail([shaping])

      refute html =~ "shaping"
      refute html =~ "vetoed"

      # The control: the display slug IS there, so the refutes above are
      # about the spelling and not about an empty render.
      assert html =~ "taking-shape"
    end

    test "every card carries its evidence quote, at every state" do
      cards = [
        candidate(%{state: :heard, classified_intent: nil, evidence_quote: "quote alpha"}),
        candidate(%{state: :thinking, evidence_quote: "quote bravo"}),
        candidate(%{state: :shaping, evidence_quote: "quote charlie"}),
        candidate(%{state: :acting, evidence_quote: "quote delta"})
      ]

      html = rail(cards)

      for card <- cards do
        assert node(html, card) |> LazyHTML.to_html() =~ card.evidence_quote
      end
    end
  end

  # ── Card reading order ────────────────────────────────────────────────

  describe "card reading order" do
    # THE INVARIANT: the assignment renders BELOW the evidence quote.
    #
    # It has been inverted and fixed twice. Flipped, the assignment sits
    # directly under the title beside the byline, and the card reads as
    # though the ASSIGNEE is who spoke — the exact authorship confusion
    # this component exists to remove. The reading order the approved
    # canvas draws is: what was said → who said it → the evidence →
    # who will action it.
    #
    # Asserted on DOM ORDER over the card's subtree, never on text and
    # never on class names. A `=~` against the rendered string is a text
    # match by another name and breaks the moment an attribute reorders.
    # `Floki.find/2` answers in document order, so the index of each
    # marker in its result IS the card's reading order.
    #
    # RED ON PURPOSE — see `Platform.PendingFix`. Today the populated
    # card renders its evidence quote as `meeting-candidate-title` and
    # has no `meeting-candidate-quote` element at all; only the skeleton
    # spells it that way. Stage 4 of task `01a05b14` gives the populated
    # card the italic left-ruled quote line and moves the assignment to
    # the card's last line, which is what turns this green. This task
    # asserts the relation and deliberately does NOT edit the template:
    # two agents editing `candidate_rail.ex` on overlapping branches is
    # how work gets lost.
    @order_markers "[data-role='meeting-candidate-byline']," <>
                     "[data-role='meeting-candidate-quote']," <>
                     "[data-role='meeting-candidate-assignment']"

    defp reading_order(html, %MeetingCandidate{id: id}) do
      {:ok, doc} = Floki.parse_fragment(html)

      doc
      |> Floki.find("[data-role='meeting-candidate-card'][data-candidate-id='#{id}']")
      |> Floki.find(@order_markers)
      |> Enum.map(fn node -> node |> Floki.attribute("data-role") |> List.first() end)
      |> Enum.map(&String.replace_prefix(&1, "meeting-candidate-", ""))
    end

    # Every state that renders a card at all, not just the fully
    # populated one: the inversion has previously survived in one branch
    # of an `:if` while the other read correctly, so a test covering only
    # the happy card is how the last two got through.
    defp order_cases do
      [
        {"forming — classified, still early",
         candidate(%{
           state: :heard,
           classified_intent: "action_item",
           speaker: "Harper Parker",
           assigned_agent_slug: "octavius"
         })},
        {"full — the populated card",
         candidate(%{state: :shaping, speaker: "Harper Parker", assigned_agent_slug: "octavius"})},
        {"acting — armed and counting down",
         candidate(%{
           state: :acting,
           speaker: "Harper Parker",
           assigned_agent_slug: "octavius",
           acts_at: DateTime.add(@now, 30, :second)
         })},
        # UNATTRIBUTED: renders NO byline at all, and the quote →
        # assignment relation still has to hold. A test that only covers
        # the fully-populated card is how the last two inversions got
        # through.
        {"nil speaker — unattributed, renders no byline",
         candidate(%{state: :shaping, speaker: nil, assigned_agent_slug: "octavius"})},
        {"blank speaker — the classifier's empty-string reading",
         candidate(%{state: :shaping, speaker: "   ", assigned_agent_slug: "octavius"})},
        {"unassigned — the sentinel row",
         candidate(%{
           state: :shaping,
           speaker: "Harper Parker",
           assigned_agent_slug: nil,
           target_role: "null"
         })}
      ]
    end

    @tag :pending_fix
    test "the assignment renders after the evidence quote so the byline cannot read as the assignee" do
      for {label, card} <- order_cases() do
        order = reading_order(rail([card]), card)

        quote_at = Enum.find_index(order, &(&1 == "quote"))
        assignment_at = Enum.find_index(order, &(&1 == "assignment"))
        byline_at = Enum.find_index(order, &(&1 == "byline"))

        # THE ANTI-VACUITY GUARD. Without it, every ordering assertion
        # below is satisfied by a card that renders neither marker and
        # the test passes while asserting nothing at all.
        assert is_integer(quote_at) and is_integer(assignment_at),
               "#{label}: the card must render BOTH the evidence quote and the " <>
                 "assignment for its reading order to mean anything; " <>
                 "markers in document order: #{inspect(order)}"

        assert assignment_at > quote_at,
               "#{label}: the assignment must follow the evidence quote, " <>
                 "got #{inspect(order)}"

        if is_integer(byline_at) do
          assert byline_at < quote_at,
                 "#{label}: the byline must precede the evidence quote, " <>
                   "got #{inspect(order)}"
        end
      end
    end

    # The SKELETON is the one state deliberately outside the set above:
    # it has no agent yet, so it renders a quote and NO assignment BY
    # DESIGN. Asserted as a positive claim rather than left as a hole in
    # the case list — a state quietly dropped from an ordering test is
    # indistinguishable from a state the test forgot.
    test "the skeleton card carries the quote and no assignment — and still cannot invert" do
      skeleton = candidate(%{state: :heard, classified_intent: nil, speaker: "Harper Parker"})

      assert CandidateRail.presentation(skeleton) == :skeleton

      order = reading_order(rail([skeleton]), skeleton)

      assert "quote" in order,
             "the shimmering card must still show the fragment that triggered it, got #{inspect(order)}"

      # If an assignment ever appears here it must obey the same
      # relation; today there is none, and that is the claim.
      case {Enum.find_index(order, &(&1 == "quote")),
            Enum.find_index(order, &(&1 == "assignment"))} do
        {_q, nil} ->
          :ok

        {q, a} ->
          assert a > q, "skeleton: assignment must follow the quote, got #{inspect(order)}"
      end
    end

    test "reading_order/2 measures document order rather than returning a constant" do
      # The control for the assertions above. `Floki.find/2` is shown to
      # distinguish two different arrangements of the same three markers,
      # so a green ordering assertion is a measurement and not a tautology.
      html = """
      <div data-role="meeting-candidate-card" data-candidate-id="ctl">
        <p data-role="meeting-candidate-byline">who</p>
        <p data-role="meeting-candidate-quote">what</p>
        <p data-role="meeting-candidate-assignment">to whom</p>
      </div>
      """

      inverted = """
      <div data-role="meeting-candidate-card" data-candidate-id="ctl">
        <p data-role="meeting-candidate-assignment">to whom</p>
        <p data-role="meeting-candidate-byline">who</p>
        <p data-role="meeting-candidate-quote">what</p>
      </div>
      """

      probe = %MeetingCandidate{id: "ctl"}

      assert reading_order(html, probe) == ["byline", "quote", "assignment"]
      assert reading_order(inverted, probe) == ["assignment", "byline", "quote"]
    end
  end

  # ── 6. THE COMMIT WINDOW ──────────────────────────────────────────────

  describe "the commit window" do
    test "the ring is GONE, and so is the prose that restated its number" do
      card = armed(20)
      html = rail([card])

      # The positive control FIRST. A countdown has to be on this page,
      # or every refute below is true because the foot never rendered
      # and this test measures nothing.
      assert foot(html, card) != []
      assert text_of(node(html, card), "[data-role='meeting-candidate-remaining']") == "20"

      # Three encodings of one number became two. The ring and the bar
      # were both continuous proportional encodings of `remaining`; the
      # ring is the one FE-14's floor lease needs, and it rendered in
      # `--cc-ring-progress` green, which is SPEAKING's colour.
      refute present?(node(html, card), "[data-role='meeting-candidate-ring-progress']")
      refute present?(node(html, card), "[data-role='meeting-candidate-ring']")
      refute present?(node(html, card), "svg")

      # `Starting in 20s` — a third statement of the same number, in
      # prose, on a card that already shows it twice.
      refute present?(node(html, card), "[data-role='meeting-candidate-remaining-word']")
      refute html =~ "Starting in"

      # The geometry the ring needed goes with it. Left behind, it is an
      # attribute the ticker no longer reads and the next reader has to
      # work out is dead.
      assert LazyHTML.attribute(foot(html, card), "data-circumference") == []
    end

    test "the count is BARE SECONDS — not `0:20`, not `20s`" do
      card = armed(20)
      html = rail([card])

      count = text_of(node(html, card), "[data-role='meeting-candidate-remaining']")

      assert count == "20"
      refute count =~ ":"
      refute count =~ "s"

      # `data-remaining` is what the ticker and the board test read, and
      # it must agree with the glyph a human sees.
      assert node(html, card)
             |> LazyHTML.query("[data-role='meeting-candidate-remaining']")
             |> LazyHTML.attribute("data-remaining") == ["20"]
    end

    test "the drain's width is the REMAINING fraction, not the elapsed one" do
      full = armed(30)
      half = armed(15)
      spent = armed(0)

      html = rail([full, half, spent])

      # Wired to the wrong end of the fraction, a bar looks entirely
      # plausible and counts backwards: it would grow as the card ran
      # out. Three points pin the direction as well as the scale.
      assert drain_width(html, full) == "width: 100.0%"
      assert drain_width(html, half) == "width: 50.0%"
      assert drain_width(html, spent) == "width: 0.0%"
    end

    test "the threshold is published to the client rather than duplicated in it" do
      card = armed(20)
      html = rail([card])

      assert LazyHTML.attribute(foot(html, card), "data-warning-seconds") ==
               [to_string(Countdown.warning_seconds())]

      assert LazyHTML.attribute(foot(html, card), "data-total-seconds") ==
               [to_string(Countdown.countdown_seconds())]
    end

    # THE TWO-SIDED ASSERTION, and it has to be two-sided or it is
    # vacuous: a card that is amber at every value passes "amber appears
    # at 5" without the threshold existing at all. The refute at 6 is
    # what makes the assert at 5 mean something.
    #
    # MUTATION RUN (2026-09-06): `warning?/1` forced to `true` for every
    # remaining value, so every armed card is amber. The 6-second refutes
    # below go red; the 5- and 1-second asserts stay green. A one-sided
    # test survives that mutation untouched.
    test "grey at 6 seconds, amber at 5 and at 1 — both sides, count and drain" do
      grey = armed(6)
      edge = armed(5)
      last = armed(1)

      html = rail([grey, edge, last])

      count = "[data-role='meeting-candidate-remaining']"
      drain = "[data-role='meeting-candidate-drain']"

      # Positive controls. All three cards must be armed and rendering
      # both elements, or the refutes pass on absent markup.
      for card <- [grey, edge, last] do
        assert present?(node(html, card), count)
        assert present?(node(html, card), drain)
      end

      # ABOVE the threshold: neither element is warned.
      refute classes(html, grey, count) =~ "candidate-count--warning"
      refute classes(html, grey, drain) =~ "candidate-drain--warning"

      # AT the threshold, and inside it. `<=`, so 5 is amber.
      assert classes(html, edge, count) =~ "candidate-count--warning"
      assert classes(html, edge, drain) =~ "candidate-drain--warning"

      assert classes(html, last, count) =~ "candidate-count--warning"
      assert classes(html, last, drain) =~ "candidate-drain--warning"
    end

    test "a fired card is still amber at zero rather than falling back to rest" do
      # A card past its deadline waits for the sweeper, and during that
      # window it is the most committed thing on the rail. `remaining <=
      # warning` covers zero; a range check written `in 1..5` would drop
      # it back to grey at the last instant.
      spent = armed(0)
      html = rail([spent])

      assert text_of(node(html, spent), "[data-role='meeting-candidate-remaining']") == "0"

      assert classes(html, spent, "[data-role='meeting-candidate-remaining']") =~
               "candidate-count--warning"
    end

    test "a DISARMED card has no count and no drain at all" do
      armed_card = armed(20)
      disarmed = candidate(%{acts_at: nil})

      html = rail([armed_card, disarmed])

      # The control: this page does render a drain.
      assert present?(node(html, armed_card), "[data-role='meeting-candidate-drain']")

      refute present?(node(html, disarmed), "[data-role='meeting-candidate-drain']")
      refute present?(node(html, disarmed), "[data-role='meeting-candidate-remaining']")
    end
  end

  # ── The armed card names its outcome (task 01a0740e stage 2) ─────────
  #
  # A NEW describe on purpose. Nothing in "the commit window" above is
  # edited or relaxed by this stage, and in particular its two
  # refutations still stand exactly as written:
  #
  #   * `refute count =~ "s"` / `refute count =~ ":"` — the count is
  #     still bare seconds. Every word of the new sentence lives in a
  #     SIBLING element, so nothing this stage adds can reach that node.
  #   * `refute present?(..., "meeting-candidate-remaining-word")` and
  #     `refute html =~ "Starting in"` — the prose FE-9 deleted stays
  #     deleted. It was banned for restating the NUMBER a third time.
  #     The sentence here carries the outcome KIND, which appears
  #     nowhere else on an armed card, so it is a different claim under
  #     a different `data-role` and not a revert of that decision.
  @sentence "[data-role='meeting-candidate-armed-outcome']"

  # An armed card AIMED at a kind. `outcome_kind` is the only field that
  # can answer here: `Candidates` nils `acts_at` in the same update that
  # moves the row to `:acting`, and `graduate/2` — the only writer of
  # `task_id` / `canvas_id` — runs strictly after that, so an armed card
  # has nil ids by construction. The fixtures below assert that rather
  # than assuming it.
  defp armed_kind(secs, kind) do
    candidate(%{acts_at: DateTime.add(@now, secs, :second), outcome_kind: kind})
  end

  # HEEx indents the sentence across lines; the reader sees one line.
  defp sentence(html, candidate) do
    html
    |> node(candidate)
    |> LazyHTML.query(@sentence)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "the armed card names what it is about to make" do
    test "a card aimed at a TASK says so, while both of its ids are still nil" do
      card = armed_kind(24, :task)

      # The premise, asserted rather than assumed: this is what makes
      # `outcome_label/1` — which keys on the ids — unable to answer for
      # an armed card, and `outcome_kind` the only field that can.
      assert card.task_id == nil
      assert card.canvas_id == nil

      html = rail([card])

      # Positive control first: the foot has to be on the page at all.
      assert Enum.any?(foot(html, card))
      assert present?(node(html, card), @sentence)

      assert sentence(html, card) == "Creating a task in"
    end

    test "a card aimed at an ARTIFACT says canvas, never the stored word" do
      card = armed_kind(24, :artifact)

      assert card.task_id == nil
      assert card.canvas_id == nil

      html = rail([card])

      assert Enum.any?(foot(html, card))
      assert present?(node(html, card), @sentence)

      assert sentence(html, card) == "Creating a canvas in"

      # `:artifact` is the STORED member and `canvas` is the word. A
      # catch-all through `to_string/1` would put the schema's vocabulary
      # in front of a human mid-meeting.
      refute sentence(html, card) =~ "artifact"
    end

    # THE ANTI-VACUITY ASSERTION, and it is why both kinds are rendered
    # into ONE rail. A test that exercises only `:task` passes with the
    # bug fully intact: a sentence hard-coded to "task" satisfies every
    # assertion above and still tells a canvas card's reader the wrong
    # thing. Only the inequality catches that.
    test "TWO KINDS IN ONE RAIL do not say the same thing" do
      tasked = armed_kind(24, :task)
      canvassed = armed_kind(24, :artifact)

      html = rail([tasked, canvassed])

      assert Enum.any?(foot(html, tasked))
      assert Enum.any?(foot(html, canvassed))
      assert present?(node(html, tasked), @sentence)
      assert present?(node(html, canvassed), @sentence)

      assert sentence(html, tasked) != sentence(html, canvassed)
    end

    # The hook constraint, asserted in the DOM. `CandidateClock` walks
    # every `[data-role='meeting-candidate-remaining']` once a second and
    # assigns `el.textContent`, so prose INSIDE that node is erased on
    # the first tick — invisible to every server-render test and visible
    # to anyone who watches a real card for one second.
    test "the sentence is a SEPARATE node, and the count is still digits only" do
      card = armed_kind(24, :artifact)
      html = rail([card])
      card_node = node(html, card)

      count_node = LazyHTML.query(card_node, "[data-role='meeting-candidate-remaining']")

      # Positive controls for both refutations below.
      assert present?(card_node, @sentence)
      assert Enum.any?(count_node)

      # The words are not in the node the ticker overwrites...
      refute present?(count_node, @sentence)
      assert text_of(card_node, "[data-role='meeting-candidate-remaining']") == "24"
      assert text_of(card_node, "[data-role='meeting-candidate-remaining']") =~ ~r/\A\d+\z/

      # ...and the number is not restated in the words.
      refute sentence(html, card) =~ ~r/\d/
    end

    test "a DISARMED card carries no sentence at all" do
      armed_card = armed_kind(24, :task)
      disarmed = candidate(%{acts_at: nil, outcome_kind: :task})

      html = rail([armed_card, disarmed])

      # The control: this page does render the sentence. `countdown_foot/1`
      # is gated on `armed?/1`, so the spent row, the closed row and the
      # skeleton are all untouched by this stage.
      assert present?(node(html, armed_card), @sentence)

      refute present?(node(html, disarmed), @sentence)
    end

    # REGRESSION on the half that was ALREADY CORRECT, asserted without
    # modifying it. `outcome_label/1` is rendered at
    # `[data-role='meeting-candidate-outcome']` and distinguishes the two
    # kinds after graduation; the ticket's claim that it is dead code is
    # wrong, and this stage must not make it true.
    test "the graduated half still names its deliverable, and still distinguishes them" do
      tasked = candidate(%{state: :acting, task_id: Ecto.UUID.generate()})
      canvassed = candidate(%{state: :acting, canvas_id: Ecto.UUID.generate()})

      html = rail([tasked, canvassed])

      outcome = "[data-role='meeting-candidate-outcome']"

      assert present?(node(html, tasked), outcome)
      assert present?(node(html, canvassed), outcome)

      tasked_text = text_of(node(html, tasked), outcome)
      canvassed_text = text_of(node(html, canvassed), outcome)

      assert tasked_text =~ "Added to Tasks"
      assert canvassed_text =~ "Added to Canvas"
      assert tasked_text != canvassed_text
    end
  end

  # ── 8. The rail is ordered by deadline (task 01a0740e stage 4) ────────

  describe "rail order" do
    # THE DERANGEMENT, and it is the whole point of the fixture.
    #
    # Insertion order is [a, b, c]; deadline order is [c, a, b]. The two
    # disagree at EVERY position, so a sort that quietly fell back to
    # `inserted_at` — the old `stage_rank/1` tie-break, and the exact
    # regression this stage exists to prevent — cannot coincidentally
    # pass. Neither can "no sort at all": the list is handed in as
    # [b, c, a], which is a third order again.
    #
    # Every card is `:acting`, so the stage axis is CONSTANT. Under the
    # old rule these three sorted purely by arrival, which is the
    # behaviour being overturned.
    defp deranged do
      a = armed(10, 0)
      b = armed(20, 1)
      c = armed(5, 2)
      {a, b, c}
    end

    test "armed cards read soonest-to-fire first, not first-arrived first" do
      {a, b, c} = deranged()

      order = rail_order(rail([b, c, a]))

      # Positive control: three cards actually rendered. Without it every
      # assertion below is a claim about an empty list.
      assert length(order) == 3

      assert order == ids([c, a, b])

      # The two mutations named in the stage notes, refuted explicitly
      # rather than left to the equality above: arrival order, and the
      # order the caller happened to pass in.
      refute order == ids([a, b, c])
      refute order == ids([b, c, a])
    end

    test "an UNARMED open card sits below every armed one" do
      # Stacked against the new rule on both of the old axes: it arrived
      # BEFORE either armed card, and `:heard` is stage rank 0. Arrival
      # order and stage order both put it on top; only the deadline rule
      # puts it at the bottom.
      unarmed =
        candidate(%{
          state: :heard,
          acts_at: nil,
          inserted_at: DateTime.add(@now, -30, :second)
        })

      soon = armed(5, 0)
      later = armed(25, 1)

      order = rail_order(rail([unarmed, later, soon]))

      assert length(order) == 3
      assert order == ids([soon, later, unarmed])

      # Stated as a relation too, so the claim survives a fixture edit:
      # a card with no deadline is below every card that has one.
      assert Enum.find_index(order, &(&1 == unarmed.id)) == 2
    end

    test "a frozen `order` holds a stale sequence that an unfrozen render does not" do
      {a, b, c} = deranged()
      cards = [b, c, a]

      # The frozen sequence is a real stale reading — what the rail
      # showed before the deadlines moved — and it is neither the live
      # order nor the arrival order.
      stale = ids([b, a, c])

      assert rail_order(rail(cards, stale)) == stale

      # THE CONTROL, and it is the load-bearing half. The same list, the
      # same render, no freeze: a rail that ignored `order` entirely
      # would pass the line above only if the fixture happened to agree
      # with the live sort. It does not.
      assert rail_order(rail(cards, nil)) == ids([c, a, b])
      refute rail_order(rail(cards, nil)) == stale
    end

    test "a card that arrived after the freeze is appended below the frozen ones" do
      {a, b, c} = deranged()

      # Soonest to fire of all four. Under the live sort it would be
      # first; a frozen rail must still SHOW it, and must not let it
      # jump the cards the reader is looking at.
      arrived = armed(1, 3)

      stale = ids([b, a, c])
      order = rail_order(rail([arrived, b, c, a], stale))

      assert length(order) == 4
      assert order == stale ++ [arrived.id]
    end

    test "display_order/1 answers exactly what the rail draws" do
      # The seam the freeze is captured through: the LiveView calls this
      # instead of trusting ids from the browser, so it has to be the
      # same sort the render runs. Asserted against the DOM rather than
      # against a hand-written list, which is what makes it a comparison
      # and not a second copy of the rule.
      {a, b, c} = deranged()
      unarmed = candidate(%{state: :heard, acts_at: nil, inserted_at: @now})

      cards = [b, unarmed, c, a]

      assert CandidateRail.display_order(cards) == rail_order(rail(cards))
      assert length(CandidateRail.display_order(cards)) == 4
    end
  end

  describe "the spent row a stop leaves behind" do
    # `do_stop/3` nulls `acts_at` as part of the UPDATE that wins the
    # race against the sweeper, so by the time the rail re-renders the
    # stopped card's sort position no longer exists on the row. The
    # stash carries it, and these tests are about the rail putting it
    # back in that slot rather than at the end of the list.
    defp undo(candidate, secs \\ 10) do
      %{
        id: candidate.id,
        acts_at: candidate.acts_at,
        expires_at: DateTime.add(@now, secs, :second)
      }
    end

    test "it renders IN the slot the card held, not appended below the rail" do
      # Deadlines 5s and 20s apart, so the stopped card belongs at the
      # TOP. An implementation that appends the spent row — the obvious
      # one, and the one this test exists to fail — puts it second.
      soonest = armed(5, 0)
      later = armed(20, 1)

      html = rail([later], nil, undo(soonest))

      assert row_order(html) == [soonest.id, later.id]

      # The control: the same two cards with no stop at all put the
      # soonest FIRST too, so the assertion above is about placement and
      # not about a spent row that happens to sort to the top always.
      assert rail_order(rail([soonest, later])) == [soonest.id, later.id]
    end

    test "and BELOW a card that was armed sooner than the one that was stopped" do
      # The mirror of the test above. Together they rule out a spent row
      # pinned to either end of the rail: one of the two would fail.
      soonest = armed(5, 0)
      stopped = armed(20, 1)

      assert row_order(rail([soonest], nil, undo(stopped))) == [soonest.id, stopped.id]
    end

    test "it offers NO stop control, no count and no drain" do
      stopped = armed(12, 0)
      html = rail([], nil, undo(stopped))

      row = spent_node(html)

      # The card this row replaces carried all three. The POSITIVE
      # control is the same fixture drawn as a live card: without it
      # every `refute` below would also pass against a rail that drew
      # nothing at all.
      live = LazyHTML.from_fragment(rail([stopped]))
      assert present?(live, "[data-role='meeting-candidate-stop']")
      assert present?(live, "[data-role='meeting-candidate-remaining']")
      assert present?(live, "[data-role='meeting-candidate-drain']")

      assert Enum.any?(row)
      refute present?(row, "[data-role='meeting-candidate-stop']")
      refute present?(row, "[data-role='meeting-candidate-remaining']")
      refute present?(row, "[data-role='meeting-candidate-drain']")

      # What it DOES carry.
      assert LazyHTML.text(row) =~ "Stopped"
      assert present?(row, "[data-role='meeting-candidate-undo']")
    end

    test "the undo control is wired to the server, not to a class name" do
      stopped = armed(12, 0)
      row = spent_node(rail([], nil, undo(stopped)))

      button = LazyHTML.query(row, "[data-role='meeting-candidate-undo']")

      assert LazyHTML.attribute(button, "phx-click") == ["undo_stop_candidate"]
      assert LazyHTML.attribute(button, "phx-value-candidate_id") == [stopped.id]
    end

    test "it publishes its own expiry, and is GONE once that instant has passed" do
      stopped = armed(12, 0)

      row = spent_node(rail([], nil, undo(stopped, 10)))
      expires_at = DateTime.add(@now, 10, :second)
      assert LazyHTML.attribute(row, "data-expires-at") == [DateTime.to_iso8601(expires_at)]

      # The SERVER re-checks the same instant, so a reload after the
      # window does not bring the row back — the client ticker is the
      # belt and this is the braces.
      assert rail([], nil, undo(stopped, -1)) |> spent_node() |> Enum.empty?()
    end

    test "no undo stash means no spent row" do
      assert rail([armed(12, 0)], nil, nil) |> spent_node() |> Enum.empty?()
    end
  end

  describe "the activity log covers every kind that can be written" do
    test "every MeetingCandidateEvent kind has a line" do
      # `event_line/2` has one clause per kind and NO catch-all, which is
      # deliberate — a derived or invented line is the defect the log
      # exists to remove. The cost of that choice is that a new kind
      # raises FunctionClauseError on a real rail, so the set is walked
      # here and this test is what fails first.
      for kind <- MeetingCandidateEvent.kinds() do
        line = CandidateDisplay.event_line(kind, %{})

        assert is_binary(line) and line != "",
               "no activity-log line for the #{inspect(kind)} event kind"
      end
    end
  end

  # ── A closed row that produced something (task 01a078d0 stage 2) ──────

  describe "the closed row names its deliverable and can reach it" do
    test "a task row and a canvas row carry DIFFERENT hrefs and DIFFERENT kind labels" do
      # ONE fixture proves nothing about a branch. Two rows differing only
      # in WHICH id they carry must produce two different routes and two
      # different class markers, or the row is not distinguishing the
      # kinds at all — it is printing the same markup twice.
      task_row =
        closed_accepted(%{
          evidence_quote: "rotate the staging secrets",
          task_id: "01a078d0-bedd-7001-a3d5-ee9c6c85aa59"
        })

      canvas_row =
        closed_accepted(%{
          evidence_quote: "write up what we agreed",
          canvas_id: "01a07a60-8cbd-7001-8000-dab13283b524",
          outcome_kind: :artifact,
          closed_at: DateTime.add(@now, -60, :second)
        })

      html = rail_closed([task_row, canvas_row])

      task_link = link_in(closed_row(html, task_row))
      canvas_link = link_in(closed_row(html, canvas_row))

      # ORDER IS LOAD-BEARING. The title assertion is keyed on the
      # `data-role` and NOT on the `a` tag, so it holds whether the row
      # renders a link or falls back to a `<p>` — and it is asserted
      # FIRST so that the mutation below (`task_id: nil` on this
      # fixture) reddens the href assertion while this one is still
      # reached and still green. Two assertions that go red together are
      # one assertion wearing two names.
      assert title_of(html, task_row) == "rotate the staging secrets"

      # THE VALUE, not the presence of a label. "Added to Tasks" with no
      # href is the defect this row exists to fix, wearing better copy.
      assert attr(task_link, "href") == "/tasks/01a078d0-bedd-7001-a3d5-ee9c6c85aa59"
      assert attr(canvas_link, "href") == "/canvases/01a07a60-8cbd-7001-8000-dab13283b524"
      refute attr(task_link, "href") == attr(canvas_link, "href")

      assert kind_of(html, task_row) == "TASK"
      assert kind_of(html, canvas_row) == "CANVAS"
      refute kind_of(html, task_row) == kind_of(html, canvas_row)

      # The link IS the title — one tap target, and the words are the
      # quote, which is also what `deliverable_title/2` mints from.
      assert LazyHTML.text(task_link) |> String.trim() == "rotate the staging secrets"

      # `Done` is REPLACED, not appended to. It spends the most scannable
      # position on the one fact the reader already has.
      refute present?(closed_row(html, task_row), "[data-role='meeting-candidate-closed-reason']")
      refute LazyHTML.to_html(closed_row(html, task_row)) =~ "Done"

      # The spent bar, only on a row that reached something.
      assert present?(closed_row(html, task_row), "[data-role='meeting-candidate-closed-bar']")
      assert present?(closed_row(html, canvas_row), "[data-role='meeting-candidate-closed-bar']")
    end

    test "an accepted row that reached NOTHING renders no anchor, no kind label and no bar" do
      # Reachable in production: `Candidates.record_only_close/1` writes
      # `:accepted` with `queue_status: "completed"` and mints nothing —
      # the ack arm for an `:artifact` candidate or one that was never
      # armed. A link built from a nil id would be worse than the gap.
      empty =
        closed_accepted(%{evidence_quote: "someone should look at the invoice", task_id: nil})

      html = rail_closed([empty])
      row = closed_row(html, empty)

      assert Enum.any?(row)
      refute present?(row, "a[data-role='meeting-candidate-title']")
      refute present?(row, "[data-role='meeting-candidate-outcome-kind']")
      refute present?(row, "[data-role='meeting-candidate-closed-bar']")
      refute LazyHTML.to_html(row) =~ "href="

      # What it DOES say, and no error colour or retry anywhere near it.
      assert text_of(row, "[data-role='meeting-candidate-closed-outcome']") ==
               "Nothing was created"

      assert title_of(html, empty) == "someone should look at the invoice"
    end

    test "a NON-accepted closed row is untouched: its reason line, and no link" do
      # The whole value of the Closed section, and an existing board test
      # asserts this string on the real route. A disposition-blind
      # renderer would strip it.
      vetoed =
        closed_accepted(%{
          evidence_quote: "let us buy the expensive one",
          disposition: :rejected,
          closed_reason: :duplicate,
          closed_note: "01a03f57",
          task_id: "01a078d0-bedd-7001-a3d5-ee9c6c85aa59"
        })

      html = rail_closed([vetoed])
      row = closed_row(html, vetoed)

      assert text_of(row, "[data-role='meeting-candidate-closed-reason']") ==
               "Already on the backlog — 01a03f57"

      # It carries a `task_id`, and it still gets no link: the treatment
      # is keyed on the DISPOSITION, so a rejected duplicate that happens
      # to point at the row it duplicates does not become a link.
      refute present?(row, "a[data-role='meeting-candidate-title']")
      refute present?(row, "[data-role='meeting-candidate-outcome-kind']")
      refute present?(row, "[data-role='meeting-candidate-closed-bar']")
    end
  end

  # A closed, accepted row. `closed_at` is required rather than defaulted
  # to nil because the rail sorts the closed list on it.
  defp closed_accepted(attrs) do
    %{
      state: :closed,
      closed_reason: :done,
      closed_at: @now,
      disposition: :accepted,
      disposition_at: @now,
      outcome_kind: :task,
      classified_intent: "action_item"
    }
    |> Map.merge(Map.new(attrs))
    |> candidate()
  end

  defp rail_closed(closed) do
    render_component(&CandidateRail.candidate_rail/1,
      candidates: [],
      closed: closed,
      events: %{},
      now: @now
    )
  end

  defp closed_row(html, %MeetingCandidate{id: id}) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='meeting-candidate-closed-card'][data-candidate-id='#{id}']")
  end

  # `query/2` descends; `filter/2` would match only the fragment's ROOT
  # nodes and answer `[]` for anything inside the `<details>`.
  defp link_in(row), do: LazyHTML.query(row, "a[data-role='meeting-candidate-title']")

  defp title_of(html, candidate),
    do: text_of(closed_row(html, candidate), "[data-role='meeting-candidate-title']")

  defp kind_of(html, candidate),
    do: text_of(closed_row(html, candidate), "[data-role='meeting-candidate-outcome-kind']")

  defp attr(nodes, name), do: nodes |> LazyHTML.attribute(name) |> List.first()
end
