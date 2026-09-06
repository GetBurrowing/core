defmodule Platform.Meetings.Countdown do
  @moduledoc """
  The one number, and the arithmetic that arms a candidate (task
  01a03fba).

  Harper pinned the countdown at **30 seconds, GLOBAL** on 2026-08-27 —
  not per card type, no per-type override to build, store or expose. So
  it is one module attribute and one public reader, and every caller
  that needs it (`Platform.Meetings.Candidates`, the sweeper, and the
  countdown ring on `01a03f4e-78b1`) reads it from here rather than
  carrying its own copy.

  ## Why per-CARD and not per-cursor

  The intent queue is an ack-gated serial cursor — a second dispatch for
  a meeting answers `{:error, {:cursor_busy, other}}` — and it is a fair
  question whether a countdown belongs on that cursor instead of on each
  card. Measured on 2026-08-29 at `7a605675`, it does not:

    * The cursor gate is on the door into `:dispatched` only
      (`IntentQueue.Server`, the `status == :dispatched` branch of
      `do_transition/4`). `handle_call({:enqueue, attrs}, ...)` has no
      cursor check, so N candidates sit open per meeting at once. A
      single per-meeting deadline has no way to say which of them it is
      for.
    * `Platform.Meetings.Candidates.graduate/2` never touches the queue.
      It calls `Platform.Tasks.create_task/2` and
      `Platform.Chat.create_canvas/1` directly. The countdown gates
      GRADUATION; the cursor gates DISPATCH. They are different rails,
      and one meeting can legitimately be doing both.
    * The cursor's only deadline slot, `ack_timer`, is a single
      `{intent_id, ref, phase}` tuple on a `restart: :temporary`
      GenServer whose ETS dies with it. It can hold one deadline and
      loses it on a crash.

  A per-meeting countdown would additionally serialise the cards: the
  second thing said in a meeting would not start its 30 seconds until
  the first had graduated, which is not what a rail of independently
  counting cards means.

  ## The extension signal, and what it does NOT cover

  `acts_at` moves forward when — and only when — an utterance actually
  attaches to the card, because that is the only signal in the system
  that says "this specific thing is still being discussed".
  `Platform.Meetings.Candidates.attach_utterance/2` is the single write
  that does it.

  Two limitations follow from `Platform.Meetings.ThreadResolver`, and
  both are DEFERRED rather than fixed here. They are pinned by tests in
  `test/platform/meetings/countdown_test.exs` so they are measured
  facts, not remembered ones:

    1. **A colleague agreeing does not extend the countdown.** The
       resolver's `gate/3` requires `same_speaker?/2` AND `in_window?/2`,
       and `normalize_speaker/1` maps `nil` and `""` to nil, which never
       matches. So "and make it mobile" from a second person opens a new
       card instead of extending the first. Widening that is a change to
       the THREADING contract (task `01a03fb9`) — it would re-open the
       retraction gate's "exactly one candidate survives the speaker and
       window filter" invariant, which `RetractionGateTest` asserts — so
       it is not something the countdown ticket gets to decide on its
       way past.
    2. **The two clocks do not compose.** `ThreadResolver`'s
       `@window_seconds` is 60, double this module's 30. A same-speaker
       continuation arriving at t=45s is inside the threading window but
       arrives at a card that has already fired and closed. It cannot
       thread onto a closed card — `Candidates.open_for_meeting/1`
       excludes `:closed` — so it opens a second card instead. That is
       coherent (nothing is lost or double-acted) but it is lossy, and
       it is lossy because two numbers were chosen independently. Making
       them agree means moving one of them, and both belong to someone
       else: 30s is Harper's, 60s is the threading ticket's.

  ## The THIRD clock, and the one that minted small talk

  A model call is allowed 60 seconds and this countdown allows 30, so a
  classification can arrive after the card it was for has already fired.
  See `@provider_receive_timeout_ms` and
  `Platform.Meetings.Candidates.claim_due/2`.
  """

  # 30 seconds, GLOBAL (Harper, 2026-08-27). One number, no per-type
  # override.
  @countdown_seconds 30

  # The last 5 seconds, in which the card's drain and its count STEP to
  # `--color-warning` (task 01a0740e stage 3).
  #
  # It lives here rather than in the rail because two independent things
  # have to agree about it and neither may hold its own copy: the server
  # renders the threshold class at first paint, and `CandidateClock`
  # re-decides it every second in the browser. The rail reads this
  # number into `data-warning-seconds` and the ticker reads it back out,
  # so a change here moves both. A constant duplicated in the hook is
  # the version where a card is amber on render and grey a second later.
  #
  # A STEP and not a ramp: a card gradually becoming alarming over
  # thirty seconds has no findable threshold, and peripheral vision
  # catches events rather than gradients. The step is also the only
  # version a test can assert two-sidedly, which
  # `candidate_rail_test.exs` does — grey at 6, amber at 5 and at 1.
  @warning_seconds 5

  # A compile-time assertion, same posture as the provider one below.
  # A warning window at or above the countdown means every card is amber
  # from the instant it is armed, which is the "always on" failure the
  # two-sided test exists to catch — caught here at compile time as well
  # so it cannot be introduced by editing this file alone.
  if @warning_seconds >= @countdown_seconds do
    raise "warning window (#{@warning_seconds}s) must sit INSIDE the countdown " <>
            "(#{@countdown_seconds}s) — otherwise every armed card renders amber"
  end

  # The number this one is INVERTED against, stated here so the next
  # person does not have to rediscover it (task 01a06575 round 3).
  #
  # `Platform.Agents.Providers.Anthropic`, `.OpenAI` and `.Codex` each
  # give one model call `receive_timeout: 60_000` — double this
  # countdown. So a meeting-intent classification taking 31 to 60 seconds
  # is entirely inside what the HTTP client permits and entirely outside
  # what this countdown tolerates, and `CandidateSweeper` ticks once a
  # second, so the window is wide rather than a sliver.
  #
  # Neither number is wrong and NEITHER MOVES. 30 seconds is a human
  # review window Harper pinned; 60 seconds is what a real model call
  # needs. What the inversion means is that "the classifier has answered"
  # cannot be assumed by anything downstream of the deadline — which is
  # why `Platform.Meetings.Candidates.claim_due/2` refuses to claim a
  # candidate whose `classified_intent` is still nil, and why that
  # refusal is an eligibility rule that leaves the deadline standing
  # rather than a claim-and-drop.
  #
  # `countdown_test.exs` asserts this attribute against each provider's
  # `receive_timeout_ms/0`, so the two cannot drift apart silently.
  @provider_receive_timeout_ms 60_000

  # THE UNDO WINDOW (task 01a0740e stage 5). A stop leaves a spent row in
  # the slot the card occupied, carrying `Undo`, and the row disappears
  # when this many seconds have passed.
  #
  # Ten, and the two bounds are both real. Long enough that a mis-click
  # noticed mid-sentence can still be taken back — a participant who
  # pressed the wrong card is usually still talking when they realise.
  # Short enough that a busy rail is not carrying spent rows for every
  # card somebody has stopped; the rail is ordered by urgency and a
  # column of dead rows pushes the live cards down.
  #
  # It is deliberately much shorter than @countdown_seconds. The undo is
  # a correction to a click, not a second review window — the review
  # window is what the restored card gets when it comes back disarmed.
  @undo_seconds 10

  if @undo_seconds >= @countdown_seconds do
    raise "the undo window (#{@undo_seconds}s) must be shorter than the countdown " <>
            "(#{@countdown_seconds}s) — see the @undo_seconds note in #{__MODULE__}"
  end

  # A compile-time assertion, not a comment. If somebody ever makes the
  # countdown longer than a model call is allowed to take, the reasoning
  # above stops being true and this file must be re-read.
  if @provider_receive_timeout_ms <= @countdown_seconds * 1_000 do
    raise "countdown (#{@countdown_seconds}s) no longer sits inside the provider " <>
            "receive timeout (#{@provider_receive_timeout_ms}ms) — re-read the " <>
            "@provider_receive_timeout_ms note in #{__MODULE__}"
  end

  @doc """
  The countdown, in seconds. The single source of the number.
  """
  @spec countdown_seconds() :: pos_integer()
  def countdown_seconds, do: @countdown_seconds

  @doc """
  The seconds remaining at or below which a card is in its warning step.

  Read by `PlatformWeb.Components.Meetings.CandidateRail` on render and
  published to the client as `data-warning-seconds`, so the server's
  first paint and the ticker's every subsequent one apply the same rule.
  """
  @spec warning_seconds() :: pos_integer()
  def warning_seconds, do: @warning_seconds

  @doc """
  How long a stopped card's `Undo` stays on the rail, in seconds.

  Read by `PlatformWeb.MeetingLive` when it stamps the spent row's
  `expires_at`, and by the rail when it decides whether to draw that row
  at all. The client ticker enforces the same instant from
  `data-expires-at`, so there is one number and no second clock.
  """
  @spec undo_seconds() :: pos_integer()
  def undo_seconds, do: @undo_seconds

  @doc """
  The per-call model receive timeout this countdown is inverted against,
  in milliseconds.

  Not configuration and not used to make a request — it is the provider
  constant this module's own reasoning depends on, exposed so a test can
  bind the two rather than trusting a comment. See
  `@provider_receive_timeout_ms`.
  """
  @spec provider_receive_timeout_ms() :: pos_integer()
  def provider_receive_timeout_ms, do: @provider_receive_timeout_ms

  @doc """
  The instant a card last spoken to at `from` should act.

  Returns `nil` for a nil input rather than defaulting to now, so an
  unarmed card stays unarmed: "we have no utterance time" and "act 30
  seconds from this moment" are different claims and the caller must not
  be able to get the second by accident.
  """
  @spec acts_at(DateTime.t() | nil) :: DateTime.t() | nil
  def acts_at(nil), do: nil

  def acts_at(%DateTime{} = from), do: DateTime.add(from, @countdown_seconds, :second)

  def acts_at(_), do: nil

  @doc """
  Seconds remaining before `acts_at`, floored at zero, or `nil` for a
  disarmed card. What the card's count and drain on `01a03f4e-78b1`
  render (the ring they replaced was dropped by task 01a0740e).
  """
  @spec remaining_seconds(DateTime.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def remaining_seconds(acts_at, now \\ DateTime.utc_now())

  def remaining_seconds(nil, _now), do: nil

  def remaining_seconds(%DateTime{} = acts_at, %DateTime{} = now) do
    acts_at |> DateTime.diff(now, :second) |> max(0)
  end
end
