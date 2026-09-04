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

  alias Platform.Meetings.MeetingCandidate
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

  defp index_of(roles, role), do: Enum.find_index(roles, &(&1 == role))

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
end
