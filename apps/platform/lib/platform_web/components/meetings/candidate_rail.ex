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

  The mockup draws the ring only on stage 4. The system does not arm
  cards there: `record_heard/1` sets `acts_at` at `:heard`, and
  `Platform.Meetings.Candidates.claim_due/2` is what moves a row to
  `:acting` — *after* the deadline has already passed. Rendering the
  ring on `state == :acting` would therefore show a countdown only on
  cards whose countdown had finished.

  So the ring renders whenever `acts_at` is set, at whatever stage, and
  the stage colouring is a separate axis. This is a deliberate
  divergence from the mockup, and it is the direction that keeps the
  number true.

  ## Review mode versus act mode

  The ticket's two modes are not a third column; they fall out of
  `acts_at`, which `Platform.Meetings.automation_mode/1` already
  governs:

    * `acts_at != nil` — **act**: the ring, and a stop control that
      calls `Candidates.stop/3`.
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

  # 2πr for the r=15 circle the mockup draws in a 36-unit viewBox. Kept
  # here as one number because the dash array and the JS hook's
  # dash-offset arithmetic have to agree exactly or the ring's empty
  # state is a thin visible sliver.
  @ring_circumference 94.25

  # Ascending stage order, so the rail reads as the mockup lays it out:
  # heard → thinking → taking shape → acting. `open_for_meeting/1`
  # returns newest-first, which is the right order for a threading
  # question and the wrong one for a board.
  @stage_rank %{heard: 0, thinking: 1, shaping: 2, acting: 3, closed: 4}

  attr(:candidates, :list, default: [])
  attr(:closed, :list, default: [])
  attr(:events, :map, default: %{})
  attr(:now, :any, default: nil)
  attr(:error, :string, default: nil)

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

    open = Enum.sort_by(assigns.candidates, &stage_rank/1)
    closed = Enum.sort_by(assigns.closed, & &1.closed_at, {:desc, DateTime})

    assigns =
      assigns
      |> assign(:open, open)
      |> assign(:closed, closed)
      |> assign(:now, now)
      |> assign(:ring_circumference, @ring_circumference)

    ~H"""
    <section
      :if={@open != [] or @closed != [] or @error}
      class="border-base-300 bg-base-200/40 border-b px-3 py-3"
      data-role="meeting-candidate-countdown-rail"
    >
      <header class="mb-3 flex items-center gap-2">
        <span class="candidate-rail-dot" aria-hidden="true"></span>
        <h3 class="text-base-content/60 text-[11px] font-semibold tracking-[0.09em] uppercase">
          Meeting tasks
        </h3>
        <span
          class="bg-base-300 text-base-content/70 rounded-full px-2 py-px text-[11px] tabular-nums"
          data-role="meeting-candidate-count"
        >
          {length(@open)}
        </span>
      </header>

      <div :if={@open != []} class="flex flex-col gap-2">
        <article
          :for={candidate <- @open}
          class={["candidate-card", "candidate-card--#{CandidateDisplay.slug(candidate.state)}"]}
          data-role="meeting-candidate-card"
          data-candidate-id={candidate.id}
          data-stage={CandidateDisplay.slug(candidate.state)}
        >
          <p class="candidate-card__stage" data-role="meeting-candidate-stage">
            {CandidateDisplay.stage_label(candidate.state)}
          </p>

          <.card_head candidate={candidate} />

          <.activity_log
            :if={presentation(candidate) in [:skeleton, :forming]}
            lines={Map.get(@events, candidate.id, [])}
            candidate_id={candidate.id}
          />

          <p
            :if={presentation(candidate) == :full}
            class="candidate-card__chips"
            data-role="meeting-candidate-chips"
          >
            <span class="candidate-card__chip" data-role="meeting-candidate-utterances">
              {utterance_count(candidate)}
            </span>
          </p>

          <.review_row :if={review?(candidate)} candidate={candidate} />

          <.countdown_foot
            :if={armed?(candidate)}
            candidate={candidate}
            now={@now}
            circumference={@ring_circumference}
          />
        </article>
      </div>

      <details :if={@closed != []} class="candidate-closed" data-role="meeting-candidates-closed">
        <summary class="candidate-closed__summary" data-role="meeting-candidates-closed-summary">
          {length(@closed)} closed
        </summary>

        <div class="mt-2 flex flex-col gap-2">
          <article
            :for={candidate <- @closed}
            class="candidate-card candidate-card--closed"
            data-role="meeting-candidate-closed-card"
            data-candidate-id={candidate.id}
            data-closed-reason={CandidateDisplay.closed_reason_slug(candidate.closed_reason)}
          >
            <p
              class="candidate-card__title candidate-card__title--dead"
              data-role="meeting-candidate-title"
            >
              {candidate.evidence_quote}
            </p>
            <p class="candidate-card__reason" data-role="meeting-candidate-closed-reason">
              {CandidateDisplay.closed_reason_line(candidate.closed_reason, candidate.closed_note)}
            </p>
          </article>
        </div>
      </details>

      <p :if={@error} class="text-warning mt-2 text-xs" data-role="meeting-candidate-error">
        {@error}
      </p>
    </section>
    """
  end

  # ── Card head ──────────────────────────────────────────────────────────

  # The three treatments the mockup draws, in one component so the
  # avatar/title pairing cannot drift between them. `:skeleton` has no
  # avatar and no title BY DESIGN — showing a face there would be a
  # claim the card cannot back up, and inventing a title is how you get
  # a confident card about somebody's dropped audio.
  attr(:candidate, :map, required: true)

  defp card_head(assigns) do
    assigns = assign(assigns, :presentation, presentation(assigns.candidate))

    ~H"""
    <div :if={@presentation == :skeleton} data-role="meeting-candidate-skeleton">
      <span class="candidate-skeleton candidate-skeleton--a"></span>
      <span class="candidate-skeleton candidate-skeleton--b"></span>
      <p class="candidate-card__micro">Heard something — getting started</p>
    </div>

    <div :if={@presentation != :skeleton} class="flex items-start gap-2.5">
      <.candidate_avatar candidate={@candidate} presentation={@presentation} />

      <div class="min-w-0 flex-1">
        <p
          class={[
            "candidate-card__title",
            @presentation == :forming && "candidate-card__title--half"
          ]}
          data-role="meeting-candidate-title"
        >
          {@candidate.evidence_quote}
        </p>
        <p
          :if={byline(@candidate)}
          class="candidate-card__byline"
          data-role="meeting-candidate-byline"
        >
          {byline(@candidate)}
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

  # The ring is driven client-side by the `CandidateRing` hook against
  # `data-acts-at`, so the number ticks without a server round trip. The
  # server still renders the CURRENT value into both the text node and
  # `data-remaining`, which means a session with JS disabled sees a true
  # (if frozen) number rather than a placeholder, and the hook's first
  # tick is a correction of at most one second rather than a reveal.
  attr(:candidate, :map, required: true)
  attr(:now, :any, required: true)
  attr(:circumference, :float, required: true)

  defp countdown_foot(assigns) do
    remaining = Countdown.remaining_seconds(assigns.candidate.acts_at, assigns.now)

    assigns =
      assigns
      |> assign(:remaining, remaining)
      |> assign(:offset, dash_offset(remaining, assigns.circumference))

    ~H"""
    <div
      class="candidate-foot"
      id={"candidate-foot-#{@candidate.id}"}
      phx-hook="CandidateRing"
      data-role="meeting-candidate-countdown"
      data-candidate-id={@candidate.id}
      data-acts-at={DateTime.to_iso8601(@candidate.acts_at)}
      data-total-seconds={Countdown.countdown_seconds()}
      data-circumference={@circumference}
    >
      <span class="candidate-ring" data-role="meeting-candidate-ring">
        <svg viewBox="0 0 36 36" class="candidate-ring__svg" aria-hidden="true">
          <circle class="candidate-ring__track" cx="18" cy="18" r="15" />
          <circle
            class="candidate-ring__progress"
            cx="18"
            cy="18"
            r="15"
            data-role="meeting-candidate-ring-progress"
            stroke-dasharray={@circumference}
            stroke-dashoffset={@offset}
          />
        </svg>
        <time
          class="candidate-ring__secs"
          datetime={DateTime.to_iso8601(@candidate.acts_at)}
          data-role="meeting-candidate-remaining"
          data-remaining={@remaining}
        >
          {@remaining}
        </time>
      </span>

      <p class="candidate-foot__txt">
        Starting in <span data-role="meeting-candidate-remaining-word">{@remaining}</span>s
      </p>

      <button
        type="button"
        phx-click="stop_candidate"
        phx-value-candidate_id={@candidate.id}
        data-role="meeting-candidate-stop"
        data-candidate-id={@candidate.id}
        class="candidate-btn ml-auto"
        aria-label={"Stop — do not act on \"#{@candidate.evidence_quote}\""}
        title="Stop — do not act on this"
      >
        Stop
      </button>
    </div>
    """
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

  # `Octavius · drafting`. Falls back to the state word alone when no
  # agent has been assigned — the presence mockup's own pattern for a
  # row with no name on it — and to nothing at all when there is neither.
  defp byline(candidate) do
    case {CandidateDisplay.agent_name(candidate), CandidateDisplay.byline_state(candidate)} do
      {nil, nil} -> nil
      {nil, state} -> state
      {name, nil} -> name
      {name, state} -> name <> " · " <> state
    end
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
  defp armed?(%{acts_at: %DateTime{}}), do: true
  defp armed?(_), do: false

  # Review mode is the complement of act mode, but only once there is
  # something worth judging: the mockup puts the human gate at stage 3,
  # "after the expensive model wrote something worth judging, before a
  # principal agent is spent on it". Offering `Go ahead` on a shimmering
  # skeleton would be asking a human to approve an utterance nobody has
  # classified.
  defp review?(candidate), do: not armed?(candidate) and presentation(candidate) == :full

  defp stage_rank(%{state: state} = candidate) do
    {Map.get(@stage_rank, state, 9), DateTime.to_unix(candidate.inserted_at, :microsecond)}
  end

  # A full ring at t=total, an empty one at t=0. `nil` (a disarmed card)
  # never reaches here — `armed?/1` gates the whole foot.
  defp dash_offset(remaining, circumference) when is_integer(remaining) do
    total = Countdown.countdown_seconds()
    fraction = remaining / total
    Float.round(circumference * (1 - min(fraction, 1.0)), 2)
  end

  defp dash_offset(_remaining, circumference), do: circumference
end
