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
  disarmed card. What the ring on `01a03f4e-78b1` renders.
  """
  @spec remaining_seconds(DateTime.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def remaining_seconds(acts_at, now \\ DateTime.utc_now())

  def remaining_seconds(nil, _now), do: nil

  def remaining_seconds(%DateTime{} = acts_at, %DateTime{} = now) do
    acts_at |> DateTime.diff(now, :second) |> max(0)
  end
end
