defmodule Platform.Meetings.AgentActivity do
  @moduledoc """
  Per-meeting agent activity — what an agent is doing *in this meeting,
  right now* (task `01a04a98`).

  Before this module the meeting bottom strip's `<.agent_tile>` was
  passed `activity_state={:idle}` as a literal at its only call site,
  and the participant rail's status dot read `agents.status` — a
  GLOBAL column that says nothing about the meeting being viewed. Both
  surfaces claimed to be activity signals; neither was.

  ## The two real signals

  There is no `meeting_activity` table and this module does not add
  one. It folds the two per-meeting signals that already exist:

    * **`:computing`** — `Platform.Meetings.IntentQueue` is meeting- AND
      agent-scoped and already tracks `@in_flight_statuses
      [:dispatched, :acked]` against a `target_agent_id`. An in-flight
      row IS "this agent is working on something for this meeting".
      Mirrored onto the meeting shell topic from the queue server's
      single transition write path, and hydrated at mount from
      `IntentQueue.list/1`.

    * **`:typing`** — `{:agent_typing, %{space_id, participant_id,
      typing}}`, broadcast on the meeting's chat-space topic by
      `Platform.Chat.AgentResponder` and `PlatformWeb.RuntimeChannel`.
      `participant_id` there is a `Platform.Chat.Participant` id, not
      an `Agents.Agent` id, so it has to be bridged —
      `agent_id_for_chat_participant/1` is that bridge.

  ## `:listening` has no producer

  `:listening` is a declared state of `<.agent_tile>` and is
  deliberately left UNREACHABLE. Nothing in the system emits "this
  agent is listening": LiveKit's `ActiveSpeakersChanged` is a
  client-side signal about *audio* that never identifies an agent tile
  (the client's identity space is `"agent:" <> slug`; the tile's is
  `"agent:" <> agent_id`), and TTS playback is not modelled anywhere.
  Faking it — deriving it from "the agent is in the room" — would
  rebuild exactly the always-on lie this task exists to remove. It
  stays in the enum so the tile keeps a slot for a real producer.

  ## Precedence

  `:typing` beats `:computing`. Both mean the agent is working, but
  typing is the narrower and more recent claim about the same agent —
  an agent that is emitting output is by definition still working, so
  `:computing` adds nothing on top of it.

  ## The 120-second ceiling

  Each signal maps `agent_id => DateTime` — the moment that agent
  ENTERED the signal — and `resolve_at/2` caps `:computing` and
  `:typing` at 120 seconds. Past the ceiling the agent resolves
  `:failed`.

  Three properties are load-bearing:

    * **Derived at read time, by a pure function.** No timer, no
      process, no `Process.send_after/3`, no sweep. Expiry is a
      function of `entered_at` and the `now` handed in, so it can be
      proved by calling `resolve_at(activity, two_minutes_on)` with
      nothing running at all. A state something has to REMEMBER to
      clear is a state it will forget to clear — which is precisely
      the bug this module already documents against itself below.

    * **It resolves `:failed`, not `:idle`.** Dropping back to idle
      would erase the fact that something went wrong, restoring the
      "finished" / "vanished" ambiguity that `mirror_intent_row/2`
      broadcasts a failure terminal to remove. `:failed` outranks the
      working states, so it caps them.

    * **Re-asserting a signal does NOT restamp it.** `put/4` stamps
      only on a transition INTO a signal the agent did not already
      hold. A producer that repeats "still computing" every few
      seconds would otherwise reset the age on every repeat and the
      ceiling could never fire — the ceiling exists for the producer
      that has stopped, but it has to survive one that has not.

  120 seconds is long enough for a real multi-tool turn and short
  enough that the human who spoke is still waiting; the incident behind
  it was about 40 seconds of silence.

  The ceiling is not a claim that the intent failed at the 120th
  second. It is a refusal to keep claiming the agent is working when
  nothing has said so for two minutes.

  `resolve/1` and `for_agent/2` are the pre-ceiling reads and are
  deliberately left as they were — they answer "which signals does this
  agent hold", which is what today's callers ask. Moving the render
  path onto `resolve_at/2` is a later stage.

  ## `:heard` — a per-utterance receipt, not a resting badge (task 01a06e07)

  `Platform.Meetings.deliver_transcript_segment/2` fans a FINAL transcript
  segment out to every seated agent's brain runtime and returns
  `%{delivered: [agent_id], skipped: [{agent_id, reason}]}}`. Each agent in
  `delivered` gets one `:heard` broadcast, from the exact call site that
  computes that list.

  `:heard` is stamped only in `heard` (a fourth `stamps()` field, alongside
  `computing`/`typing`/`failed`) and it is decayed in `resolve_at/2`, from
  its own `entered_at`, back to whatever the agent's OTHER signals say —
  never to `:failed`. Two seconds after the segment, the agent reads
  exactly as it would have if `:heard` had never been stamped. That is a
  different shape of decay than the ceiling above: the ceiling CAPS a
  signal that is still held; `:heard`'s decay REMOVES it from
  consideration, so `resolve_at/2` falls through to the next signal in
  precedence (or to absence, i.e. idle) once two seconds have passed.

  It also does not obey the no-restamp rule the ceiling depends on.
  Re-asserting `:computing` must not reset its age, because the ceiling
  exists to catch a producer that has gone silent. `:heard` is the
  opposite kind of signal — each delivered segment is a DISTINCT receipt
  — so a second segment landing before the first one's two seconds are up
  restarts the window rather than being absorbed by it.

  ### The trap this is one signal away from becoming

  `:listening` was removed from this rail (canvas `01a05b11-54ff`,
  ratified by the product lead 2026-09-03) because every agent in a call is always
  listening, so a badge that is on for everyone all the time takes a row
  from a state that actually turns over. `:heard` is legitimate ONLY
  because it turns over: it is true for about two seconds after a
  specific utterance and false the rest of the time. A `:heard` that
  never decayed, or that lit up for every agent in the room regardless of
  whether their runtime actually received anything, would be `:listening`
  under a new name — and it would have to be removed again for the same
  reason. `test/platform/meetings/agent_activity_test.exs` pins the decay
  directly: two seconds after the stamp, the agent is NOT `:heard`.

  ### Honesty limit

  `delivered` means the transcript frame was broadcast onto the agent's
  runtime topic WHILE THAT RUNTIME WAS ONLINE per
  `Platform.Federation.RuntimePresence.online?/1` — nothing more. It does
  NOT mean the agent's brain process consumed the frame, acted on it, or
  is even still online by the time this text renders; presence is checked
  at the moment of delivery, not proven. This module never calls
  `RuntimePresence.prove/2` and never adds `"meeting_transcript"` to any
  runtime's `proven` map — that would be core certifying its own send,
  the exact inversion task `01a06dfb` exists to remove, and
  `test/platform/meetings/transcript_delivery_test.exs` pins the absence
  of it. A seated agent whose runtime resolution failed outright (the
  `:no_runtime` skip reason) never appears in `delivered` and so can never
  go `:heard` — that is what keeps `:heard` distinguishable from merely
  "connected": it requires both a resolved runtime AND presence on it at
  the instant of delivery.

  ## Pushed state — `:thinking` and `:composing` (task 01a07400 stage 1)

  Every signal above is something CORE observed: an intent row it wrote,
  a typing toggle it relayed, a transcript segment it delivered. That
  leaves core blind to the one thing only the agent knows — that it is
  mid-turn on work core never dispatched, or drafting a reply it has not
  started emitting. A federated runtime can DECLARE those two states:

    * **`:thinking`** — the agent is working on something it alone knows about.
    * **`:composing`** — the agent is drafting output it has not begun emitting.

  Those two and no others. `:computing`, `:typing`, `:failed` and `:heard`
  all have core-side producers already, and letting a runtime assert them
  would let it overwrite core's own observations with a claim.

  ### Why a pushed state is safe here, when it usually is not

  Ticket `01a06e07` argued — correctly, and this module's own `:heard`
  section repeats it — that *a state the agent must remember to emit is a
  state it will forget to clear*. Pushed state is the shape that argument
  condemns, so the answer has to be structural rather than a promise:

  **The server expires it.** Every pushed row carries its own `ttl_ms` and
  is checked against it on EVERY read, and again by a periodic sweep. A
  runtime that crashes mid-`:thinking`, is OOM-killed, or has its socket
  cut lapses back to its underlying state within the ttl with nothing
  running on its behalf and no message from it. There is deliberately no
  cleanup callback, no `terminate/2`, no disconnect hook and no
  presence-drop handler anywhere on this path: all four are code that runs
  only when the agent dies POLITELY, and the case that matters is the one
  where it does not. `pushed/3` re-derives liveness from `pushed_at`,
  `ttl_ms` and the `now` handed in, so an expired state resolves exactly
  as if it had never been pushed — provably, by calling it with two
  `DateTime`s and nothing running at all.

  Refreshing is therefore the runtime's whole job: a pushed state is a
  heartbeat, and `push/4` deliberately RESTAMPS on repeat — the exact
  opposite of `put_at/5`'s no-restamp rule, and for the exact opposite
  reason. The ceiling's no-restamp rule exists to catch a producer that
  has gone silent; here going silent is precisely what expiry is for, so a
  repeat must be allowed to extend the claim.

  ### Where pushed state sits in the precedence chain

  Resolution order, highest first, is
  **`:failed` > `:typing` > pushed > `:computing`**, with `:heard`
  overlaid on top of the result as it already was. `resolve_at/3` is the
  reader that applies it; `resolve_at/2` is unchanged and knows nothing
  about pushed state.

    * **Below `:failed`.** A `:failed` stamp is a terminal core observed
      (`mirror_intent_row/2` repeating the queue's `:timed_out`). An
      agent's self-report must not be able to paint over the one state
      that says something went wrong.
    * **Below `:typing`.** `:typing` is core relaying output the agent is
      actually emitting. Emitted output beats a claim about intent, by the
      same logic that already makes `:typing` beat `:computing`.
    * **Above `:computing`.** Same rule as `:typing` over `:computing`:
      the narrower and more recent claim about the same agent wins. An
      in-flight intent row says core dispatched work; a live pushed state
      says the agent is on it right now.

  That placement has one consequence worth stating outright, because it is
  the feature rather than a side effect: **a live pushed state pre-empts
  the 120-second ceiling.** The ceiling caps `:computing`/`:typing` only
  when the walk reaches those layers, and a live pushed state claims the
  agent's slot before it gets there. An agent that is genuinely mid-turn
  for three minutes and says so every ttl reads `:thinking`, not
  `:failed`; one that stops saying so lapses within the ttl and the
  ceiling resumes. Pushed states are never capped by `cap/2` — their ttl
  is their bound, and it is a much tighter one.

  Pushed states are also absent from `resolve/1` and `for_agent/2`, for
  the same reason `:heard` is: neither reader takes a `now`, so neither
  can age anything out, and a state that cannot expire through a reader
  latches forever through it.

  ### The ttl is configuration, not a tuned constant

  `pushed_ttl_ms/0` reads
  `Application.get_env(:platform, :meeting_agent_pushed_ttl_ms, …)`. The
  compiled default is a placeholder and is NOT a measurement: choosing it
  properly needs the agent think-time distribution from task
  `01a07400-64bd`, which had not reported when this shipped. A number
  guessed here and left as a literal is a number that becomes permanent,
  so the contract is the config key; the default is only what applies
  until someone with the distribution sets it.

  ## `:speaking` and `:delayed` — the two core CAN produce (task 01a07400 stage 2)

  Stage 1 gave the agent two states core cannot see. These two are the
  other side: states core can assert honestly because core owns the fact
  behind them, so neither needs a runtime to remember anything.

  ### `:speaking` — core is the thing playing the audio

  Stamped in `mark_speaking/4` from `Platform.Meetings.say/4`, at the
  moment the `meeting_say` frame goes out, and cleared in
  `clear_speaking/3` from `record_agent_say_ack/2` when the receipt comes
  back. `Platform.Meetings.SpeakingWindow` is the seam between the two —
  `meetings.ex` gets a single call at each end and none of this logic.

  **Known and accepted: this over-reports slightly at the tail.** The ack
  arrives after PLAYOUT FINISHES, not when the last audio frame is
  handed to the room, so the window runs a little past the actual sound.
  That is a consequence of `01a06f5d`'s ack shape and it is the right way
  round to be wrong: the reader of this state is the human deciding
  whether to start talking, and telling them the agent is still speaking
  when it has just stopped costs a beat, while the opposite costs a
  collision. Fixing the ack's timing is `01a06f5d`'s job, not this one's.

  Both bounds that keep it from becoming a latch are structural rather
  than promised:

    * The ack CLEARS it, and clearing is pinned by a test that asserts
      both ends. A `:speaking` that is only ever set is an agent pinned as
      permanently talking — `:listening` again, under a word that turns
      over on paper and not in practice.
    * A ttl covers the ack that never arrives (a runtime killed
      mid-playout). Unlike stage 1's, that ttl is DERIVED rather than
      configured: core knows how many characters it dispatched, so
      `speaking_ttl_ms/1` computes the playout bound from the utterance
      instead of from a dial. It is generous on purpose — it is a
      backstop, not the normal path.

  ### `:delayed` — inferred, and it cannot exist without its reason

  `Platform.Meetings.AgentActivity.Delayed` is the state, and it is a
  struct with `@enforce_keys [:reason]` rather than an atom with a reason
  hung off it. There is no arity, no default and no code path in this
  module that produces a reason-less `:delayed`: `apply_delays/2` accepts
  only a valid `Delayed`, and `delays_from_facts/1` simply omits any agent
  whose facts yield no specific cause. "A spinner that does not say what it
  is waiting for" is the opacity this task exists to remove, so it is made
  unrepresentable rather than discouraged.

  The reasons come from `Platform.Meetings.AgentDelayReason`, and only its
  PROMOTABLE clauses — see `AgentDelayReason.specific_for_agent/1` for why
  the default `"still running a tool"` and `"no voice worker in this
  room"` both stay notes beside a working state rather than becoming
  states.

  `:delayed` is applied AFTER resolution, not as a layer within it, because
  it is a qualification of the working state rather than a competitor to
  it. It never touches `:idle`, `:failed`, `:heard` or `:speaking`.

  ## What this is NOT

  **Still not a process.** `%AgentActivity{}` is a value a consumer
  (today, `PlatformWeb.MeetingLive`) holds in its own state and folds
  signals into, and this module exports no `init/1` and no
  `handle_info/2` — `agent_activity_test.exs` pins that directly, because
  the 120-second ceiling has to stay provable by handing a value and two
  `DateTime`s to a function with nothing running. Pushed state did not
  change that: its expiry is decided on every read by `live?/2`, so it is
  as pure as the ceiling is, and the GenServer that owns the ETS table
  lives in `Platform.Meetings.AgentActivity.Store` precisely so the guard
  keeps holding. Nothing here writes, broadcasts or remembers a state
  change on an elapsed-time guess.

  It IS a store now, for pushed state only, and the two halves stay
  separable: every signal-derived reading is a function of the struct and
  a `now`, and no reader touches the table unless it was handed a
  `meeting_id` (`resolve_at/3`, and only that).

  Two consequences of the value half worth naming:

    * A socket that mounts mid-meeting hydrates `:computing` from the
      live queue, but **cannot** hydrate `:typing` — the typing signal
      is a transient broadcast with nowhere to read it back from. A
      late joiner sees a typing agent from its next toggle onward.
    * If a meeting's queue owner stops (`:meeting_finished`) while a
      row is in flight, no terminal transition is broadcast — nothing
      ever tells the socket that agent stopped. That used to hold the
      agent `:computing` until the socket remounted; the read-time
      ceiling above now caps it at two minutes. What has not changed is
      the refusal to invent a terminal transition the queue never
      reached: nothing here writes, broadcasts or remembers a state
      change on an elapsed-time guess.
  """

  alias Platform.Chat.Participant
  alias Platform.Meetings.AgentActivity.Delayed
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @typedoc "The activity states `PlatformWeb.Components.Meeting.AgentTile` renders."
  @type state ::
          :idle
          | :typing
          | :computing
          | :failed
          | :listening
          | :heard
          | :thinking
          | :composing
          | :speaking
          | :delayed

  @typedoc """
  A raw signal name. `:listening` is absent — it has no producer.
  `:heard` has one (`Platform.Meetings.deliver_transcript_segment/2`) but
  is deliberately excluded from `@precedence` below — see the moduledoc's
  `:heard` section for why its decay lives only in `resolve_at/2`.

  `:thinking` and `:composing` are absent for a different reason: they are
  not signals at all. A signal is folded into the struct by `put_at/5` and
  is latched until a producer clears it; a pushed state lives in the ETS
  store, is asserted by the agent rather than observed by core, and expires
  on its own. See `pushed_states/0`.
  """
  @type signal :: :computing | :typing | :failed | :heard

  @typedoc "A state a federated runtime may declare about itself."
  @type pushed_state :: :thinking | :composing

  @typedoc """
  One row of the pushed-state store.

  `pushed_at` is a wall clock, not monotonic, for the same reason every
  other clock in this module is: the whole expiry model here is derived at
  READ time from a `now` the caller hands in, so a test proves it by
  choosing two `DateTime`s rather than by sleeping. Reads, the sweep and
  the writer all run on one node, so there is no cross-node skew to
  survive.
  """
  @type pushed_entry :: %{
          state: pushed_state(),
          reason: String.t() | nil,
          pushed_at: DateTime.t(),
          ttl_ms: pos_integer()
        }

  @typedoc """
  One row of the `:speaking` store.

  `utterance_id` is carried so `clear_speaking/3` can refuse to end a
  window that a LATER dispatch opened — see `mark_speaking/4`. `ttl_ms`
  comes from `speaking_ttl_ms/1` and is a bound on playout, not a
  heartbeat interval: nothing refreshes a `:speaking` row.
  """
  @type speaking_entry :: %{
          state: :speaking,
          utterance_id: binary(),
          started_at: DateTime.t(),
          ttl_ms: pos_integer()
        }

  @states [
    :idle,
    :typing,
    :computing,
    :failed,
    :listening,
    :heard,
    :thinking,
    :composing,
    :speaking,
    :delayed
  ]
  @signals [:computing, :typing, :failed, :heard]
  @pushed_states [:thinking, :composing]

  # The states `:delayed` may QUALIFY. An agent has to be working before it
  # can be blocked: `:idle` is not delayed, it is idle; `:failed` already
  # said something went wrong and must not be softened into "waiting";
  # `:heard` is a two-second receipt for a specific utterance; and
  # `:speaking` is audio going out RIGHT NOW, which is the one state that
  # cannot simultaneously be stuck. See `apply_delays/2`.
  @delayable_states [:computing, :typing, :thinking, :composing]

  # Ordered by precedence, highest first. `resolve/1` AND `for_agent/2`
  # walk this, so adding a producer here means it gains an UNDECAYED,
  # permanent-once-set reading through those two functions. `:heard`
  # stays OUT of this list for exactly that reason: it has no "off"
  # broadcast (nothing ever un-hears an utterance), so if it appeared
  # here it would latch forever the first time any agent heard anything
  # — precisely the always-on-for-everyone shape `:listening` was
  # removed for. Its decay is applied separately, in `resolve_at/2`,
  # which is the only reader that knows how to age it out.
  @precedence [:failed, :typing, :computing]

  # The order `resolve_at/2` and `resolve_at/3` walk, highest first.
  #
  # Identical to `@precedence` except for the `:pushed` layer wedged
  # between `:typing` and `:computing` — see the moduledoc's "Where pushed
  # state sits in the precedence chain". `resolve_at/2` walks this with an
  # EMPTY pushed map, so the two lists cannot drift into disagreeing about
  # where the signal layers sit relative to each other. They stay separate
  # attributes because `@precedence` is also walked by `resolve/1` and
  # `for_agent/2`, neither of which takes a `now` and so neither of which
  # may ever see a layer that has to be aged out.
  # `:speaking` is FIRST, above `:failed`, and that is the one placement
  # here that is not inherited from `@precedence`.
  #
  # Stage 1 put pushed states BELOW `:failed` on the grounds that an
  # agent's self-report must not paint over the one reading that says
  # something went wrong. That argument is about self-reports and does not
  # reach this layer: `:speaking` is not a claim the agent made, it is
  # core's record that core itself dispatched audio for this agent, at a
  # moment it can name. Present-tense evidence that the agent is producing
  # output outranks a past terminal — the same judgement `put_at/5`'s
  # `clear_stale_failure/4` already makes when a NEW in-flight intent
  # retires an old failure, because "Couldn't" beside an agent that is
  # audibly talking is the defect, not the safeguard.
  #
  # It is bounded, so it cannot hide a failure indefinitely: a `:speaking`
  # row carries a ttl derived from the length of the text core sent, and a
  # lapsed one stops resolving whether or not any ack ever arrives.
  @resolution_order [:speaking, :failed, :typing, :pushed, :computing]

  # Long enough for a real multi-tool turn, short enough that the human
  # who spoke is still waiting. Applied at READ time only — see the
  # moduledoc for why there is no timer behind it.
  @ceiling_seconds 120

  # How long a `:heard` stamp reads as `:heard` before `resolve_at/2`
  # lets it fall back to whatever the agent's other signals say. Chosen
  # to read as "just now" for one utterance without bleeding into the
  # next one in an active exchange.
  @heard_decay_seconds 2

  # Both meeting surfaces (`PlatformWeb.MeetingLive` and the quickmeet panel
  # inside `ChatLive`, task 01a06e07 stage 3) re-render the rail's ages on
  # this exact cadence. One constant so the two schedulers cannot drift to
  # different intervals and read the same clock at different rates.
  @tick_interval_ms 1_000

  # The pushed-state store. `{{meeting_id, agent_id}, pushed_entry()}`.
  #
  # Named, public, owned by this module's GenServer purely for the table's
  # lifecycle — pushes and reads happen in the caller's process, the shape
  # `PressWindow`, `SayRegistry` and `VoiceSeatCache` all use.
  @pushed_table :meeting_agent_pushed_state

  # A PLACEHOLDER, not a measurement. Read through `pushed_ttl_ms/0`, which
  # goes to `Application.get_env/3` first, so the deployable dial exists
  # before the number is known.
  #
  # Setting it properly needs the agent think-time distribution from task
  # `01a07400-64bd`, which was still running and had not reported when this
  # shipped. All that is claimed for 30s is the shape of the constraint:
  # comfortably longer than the couple of seconds a trivial turn takes (or
  # a runtime would have to heartbeat absurdly often), and comfortably
  # SHORTER than `ceiling_seconds/0`, or a pushed state that pre-empts the
  # ceiling could outlive the window the ceiling exists to bound and a dead
  # agent would read `:thinking` for longer than it would have read
  # `:computing`. Anything more precise than that is guesswork, and a
  # guessed literal left in the source is a guessed literal forever.
  @default_pushed_ttl_ms 30_000

  # How often the sweep runs. Expiry is already enforced on every read, so
  # this only bounds how long a lapsed row occupies the table — it is not
  # what makes a lapsed state stop reading as live. Deliberately shorter
  # than the default ttl so the table does not accumulate a full ttl's
  # worth of dead rows between passes.
  @pushed_sweep_interval_ms 10_000

  # Bounds one row. A reason is a short human-readable note rendered beside
  # the state, not a log line; a runtime that sends an essay gets it cut
  # rather than having the push refused, because the state is the load-
  # bearing half and losing it over a long string would be the worse
  # outcome.
  @pushed_reason_max_chars 200

  # The `:speaking` store (task 01a07400 stage 2).
  # `{{meeting_id, agent_id}, speaking_entry()}`.
  #
  # A SECOND table rather than a second kind of row in `@pushed_table`,
  # because the two layers have to be able to coexist: `:speaking` and a
  # pushed `:composing` sit at different points in `@resolution_order`, and
  # sharing one key per agent would mean core's dispatch silently deleting
  # the agent's own declaration (or the reverse). Same OWNER though —
  # `AgentActivity.Store` creates both and sweeps both — so this extends
  # that store rather than standing up a second process beside it.
  @speaking_table :meeting_agent_speaking_state

  # The floor and the rate behind `speaking_ttl_ms/1`.
  #
  # Neither is a guess about agent behaviour, which is what made stage 1's
  # pushed ttl a config key rather than a constant. This ttl is a bound on
  # PLAYOUT, and playout length is a fact about text core is holding in its
  # hand at the moment it dispatches: ~150 words per minute is the ordinary
  # TTS speaking rate, ~5 characters per word, so ~12.5 chars/s — 80ms per
  # character. The floor covers the fixed cost of getting audio started at
  # all, and keeps a three-word utterance's ttl from being a few hundred
  # milliseconds.
  #
  # It is deliberately an OVER-estimate. The ttl is not what normally ends
  # a `:speaking`; the ack is. This is only the bound for the case where no
  # ack ever comes, and over-running there shows "still speaking" slightly
  # too long, which is the safe direction — the person this state exists
  # for is the one deciding whether to start talking.
  @speaking_floor_ms 5_000
  @speaking_ms_per_char 80

  defstruct computing: %{}, typing: %{}, failed: %{}, heard: %{}

  @typedoc "`agent_id => the DateTime that agent ENTERED this signal`."
  @type stamps :: %{binary() => DateTime.t()}

  @type t :: %__MODULE__{
          computing: stamps(),
          typing: stamps(),
          failed: stamps(),
          heard: stamps()
        }

  @typedoc """
  One `resolve_at/2` entry: the capped state, plus the clock it was capped
  from.

  `:reason` is present on `:delayed` entries and ONLY on those — see
  `apply_delays/2`. It is not an optional decoration on a `:delayed`: the
  only way an entry acquires that state is by being handed a
  `Platform.Meetings.AgentActivity.Delayed`, which cannot exist without one.
  """
  @type resolved :: %{
          :state => state(),
          :entered_at => DateTime.t(),
          :age_s => integer(),
          optional(:reason) => String.t()
        }

  @doc """
  The ETS table the pushed-state store lives in.

  Exposed for exactly one caller: `Platform.Meetings.AgentActivity.Store`,
  the GenServer that owns the table's lifecycle and drives the sweep.

  **The process deliberately lives in another module.** The read-time
  ceiling test in `agent_activity_test.exs` pins that THIS module exports
  no `init/1` and no `handle_info/2` — "turning it into a GenServer to
  sweep the ceiling is the change this forbids" — and that guard is right
  and stays exactly as it was. Everything the struct half of this module
  resolves is still a pure function of a value and a `now`, with no pid,
  no timer and no process behind it, and a value still round-trips through
  `term_to_binary/1` and expires identically.

  Pushed state does not weaken that. Its expiry is a pure function too —
  `live?/2`, applied on every read — and the sweep deletes nothing a read
  would not already have hidden. What the process is for is the table's
  lifecycle and reclaiming space, the same job
  `Platform.Meetings.PressWindow` and `Platform.Meetings.SayRegistry` do
  for theirs. Keeping it in its own module is what makes that distinction
  checkable rather than a claim in a comment.
  """
  @spec pushed_table() :: atom()
  def pushed_table, do: @pushed_table

  @doc "The states an agent tile can render."
  @spec states() :: [state()]
  def states, do: @states

  @doc "The signals that actually have a producer."
  @spec signals() :: [signal()]
  def signals, do: @signals

  @doc """
  The states a federated runtime may declare about itself: `:thinking` and
  `:composing`, and nothing else.

  Every other member of `states/0` is derived from something core observed,
  and a runtime that could assert those would be able to overwrite core's
  own record with a claim — `:failed` most damagingly of all. These two are
  the states core has no way to see.
  """
  @spec pushed_states() :: [pushed_state()]
  def pushed_states, do: @pushed_states

  @doc """
  The ETS table `:speaking` rows live in (task `01a07400` stage 2).

  Exposed for the same single caller `pushed_table/0` is:
  `Platform.Meetings.AgentActivity.Store`, which creates it and sweeps it.
  """
  @spec speaking_table() :: atom()
  def speaking_table, do: @speaking_table

  @doc """
  The states a `:delayed` may qualify — the working ones, and only those.

  `apply_delays/2` leaves every other state alone. See `@delayable_states`.
  """
  @spec delayable_states() :: [state()]
  def delayable_states, do: @delayable_states

  @doc """
  How long a `:speaking` row for `char_count` characters reads as live
  before it lapses.

  Derived, not configured, and that is the difference from
  `pushed_ttl_ms/0`. Stage 1's pushed ttl is a config key because nobody
  knows how long an agent thinks for. This one bounds PLAYOUT, and core
  knows exactly how much text it dispatched — so the number comes from the
  utterance rather than from a dial someone has to remember to set.

  A generous over-estimate on purpose: the ack, not the ttl, is what
  normally ends a `:speaking`. This is the bound for an ack that never
  arrives, and over-running there is the safe direction.
  """
  @spec speaking_ttl_ms(non_neg_integer()) :: pos_integer()
  def speaking_ttl_ms(char_count) when is_integer(char_count) and char_count >= 0,
    do: @speaking_floor_ms + char_count * @speaking_ms_per_char

  def speaking_ttl_ms(_char_count), do: @speaking_floor_ms

  @doc """
  Milliseconds a pushed state reads as live before it lapses.

  `Application.get_env(:platform, :meeting_agent_pushed_ttl_ms, …)` — the
  config key is the contract; the compiled default is a placeholder pending
  the think-time distribution from task `01a07400-64bd`. See the moduledoc.

  A non-positive or non-integer configured value is ignored in favour of
  the default: a ttl of zero or below would expire every push on the read
  that follows it, which is indistinguishable from the feature being off
  and is never what someone setting this key means.
  """
  @spec pushed_ttl_ms() :: pos_integer()
  def pushed_ttl_ms do
    case Application.get_env(:platform, :meeting_agent_pushed_ttl_ms, @default_pushed_ttl_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_pushed_ttl_ms
    end
  end

  @doc "Milliseconds between pushed-state sweeps."
  @spec pushed_sweep_interval_ms() :: pos_integer()
  def pushed_sweep_interval_ms, do: @pushed_sweep_interval_ms

  @doc "Maximum length of a pushed state's `reason`; longer text is truncated."
  @spec pushed_reason_max_chars() :: pos_integer()
  def pushed_reason_max_chars, do: @pushed_reason_max_chars

  @doc """
  Seconds after which `resolve_at/2` lets a `:heard` stamp fall back to
  the agent's underlying state. Exposed for the same reason
  `ceiling_seconds/0` is: a caller or test states the bound once.
  """
  @spec heard_decay_seconds() :: pos_integer()
  def heard_decay_seconds, do: @heard_decay_seconds

  @doc """
  Seconds after which `resolve_at/2` caps a working signal at `:failed`.

  Exposed so a caller or a test states the bound once rather than
  restating 120 and drifting from it.
  """
  @spec ceiling_seconds() :: pos_integer()
  def ceiling_seconds, do: @ceiling_seconds

  @doc """
  Milliseconds between agent-activity render ticks.

  Exposed so `PlatformWeb.MeetingLive` and
  `PlatformWeb.ChatLive.MeetingHooks` schedule their `:agent_activity_tick`
  loops on the identical interval, one constant read twice rather than
  the number typed twice and left free to drift.
  """
  @spec tick_interval_ms() :: pos_integer()
  def tick_interval_ms, do: @tick_interval_ms

  @doc "An empty activity value — every agent resolves `:idle`."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Seed `:computing` from `meeting_id`'s LIVE intent queue.

  This is the mount-time hydration, and it is the difference between a
  late-joining viewer seeing the truth and seeing an agent frozen at
  whatever the tile's default happened to be. `IntentQueue.list/1`
  returns `[]` when no owner is running, which correctly resolves to
  "every agent idle".
  """
  @spec hydrate(binary()) :: t()
  def hydrate(meeting_id) when is_binary(meeting_id) do
    in_flight = IntentQueue.in_flight_statuses()
    failure = IntentQueue.failure_statuses()

    rows =
      meeting_id
      |> IntentQueue.list()
      |> Enum.filter(&is_binary(Map.get(&1, :target_agent_id)))

    now = DateTime.utc_now()

    computing =
      rows
      |> Enum.filter(&(Map.get(&1, :status) in in_flight))
      |> Map.new(&{&1.target_agent_id, stamp_from(&1, [:dispatched_at, :enqueued_at], now)})

    %__MODULE__{computing: computing, failed: hydrate_failed(rows, failure, now)}
  end

  def hydrate(_), do: new()

  # `:failed` is seeded only from an agent's MOST RECENT row.
  #
  # A remounting viewer must see what is true now, and "this agent has
  # failed at some point today" is not that — every agent would wear a
  # permanent red cap by mid-afternoon and the state would stop meaning
  # anything. `IntentQueue.list/1` is oldest-first, so the last row per
  # agent wins the reduce, and only that row's status is consulted.
  #
  # An agent whose latest row is in flight is therefore NOT seeded as
  # failed even if the row before it timed out, which matches
  # `clear_stale_failure/4`'s live behaviour. Hydration and the live
  # path have to agree, or a remount silently changes the screen.
  defp hydrate_failed(rows, failure_statuses, now) do
    rows
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, row.target_agent_id, row) end)
    |> Enum.filter(fn {_agent_id, row} -> Map.get(row, :status) in failure_statuses end)
    |> Map.new(fn {agent_id, row} ->
      {agent_id, stamp_from(row, [:timed_out_at, :dispatched_at, :enqueued_at], now)}
    end)
  end

  # A hydrating socket takes the ROW's clock, not its own.
  #
  # `entered_at` has to be when the agent started working, not when
  # this viewer happened to open the page. Stamping hydration with
  # `now` would reset every age on every remount, and a socket that
  # reconnects inside the window would hold a dead agent `:computing`
  # forever — the ceiling defeated by exactly the remount it exists to
  # survive. `dispatched_at` is stamped for both in-flight statuses
  # (`:dispatched`, `:acked`); `enqueued_at` is the fallback, and `now`
  # the last resort for a row carrying neither.
  defp stamp_from(row, keys, now) do
    Enum.find_value(keys, now, fn key ->
      case Map.get(row, key) do
        %DateTime{} = at -> at
        _ -> nil
      end
    end)
  end

  @doc """
  Fold one signal into the activity value.

  `active?` false removes the agent from that signal without touching
  the other — an agent can stop typing while an intent is still in
  flight, and that must resolve `:computing`, not `:idle`.
  """
  @spec put(t(), signal(), binary(), boolean()) :: t()
  def put(%__MODULE__{} = activity, signal, agent_id, active?)
      when signal in @signals and is_binary(agent_id) and is_boolean(active?) do
    put_at(activity, signal, agent_id, active?, DateTime.utc_now())
  end

  def put(%__MODULE__{} = activity, _signal, _agent_id, _active?), do: activity

  @doc """
  `put/4` with the clock handed in, and the home of the no-restamp rule.

  A stamp is taken ONLY on a transition into a signal the agent did not
  already hold. Re-asserting a signal the agent holds returns the value
  untouched, so the age keeps running from the first assertion.

  That is the subtle half of the ceiling. `:computing` is mirrored from
  every intent-row transition and `:typing` from every toggle a chat
  producer emits, so a live agent re-asserts the same signal
  repeatedly. If each repeat restamped, the age would reset on every
  one and the ceiling could never fire for a producer that is still
  talking — the value would expire only in the one case where nothing
  arrives at all, which is a much smaller guarantee than the one this
  is meant to give.

  Explicit `now` because the ceiling has to be provable without a
  clock, a timer or a `Process.sleep/1`: a test builds an aged value by
  choosing the two `DateTime`s.

  `:heard` is the one exception to the no-restamp rule, and
  `restamp_on_repeat?/1` below is where that exception lives. It is a
  per-utterance event rather than a continuous claim: a second delivered
  segment arriving while the first is still inside its two-second decay
  window is a NEW receipt, not a repeat of the old one, so it has to
  restart the window rather than being absorbed by it the way a repeated
  "still computing" is.
  """
  @spec put_at(t(), signal(), binary(), boolean(), DateTime.t()) :: t()
  def put_at(%__MODULE__{} = activity, signal, agent_id, active?, %DateTime{} = now)
      when signal in @signals and is_binary(agent_id) and is_boolean(active?) do
    stamps = Map.fetch!(activity, signal)

    updated =
      cond do
        not active? -> Map.delete(stamps, agent_id)
        restamp_on_repeat?(signal) -> Map.put(stamps, agent_id, now)
        Map.has_key?(stamps, agent_id) -> stamps
        true -> Map.put(stamps, agent_id, now)
      end

    activity
    |> Map.put(signal, updated)
    |> clear_stale_failure(signal, agent_id, active?)
  end

  def put_at(%__MODULE__{} = activity, _signal, _agent_id, _active?, _now), do: activity

  defp restamp_on_repeat?(:heard), do: true
  defp restamp_on_repeat?(_signal), do: false

  @doc """
  Fold one `{:agent_typing, …}` broadcast into the value.

  THE one implementation of the typing fold, for both surfaces. Task
  `01a05b14` stage 5 (round 2) found `/meetings` folding this signal in
  `PlatformWeb.MeetingLive.handle_info/2` while the quickmeet had no
  fold at all — so "Writing" was unreachable on the chat surface while
  the composer on the same page showed "X is thinking…" from the same
  broadcast. Both surfaces now call this.

  `chat_participant_id` is a `Platform.Chat.Participant` id and is
  bridged through `agent_id_for_chat_participant/1`: a human
  participant, an unknown id or a malformed one resolves to `nil` and
  leaves the value untouched, so a person typing in the meeting chat
  cannot light an agent row. `typing` is compared to `true` rather than
  pattern-matched, so a payload carrying anything else reads as
  "stopped" instead of raising inside a `handle_info`.
  """
  @spec put_typing(t(), term(), term()) :: t()
  def put_typing(%__MODULE__{} = activity, chat_participant_id, typing) do
    case agent_id_for_chat_participant(chat_participant_id) do
      agent_id when is_binary(agent_id) -> put(activity, :typing, agent_id, typing == true)
      nil -> activity
    end
  end

  # A socket that never hydrated the struct (nil) folds nothing rather
  # than crashing the LiveView that received a broadcast.
  def put_typing(activity, _chat_participant_id, _typing), do: activity

  # A new in-flight intent retires the previous failure for that agent.
  #
  # Without this the `:failed` cap is permanent for the life of the
  # socket: `:failed` outranks `:computing`, so an agent that failed
  # once would render "Couldn't" while visibly working on the next
  # request. Retiring it on the START of new work — not on its
  # completion — is what makes the dock track what the agent is doing
  # NOW rather than the worst thing it has ever done.
  #
  # Deliberately keyed on `:computing` going ACTIVE. `:typing` is a
  # chat signal that can fire for reasons unrelated to the intent that
  # failed, so clearing on it would erase a real failure by coincidence.
  defp clear_stale_failure(%__MODULE__{} = activity, :computing, agent_id, true) do
    %{activity | failed: Map.delete(activity.failed, agent_id)}
  end

  defp clear_stale_failure(%__MODULE__{} = activity, _signal, _agent_id, _active?), do: activity

  @doc """
  The `%{agent_id => state}` map. Idle agents are ABSENT rather than
  mapped to `:idle`, so the map's size is the number of agents actually
  doing something.
  """
  @spec resolve(t()) :: %{binary() => state()}
  def resolve(%__MODULE__{} = activity) do
    Enum.reduce(@precedence, %{}, fn signal, acc ->
      activity
      |> Map.fetch!(signal)
      |> Enum.reduce(acc, fn {agent_id, _entered_at}, inner ->
        Map.put_new(inner, agent_id, signal)
      end)
    end)
  end

  @doc """
  `resolve/1` with the ceiling applied, against the `now` handed in.

  Returns `%{agent_id => %{state:, entered_at:, age_s:}}`. Idle agents
  stay ABSENT, as in `resolve/1`.

  A `:computing` or `:typing` whose `age_s` has reached
  `ceiling_seconds/0` resolves **`:failed`** — not `:idle`. An agent
  that has been "Thinking" for two minutes with nothing arriving has
  not finished and has not gone idle; something went wrong, and idle
  would erase that.

  `:failed` is never aged out. It is already a terminal reading, its
  age is how long ago it happened, and there is no truer state to
  decay into.

  Pure: the only inputs are the value and `now`. Nothing is written,
  broadcast, scheduled or remembered, so a caller may call this on
  every render, and a reviewer can prove the ceiling by calling it
  twice with two `DateTime`s and no processes running.

  A `now` that predates a stamp (clock skew between the hydrating row
  and the reader) yields a negative `age_s` and no cap, which is the
  right way round: skew must not manufacture a failure.

  ## `:heard` is layered on top, not folded through `@precedence`

  The reduce below computes the SAME value `resolve_at/2` always has —
  `:heard` never participates in it, for the reason `@precedence`'s own
  comment gives. Afterwards, every live (age under `heard_decay_seconds/0`)
  `:heard` stamp overwrites that agent's entry with `:heard`, and every
  decayed one is left alone — which is what makes the base value the
  agent's "underlying state" for `:heard` to fall back to. An agent with
  no other signal at all still gets a `:heard` entry while it is live
  (overwriting nothing) and reverts to ABSENT — idle — once it decays,
  exactly like every other signal's absence.
  """
  @spec resolve_at(t(), DateTime.t()) :: %{binary() => resolved()}
  def resolve_at(%__MODULE__{} = activity, %DateTime{} = now),
    do: resolve_layered(activity, %{}, now)

  @doc """
  `resolve_at/2` with `meeting_id`'s LIVE store-backed states folded in —
  the agent's own pushed `:thinking`/`:composing`, and core's `:speaking`.

  The one reader that knows about the store. It reads the store
  (so it is not pure, unlike `resolve_at/2`), takes only the rows that have
  not lapsed as of `now`, and resolves them at the `:pushed` layer of
  `@resolution_order` — **below `:failed` and `:typing`, above
  `:computing`**. The moduledoc's "Where pushed state sits in the
  precedence chain" is the argument for that placement; the consequence
  that matters is that a live pushed state claims the agent's slot before
  the walk reaches `:computing`/`:typing`, and so pre-empts the
  120-second ceiling for exactly as long as the runtime keeps refreshing.

  Pushed states are never capped by `cap/2`. Their ttl is their bound and
  it is far tighter than `ceiling_seconds/0`; capping them a second time at
  120 seconds would be dead code today and a silent contradiction the day
  someone configured a longer ttl.

  `:heard` still overlays the result, unchanged — a delivered utterance is
  a receipt for a specific event and outranks any standing claim, including
  a self-declared one.

  `:speaking` is read from the same store and resolves at the TOP of
  `@resolution_order`, above `:failed`. It is not capped by `cap/2` either:
  like a pushed state, its ttl is its bound, and unlike a pushed state that
  ttl was computed by core from the length of the text core itself sent.

  This does not apply `:delayed` — that layer needs facts gathered per
  agent (a DB read and a presence check each), which is the render loop's
  decision to make. Pipe the result through `apply_delays/2`.
  """
  @spec resolve_at(t(), binary(), DateTime.t()) :: %{binary() => resolved()}
  def resolve_at(%__MODULE__{} = activity, meeting_id, %DateTime{} = now)
      when is_binary(meeting_id) do
    store = %{
      pushed: pushed_all(meeting_id, now),
      speaking: speaking_all(meeting_id, now)
    }

    resolve_layered(activity, store, now)
  end

  defp resolve_layered(%__MODULE__{} = activity, store, %DateTime{} = now) do
    base =
      Enum.reduce(@resolution_order, %{}, fn layer, acc ->
        layer
        |> layer_entries(activity, store)
        |> Enum.reduce(acc, fn {agent_id, state, entered_at}, inner ->
          Map.put_new_lazy(inner, agent_id, fn -> resolved(state, entered_at, now) end)
        end)
      end)

    Enum.reduce(activity.heard, base, fn {agent_id, entered_at}, acc ->
      age_s = DateTime.diff(now, entered_at, :second)

      if age_s < @heard_decay_seconds and not speaking?(acc, agent_id) do
        Map.put(acc, agent_id, %{state: :heard, entered_at: entered_at, age_s: age_s})
      else
        acc
      end
    end)
  end

  # `:heard` overlays every state EXCEPT `:speaking` (task 01a07400 stage 2).
  #
  # It outranks the others because a delivered utterance is a receipt for a
  # specific event and they are standing claims — stage 1 made that
  # argument for pushed state and it holds. `:speaking` is the one case
  # where the overlay would do harm rather than good, and the situation is
  # not hypothetical: a human talking over an agent produces a transcript
  # segment that is delivered to that agent's runtime, so the agent goes
  # `:heard` while its own audio is mid-playout. Hiding "this agent is
  # talking right now" for two seconds, at the exact moment two people are
  # already talking at once, would suppress the reading precisely when it
  # is most needed. The receipt is the less urgent of the two facts, so it
  # yields.
  defp speaking?(resolved, agent_id) do
    match?(%{state: :speaking}, Map.get(resolved, agent_id))
  end

  # `{agent_id, state, entered_at}` for one layer of `@resolution_order`.
  # The pushed layer's `entered_at` is the row's `pushed_at`, so the age the
  # rail renders for a declared state is how long ago the agent declared it
  # — not how long ago the socket noticed.
  defp layer_entries(:pushed, _activity, store) do
    store
    |> Map.get(:pushed, %{})
    |> Enum.map(fn {agent_id, %{state: state, pushed_at: pushed_at}} ->
      {agent_id, state, pushed_at}
    end)
  end

  # The `:speaking` layer's `entered_at` is `started_at` — the moment core
  # dispatched the audio — so the rail's age is how long the agent has been
  # talking, not how long ago the socket noticed.
  defp layer_entries(:speaking, _activity, store) do
    store
    |> Map.get(:speaking, %{})
    |> Enum.map(fn {agent_id, %{started_at: started_at}} ->
      {agent_id, :speaking, started_at}
    end)
  end

  defp layer_entries(signal, %__MODULE__{} = activity, _store) do
    activity
    |> Map.fetch!(signal)
    |> Enum.map(fn {agent_id, entered_at} -> {agent_id, signal, entered_at} end)
  end

  defp resolved(signal, entered_at, now) do
    age_s = DateTime.diff(now, entered_at, :second)

    %{state: cap(signal, age_s), entered_at: entered_at, age_s: age_s}
  end

  defp cap(signal, age_s) when signal in [:computing, :typing] and age_s >= @ceiling_seconds,
    do: :failed

  defp cap(signal, _age_s), do: signal

  @doc """
  `resolve_at/2` for a caller that may be holding either the real struct or
  an already-resolved `%{agent_id => state}}` map — the same "accepts
  either" contract `for_agent/2` established for the pre-ceiling read,
  extended to this one (task `01a06e07` stage 3, the render path's move
  onto the ceiling-aware read).

  A plain map (what hand-built test fixtures and `for_agent/2`'s existing
  callers hold) carries no timestamp to age or cap against, so every entry
  is wrapped with `age_s: 0` and `entered_at: now` rather than invented. A
  caller that actually needs the ceiling or the age has to hold the real
  struct; this exists so a render helper can treat either shape uniformly
  without a second code path.
  """
  @spec resolve_for_render(t() | %{binary() => state()} | nil, DateTime.t()) ::
          %{binary() => resolved()}
  def resolve_for_render(%__MODULE__{} = activity, %DateTime{} = now),
    do: resolve_at(activity, now)

  def resolve_for_render(map, %DateTime{} = now) when is_map(map) do
    Map.new(map, fn {agent_id, state} ->
      {agent_id, %{state: state, entered_at: now, age_s: 0}}
    end)
  end

  def resolve_for_render(nil, %DateTime{} = now), do: resolve_at(new(), now)

  @doc """
  This agent's state, defaulting to `:idle`.

  Accepts either the struct or an already-resolved map so a render can
  take whichever it holds.
  """
  @spec for_agent(t() | %{binary() => state()} | nil, binary() | nil) :: state()
  def for_agent(nil, _agent_id), do: :idle
  def for_agent(_activity, agent_id) when not is_binary(agent_id), do: :idle

  def for_agent(%__MODULE__{} = activity, agent_id) do
    Enum.find_value(@precedence, :idle, fn signal ->
      if Map.has_key?(Map.fetch!(activity, signal), agent_id), do: signal
    end)
  end

  def for_agent(map, agent_id) when is_map(map), do: Map.get(map, agent_id, :idle)

  # ── Pushed state ───────────────────────────────────────────────────────────

  @doc """
  Record `state` as `agent_id`'s self-declared activity in `meeting_id`.

  Accepts `:thinking` and `:composing` only (`pushed_states/0`); anything
  else is refused with `{:error, {:unsupported_state, state}}` rather than
  stored, so the set of states a runtime can assert is closed at the door.

  Options:

    * `:reason` — a short note ("summarising the last ten minutes"),
      truncated to `pushed_reason_max_chars/0`. Anything that is not a
      non-blank binary becomes `nil`.
    * `:ttl_ms` — override `pushed_ttl_ms/0` for this row. A row carries
      the ttl it was pushed with, so changing the config does not
      retroactively lengthen or shorten a claim already made.
    * `:now` — the `DateTime` to stamp, for tests.

  ## Refreshing is a restamp, deliberately

  Pushing again — same state or a different one — replaces the row and
  restarts the ttl. That is the exact opposite of `put_at/5`'s no-restamp
  rule, and for the exact opposite reason. The 120-second ceiling exists to
  catch a producer that has gone silent, so it must survive one that has
  not, and restamping would defeat it. Here, going silent is what the ttl
  is FOR: the whole safety argument is that a crashed agent stops
  refreshing and lapses. A heartbeat that could not extend its own claim
  would not be a heartbeat.

  Returns `{:error, :store_unavailable}` if the table does not exist (a
  push during early boot, before `init/1` ran). Refusing is right rather
  than degrading quietly: a runtime that believes it declared `:thinking`
  and did not would be told nothing while the meeting showed it idle.
  """
  @spec push(binary(), binary(), pushed_state(), keyword()) ::
          {:ok, pushed_entry()} | {:error, term()}
  def push(meeting_id, agent_id, state, opts \\ [])

  def push(meeting_id, agent_id, state, opts)
      when is_binary(meeting_id) and is_binary(agent_id) and state in @pushed_states and
             is_list(opts) do
    entry = %{
      state: state,
      reason: normalize_reason(Keyword.get(opts, :reason)),
      pushed_at: Keyword.get(opts, :now) || DateTime.utc_now(),
      ttl_ms: normalize_ttl(Keyword.get(opts, :ttl_ms))
    }

    if pushed_table?() do
      :ets.insert(@pushed_table, {{meeting_id, agent_id}, entry})
      {:ok, entry}
    else
      {:error, :store_unavailable}
    end
  end

  def push(meeting_id, agent_id, state, _opts)
      when is_binary(meeting_id) and is_binary(agent_id),
      do: {:error, {:unsupported_state, state}}

  def push(_meeting_id, _agent_id, _state, _opts), do: {:error, :invalid_key}

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @pushed_reason_max_chars)
    end
  end

  defp normalize_reason(_reason), do: nil

  defp normalize_ttl(ms) when is_integer(ms) and ms > 0, do: ms
  defp normalize_ttl(_ms), do: pushed_ttl_ms()

  @doc """
  `agent_id`'s live pushed state in `meeting_id`, or `nil`.

  **This is the read-path expiry.** A row whose age has reached its own
  `ttl_ms` returns `nil` — the same answer as a row that was never written
  — whether or not the sweep has run since it lapsed. The sweep only
  reclaims the space; it is not what makes a lapsed state stop reading as
  live, and deleting this check would leave a `:thinking` that a crashed
  runtime pushed reading as live until the next sweep and then, if the
  sweep were also removed or delayed, forever.

  `now` defaults to `DateTime.utc_now/0` and is explicit so the expiry is
  provable without a clock or a sleep.
  """
  @spec pushed(binary(), binary(), DateTime.t()) :: pushed_entry() | nil
  def pushed(meeting_id, agent_id, now \\ DateTime.utc_now())

  def pushed(meeting_id, agent_id, %DateTime{} = now)
      when is_binary(meeting_id) and is_binary(agent_id) do
    if pushed_table?() do
      case :ets.lookup(@pushed_table, {meeting_id, agent_id}) do
        [{_key, entry}] -> if live?(entry, now), do: entry, else: nil
        _ -> nil
      end
    else
      nil
    end
  end

  def pushed(_meeting_id, _agent_id, _now), do: nil

  @doc """
  Every LIVE pushed state in `meeting_id`, as `%{agent_id => entry}`.

  Lapsed rows are filtered by the same `live?/2` check `pushed/3` applies,
  so a meeting-wide read cannot disagree with a per-agent one.
  """
  @spec pushed_all(binary(), DateTime.t()) :: %{binary() => pushed_entry()}
  def pushed_all(meeting_id, now \\ DateTime.utc_now())

  def pushed_all(meeting_id, %DateTime{} = now) when is_binary(meeting_id) do
    if pushed_table?() do
      @pushed_table
      |> :ets.match_object({{meeting_id, :_}, :_})
      |> Enum.filter(fn {_key, entry} -> live?(entry, now) end)
      |> Map.new(fn {{_meeting_id, agent_id}, entry} -> {agent_id, entry} end)
    else
      %{}
    end
  end

  def pushed_all(_meeting_id, _now), do: %{}

  @doc """
  Drop `agent_id`'s pushed state in `meeting_id`.

  For a runtime that finishes early and wants to say so rather than wait
  out its ttl. It is a convenience and nothing depends on it being called —
  that is the whole point of the ttl.
  """
  @spec clear_pushed(binary(), binary()) :: :ok
  def clear_pushed(meeting_id, agent_id) when is_binary(meeting_id) and is_binary(agent_id) do
    if pushed_table?(), do: :ets.delete(@pushed_table, {meeting_id, agent_id})
    :ok
  end

  def clear_pushed(_meeting_id, _agent_id), do: :ok

  @doc """
  Delete every row that has lapsed as of `now`. Returns how many went.

  The second half of "expires on read AND sweep". Reads are already correct
  without this; what it adds is that the table cannot grow without bound
  from meetings that ended while an agent was mid-declaration, and that a
  lapsed row does not sit there being re-checked for the life of the node.

  Public and `now`-taking so a test drives it directly instead of waiting
  `pushed_sweep_interval_ms/0`.
  """
  @spec sweep_pushed(DateTime.t()) :: non_neg_integer()
  def sweep_pushed(%DateTime{} = now) do
    if pushed_table?() do
      expired =
        :ets.foldl(
          fn {key, entry}, acc -> if live?(entry, now), do: acc, else: [key | acc] end,
          [],
          @pushed_table
        )

      Enum.each(expired, &:ets.delete(@pushed_table, &1))
      length(expired)
    else
      0
    end
  end

  # THE expiry predicate, shared by every read and by the sweep so the two
  # can never disagree about whether a given row is still live.
  #
  # `>=` rather than `>`: at exactly `ttl_ms` the claim has been held for
  # its full stated life and is done. A `now` that predates the stamp
  # yields a negative diff and reads as live, which is the same direction
  # `resolve_at/2` takes on skew.
  defp live?(%{pushed_at: pushed_at, ttl_ms: ttl_ms}, now) do
    DateTime.diff(now, pushed_at, :millisecond) < ttl_ms
  end

  defp live?(_entry, _now), do: false

  # A read or push before `init/1` installed the table degrades rather than
  # crashing the caller — the guard `PressWindow` and `VoiceSeatCache` use.
  defp pushed_table?, do: :ets.info(@pushed_table) != :undefined

  # ── `:speaking` ────────────────────────────────────────────────────────────

  @doc """
  Record that core has just dispatched `utterance_id`'s audio for
  `agent_id` in `meeting_id`.

  Called from `Platform.Meetings.SpeakingWindow.dispatched/4`, which is the
  one-line call site inside `Platform.Meetings.say/4`, immediately after
  the `meeting_say` frame goes out. That is what makes `:speaking` core's
  own observation rather than a report: core is the thing that sent the
  audio, and it stamps the state at the moment it sent it.

  Options:

    * `:char_count` — how many characters were dispatched; drives the ttl
      through `speaking_ttl_ms/1`.
    * `:ttl_ms` — override that, for tests.
    * `:now` — the `DateTime` to stamp, for tests.

  ## The utterance id is stored, and that is what makes overlap safe

  A row remembers WHICH utterance it is for. `clear_speaking/3` only
  deletes a row whose `utterance_id` matches, so if a second say is
  dispatched while a first is still playing, the late ack for the first one
  finds the second one's id in the row and leaves it standing. Without
  that, an agent still mid-sentence would go quiet on screen because an
  earlier utterance finally reported in — an UNDER-report, and this state
  exists for the person deciding whether to start talking.

  Returns `{:error, :store_unavailable}` if the table does not exist, for
  the same reason `push/4` does.
  """
  @spec mark_speaking(binary(), binary(), binary(), keyword()) ::
          {:ok, speaking_entry()} | {:error, term()}
  def mark_speaking(meeting_id, agent_id, utterance_id, opts \\ [])

  def mark_speaking(meeting_id, agent_id, utterance_id, opts)
      when is_binary(meeting_id) and is_binary(agent_id) and is_binary(utterance_id) and
             is_list(opts) do
    entry = %{
      state: :speaking,
      utterance_id: utterance_id,
      started_at: Keyword.get(opts, :now) || DateTime.utc_now(),
      ttl_ms: normalize_speaking_ttl(Keyword.get(opts, :ttl_ms), Keyword.get(opts, :char_count))
    }

    if speaking_table?() do
      :ets.insert(@speaking_table, {{meeting_id, agent_id}, entry})
      {:ok, entry}
    else
      {:error, :store_unavailable}
    end
  end

  def mark_speaking(_meeting_id, _agent_id, _utterance_id, _opts), do: {:error, :invalid_key}

  defp normalize_speaking_ttl(ms, _char_count) when is_integer(ms) and ms > 0, do: ms
  defp normalize_speaking_ttl(_ms, char_count), do: speaking_ttl_ms(char_count || 0)

  @doc """
  Clear `agent_id`'s `:speaking` in `meeting_id`, but only if the live row
  is the one for `utterance_id`.

  **This is the half a test has to pin.** A `:speaking` that is only ever
  set is an agent pinned as permanently talking — the `:listening` failure
  in a new costume, and the exact shape the ttl below is a backstop for
  rather than a substitute for. The ack is what normally ends the state;
  the ttl is what covers an ack that never comes.

  The id check is described in `mark_speaking/4`. A row for a DIFFERENT
  utterance is left exactly as it is, and so is a row that has already
  lapsed (deleting it is the sweep's job, and it reads as absent either
  way).
  """
  @spec clear_speaking(binary(), binary(), binary()) :: :ok
  def clear_speaking(meeting_id, agent_id, utterance_id)
      when is_binary(meeting_id) and is_binary(agent_id) and is_binary(utterance_id) do
    if speaking_table?() do
      case :ets.lookup(@speaking_table, {meeting_id, agent_id}) do
        [{key, %{utterance_id: ^utterance_id}}] -> :ets.delete(@speaking_table, key)
        _ -> :ok
      end
    end

    :ok
  end

  def clear_speaking(_meeting_id, _agent_id, _utterance_id), do: :ok

  @doc """
  `agent_id`'s live `:speaking` row in `meeting_id`, or `nil`.

  Read-path expiry, identical in shape to `pushed/3`: a row past its own
  `ttl_ms` answers `nil` whether or not the sweep has run.
  """
  @spec speaking(binary(), binary(), DateTime.t()) :: speaking_entry() | nil
  def speaking(meeting_id, agent_id, now \\ DateTime.utc_now())

  def speaking(meeting_id, agent_id, %DateTime{} = now)
      when is_binary(meeting_id) and is_binary(agent_id) do
    if speaking_table?() do
      case :ets.lookup(@speaking_table, {meeting_id, agent_id}) do
        [{_key, entry}] -> if speaking_live?(entry, now), do: entry, else: nil
        _ -> nil
      end
    else
      nil
    end
  end

  def speaking(_meeting_id, _agent_id, _now), do: nil

  @doc "Every LIVE `:speaking` row in `meeting_id`, as `%{agent_id => entry}`."
  @spec speaking_all(binary(), DateTime.t()) :: %{binary() => speaking_entry()}
  def speaking_all(meeting_id, now \\ DateTime.utc_now())

  def speaking_all(meeting_id, %DateTime{} = now) when is_binary(meeting_id) do
    if speaking_table?() do
      @speaking_table
      |> :ets.match_object({{meeting_id, :_}, :_})
      |> Enum.filter(fn {_key, entry} -> speaking_live?(entry, now) end)
      |> Map.new(fn {{_meeting_id, agent_id}, entry} -> {agent_id, entry} end)
    else
      %{}
    end
  end

  def speaking_all(_meeting_id, _now), do: %{}

  @doc """
  Delete every `:speaking` row that has lapsed as of `now`. Returns how
  many went.

  The space-reclaiming half, exactly as `sweep_pushed/1` is for pushed
  rows: reads are already correct without it.
  """
  @spec sweep_speaking(DateTime.t()) :: non_neg_integer()
  def sweep_speaking(%DateTime{} = now) do
    if speaking_table?() do
      expired =
        :ets.foldl(
          fn {key, entry}, acc ->
            if speaking_live?(entry, now), do: acc, else: [key | acc]
          end,
          [],
          @speaking_table
        )

      Enum.each(expired, &:ets.delete(@speaking_table, &1))
      length(expired)
    else
      0
    end
  end

  defp speaking_live?(%{started_at: started_at, ttl_ms: ttl_ms}, now) do
    DateTime.diff(now, started_at, :millisecond) < ttl_ms
  end

  defp speaking_live?(_entry, _now), do: false

  defp speaking_table?, do: :ets.info(@speaking_table) != :undefined

  # ── `:delayed` ─────────────────────────────────────────────────────────────

  @doc """
  Turn `%{agent_id => facts}` into `%{agent_id => Delayed.t()}`, dropping
  every agent with nothing specific to say.

  THE place "no reason means no `:delayed`" is decided. An agent whose
  facts yield no specific cause is simply absent from the result, so a
  caller cannot end up holding a `:delayed` it has no reason for — there is
  no key to hold. `Delayed.from_facts/1` does the per-agent half; this is
  the map-shaped one the render loop wants.

  Pure. `facts` is `Platform.Meetings.AgentDelayReason.facts()`; gathering
  them costs a DB read and a presence check per agent, which is why that
  cost is the caller's to decide and not this module's.
  """
  @spec delays_from_facts(%{binary() => map()}) :: %{binary() => Delayed.t()}
  def delays_from_facts(facts_by_agent) when is_map(facts_by_agent) do
    Enum.reduce(facts_by_agent, %{}, fn {agent_id, facts}, acc ->
      case Delayed.from_facts(facts) do
        {:ok, delayed} when is_binary(agent_id) -> Map.put(acc, agent_id, delayed)
        _ -> acc
      end
    end)
  end

  def delays_from_facts(_facts_by_agent), do: %{}

  @doc """
  The same value with every `:heard` stamp dropped (task 01a07400 stage 3).

  Pure, and a struct rewrite rather than a new reader: `resolve_at/2` and
  `resolve_at/3` are unchanged, so nothing that resolves today resolves
  differently. Feeding them this value simply asks the question they
  already answer with the `:heard` overlay taken out of the input.

  ## Why a render surface needs it

  `resolve_at/2` OVERWRITES an agent's entry with `:heard` for two seconds,
  so the state underneath is not recoverable from its output. Saru's
  direction (canvas `01a07402-99e3`) rules that a heard flash must **not**
  swap the state word — "a rail of four agents would strobe through
  Heard/Idle/Heard and become unreadable exactly when the room is
  busiest" — so `PlatformWeb.Components.Meetings.ParticipantRail` needs
  BOTH readings at once: the heard-inclusive one to paint the ring, and
  this one to choose the word.

  Resolving twice is the deliberate cost. The alternative — making
  `resolve_at/2` carry the displaced state along inside the entry — would
  change the shape every existing reader and test matches on
  (`%{state: :heard}`), to serve one surface's layout. This keeps the
  overlay exactly as `01a06e07` shipped it and lets the caller ask the
  question a second way.

  It does NOT relax the decay. A stamp older than `heard_decay_seconds/0`
  is already invisible to `resolve_at/2`; this drops the live ones too, for
  a reader that has separately established there is a flash to draw.
  """
  @spec without_heard(t()) :: t()
  def without_heard(%__MODULE__{} = activity), do: %__MODULE__{activity | heard: %{}}

  @doc """
  Overlay `:delayed` onto an already-resolved map.

  `resolved` is `resolve_at/2` or `resolve_at/3`'s output; `delays` is
  `%{agent_id => Delayed.t()}`, normally from `delays_from_facts/1`. An
  agent that is in `delayable_states/0` and has a delay becomes
  `%{state: :delayed, reason: …}`, keeping the `entered_at` and `age_s` of
  the state it was in — the delay explains that work, it does not restart
  its clock.

  ## Two things it refuses, and both are the point

  **A `:delayed` with no reason.** The value must pass
  `Delayed.valid?/1`. `@enforce_keys` already stops `%Delayed{}` compiling
  and `struct!/2` at runtime, but `struct(Delayed, %{})` produces
  `%Delayed{reason: nil}` and would otherwise sail through to the screen as
  a spinner that says nothing. Anything that is not a valid `Delayed` —
  including the bare atom `:delayed`, a string, or `nil` — is dropped, and
  the agent keeps the state it had.

  **Delaying a state that is not working.** `:idle` is not blocked, it is
  idle. `:failed` already said something went wrong and must not be
  softened into "waiting for" something. `:heard` is a two-second receipt.
  `:speaking` is audio going out right now, which cannot simultaneously be
  stuck. Only `delayable_states/0` are qualified.

  Applied AFTER resolution rather than as a layer inside it, deliberately.
  `:delayed` is not a competing claim about what the agent is doing — the
  agent is still computing, or still thinking. It is a qualification of
  that claim with the cause, so it needs the resolved answer to qualify.
  """
  @spec apply_delays(%{binary() => resolved()}, %{binary() => Delayed.t()}) ::
          %{binary() => resolved()}
  def apply_delays(resolved, delays) when is_map(resolved) and is_map(delays) do
    Enum.reduce(delays, resolved, fn {agent_id, delayed}, acc ->
      case Map.fetch(acc, agent_id) do
        {:ok, %{state: state} = entry} ->
          if state in @delayable_states and Delayed.valid?(delayed) do
            Map.put(acc, agent_id, Map.merge(entry, %{state: :delayed, reason: delayed.reason}))
          else
            acc
          end

        :error ->
          acc
      end
    end)
  end

  def apply_delays(resolved, _delays) when is_map(resolved), do: resolved

  # ── Publishing ─────────────────────────────────────────────────────────────

  @doc """
  Mirror an intent row's in-flight-ness onto the meeting SHELL topic.

  Called from `Platform.Meetings.IntentQueue.Server`'s single status
  write path, so there is exactly one publisher per transition. The
  shell topic (`meeting:<id>`) is used rather than
  `meeting:<id>:intents` because **guests subscribe to the shell topic
  and not to the intents topic** — an agent tile that only lit up for
  authenticated viewers would be a second half-truth.

  A row with no `target_agent_id` is not about any one agent and is
  silently ignored.
  """
  @spec mirror_intent_row(binary(), map()) :: :ok
  def mirror_intent_row(meeting_id, %{target_agent_id: agent_id} = row)
      when is_binary(meeting_id) and is_binary(agent_id) do
    status = Map.get(row, :status)

    broadcast(meeting_id, :computing, agent_id, status in IntentQueue.in_flight_statuses())

    # A failure terminal is BROADCAST, not merely un-broadcast.
    #
    # Before this line, `:timed_out` and `:completed` were the same
    # event on this topic: both fall outside `in_flight_statuses/0`, so
    # both cleared `:computing` and the avatar went quietly back to
    # idle. An agent that never answered and an agent that finished the
    # job were indistinguishable on screen — the exact class of defect
    # task 01a0554f removed from the invite control, in a second place.
    #
    # This is a REAL terminal transition, which is what makes it
    # legitimate. This module's own moduledoc refuses to invent a
    # terminal state the queue never reached ("a worse lie than a stale
    # one"), and that still holds: nothing here fires on a timer or on
    # an elapsed-time guess. The queue says `:timed_out`; the dock
    # repeats it.
    #
    # Ordering matters. `:computing` is cleared FIRST so a consumer that
    # applies both in arrival order never briefly holds an agent as
    # both failed and computing.
    if status in IntentQueue.failure_statuses() do
      broadcast(meeting_id, :failed, agent_id, true)
    else
      :ok
    end
  end

  def mirror_intent_row(_meeting_id, _row), do: :ok

  @doc """
  Publish `{:agent_activity, %{meeting_id, agent_id, signal, active?}}`
  on the meeting shell topic.

  The payload is the RAW signal, not the resolved state, because
  resolution needs both signals at once and only the consumer holds
  both.
  """
  @spec broadcast(binary(), signal(), binary(), boolean()) :: :ok
  def broadcast(meeting_id, signal, agent_id, active?)
      when is_binary(meeting_id) and signal in @signals and is_binary(agent_id) and
             is_boolean(active?) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      MeetingsPubSub.meeting_topic(meeting_id),
      {:agent_activity,
       %{meeting_id: meeting_id, agent_id: agent_id, signal: signal, active?: active?}}
    )
  end

  # ── The Chat.Participant <-> Agent bridge ──────────────────────────────────

  @doc """
  Resolve a `Platform.Chat.Participant` id to the `Agents.Agent` id it
  seats, or `nil`.

  `{:agent_typing, …}` carries a chat participant id; every meeting
  surface keys agents by `agents.id` (that is what
  `Meetings.Participant.agent_id` and the tile's `data-agent` are).
  Without this bridge the typing signal arrives addressed to an id no
  meeting surface has ever heard of — which is why the event was
  reaching `MeetingLive` and being dropped by its catch-all.

  Returns `nil` for a human participant, so a human's typing indicator
  can never light an agent tile.
  """
  @spec agent_id_for_chat_participant(binary() | nil) :: binary() | nil
  def agent_id_for_chat_participant(participant_id) when is_binary(participant_id) do
    # `Platform.UUID.valid?/1`, not a bare `is_binary`: this id arrives on a
    # PubSub payload rather than out of a query, `Repo.get/2` RAISES
    # `Ecto.Query.CastError` on a malformed one, and the raise would land
    # inside a `handle_info` and take the whole MeetingLive down. `nil` — "no
    # agent behind that id" — is already the honest answer for every other
    # miss on this path.
    if Platform.UUID.valid?(participant_id) do
      lookup_agent_id(participant_id)
    else
      nil
    end
  end

  def agent_id_for_chat_participant(_), do: nil

  defp lookup_agent_id(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{participant_type: "agent", participant_id: agent_id}
      when is_binary(agent_id) ->
        agent_id

      _ ->
        nil
    end
  end
end
