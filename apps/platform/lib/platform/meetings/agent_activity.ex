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
  ratified by Harper 2026-09-03) because every agent in a call is always
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

  ## What this is NOT

  Not a process and not a store. `%AgentActivity{}` is a value a
  consumer (today, `PlatformWeb.MeetingLive`) holds in its own state
  and folds signals into. Two consequences worth naming:

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
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @typedoc "The activity states `PlatformWeb.Components.Meeting.AgentTile` renders."
  @type state :: :idle | :typing | :computing | :failed | :listening | :heard

  @typedoc """
  A raw signal name. `:listening` is absent — it has no producer.
  `:heard` has one (`Platform.Meetings.deliver_transcript_segment/2`) but
  is deliberately excluded from `@precedence` below — see the moduledoc's
  `:heard` section for why its decay lives only in `resolve_at/2`.
  """
  @type signal :: :computing | :typing | :failed | :heard

  @states [:idle, :typing, :computing, :failed, :listening, :heard]
  @signals [:computing, :typing, :failed, :heard]

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

  defstruct computing: %{}, typing: %{}, failed: %{}, heard: %{}

  @typedoc "`agent_id => the DateTime that agent ENTERED this signal`."
  @type stamps :: %{binary() => DateTime.t()}

  @type t :: %__MODULE__{
          computing: stamps(),
          typing: stamps(),
          failed: stamps(),
          heard: stamps()
        }

  @typedoc "One `resolve_at/2` entry: the capped state, plus the clock it was capped from."
  @type resolved :: %{state: state(), entered_at: DateTime.t(), age_s: integer()}

  @doc "The states an agent tile can render."
  @spec states() :: [state()]
  def states, do: @states

  @doc "The signals that actually have a producer."
  @spec signals() :: [signal()]
  def signals, do: @signals

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
  def resolve_at(%__MODULE__{} = activity, %DateTime{} = now) do
    base =
      Enum.reduce(@precedence, %{}, fn signal, acc ->
        activity
        |> Map.fetch!(signal)
        |> Enum.reduce(acc, fn {agent_id, entered_at}, inner ->
          Map.put_new_lazy(inner, agent_id, fn -> resolved(signal, entered_at, now) end)
        end)
      end)

    Enum.reduce(activity.heard, base, fn {agent_id, entered_at}, acc ->
      age_s = DateTime.diff(now, entered_at, :second)

      if age_s < @heard_decay_seconds do
        Map.put(acc, agent_id, %{state: :heard, entered_at: entered_at, age_s: age_s})
      else
        acc
      end
    end)
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
