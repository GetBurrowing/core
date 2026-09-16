defmodule PlatformWeb.Components.Meetings.CallRecap do
  @moduledoc """
  The after-meeting recap — what a viewer sees once they have LEFT a call
  (task 01a07410 / FE-17 stage 6). Shown on both surfaces: a full-viewport
  takeover on mobile and, since 01a0691d, the sponsor prototype's centered
  `.after-screen` panel on desktop (see `call_recap/1` for the `lg:` split).

  Four things, in this order: what the meeting was, how long it ran, who
  was in it, and what it PRODUCED — the cards that graduated and what
  each became, the cards that were closed and why, and the cards that
  were still open at the moment the viewer left.

  ## Its own file, deliberately

  `meeting_live.html.heex` is the most contended file in the repo; this
  component keeps the recap's markup out of it so the template gains one
  call site and nothing else. `MeetingLive` owns the `:call_recap`
  assign (built when the `meeting_leave` / `meeting_left` event passes
  through, cleared on `meeting_join` and on dismiss) and hands it here.

  ## Vocabulary is borrowed, never re-invented

  Every word that names a candidate's fate comes from
  `PlatformWeb.Components.Meetings.CandidateDisplay`:

    * `outcome_label/1` — "Added to Tasks" / "Added to Canvas", keyed on
      the STORED ids (`task_id` / `canvas_id`), never on `outcome_kind`
      or `state`. FE-11 shipped that wording on the card; the recap
      repeats it rather than paraphrasing, so the card and the recap
      cannot disagree about what a card became.
    * `outcome_kind_label/1` — the "TASK" / "CANVAS" tag, same keying.
    * `outcome_path/1` — the link to the thing.
    * `closed_reason_label/1` — the recorded reason on a closed card.

  There is NO `to_string/1` fallback anywhere in this module. A reason
  the label table does not know is rendered as "reason not recorded" by
  the `nil` clause of `closed_reason_line/1`, and an unknown ATOM raises
  a `FunctionClauseError` inside `CandidateDisplay`, which is the
  correct answer: a newly added state must be given words on purpose,
  not be printed as its storage name.

  ## The empty state says so

  A call that produced nothing renders a sentence saying it produced
  nothing (`data-role="call-recap-empty"`), in the register
  `CallShell.call_rail/1` uses for an empty Canvas tab. A blank region
  reads as "still loading", and after a call that is a lie: nothing is
  being captured any more.
  """

  use Phoenix.Component

  alias PlatformWeb.Components.Meetings.CandidateDisplay

  @doc """
  Split a meeting's candidates into what the recap lists.

  Returns `%{graduated: [...], closed: [...], open: [...]}`:

    * `graduated` — rows carrying a `task_id` or a `canvas_id`, i.e. rows
      `outcome_label/1` has words for. Keyed on the ids for the same
      reason `outcome_label/1` is: `graduate/2` can fail and leave an
      `:acting` row with no deliverable, and that row must NOT be listed
      as something the call produced.
    * `closed` — `state == :closed` rows with no deliverable. Their
      `closed_reason` is what the recap shows.
    * `open` — everything else: cards that were still counting, thinking
      or acting-without-a-deliverable when the viewer left.

  Order within each group is the board's (oldest first), unchanged.
  """
  @spec produced([map()]) :: %{graduated: [map()], closed: [map()], open: [map()]}
  def produced(candidates) when is_list(candidates) do
    Enum.reduce(candidates, %{graduated: [], closed: [], open: []}, fn candidate, acc ->
      key =
        cond do
          CandidateDisplay.outcome_label(candidate) != nil -> :graduated
          candidate.state == :closed -> :closed
          true -> :open
        end

      Map.update!(acc, key, &(&1 ++ [candidate]))
    end)
  end

  @doc """
  The line under a closed card: its recorded reason, or an explicit
  "reason not recorded" when the row has none.

  Never blank. The `nil` clause exists because a `:closed` row can carry
  no `closed_reason` (`closed_reason_slug/1` in `CandidateDisplay`
  documents that case); saying so is distinguishable from every real
  reason, whereas an empty line is not.
  """
  @spec closed_reason_line(map()) :: String.t()
  def closed_reason_line(%{closed_reason: nil}), do: "Closed, reason not recorded"

  def closed_reason_line(%{closed_reason: reason}) when is_atom(reason),
    do: CandidateDisplay.closed_reason_label(reason)

  @doc """
  How long the call ran, in words, from `started_at` to `ended_at`.

  `nil` `started_at` answers `nil` — the caller renders "not recorded"
  rather than a made-up zero. Under a minute is said in words too, so
  a 40-second call does not read as "0 min".
  """
  @spec duration_label(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def duration_label(nil, _ended_at), do: nil

  def duration_label(%DateTime{} = started_at, %DateTime{} = ended_at) do
    seconds = max(DateTime.diff(ended_at, started_at, :second), 0)
    minutes = div(seconds, 60)

    cond do
      seconds < 60 -> "Under a minute"
      minutes < 60 -> "#{minutes} min"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)} hr"
      true -> "#{div(minutes, 60)} hr #{rem(minutes, 60)} min"
    end
  end

  @doc """
  "Who was in it", as one sentence. Names come from the roster the
  viewer saw at the moment they left.
  """
  @spec roster_line([String.t()]) :: String.t()
  def roster_line([]), do: "Nobody else was recorded in the call."
  def roster_line([only]), do: only
  def roster_line([first, second]), do: "#{first} and #{second}"

  def roster_line(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  attr :id, :string, default: "meeting-call-recap"
  attr :meeting, :map, required: true, doc: "the `Platform.Meetings.Meeting` row"

  attr :recap, :map,
    required: true,
    doc:
      "`%{left_at: DateTime.t(), participants: [String.t()], candidates: [MeetingCandidate.t()]}`"

  attr :shell?, :boolean,
    default: true,
    doc:
      "shell surface (bottom nav present) or the chrome-less guest/member surface; decides the bottom padding"

  @doc """
  The recap panel. Fixed, above the stage it replaces, on both surfaces.

  Below `lg` it is the full-viewport mobile takeover it has always been.
  At `lg` it becomes the desktop `.after-screen` from the sponsor
  prototype: the same fixed ground, but the content is a centered
  `max-w-[880px]` column (`lg:items-center lg:py-10`, `lg:flex-none`) and
  the two produced groups sit side by side in a `lg:grid-cols-2` grid —
  "what became something" beside "what closed without becoming anything".
  All of this is CSS-only (`lg:` prefixes) so the mobile rendering is
  byte-for-byte what it was; there is one markup for both widths.

  Bottom padding clears `env(safe-area-inset-bottom)` and, on the shell
  surface, `var(--bottom-nav-height,0px)` as well — the guest surface
  carries no shell chrome and `meeting_live_test.exs` refutes the literal
  `bottom-nav` in a guest document.

  Colour comes from semantic token slots only: `base-200` ground,
  `border-edge` rules, `base-content/60` secondary lines, `primary` for
  the one action.
  """
  def call_recap(assigns) do
    %{graduated: graduated, closed: closed, open: open} = produced(assigns.recap.candidates)

    assigns =
      assigns
      |> assign(:graduated, graduated)
      |> assign(:closed, closed)
      |> assign(:open, open)
      |> assign(:produced_nothing?, graduated == [] and closed == [] and open == [])
      |> assign(:duration, duration_label(assigns.meeting.started_at, assigns.recap.left_at))

    ~H"""
    <section
      id={@id}
      class={[
        "fixed inset-0 z-50 flex flex-col overflow-y-auto bg-base-200 text-base-content",
        "lg:items-center lg:py-10",
        if(@shell?,
          do: "pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+1rem)]",
          else: "pb-[calc(env(safe-area-inset-bottom)+1rem)]"
        )
      ]}
      role="region"
      aria-labelledby={"#{@id}-title"}
      data-role="call-recap"
    >
      <%!-- Below `lg` this wrapper is `flex-1` and fills the takeover just
           like the section did before it existed; at `lg` it collapses to
           the centered `max-w-[880px]` `.after-screen` panel. Purely a
           layout node — no visible chrome of its own, so the base-100 cards
           inside keep their base-200 ground on both widths. --%>
      <div
        class="flex w-full flex-1 flex-col lg:max-w-[880px] lg:flex-none"
        data-role="call-recap-panel"
      >
        <header class="flex items-start gap-3 border-b border-edge px-4 pt-[calc(env(safe-area-inset-top)+1rem)] pb-3 lg:pt-4">
          <div class="min-w-0 flex-1">
            <p class="text-xs uppercase tracking-wide text-base-content/60">You left the call</p>
            <h1 id={"#{@id}-title"} class="truncate text-lg font-semibold" data-role="call-recap-name">
              {@meeting.name}
            </h1>
          </div>
          <button
            type="button"
            phx-click="dismiss_call_recap"
            class="btn btn-ghost btn-sm btn-square min-h-11"
            aria-label="Close the recap"
            data-role="call-recap-dismiss"
          >
            <span class="hero-x-mark size-5" aria-hidden="true"></span>
          </button>
        </header>

        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 border-b border-edge px-4 py-3 text-sm">
          <dt class="text-base-content/60">Ran for</dt>
          <dd data-role="call-recap-duration">
            {@duration || "Start time not recorded"}
          </dd>
          <dt class="text-base-content/60">In the call</dt>
          <dd data-role="call-recap-roster">{roster_line(@recap.participants)}</dd>
        </dl>

        <div class="flex-1 px-4 py-3">
          <h2 class="mb-2 text-xs uppercase tracking-wide text-base-content/60">
            What this call produced
          </h2>

          <%!-- Honest empty state. Same register as `call_rail/1`'s empty
             Canvas tab: it names the condition and says, in words, that
             nothing is still being captured. A blank region here would
             read as loading, and after a call nothing is loading. --%>
          <p
            :if={@produced_nothing?}
            class="rounded-box border border-dashed border-edge px-3 py-2.5 text-sm text-base-content/60"
            data-role="call-recap-empty"
          >
            This call produced nothing. No cards were formed from it, and nothing from it is still
            being captured.
          </p>

          <%!-- The mock's desktop `.after-screen` lays "became something" and
             "closed without becoming" out as two columns (`grid-cols:1fr
             1fr`). This wrapper does the same at `lg`; below `lg` it is an
             inert block, so the two groups stack exactly as they did before
             — the `mt-4` gap between them survives as `lg:mt-0` inside the
             grid. --%>
          <div class="lg:grid lg:grid-cols-2 lg:gap-6">
            <ul :if={@graduated != []} class="flex flex-col gap-2" data-role="call-recap-graduated">
              <li
                :for={candidate <- @graduated}
                class="rounded-box border border-edge bg-base-100 px-3 py-2.5"
                data-role="call-recap-outcome"
                data-candidate-id={candidate.id}
                data-outcome-kind={CandidateDisplay.outcome_kind_label(candidate)}
              >
                <p class="text-sm">{candidate.evidence_quote}</p>
                <a
                  href={CandidateDisplay.outcome_path(candidate)}
                  class="mt-1 inline-flex min-h-11 items-center gap-1.5 text-sm text-primary"
                  data-role="call-recap-outcome-link"
                >
                  <span class="hero-arrow-top-right-on-square size-4" aria-hidden="true"></span>
                  <span data-role="call-recap-outcome-label">
                    {CandidateDisplay.outcome_label(candidate)}
                  </span>
                  <span class="font-mono text-[11px] text-base-content/60">
                    {CandidateDisplay.outcome_kind_label(candidate)}
                  </span>
                </a>
              </li>
            </ul>

            <div :if={@closed != []} class="mt-4 lg:mt-0" data-role="call-recap-closed">
              <h3 class="mb-2 text-xs uppercase tracking-wide text-base-content/60">
                Closed without becoming anything
              </h3>
              <ul class="flex flex-col gap-2">
                <li
                  :for={candidate <- @closed}
                  class="rounded-box border border-edge px-3 py-2.5"
                  data-role="call-recap-closed-card"
                  data-candidate-id={candidate.id}
                >
                  <p class="text-sm">{candidate.evidence_quote}</p>
                  <p class="mt-1 text-xs text-base-content/60" data-role="call-recap-closed-reason">
                    {closed_reason_line(candidate)}
                  </p>
                </li>
              </ul>
            </div>
          </div>

          <p :if={@open != []} class="mt-4 text-xs text-base-content/60" data-role="call-recap-open">
            {length(@open)} {if length(@open) == 1, do: "card was", else: "cards were"} still open when you left.
          </p>
        </div>

        <div class="px-4 pt-3">
          <.link
            navigate="/meetings"
            class="btn btn-primary min-h-11 w-full"
            data-role="call-recap-done"
          >
            Back to meetings
          </.link>
        </div>
      </div>
    </section>
    """
  end
end
