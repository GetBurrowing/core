defmodule PlatformWeb.Components.Meetings.CandidateCountdown do
  @moduledoc """
  The armed-candidate rail and its stop button (task 01a03fba stage 4).

  One row per `meeting_candidates` row that is counting down, each with
  a stop control. It is the human half of a countdown whose other half
  runs in `Platform.Meetings.CandidateSweeper` with nobody watching.

  ## Why this is NOT inside `intents_collapse/1`

  That bar renders `IntentQueue` rows and is wrapped in an `:if` on
  `@intents_visible?`, which resolves the `meeting_producer` role. The
  ticket's requirement is that stop *works from any participant's
  session* — a guest holds `"meeting:{id}"` and not
  `"meeting:{id}:intents"`, so putting the stop button in that bar would
  make it unreachable for exactly the people the requirement is about.
  This component has no role gate.

  They are also different records. A candidate exists from the moment
  something is HEARD, before classification, so a card can be armed and
  stoppable while no intent row exists for it at all — and the intent
  bar's X (`intent_remove`) cannot reach one of those, because
  `Candidates.get_by_intent_id/1` has nothing to find.

  ## The number rendered is the number at render time

  `remaining` is computed on the server when the page renders and does
  not tick. A ticking ring is `01a03f4e-78b1`, and a JS countdown that
  drifted away from `acts_at` would be the "timer that lies" this
  feature exists to remove. The `<time datetime=...>` carries the actual
  deadline so the ring ticket has an honest value to animate against
  rather than a duration it would have to re-derive.
  """

  use PlatformWeb, :html

  alias Platform.Meetings.Countdown

  attr(:candidates, :list, default: [])
  attr(:now, :any, default: nil)
  attr(:error, :string, default: nil)

  @doc """
  Render the rail. Renders NOTHING — not an empty container — when no
  candidate is armed, matching `intents_collapse/1`'s posture: there is
  no layout space to reserve for a countdown that is not running.

  The exception is `@error`, which keeps the section alive with no list.
  The message this carries is *"too late — this one already went
  ahead"*, and by the time it is set the card it is about is gone from
  the rail: a message that could only render alongside the row it
  contradicts could never render at all.
  """
  def candidate_countdown_rail(assigns) do
    now = assigns.now || DateTime.utc_now()

    armed = Enum.filter(assigns.candidates, &armed?/1)

    assigns = assign(assigns, armed: armed, now: now)

    ~H"""
    <section
      :if={@armed != [] or @error}
      class="border-base-300 bg-base-200 border-b px-3 py-2"
      data-role="meeting-candidate-countdown-rail"
    >
      <h3 :if={@armed != []} class="text-base-content/60 mb-1 text-xs font-medium">
        About to act
      </h3>
      <ul :if={@armed != []} class="flex flex-col gap-1">
        <li
          :for={candidate <- @armed}
          class="flex items-center gap-2"
          data-role="meeting-candidate-countdown"
          data-candidate-id={candidate.id}
        >
          <time
            class="text-base-content/70 shrink-0 font-mono text-xs tabular-nums"
            datetime={DateTime.to_iso8601(candidate.acts_at)}
            data-role="meeting-candidate-remaining"
            data-remaining={Countdown.remaining_seconds(candidate.acts_at, @now)}
          >
            {Countdown.remaining_seconds(candidate.acts_at, @now)}s
          </time>
          <span class="text-base-content/80 min-w-0 flex-1 truncate text-xs">
            {candidate.evidence_quote}
          </span>
          <button
            type="button"
            phx-click="stop_candidate"
            phx-value-candidate_id={candidate.id}
            data-role="meeting-candidate-stop"
            data-candidate-id={candidate.id}
            class="btn btn-ghost btn-xs"
            aria-label={"Stop — do not act on \"#{candidate.evidence_quote}\""}
            title="Stop — do not act on this"
          >
            <span class="hero-stop-circle size-4"></span>
            <span>Stop</span>
          </button>
        </li>
      </ul>
      <p :if={@error} class="text-warning mt-1 text-xs" data-role="meeting-candidate-error">
        {@error}
      </p>
    </section>
    """
  end

  # A candidate with a nil `acts_at` is disarmed — stopped, or opened
  # while the meeting's automation was off — and there is nothing to
  # count down or stop.
  defp armed?(%{acts_at: %DateTime{}}), do: true
  defp armed?(_), do: false
end
