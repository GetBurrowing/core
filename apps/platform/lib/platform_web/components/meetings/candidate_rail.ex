defmodule PlatformWeb.Components.Meetings.CandidateRail do
  @moduledoc """
  The live meeting task board — one CARD per candidate (task
  01a03f4e-78b1).

  This replaces `PlatformWeb.Components.Meetings.CandidateCountdown`,
  which rendered each armed candidate as a single list row
  (`30s  "…"  [Stop]`) and rendered nothing at all for a candidate that
  was not armed. Three consequences of that shape are what this module
  exists to fix:

    * A candidate in `:heard`, `:thinking` or `:shaping` was invisible.
      Only `acts_at != nil` reached the DOM, so the board showed the
      last two seconds of a card's life and none of the rest.
    * A CLOSED candidate was invisible too — which is the exact
      opposite of the ticket's decision 3, *"killed cards do not
      vanish… they keep their reason"*. The rail was a queue; it is
      supposed to be a record.
    * Every row rendered identically, so the mockup's organising idea —
      **colour is earned, never given** — had nothing to sort by. A grey
      card has cost nobody anything; a coloured one has passed a gate
      and has an agent's name on it. That distinction only works if the
      two look different.

  ## Presentation is keyed on `classified_intent`, not only on `state`

  The mockup draws the stage-1 skeleton as "no title — at that point we
  genuinely do not know what it is". The row that matches that
  description is not simply `state == :heard`: `record_heard/1` opens a
  row at `:heard` carrying the utterance, and `reconcile/2` later writes
  `classified_intent` onto that same row WITHOUT advancing `state` (the
  advance comes separately, from `IntentQueue.Server`). So there is a
  real window in which a card is `:heard` and already classified.

  Keying the skeleton on `state` alone would hold the shimmer up over a
  card the system had already worked out, which is the "progress bar
  that lies" failure in its purest form. `presentation/1` therefore
  answers `:skeleton` only while `classified_intent` is nil — the
  literal condition the mockup's caption describes.

  ## The countdown follows `acts_at`, NOT the stage

  The mockup draws the clock only on stage 4. The system does not arm
  cards there: `record_heard/1` sets `acts_at` at `:heard`, and
  `Platform.Meetings.Candidates.claim_due/2` is what moves a row to
  `:acting` — *after* the deadline has already passed. Rendering the
  countdown on `state == :acting` would therefore show it only on cards
  whose countdown had finished.

  So the count and its drain render whenever `acts_at` is set, at
  whatever stage, and the stage colouring is a separate axis. This is a
  deliberate divergence from the mockup, and it is the direction that
  keeps the number true.

  ## The rail is ordered by DEADLINE, not by stage

  Concurrency is normal — several cards are open at once — and POSITION
  is what says which of them is about to commit. So open cards that are
  ARMED sort by `acts_at` ASCENDING, soonest to fire at the top,
  tie-broken by `inserted_at` so two cards armed in the same second hold
  a stable order. In arrival order a card at 3 seconds can sit below a
  card at 28, and the one about to irreversibly act is then the one a
  reader is least likely to look at.

  Sorting on `acts_at` rather than on remaining seconds is not an
  approximation. The countdown is 30 seconds globally and every card in
  one render is measured against one `now`, so "least time remaining"
  and "earliest deadline" are the same ordering. Sorting the stored
  column keeps the sort deterministic, independent of `now`, and
  testable without freezing a clock.

  UNARMED open cards (review mode, `acts_at == nil`) sit BELOW every
  armed card and keep stage order among themselves. A card with no
  deadline cannot compete for urgency; folded into one sort it would
  either park above everything or read as though it had a full thirty
  seconds left. The Closed disclosure is untouched and stays newest
  first.

  ## Order FREEZES while a pointer is over the rail

  The cost of ordering by deadline is that a card can move while
  somebody is reading it, and slide a different card under a cursor that
  was on its way to `Stop`. The `order` attr is the mitigation: when it
  holds a list of candidate ids those cards render in exactly that
  sequence, and any card not named in it is appended below in the normal
  order. `CandidateClock` pushes `candidate_rail_freeze` on
  `pointerenter` and `candidate_rail_thaw` on `pointerleave`; the
  LiveView captures `display_order/1` into the assign in between.

  It is insurance against three discrete events, not a cure for churn.
  With one global thirty-second window and one `now` per render the sort
  key is STATIC, so the order can only change when a card arrives, when
  a card fires or is stopped and leaves, or when
  `Platform.Meetings.Candidates.attach_utterance/2` pushes one card's
  `acts_at` forward. Held for the length of a hover none of the three
  can move the ground under a click. Held longer the rail would lie
  about urgency, which is why the assign clears on `pointerleave` and
  not on a timer.

  ARRIVAL and DEPARTURE are animated (`phx-mounted` / `phx-remove`); a
  REORDER is not. A true position animation means measuring every card
  on every patch in JS, which is real weight bought for an event that
  fires a handful of times in a meeting. If a busy gate proves that
  wrong, the answer is that measurement and not abandoning the order.

  ## Review mode versus act mode

  The ticket's two modes are not a third column; they fall out of
  `acts_at`, which `Platform.Meetings.automation_mode/1` already
  governs:

    * `acts_at != nil` — **act**: the count and its drain, and a stop
      control that calls `Candidates.stop/3`.
    * `acts_at == nil` on an open card — **review**: `Not now` /
      `Go ahead`, which call `close/2` and `graduate/2`.

  A card in review mode has no deadline to draw and a card counting down
  has already had its permission granted by the meeting's automation
  mode, so the two are mutually exclusive by construction rather than by
  an `:if` somebody has to keep consistent.

  ## What is deliberately NOT here

  **`↻ extended — still being discussed`.** The mockup draws it and the
  ticket asks for it, and there is nothing truthful to put behind it
  yet. `Platform.Meetings.Countdown`'s moduledoc measures why:
  `ThreadResolver.gate/3` requires `same_speaker?/2`, so a colleague
  agreeing opens a new card instead of extending this one; and the
  threading window is 60s against a 30s countdown, so a same-speaker
  continuation at t=45 arrives at a card that has already fired. Both
  limits are pinned by tests in `test/platform/meetings/countdown_test.exs`.
  An extension line that rendered on a static condition would be
  decoration; one that rendered on a real extension would be dead code
  today. It is left out, and this paragraph is why.

  **The raw storage vocabulary.** Every user-visible string and every
  `data-` slug goes through
  `PlatformWeb.Components.Meetings.CandidateDisplay`. See that module
  for the argument; the short version is that a card must not tell a
  colleague their idea was *vetoed*.
  """

  use PlatformWeb, :html

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias Platform.Meetings.Countdown
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  # Stage order, and it now ranks ONLY the cards that have no deadline.
  #
  # This comment used to read "ascending stage order, so the rail reads
  # as the mockup lays it out: heard → thinking → taking shape →
  # acting". That is no longer true of the rail as a whole, and it is
  # rewritten rather than left standing: a stale comment about a sort is
  # how the next reader puts the old sort back. `sort_open/2` places
  # ARMED cards above these, ordered by `acts_at`; the moduledoc section
  # "The rail is ordered by DEADLINE, not by stage" carries the argument.
  #
  # A rank is still needed for the unarmed remainder, because
  # `open_for_meeting/1` returns newest-first — the right order for a
  # threading question and the wrong one for a board.
  @stage_rank %{heard: 0, thinking: 1, shaping: 2, acting: 3, closed: 4}

  # A DOM id is REQUIRED by `phx-hook` and must be unique on the page.
  # `call_rail/1` is rendered on the meeting route AND in the chat
  # quickmeet panel under two different ids, so this one is derived from
  # the caller's rather than hard-coded: a duplicate id is the failure
  # where LiveView patches one rail's cards into the other's.
  attr(:id, :string, default: "meeting-candidate-rail")
  attr(:candidates, :list, default: [])
  attr(:closed, :list, default: [])
  attr(:events, :map, default: %{})
  attr(:now, :any, default: nil)
  attr(:error, :string, default: nil)

  # The FROZEN order — a list of candidate ids, or nil for "sort
  # normally". Defaults to nil so `call_shell/1`, which renders this rail
  # for the in-chat quickmeet and passes neither `now` nor an order,
  # keeps getting a live sort rather than an empty one.
  attr(:order, :list, default: nil)

  # THE UNDO STASH, or nil — `%{id:, acts_at:, expires_at:}`, written by
  # `PlatformWeb.MeetingLive.apply_candidate_stop/2` on the socket that
  # handled the click.
  #
  # It is a PER-SOCKET affordance and not a broadcast one, which is why
  # it arrives as an attr rather than being derived from the candidate
  # list: the participant who pressed stop is offered the undo, and
  # everybody else sees the card move to Closed, which is what actually
  # happened. Defaults to nil, so `call_shell/1`'s quickmeet rail — which
  # has no stop handler of its own — keeps rendering exactly as before.
  attr(:undo, :map, default: nil)

  # THE CORRECTION ROSTER — the agents this rail may offer to hand a card
  # to, as `[%{id:, name:}]`, or `nil` for "this surface cannot correct"
  # (task 01a0740e stage 2).
  #
  # `nil` IS THE DEFAULT AND IT IS LOAD-BEARING, exactly as it is for
  # `order` and `undo` above. `candidate_rail/1` is rendered from
  # `call_shell.ex` on TWO surfaces: the meeting route, whose
  # `MeetingLive` carries the five `candidate_correct_*` handlers, and
  # the chat quickmeet panel, whose `ChatLive` does not. On nil this
  # module renders NO pencil and NO panel, so the quickmeet rail cannot
  # grow a button whose event nothing on that surface can handle.
  #
  # `[]` IS NOT `nil` and the two must not be collapsed. An empty list is
  # "this surface can correct, and there is no other agent in the room to
  # hand the card to" — a real state in a one-agent meeting, in which the
  # pencil and the panel still render and offer the flip and
  # `Not an action`. A panel that vanished in a one-agent room would take
  # the two working choices away with the one that had nothing to list.
  #
  # The CURRENTLY ASSIGNED agent is filtered out per card in
  # `correction_panel/1`, not here: one roster serves every card on the
  # rail, and `Candidates.correct/3` refuses a same-agent reassign
  # anyway, so offering it would be offering a choice that cannot work.
  attr(:correction_agents, :list, default: nil)

  # WHICH card has its correction panel open, or nil for none — the
  # `:candidate_correcting_id` assign, following the existing
  # `:intent_reason_picker_id` pattern. One panel at a time, because two
  # open panels on a 312px rail is two thirds of the rail spent on
  # controls for cards the reader has stopped looking at.
  #
  # A PER-SOCKET affordance like `undo`, and for the same reason: the
  # participant who pressed the pencil is the one reading the choices.
  # The RE-ARM the press caused is server state and every rail moves;
  # only the open drawer is local.
  attr(:correcting_id, :string, default: nil)

  @doc """
  Render the board.

  Renders NOTHING — not an empty container — when the meeting has
  produced no candidates at all, matching the posture of the rail this
  replaces: there is no layout space to reserve for a board with nothing
  on it, and the chat pane it sits above is the surface people are
  actually using.

  `@error` keeps the section alive with no open cards, because the
  message it carries (*"too late — this one already went ahead"*) is by
  definition about a card that has just left the open list.
  """
  def candidate_rail(assigns) do
    now = assigns.now || DateTime.utc_now()

    open =
      assigns.candidates
      |> maybe_spent(Map.get(assigns, :undo), now)
      |> sort_open(Map.get(assigns, :order))

    closed = Enum.sort_by(assigns.closed, & &1.closed_at, {:desc, DateTime})

    assigns =
      assigns
      |> assign(:open, open)
      |> assign(:closed, closed)
      |> assign(:now, now)

    ~H"""
    <section
      :if={@open != [] or @closed != [] or @error}
      id={@id}
      class="border-edge bg-base-200/40 border-b px-3 py-3"
      phx-hook="CandidateClock"
      data-role="meeting-candidate-countdown-rail"
    >
      <%!-- `Cards ● appearing live` — the drawing's own words, and an
           ACTIVITY statement rather than a label for a container. The
           count chip the previous heading carried is gone: the drawing
           does not contain one, and `2` beside a list of two cards
           restates what the reader is already looking at.

           The dot stays SUCCESS, not the mockup's amber. Amber is
           spoken for on this screen — the canvas's own slot map gives
           `--color-warning` exactly one meaning, "you are being asked
           for something", which is the invite banner and nothing else.
           A live-activity dot is asking for nothing. --%>
      <header class="mb-3 flex items-center gap-2">
        <h3
          class="text-base-content flex items-center gap-1.5 text-[11px] font-semibold tracking-[0.09em] uppercase"
          data-role="meeting-candidate-rail-heading"
        >
          Cards <span class="candidate-rail-dot" aria-hidden="true"></span> appearing live
        </h3>
      </header>

      <%!-- ONE loop, two row shapes. A spent row is not a second list
           and not a corner toast: it is drawn in the slot its card
           occupied, sorted by the same `acts_at` the live card was
           sorted on, so the eye that was on the card finds the undo
           where the card was. Written as an explicit comprehension with
           two guarded component calls rather than two `:for` loops,
           because two loops would emit every card and then every spent
           row, which is exactly the ordering this stage exists to
           preserve. --%>
      <div :if={@open != []} class="flex flex-col gap-2">
        <%= for row <- @open do %>
          <.spent_card :if={spent?(row)} rail_id={@id} row={row} />
          <.live_card
            :if={not spent?(row)}
            rail_id={@id}
            candidate={row}
            now={@now}
            events={@events}
            correction_agents={@correction_agents}
            correcting_id={@correcting_id}
          />
        <% end %>
      </div>

      <details :if={@closed != []} class="candidate-closed" data-role="meeting-candidates-closed">
        <summary class="candidate-closed__summary" data-role="meeting-candidates-closed-summary">
          {length(@closed)} closed
        </summary>

        <div class="mt-2 flex flex-col gap-2">
          <.closed_card :for={candidate <- @closed} candidate={candidate} />
        </div>
      </details>

      <p :if={@error} class="text-base-content mt-2 text-xs" data-role="meeting-candidate-error">
        {@error}
      </p>
    </section>
    """
  end

  # ── Rows ──────────────────────────────────────────────────────────────

  # ONE live card. Lifted out of the rail's comprehension unchanged in
  # task 01a0740e stage 5, so a spent row can be drawn in the same
  # sequence without the loop growing a second branch inside the
  # `<article>` itself.
  attr(:rail_id, :string, required: true)
  attr(:candidate, :map, required: true)
  attr(:now, :any, required: true)
  attr(:events, :map, required: true)
  attr(:correction_agents, :list, default: nil)
  attr(:correcting_id, :string, default: nil)

  defp live_card(assigns) do
    ~H"""
    <article
      id={"#{@rail_id}-card-#{@candidate.id}"}
      phx-mounted={JS.transition("candidate-card--enter", time: 200)}
      phx-remove={JS.transition("candidate-card--leave", time: 200)}
      class={[
        "candidate-card",
        "candidate-card--#{CandidateDisplay.slug(@candidate.state)}",
        forming?(@candidate) && "candidate-card--forming"
      ]}
      data-role="meeting-candidate-card"
      data-candidate-id={@candidate.id}
      data-stage={CandidateDisplay.slug(@candidate.state)}
    >
      <%!-- THE LADDER RUNG (task 01a0e47c stage 3, canvas 01a0e47d-3005).
             `1 · HEARD` was removed from the FORMING card below for a
             real reason (see that comment) — a bare ordinal is a fact
             about the pipeline, not the card, while it is still
             shimmering with nothing to show. A `:full` card is past
             that: it already carries a title, a quote and a byline, so
             a small rung label ADDS the one thing the product lead named
             explicitly missing — "the connection to the cards" — without
             repeating the removed defect, because there is a real card
             here for the number to be ABOUT.

             This is deliberately the SAME text
             `CandidateDisplay.stage_label/1` already produces (no
             second copy of "3 · taking shape" invented here). It used to
             also share classes with the ask-veil's own `meeting-ask-step`
             node (`ParticipantRail`); task 01a0fa7e-afd7 retired that
             node along with the rest of round 2's dashed "HEARD box"
             (the live heard text now lives in its own floating overlay,
             `meeting-ask-heard-overlay`, which carries no numbered rung
             at all — just a status line and the text window) — a viewer
             who watched "Listening while you hold" in that overlay and
             then sees "3 · taking shape" here, on the card that flew out
             of the hold (`data-candidate-id` matches the
             `meeting_ask_outcome` payload's `candidate_id`), still reads
             this label as the next rung of the SAME ladder the hold
             started climbing, just without a matching "1 · heard" label
             on the overlay side any more.
             Per the design canvas's self-critique this is NOT a running
             1-2-3 counter across the two surfaces — the numbers are
             fixed rungs (heard=1, thinking=2, shaping=3, acting=4) and
             the object flying between them is what carries continuity,
             this label just makes each rung legible where it lands.

             `presentation(@candidate) == :full` is exactly "shaping or
             acting" here — a live (non-closed) card only reaches `:full`
             once it has left `:heard`/`:thinking` (see `presentation/1`)
             — so this can never appear beside the forming sentence
             above, which is gated on the complementary
             `forming?(@candidate)`. The kind note (`TASK`/`CANVAS`)
             rides along when one is known: `outcome_kind_label/1` once
             a deliverable exists, `armed_outcome_label/1` while it is
             still armed and counting down — the same two functions
             `card_head`/`countdown_foot` already trust for that fact,
             not a third guess at it here. --%>
      <p
        :if={presentation(@candidate) == :full}
        class="text-[10px] font-semibold uppercase tracking-wider text-subtle"
        data-role="meeting-candidate-step"
      >
        {step_label_text(@candidate)}
      </p>

      <%!-- ACTOR AND ACTION, where the numbered stage label used to
             be. `1 · HEARD` named a position in a state machine, which
             is a fact about our pipeline rather than about the card;
             the drawing leads a still-forming card with a sentence
             about who is working on it instead.

             It renders ONLY while a card is still forming and ONLY
             when an agent is actually named. A placeholder actor
             ("someone is forming a card") is the same defect as a
             placeholder byline — a claim the card cannot back — so
             with no agent there is no sentence, and the skeleton
             bars beneath already say the card is in progress. --%>
      <p
        :if={forming?(@candidate) and CandidateDisplay.agent_name(@candidate)}
        class="candidate-card__forming"
        data-role="meeting-candidate-forming"
      >
        <span class="candidate-card__forming-dot" aria-hidden="true"></span>
        {CandidateDisplay.agent_name(@candidate)} is forming a card…
      </p>

      <.card_head candidate={@candidate} now={@now} />

      <.activity_log
        :if={presentation(@candidate) in [:skeleton, :forming]}
        lines={Map.get(@events, @candidate.id, [])}
        candidate_id={@candidate.id}
      />

      <%!-- `✓ Added to Tasks`. Drawn from a stored `task_id` /
             `canvas_id`, never from `state == :acting`: `graduate/2`
             can fail against an archived project and leave the row
             acting with no deliverable, so a state-keyed label would
             announce a task that was never created. --%>
      <p
        :if={CandidateDisplay.outcome_label(@candidate)}
        class="candidate-card__outcome"
        data-role="meeting-candidate-outcome"
      >
        <span aria-hidden="true">✓</span>
        {CandidateDisplay.outcome_label(@candidate)}
      </p>

      <%!-- WHO IT WENT TO — the card's LAST WRITTEN LINE, below the
             quote, which is the whole point of moving it. Under the
             title it read as attribution: a verbatim sentence with an
             agent's name directly beneath it says that agent said it.
             Last, after the evidence, it reads as what it is — where
             this is going next. Reading order is now what it is →
             who said it → the words → who will action it.

             Still a SEPARATE element from the byline, never joined to
             it. `target_label/2` absorbs the `"null"` sentinel, so an
             unrouted card says `unassigned` and never `@null`. --%>
      <p
        :if={presentation(@candidate) != :skeleton}
        class="candidate-card__assignment"
        data-role="meeting-candidate-assignment"
      >
        <span aria-hidden="true">→</span>
        {assignment(@candidate)}
      </p>

      <%!-- The APPROVAL GATE, and everything that argues for it.
             None of this is in the drawing, and it is kept anyway:
             `Not now` / `Go ahead` call `close/2` and `graduate/2`,
             and `1 utterance` is the evidence a reader weighs before
             pressing either. Deleting a live gate to match a static
             picture would remove a feature the picture simply never
             had a reason to draw. They move BELOW the assignment,
             so the card still READS in the drawing's order and the
             controls sit under it as controls. --%>
      <p
        :if={presentation(@candidate) == :full}
        class="candidate-card__chips"
        data-role="meeting-candidate-chips"
      >
        <span class="candidate-card__chip" data-role="meeting-candidate-utterances">
          {utterance_count(@candidate)}
        </span>
      </p>

      <p
        :if={Map.get(@candidate, :outcome_kind) != :artifact}
        class="text-sm text-subtle"
        data-role="meeting-candidate-evidence"
      >
        Candidate evidence · Follow-up work is reviewed after the meeting.
      </p>
      <.review_row :if={review?(@candidate)} candidate={@candidate} />

      <.countdown_foot
        :if={armed?(@candidate)}
        candidate={@candidate}
        now={@now}
        correctable?={is_list(@correction_agents)}
        correcting?={@correcting_id == @candidate.id}
      />

      <%!-- THE CORRECTION DRAWER (task 01a0740e stage 2), and it is a
             SIBLING of the foot rather than a child of it — inside the
             `<article>`, after the countdown, pushing the card taller.
             Saru's canvas 01a08322 is the authority and the ruling is
             that the timer stays visible the whole time the panel is
             open: an overlay would cover the one number the reader is
             deciding against, and a card that got shorter to make room
             would move the Stop control they might still want.

             It is out of the foot for a second, mechanical reason. The
             one `CandidateClock` hook on the rail's `<section>`
             re-queries `[data-role="meeting-candidate-countdown"]` every
             tick and rewrites the count and the drain inside it. Three
             buttons and a footnote living in that subtree would be
             re-measured once a second for nothing, and any future tick
             that touched more than the two nodes it owns would be
             rewriting a control mid-press.

             Gated on the SAME `is_list/1` as the pencil, so there is no
             arrangement of assigns that renders a panel with no pencil
             or a pencil with no panel. --%>
      <.correction_panel
        :if={armed?(@candidate) and is_list(@correction_agents) and @correcting_id == @candidate.id}
        candidate={@candidate}
        agents={@correction_agents}
      />
    </article>
    """
  end

  # ONE CLOSED ROW, and the only row on this rail that leads anywhere
  # (task 01a078d0 stage 2).
  #
  # ## Why the title is the link and there is no `View` button
  #
  # Saru's canvas "Closed candidate row: design direction"
  # (01a07a60-8cbd) is the design authority, and its ruling is one tap
  # target per row: the deliverable's name IS the link. A trailing
  # button would add a second thing to scan per row in a list read at a
  # glance during a meeting.
  #
  # The name is `evidence_quote`, and that is not an approximation of
  # the real title — `Candidates.deliverable_title/2` derives the minted
  # title from `truncate(candidate.evidence_quote)`, so on this path the
  # quote IS the title. Reading the tasks or canvases table per row to
  # find out would be an N+1 inside a render for a string we already
  # hold.
  #
  # ## Why `Done` is gone from an accepted row
  #
  # The outcome treatment REPLACES `closed_reason_line/2` here rather
  # than appending to it. `Done` spends the most scannable position in
  # the row on the one fact the reader already has: the row is in the
  # Closed list, so it is done. Everything else keeps its reason line —
  # "Already on the backlog — 01a03f57" is the whole value of the Closed
  # section, and a `:vetoed` or `:dismissed` row is UNCHANGED by this
  # component.
  #
  # ## The three shapes, and why they key on `disposition`
  #
  #   * ACCEPTED, deliverable reached — linked title, kind label, bar.
  #   * ACCEPTED, nothing reached — `Nothing was created`, and
  #     deliberately no link, no kind label and no bar. This row is
  #     real: `record_only_close/1` (candidates.ex) writes `:accepted`
  #     with `queue_status: "completed"` and mints nothing, which is the
  #     ack arm for an `:artifact` candidate or one that was never
  #     armed. Absence is the honest rendering, and Saru is explicit
  #     that it gets no error colour and no retry: a red row in a
  #     collapsed list nobody opened is an alarm nobody hears.
  #   * NOT ACCEPTED — the reason line, exactly as before.
  #
  # The link and the kind label are drawn from `outcome_path/1` and
  # `outcome_kind_label/1`, which key on the STORED IDS and never on
  # `state` or `outcome_kind` — see their docs in `CandidateDisplay`.
  # A row that reached nothing therefore cannot render an href, which is
  # the failure mode that matters: a link built from a nil id is worse
  # than the gap it was meant to fill.
  #
  # `evidence_quote` is user-controlled text. It is interpolated, never
  # `raw/1`.
  attr(:candidate, :map, required: true)

  defp closed_card(assigns) do
    candidate = assigns.candidate
    accepted? = Map.get(candidate, :disposition) == :accepted

    assigns =
      assigns
      |> assign(:outcome_path, accepted? && CandidateDisplay.outcome_path(candidate))
      |> assign(:kind_label, accepted? && CandidateDisplay.outcome_kind_label(candidate))
      |> assign(:outcome_line, accepted? && CandidateDisplay.closed_outcome_line(candidate))
      |> assign(
        :reason_line,
        not accepted? &&
          CandidateDisplay.closed_reason_line(candidate.closed_reason, candidate.closed_note)
      )

    ~H"""
    <article
      class={[
        "candidate-card candidate-card--closed",
        (@outcome_path || @outcome_line) && "candidate-card--outcome"
      ]}
      data-role="meeting-candidate-closed-card"
      data-candidate-id={@candidate.id}
      data-closed-reason={CandidateDisplay.closed_reason_slug(@candidate.closed_reason)}
    >
      <%!-- The title truncates and the kind label is `shrink-0`, so a
           long quote never squeezes the class marker out of the row —
           the brand's truncation rule, and the reason the label sits in
           its own flex item rather than inline in the title. --%>
      <div class="candidate-closed__line">
        <a
          :if={@outcome_path}
          href={@outcome_path}
          class="candidate-card__title candidate-closed__link"
          data-role="meeting-candidate-title"
        >
          {@candidate.evidence_quote}
        </a>
        <p
          :if={!@outcome_path}
          class="candidate-card__title candidate-card__title--dead"
          data-role="meeting-candidate-title"
        >
          {@candidate.evidence_quote}
        </p>
        <span
          :if={@kind_label}
          class="candidate-closed__kind"
          data-role="meeting-candidate-outcome-kind"
        >
          {@kind_label}
        </span>
      </div>

      <p :if={@reason_line} class="candidate-card__reason" data-role="meeting-candidate-closed-reason">
        {@reason_line}
      </p>

      <p
        :if={@outcome_line}
        class="candidate-closed__empty"
        data-role="meeting-candidate-closed-outcome"
      >
        {@outcome_line}
      </p>

      <%!-- The live card's drain geometry, held still. It answers the
           question you actually open the disclosure to ask — "is this
           the card I just watched?" — by reusing a shape that is
           already on screen, and it costs nothing to build. Only a row
           that reached something gets one. `aria-hidden` because it
           carries no information a screen reader is missing: the link
           above it says what the row is. --%>
      <span
        :if={@outcome_path}
        class="candidate-drain candidate-drain--spent"
        data-role="meeting-candidate-closed-bar"
        aria-hidden="true"
      >
      </span>
    </article>
    """
  end

  # THE SPENT ROW — what a stop leaves behind, for ten seconds, in the
  # slot the card was in (task 01a0740e stage 5).
  #
  # It carries `Stopped` and `Undo` and NOTHING else. No count, no drain,
  # no stop control: the countdown it is standing in for is over, and a
  # disabled or repeated stop on a row whose whole message is "this is
  # already stopped" would be a control that cannot do anything.
  #
  # `data-expires-at` is the whole expiry mechanism on the client. The
  # rail's single `CandidateClock` ticker is already walking this
  # subtree every second, so the row hides itself off the clock that
  # exists rather than off a server timer, a `Process.send_after/3` per
  # stop, or the hope that another candidate broadcast happens to
  # arrive. The SERVER re-checks the same instant on every render (see
  # `spent_row/2`), so a reload after the window has passed does not
  # bring it back.
  attr(:rail_id, :string, required: true)
  attr(:row, :map, required: true)

  defp spent_card(assigns) do
    ~H"""
    <article
      id={"#{@rail_id}-spent-#{@row.id}"}
      class="candidate-card candidate-card--spent"
      data-role="meeting-candidate-spent"
      data-candidate-id={@row.id}
      data-expires-at={DateTime.to_iso8601(@row.expires_at)}
    >
      <p class="candidate-spent__label" data-role="meeting-candidate-spent-label">
        Stopped
      </p>

      <%!-- Undo is a SAFE action: it reverses a stop and destroys
           nothing, so it is not destructive-styled at rest. Red only on
           hover and focus, through plain CSS selectors — see
           `.candidate-btn--undo` in app.css, and stage 3's identical
           argument for the stop control. --%>
      <button
        type="button"
        phx-click="undo_stop_candidate"
        phx-value-candidate_id={@row.id}
        class="candidate-btn candidate-btn--undo ml-auto"
        data-role="meeting-candidate-undo"
        data-candidate-id={@row.id}
        aria-label="Undo — bring this card back for a decision"
      >
        Undo
      </button>
    </article>
    """
  end

  # ── Card head ──────────────────────────────────────────────────────────

  # The three treatments the mockup draws, in one component so the
  # avatar/title pairing cannot drift between them. `:skeleton` has no
  # avatar and no title BY DESIGN — showing a face there would be a
  # claim the card cannot back up, and inventing a title is how you get
  # a confident card about somebody's dropped audio.
  attr(:candidate, :map, required: true)
  attr(:now, :any, required: true)

  defp card_head(assigns) do
    assigns = assign(assigns, :presentation, presentation(assigns.candidate))

    ~H"""
    <div :if={@presentation == :skeleton} data-role="meeting-candidate-skeleton">
      <span class="candidate-skeleton candidate-skeleton--a"></span>
      <span class="candidate-skeleton candidate-skeleton--b"></span>
      <%!-- No TITLE — nobody has worked out what this is yet, and an
           invented one is a confident card about somebody's dropped
           audio. The VERBATIM fragment is a different thing: it is the
           words that were actually said, which is the one claim a
           forming card can always back. `evidence_quote` is NOT NULL in
           practice — the classifier refuses to emit a candidate without
           one — so a card with no quote is a card nobody can defend. --%>
      <p class="candidate-card__quote" data-role="meeting-candidate-quote">
        {@candidate.evidence_quote}
      </p>
    </div>

    <div :if={@presentation != :skeleton} class="flex items-start gap-2.5">
      <.candidate_avatar candidate={@candidate} presentation={@presentation} />

      <div class="min-w-0 flex-1">
        <%!-- TITLE and BYLINE on ONE LINE, as the drawing sets them:
             `▤ Pricing objection — Sam · just now`. Two elements
             rather than one nested pair, so each reads on its own —
             the title says WHAT THIS IS, the byline says WHO SPOKE, and
             neither can be queried and get the other's words back.

             The title is the CLASSIFIED INTENT, humanised. It is not
             the quote: the drawing carries a short label AND a separate
             verbatim block, and printing one string into both would be
             a relabelling rather than the two claims it draws. Where
             the classifier has not answered yet there is no title at
             all — `intent_label(nil)` would render an em dash, which is
             a heading that says nothing.

             The drawing's third line (`Client pushed back on seat-based
             pricing…`) has NO column behind it. `meeting_candidates`
             stores an intent and a verbatim span, not a summary, so
             there is nothing truthful to put on that line and it is
             left out rather than filled. --%>
        <div class="candidate-card__head">
          <p
            :if={Map.get(@candidate, :classified_intent)}
            class={[
              "candidate-card__title",
              @presentation == :forming && "candidate-card__title--half"
            ]}
            data-role="meeting-candidate-title"
          >
            {CandidateDisplay.intent_label(Map.get(@candidate, :classified_intent))}
          </p>
          <%!-- WHO SPOKE, and when. A nil speaker is UNATTRIBUTED and
               renders NOTHING — no placeholder, and above all no
               fallback to the assignee, which would credit the sentence
               to an agent that was not in the room. The em dash is a
               SEPARATOR and sits outside the element, so the byline's
               text is the attribution and nothing else. --%>
          <span :if={byline(@candidate, @now)} class="candidate-card__attrib">
            <span class="candidate-card__dash" aria-hidden="true">—</span>
            <span class="candidate-card__byline" data-role="meeting-candidate-byline">
              {byline(@candidate, @now)}
            </span>
          </span>
        </div>

        <%!-- THE WORDS THAT WERE ACTUALLY SAID — the same element the
             shimmering card carries, now on every card that has left
             the skeleton, which is what lets the assignment sit BELOW
             the evidence on all of them instead of only in the drawing.
             Set as a quote, not as body copy: it is somebody else's
             sentence and the card is quoting it. --%>
        <p class="candidate-card__quote" data-role="meeting-candidate-quote">
          {@candidate.evidence_quote}
        </p>
      </div>
    </div>
    """
  end

  # A `:forming` card has no agent yet, so the mockup draws a dashed
  # placeholder with a `?` rather than a face. `agent_avatar/1` is
  # reused for the real one so a card and the agent dock seed the same
  # fallback palette from the same slug.
  attr(:candidate, :map, required: true)
  attr(:presentation, :atom, required: true)

  defp candidate_avatar(assigns) do
    ~H"""
    <span
      :if={@presentation == :forming or is_nil(CandidateDisplay.agent_name(@candidate))}
      class="candidate-avatar-ghost"
      data-role="meeting-candidate-avatar-ghost"
      aria-hidden="true"
    >
      ?
    </span>

    <.agent_avatar
      :if={@presentation == :full and CandidateDisplay.agent_name(@candidate)}
      name={CandidateDisplay.agent_name(@candidate)}
      size="sm"
      fallback_class="candidate-avatar-fallback"
    />
    """
  end

  # ── Activity log ───────────────────────────────────────────────────────

  # Every line here exists because a write to `meeting_candidate_events`
  # returned `{:ok, _}`. Nothing is derived from the candidate's state,
  # so "a candidate that closes early shows the gates that ran and no
  # others" is a property of the mechanism rather than a claim about
  # this markup. An empty stream renders no list at all rather than an
  # empty one — a log with no lines is not a log.
  attr(:lines, :list, required: true)
  attr(:candidate_id, :string, required: true)

  defp activity_log(assigns) do
    ~H"""
    <ul :if={@lines != []} class="candidate-log" data-role="meeting-candidate-log">
      <li
        :for={event <- @lines}
        class="candidate-log__line"
        data-role="meeting-candidate-log-line"
        data-event-kind={event.kind}
      >
        <span class="candidate-log__dot" aria-hidden="true"></span>
        <span>{CandidateDisplay.event_line(event.kind, event.detail)}</span>
      </li>
    </ul>
    """
  end

  # ── Review mode ────────────────────────────────────────────────────────

  attr(:candidate, :map, required: true)

  defp review_row(assigns) do
    ~H"""
    <p class="candidate-card__ask" data-role="meeting-candidate-ask">
      Needs review before I start
    </p>

    <div class="mt-2 flex gap-2" data-role="meeting-candidate-review">
      <button
        type="button"
        phx-click="decline_candidate"
        phx-value-candidate_id={@candidate.id}
        class="candidate-btn flex-1"
        data-role="meeting-candidate-decline"
        data-candidate-id={@candidate.id}
        aria-label={"Not now — do not act on \"#{@candidate.evidence_quote}\""}
      >
        Not now
      </button>
      <button
        type="button"
        phx-click="approve_candidate"
        phx-value-candidate_id={@candidate.id}
        class="candidate-btn candidate-btn--go flex-1"
        data-role="meeting-candidate-approve"
        data-candidate-id={@candidate.id}
        aria-label={"Go ahead — act on \"#{@candidate.evidence_quote}\""}
      >
        Go ahead
      </button>
    </div>
    """
  end

  # ── Act mode ───────────────────────────────────────────────────────────

  # THREE encodings of one number became TWO (task 01a0740e stage 3).
  #
  # The ring is gone. It and the drain were both CONTINUOUS PROPORTIONAL
  # encodings of `remaining` — the same claim, drawn twice — and a number
  # plus one continuous encoding is the pairing that adds information:
  # the drain answers *how much longer* at a glance, the count answers
  # *exactly how long* when you look. Three reasons it is the ring that
  # went and not the bar:
  #
  #   * `01a03fbb`'s floor lease ("may I speak now", seconds long) needs
  #     a clock language that cannot be mistaken for this one, and this
  #     ticket forbids the two sharing a visual grammar. SHAPE is the
  #     axis that survives colour-blindness, small sizes and peripheral
  #     vision, so the ring goes to the floor lease and the bar stays
  #     here. Keeping both would spend the ring and leave the neighbour
  #     nothing distinct.
  #   * The shipped ring rendered GREEN (`--cc-ring-progress`, and
  #     `--cc-ring-secs` / `--cc-foot-fg` with it). Green is SPEAKING's
  #     colour on this screen and was never this ticket's to spend.
  #     Deleting the ring removed that collision for free.
  #   * `Starting in {N}s` went with it — a third statement of the same
  #     number, in prose, under a card that already showed it twice.
  #
  # The drain is driven client-side against `data-acts-at`, so the number
  # and the width move without a server round trip. The server still
  # renders the CURRENT value into the text node, `data-remaining` and
  # the inline width, which means a session with JS disabled sees a true
  # (if frozen) card rather than a placeholder, and the first tick is a
  # correction of at most one second rather than a reveal.
  #
  # There is NO `phx-hook` on this element, deliberately. The single
  # `CandidateClock` hook sits on the rail's `<section>` and re-queries
  # `[data-role="meeting-candidate-countdown"]` every tick, so the rail
  # runs ONE interval whatever the card count and a card arriving or
  # leaving needs no mount/destroy bookkeeping. Everything the ticker
  # needs about THIS card it reads from the `data-` attributes below —
  # including `data-warning-seconds`, so the threshold the server paints
  # and the one the browser re-decides every second are the same number
  # and cannot drift.
  attr(:candidate, :map, required: true)
  attr(:now, :any, required: true)

  # Whether THIS surface can correct at all (task 01a0740e stage 2) —
  # `is_list(@correction_agents)` resolved one level up, so the boolean
  # rather than the roster crosses into this component: the foot offers
  # the pencil and never lists an agent, and passing the list here would
  # invite a future reader to render the options in the foot.
  attr(:correctable?, :boolean, default: false)
  attr(:correcting?, :boolean, default: false)

  defp countdown_foot(assigns) do
    remaining = Countdown.remaining_seconds(assigns.candidate.acts_at, assigns.now)

    assigns =
      assigns
      |> assign(:remaining, remaining)
      |> assign(:warning?, warning?(remaining))
      |> assign(:drain_width, drain_width(remaining))
      |> assign(:outcome_noun, CandidateDisplay.armed_outcome_label(assigns.candidate))

    ~H"""
    <div
      class="candidate-foot"
      id={"candidate-foot-#{@candidate.id}"}
      data-role="meeting-candidate-countdown"
      data-candidate-id={@candidate.id}
      data-acts-at={DateTime.to_iso8601(@candidate.acts_at)}
      data-total-seconds={Countdown.countdown_seconds()}
      data-warning-seconds={Countdown.warning_seconds()}
    >
      <%!-- WHAT IS ABOUT TO EXIST, said while it still does not.
           `Creating a task in 24` / `Creating a canvas in 24`. Saru's
           canvas 01a08321 is the authority and its ruling is that the
           outcome kind is a NOUN, not a state, an alarm or an action —
           so it gets TYPE and not colour, and it rides on the line that
           is already counting down at the reader rather than competing
           for attention with a chip of its own. A coloured `Task` /
           `Canvas` pill was considered there and rejected: this surface
           already spends error on the recording pill, success on the
           live pill and amber on the last five seconds of THIS
           countdown, so a fourth coloured marker beside a timer that
           turns amber would argue with it about urgency — and on a
           312px rail a chip has to hide at the tightest width, which
           recreates the exact defect FE-11 was filed about.

           ## This is NOT the `Starting in {N}s` prose FE-9 deleted

           That line was removed for restating the NUMBER a third time,
           under a card that already showed it twice. This one restates
           nothing: `outcome_kind` appears nowhere else on an armed
           card, so the sentence is the only place the reader can learn
           whether thirty seconds of silence mints a task or a canvas.
           Different claim, different `data-role`, and the phrase
           `Starting in` stays gone. The commit-window refutations that
           police that are deliberately left standing.

           SEPARATE NODE from the count, and that is load-bearing rather
           than tidy: `CandidateClock` re-queries every
           `[data-role="meeting-candidate-remaining"]` once a second and
           assigns `el.textContent`, so prose put INSIDE that node is
           erased on the first tick — a failure that passes every
           server-render test in the suite and is visible only to
           someone watching a real card for one second. The words live
           out here; the `<time>` below stays a bare integer.

           Omitted entirely when `armed_outcome_label/1` answers nil
           (a row with no `outcome_kind`). The justification for adding
           prose to this line is that it carries the KIND; with no kind
           to carry, `Creating in` would be prose for its own sake,
           which is what FE-9 removed. --%>
      <span
        :if={@outcome_noun}
        class="candidate-outcome-line"
        data-role="meeting-candidate-armed-outcome"
      >
        Creating a <span class="candidate-outcome-line__noun">{@outcome_noun}</span> in
      </span>

      <%!-- BARE SECONDS. `12`, never `0:12` and never `12s`: a unit
           beside a number that changes every second is a glyph that
           never changes, and the card's whole foot is already about
           time. Mono and tabular because the digit widths must not
           shift — this number is repainted every second on every armed
           card at once, and a proportional face makes the rail jitter
           rather than tick. `shrink-0`, so the Stop control beside it
           is what gives way first. --%>
      <time
        class={["candidate-count", @warning? && "candidate-count--warning"]}
        datetime={DateTime.to_iso8601(@candidate.acts_at)}
        data-role="meeting-candidate-remaining"
        data-remaining={@remaining}
      >
        {@remaining}
      </time>

      <%!-- THE TRAILING CONTROLS, wrapped (task 01a0740e stage 2).
           `ml-auto` moved from the Stop button onto this wrapper and
           nothing else about Stop changed: same element, same classes,
           same label, same right edge of the same row. The move is
           mechanical, not cosmetic. Two flex items each carrying
           `margin-left: auto` SPLIT the free space between them, so a
           pencil that also claimed `ml-auto` would open a gap between
           itself and Stop that grows with the rail — 18px at 312px and
           far more on the full-width mobile rail. One auto margin on a
           wrapper keeps the pair together and keeps Stop where it was.

           This is deliberately NOT the "restyle Stop so the pencil looks
           better" the ticket forbids. Stop keeps its size, its label,
           its position and its hover-only red; the pencil is what gives
           way if the row ever runs out of room. --%>
      <div class="candidate-foot__actions ml-auto">
        <%!-- THE PENCIL. Same `hero-pencil-square` as `data-role="intent-edit"`
             in `intents_collapse.ex`, so the producer bar's correction
             control and this one read as one vocabulary rather than as
             two features that happen to both be about being wrong. Not
             the same CHROME: that one is a `btn btn-ghost btn-square
             min-h-11`, sized for a 44px row on a full-width strip, and an
             11mm square here would be twice the height of the Stop
             button beside it.

             A TOGGLE, not an opener. `aria-expanded` is a promise that
             pressing again collapses, so the press has to actually do
             that — `candidate_correct_close` writes nothing and does not
             take the re-arm back. The two events are chosen by
             `@correcting?` rather than by JS, because the open panel is
             an assign on the socket and the server is the only thing
             that knows which card holds it.

             The label NAMES THE CARD, matching the Stop and review
             controls above (`aria-label={"Stop — do not act on ..."}`).
             On a rail of five armed cards, five buttons all labelled
             "Correct" are five identical stops on a screen reader's
             control list. --%>
        <button
          :if={@correctable?}
          type="button"
          phx-click={if @correcting?, do: "candidate_correct_close", else: "candidate_correct_open"}
          phx-value-candidate_id={@candidate.id}
          data-role="meeting-candidate-correct"
          data-candidate-id={@candidate.id}
          class="candidate-correct-btn"
          aria-expanded={to_string(@correcting?)}
          aria-label={"Correct this card — \"#{@candidate.evidence_quote}\""}
          title="Correct this card"
        >
          <span class="hero-pencil-square size-4" aria-hidden="true"></span>
        </button>

        <button
          type="button"
          phx-click="stop_candidate"
          phx-value-candidate_id={@candidate.id}
          data-role="meeting-candidate-stop"
          data-candidate-id={@candidate.id}
          class="candidate-btn candidate-btn--stop"
          aria-label={"Stop — do not act on \"#{@candidate.evidence_quote}\""}
          title="Stop — do not act on this"
        >
          Stop
        </button>
      </div>

      <%!-- THE DRAIN. Written INSIDE the foot so the one ticker finds it
           with the same query it uses for the count, and positioned
           ABSOLUTELY, which takes it straight back out of this flex row:
           an out-of-flow child resolves against the nearest positioned
           ancestor, and `.candidate-foot` is static while
           `.candidate-card` is relative. So it lands full-bleed on the
           CARD's bottom edge with no inset and no radius of its own, and
           reads as the card's remaining life rather than as a widget
           sitting inside it. `overflow: hidden` on the card clips it to
           the 12px corner.

           Every armed card drains at the same rate, so several side by
           side form a ladder of bar lengths — and that ladder is the
           concurrency picture this ticket exists to produce. One card
           cannot show it.

           `aria-hidden`: the `<time>` above carries the number, and a
           screen reader gets a bare percentage from this and nothing
           else. --%>
      <span
        class={["candidate-drain", @warning? && "candidate-drain--warning"]}
        data-role="meeting-candidate-drain"
        style={"width: #{@drain_width}%"}
        aria-hidden="true"
      >
      </span>
    </div>
    """
  end

  # ── Correction (task 01a0740e stage 2) ────────────────────────────────

  # THREE SENTENCES AND A FOOTNOTE. Saru's canvas 01a08322 ("FE-10
  # direction: correction is the primary path") is the design authority
  # here — advisory per ADR-0046 — and four of its rulings are visible in
  # this markup rather than derivable from it:
  #
  #   * A STACKED LIST of sentences, not a row of iconned buttons. The
  #     icon row was considered there and dropped: a row wraps into a
  #     mess when the rail narrows to 312px while a list of sentences
  #     truncates gracefully, and a toolbar reads as chrome you skim past
  #     when the whole point is that a reader should stop and pick one.
  #   * The three are EQUALS. None is filled, none is primary, none is
  #     "recommended". The message is not "pick one of these three
  #     actions", it is "any of these three is cheaper than stopping".
  #   * `Not an action` VERBATIM, and this is the one string in the file
  #     that is a settled argument rather than a label. `candidate_display.ex`
  #     flags that somebody should choose between the two stored words
  #     deliberately; Saru chose NEITHER. Both judge, and in opposite
  #     directions: one says a colleague's proposal was overruled, the
  #     other says it was beneath consideration. What the person pressing
  #     this button is reporting is narrower than either — the classifier
  #     heard something that was not a piece of work. Do not substitute a
  #     synonym and do not add a subtitle. The STORED value is untouched
  #     and stays `:dismissed`.
  #   * The training line sits UNDER the choices, one size down, muted.
  #     It is a REASON and not an instruction, so it reads as a footnote
  #     the first time and is ignorable the tenth.
  #
  # THE ASSIGNED AGENT IS FILTERED OUT HERE, per card, and the roster
  # arrives whole from the rail because one roster serves every card on
  # it. `Candidates.correct/3` refuses a same-agent reassign with
  # `{:error, :same_agent}` before it writes anything, so an option
  # naming the agent already on the card is an option that cannot work —
  # and the reason it cannot is the reason the option is pointless: a
  # correction that names the current assignee teaches the classifier
  # nothing.
  #
  # AN EMPTY LIST RENDERS NO REASSIGN OPTIONS AND STILL RENDERS THE PANEL.
  # A one-agent room is a real room, and taking the flip and
  # `Not an action` away with the list that had nothing in it would break
  # the panel in exactly the meeting most likely to have a miscast card.
  # `<ul>` with an `:if`-ed `<li>` comprehension, so nothing renders an
  # empty option or a bare bullet.
  #
  # NO `phx-hook` ANYWHERE IN HERE. The rail runs ONE `CandidateClock`
  # interval on its `<section>`; a per-panel hook would undo that, and
  # there is nothing for it to do — every value in this panel is server
  # state, and the number that moves lives in the foot above.
  attr(:candidate, :map, required: true)
  attr(:agents, :list, required: true)

  defp correction_panel(assigns) do
    assigned = Map.get(assigns.candidate, :assigned_agent_id)

    assigns =
      assigns
      |> assign(:options, Enum.reject(assigns.agents, &(&1.id == assigned)))
      |> assign(:flip_label, flip_label(assigns.candidate))

    ~H"""
    <div
      class="candidate-correction"
      data-role="meeting-candidate-correction-panel"
      data-candidate-id={@candidate.id}
    >
      <ul class="candidate-correction__list">
        <%!-- `Hand to Octavius`, never `Hand to another agent`. The
             canvas asks each option to NAME its agent, and the reason is
             the same one the assignment line is built on: a card is
             handed to somebody, and a control that says "another agent"
             makes the reader open a second thing to find out who. One
             `<li>` per agent, so a three-agent room is three sentences
             and a one-agent room is none. --%>
        <li :for={agent <- @options}>
          <button
            type="button"
            phx-click="candidate_correct_reassign"
            phx-value-candidate_id={@candidate.id}
            phx-value-agent_id={agent.id}
            class="candidate-correction__choice"
            data-role="meeting-candidate-correction-reassign"
            data-candidate-id={@candidate.id}
            data-agent-id={agent.id}
          >
            Hand to {agent.name}
          </button>
        </li>

        <%!-- WHICH DIRECTION THE FLIP GOES is a fact about the card, so
             the label is read off `outcome_kind` and the payload carries
             no direction at all: `correct/3` flips whatever the row it
             re-reads is holding. A `phx-value-to="artifact"` would be a
             second copy of the same fact, able to disagree with the first
             after a broadcast repainted the card under the reader. --%>
        <li :if={Map.get(@candidate, :outcome_kind) != :artifact}>
          <button
            type="button"
            phx-click="candidate_correct_flip"
            phx-value-candidate_id={@candidate.id}
            class="candidate-correction__choice"
            data-role="meeting-candidate-correction-flip"
            data-candidate-id={@candidate.id}
          >
            {@flip_label}
          </button>
        </li>

        <li>
          <button
            type="button"
            phx-click="candidate_correct_none"
            phx-value-candidate_id={@candidate.id}
            class="candidate-correction__choice"
            data-role="meeting-candidate-correction-none"
            data-candidate-id={@candidate.id}
          >
            Not an action
          </button>
        </li>
      </ul>

      <%!-- WHY IT IS WORTH PRESSING. One sentence, and a reason rather
           than an instruction: "Tell us what it should have been" would
           be a task handed to somebody who is in a meeting. This says
           what happens to the answer, which is the whole argument of the
           ticket — a correction is training data, and
           `IntentCorrections.recent_exemplars/2` really does read these
           rows back into the `meetings.intent_classify.v1` prompt. No em
           dashes. --%>
      <p class="candidate-correction__note" data-role="meeting-candidate-correction-note">
        Your choice is kept as an example, and the classifier reads it back next time.
      </p>
    </div>
    """
  end

  # `Make it a canvas instead` / `Make it a task instead`.
  #
  # Phrased as the DESTINATION and never as the current value, because
  # the reader is choosing where the card should go and not confirming
  # where it is. The nouns are `CandidateDisplay.armed_outcome_label/1`'s
  # — "task" and "canvas", the same two words the countdown sentence
  # directly above says — so the flip reads as the same vocabulary
  # answering back rather than as a second naming of the same two kinds.
  #
  # An `:artifact` card offers the task; anything else offers the canvas.
  # The catch-all rather than a match on `:task` is deliberate: a row
  # carrying a nil `outcome_kind` can still be corrected, and
  # `MeetingCandidate`'s own default for the column is `:task`, so "not
  # an artifact" and "a task" are the same set on every row this can
  # reach.
  defp flip_label(%{outcome_kind: :artifact}), do: "Make it a task instead"
  defp flip_label(_candidate), do: "Make it a canvas instead"

  # The ladder-rung caption for a `:full` live card — `CandidateDisplay.
  # stage_label/1`'s "3 · taking shape", plus the kind note when one is
  # known. `outcome_kind_label/1` is checked FIRST because it answers
  # from a stored id (a reached deliverable); `armed_outcome_label/1` is
  # the fallback for a still-counting-down card that has not reached one
  # yet. Both can answer nil (an unarmed, disarmed, or not-yet-classified
  # `:acting` row) and the label simply carries no kind note then — never
  # a third, invented guess.
  defp step_label_text(candidate) do
    case ladder_kind_note(candidate) do
      nil -> CandidateDisplay.stage_label(candidate.state)
      note -> CandidateDisplay.stage_label(candidate.state) <> " · " <> note
    end
  end

  defp ladder_kind_note(candidate) do
    case CandidateDisplay.outcome_kind_label(candidate) do
      nil ->
        case CandidateDisplay.armed_outcome_label(candidate) do
          nil -> nil
          noun -> String.upcase(noun)
        end

      kind ->
        kind
    end
  end

  # ── Derivations ────────────────────────────────────────────────────────

  @doc """
  Which of the mockup's three card treatments a candidate gets.

  Public because it is the module's one real decision and the tests
  assert it directly — a card that shimmers when the system already
  knows what it is, or shows a face before an agent has been chosen, is
  a bug in this function and nowhere else.
  """
  @spec presentation(map()) :: :skeleton | :forming | :full
  def presentation(%{state: state} = candidate) when state in [:heard, :thinking] do
    if is_nil(Map.get(candidate, :classified_intent)), do: :skeleton, else: :forming
  end

  def presentation(_candidate), do: :full

  # `Dalton · 2m ago` — WHO SAID IT, and when.
  #
  # It used to read `octavius · drafting · just now`: the ASSIGNED AGENT
  # in the author position. The target screen says "cards say who made
  # them and when", and `speaker` is the column that answers that
  # (`meeting_candidate.ex:144`, written by `open_new/6`). The assignee
  # answers a different question and now has its own element.
  #
  # A card with no speaker renders NO BYLINE AT ALL — not a placeholder,
  # not the assignee. The time goes with the name because "2m ago" under
  # a quote nobody is attributed for is a timestamp on an anonymous
  # sentence, and the assignment line beneath still dates the card by
  # its countdown.
  defp byline(candidate, now) do
    case CandidateDisplay.speaker_name(candidate) do
      nil ->
        nil

      speaker ->
        [speaker, CandidateDisplay.said_ago(candidate, now)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")
    end
  end

  # `→ @octavius · drafting`, `→ unassigned`. The assignee and what it
  # is doing with the card, kept apart from the byline above.
  #
  # `target_label/2` is total and absorbs the `"null"` sentinel
  # `IntentClassifier` stores for an unrouted intent, so this line says
  # the WORD "unassigned" — never `@null`, and never a bare `@` in front
  # of a role, which would read as an at-mention of a person who does
  # not exist.
  defp assignment(candidate) do
    target =
      CandidateDisplay.target_label(
        Map.get(candidate, :assigned_agent_slug),
        Map.get(candidate, :target_role)
      )

    [target, CandidateDisplay.byline_state(candidate)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp utterance_count(candidate) do
    case length(candidate.transcript_chunk_ids || []) do
      1 -> "1 utterance"
      n -> "#{n} utterances"
    end
  end

  # A card with a nil `acts_at` is disarmed — stopped, or opened while
  # the meeting's automation was off — and there is nothing to count
  # down or stop.
  defp armed?(%{outcome_kind: :artifact, acts_at: %DateTime{}}), do: true
  defp armed?(_), do: false

  # Review mode is the complement of act mode, but only once there is
  # something worth judging: the mockup puts the human gate at stage 3,
  # "after the expensive model wrote something worth judging, before a
  # principal agent is spent on it". Offering `Go ahead` on a shimmering
  # skeleton would be asking a human to approve an utterance nobody has
  # classified.
  defp review?(candidate),
    do:
      Map.get(candidate, :outcome_kind) == :artifact and not armed?(candidate) and
        presentation(candidate) == :full

  # Still being worked out — the drawing's dashed card. Keyed on the
  # PRESENTATION rather than on `state`, for the same reason
  # `presentation/1` exists: a `:heard` row that `reconcile/2` has
  # already classified is further along than its state says, and a
  # dashed border plus "is forming a card…" over a card the system has
  # finished thinking about is the progress bar that lies.
  defp forming?(candidate), do: presentation(candidate) in [:skeleton, :forming]

  defp stage_rank(%{state: state} = candidate) do
    {Map.get(@stage_rank, state, 9), arrival(candidate)}
  end

  # The tie-break, and it has to be total: the spent row (see
  # `spent_row/2`) carries the stopped card's `acts_at` and nothing else,
  # because that deadline is the only thing the sort needs from it and
  # `apply_candidate_stop/2` stashes nothing further. A row with no
  # arrival sorts first among cards sharing one microsecond, which is a
  # tie that one global thirty-second window makes vanishingly unlikely
  # and that nothing reads meaning into either way.
  defp arrival(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp arrival(_row), do: 0

  # ── The spent row ──────────────────────────────────────────────────────

  # Append the stopped card's placeholder to the list the rail sorts, so
  # ONE sort places it — by the `acts_at` it had before the stop when the
  # rail is live, and by its captured index when the rail is frozen under
  # a pointer, which is the state it is always in a beat after somebody
  # clicked `Stop`. Placing it with a second pass would have to
  # re-implement both of those.
  #
  # The window is checked HERE as well as on the client. The ticker hides
  # the row when `data-expires-at` passes; this is what stops a reload
  # eleven seconds later from drawing it again, and what makes the
  # ten seconds a fact about the offer rather than about one browser.
  defp maybe_spent(candidates, undo, now) do
    case spent_row(undo, now) do
      nil -> candidates
      row -> candidates ++ [row]
    end
  end

  defp spent_row(
         %{id: id, acts_at: %DateTime{} = acts_at, expires_at: %DateTime{} = expires_at},
         now
       ) do
    if DateTime.compare(expires_at, now) == :gt do
      %{id: id, acts_at: acts_at, expires_at: expires_at, spent?: true}
    end
  end

  defp spent_row(_undo, _now), do: nil

  defp spent?(row), do: Map.get(row, :spent?) == true

  # Declared HERE, among the private helpers, and NOT above
  # `candidate_rail/1`. `attr/3` binds its pending declarations to the
  # NEXT function defined in the module, so a public function placed
  # between the attr block and the component quietly becomes the
  # component, and every render in this file changes shape at once.
  @doc """
  The ids of `candidates` in the order the rail draws them.

  Exists so a freeze can be captured on the SERVER, from the list the
  LiveView already holds, rather than from ids the browser reports back.
  The client is trusted to say that a pointer entered the rail and
  nothing more; what was on screen at that instant is re-derived here
  through the same sort the render uses, so a crafted push cannot
  reorder anybody's rail or name a card from another meeting.
  """
  def display_order(candidates) when is_list(candidates) do
    candidates |> sort_open(nil) |> Enum.map(& &1.id)
  end

  # A FROZEN rail: the named cards hold the sequence they were captured
  # in, and a card that arrived since is appended below in the live
  # order rather than dropped. Appending is the safe half of the deal —
  # a frozen rail that hid new cards would make a hovering reader miss
  # the very card most likely to fire next.
  defp sort_open(candidates, order) when is_list(order) do
    index = order |> Enum.with_index() |> Map.new()
    {frozen, arrived} = Enum.split_with(candidates, &Map.has_key?(index, &1.id))

    Enum.sort_by(frozen, &Map.fetch!(index, &1.id)) ++ sort_open(arrived, nil)
  end

  defp sort_open(candidates, _order), do: Enum.sort_by(candidates, &rail_rank/1)

  # Armed → `{0, deadline, arrival}`; unarmed → `{1, stage, arrival}`.
  #
  # The leading flag is what keeps a card with no deadline out of the
  # urgency ladder instead of sorting it against one. Both tuples are
  # three integers of the same arity, so Erlang term order compares them
  # element by element with nothing to surprise a reader.
  #
  # The deadline is the STORED `acts_at`, never a remaining-seconds
  # figure computed against `now`: with one global window and one `now`
  # per render the two orderings are identical, and only one of them can
  # be tested without freezing a clock.
  defp rail_rank(%{acts_at: %DateTime{} = acts_at} = candidate) do
    {0, DateTime.to_unix(acts_at, :microsecond), arrival(candidate)}
  end

  defp rail_rank(candidate) do
    {stage, inserted_at} = stage_rank(candidate)
    {1, stage, inserted_at}
  end

  # The AMBER STEP, and it is a step. `<=`, so the threshold second
  # itself is amber and so is zero: a card past its deadline waiting for
  # the sweeper is the most committed thing on the rail and must not
  # drop back to rest at the last instant. Written as one comparison
  # rather than a range for exactly that reason — `in 1..5` reads the
  # same and greys out zero.
  #
  # `nil` (a disarmed card) never reaches here, because `armed?/1` gates
  # the whole foot; the clause exists so a future caller cannot get a
  # `true` out of a card that has no deadline at all.
  defp warning?(remaining) when is_integer(remaining),
    do: remaining <= Countdown.warning_seconds()

  defp warning?(_remaining), do: false

  # A full-width bar at t=total, nothing at t=0. The REMAINING fraction,
  # not the elapsed one: wired to the other end a drain looks entirely
  # plausible and grows as the card runs out.
  defp drain_width(remaining) when is_integer(remaining) do
    total = Countdown.countdown_seconds()
    Float.round(min(remaining / total, 1.0) * 100, 2)
  end

  defp drain_width(_remaining), do: 0.0
end
