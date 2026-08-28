defmodule Platform.Meetings.IntentClassifier do
  @moduledoc """
  GenServer subscriber that reacts to appended transcript segments
  (task 019f2452 stages 3–4 — Meeting Producer runtime).

  Subscribes ONCE to the canonical
  `Platform.Meetings.PubSub.subscribe_transcript_chunk/0` topic —
  Phoenix.PubSub has no wildcard match and the classifier is a single
  process per node fielding every room's traffic, mirroring the design
  the M6 responsibility router uses for `meeting:finished`.

  ## Utterance debounce (same-speaker merge)

  Upstream, `meeting-transcriber` emits one FINAL per Silero-VAD
  delimited utterance and `Meetings.append_segment/2` broadcasts one
  `transcript_chunk` per segment. Those boundaries are BREATH
  delimited, not thought delimited — roughly half of real chunks are
  partial clauses (`"I just put together a file"` /
  `"in the past 30 minutes."` arrived as two chunks and classified
  separately, both wrong).

  So an arriving chunk is HELD for `debounce_ms` instead of
  classifying immediately. Another chunk from the SAME speaker inside
  that window is concatenated onto the held one and the timer
  restarts; the merged text classifies ONCE, on the boundary:

    * **quiet timeout** — `debounce_ms` elapses with no follow-up;
    * **speaker change** — a different speaker's chunk arrives, which
      is itself an utterance boundary, so the held turn flushes
      immediately and the new speaker starts their own hold;
    * **max hold** — `max_hold_ms` since the first held fragment, so a
      monologue cannot postpone classification indefinitely;
    * **`:meeting_finished` / process termination** — see below.

  The hold is keyed on ARRIVAL time (`System.monotonic_time/1`), NOT
  on `start_time` / `end_time`: both are currently hardcoded `0`
  upstream (`MeetingAgentController.normalize_segment/1`,
  `LivekitWebhookController`), so segment time carries no information.
  Nothing here reads them — if they later become real, the boundary
  rules can consult them without restructuring.

  A held chunk that never classifies is silent data loss, which would
  be strictly worse than the noise this removes. So the hold is
  flushed — classified, not dropped — on `:meeting_finished` for the
  room and in `terminate/2` for every room (the process traps exits so
  `terminate/2` actually runs on a supervised shutdown).

  Setting `debounce_ms` to `0` disables holding entirely: every chunk
  delivers synchronously inside `handle_info/2`, which is the shape
  `config/test.exs` pins so timing-sensitive tests stay deterministic.

  ## Guard chain

  Every DELIVERED chunk (post-merge) walks the guards in order:

    1. **No assignee** — `Platform.Roles.assignee_for("meetings.intent_classify")`
       returns `nil`. Log at `:info` the FIRST time we see a room
       without an assignee (subsequent chunks for that room stay
       silent — the `state.seen_rooms` MapSet is the spam-suppressor).
       Emit telemetry with `%{reason: :no_assignee}`. Assignment IS
       the enable signal — no env-var double-gate.
    2. **Meeting muted** — `Platform.Meetings.intent_muted?/1` on the
       payload's `meeting_id` (task 019fbaac stage 2). Emits the SAME
       `:skipped` event as guard 1 with `%{reason: :muted}`. No prompt
       render, no provider call, no queue write.
    3. **No content** — `content_bearing?/1` (a pure function, see its
       own docs) rejects backchannels, bare fragments and single
       address terms BEFORE a model call is spent. Emits
       `%{reason: :no_content}` — a distinct atom, deliberately not
       folded into `:no_assignee` or `:muted`, because "nobody is
       listening", "a human said hold" and "nothing was said" are
       different facts about a meeting and the telemetry stream is how
       they get told apart.
    4. **Assignee found, meeting live, chunk has content** — hand off
       to `classify_and_enqueue/4`.

  ## Why mute sits ABOVE the content gate

  Guards 2 and 3 answer different questions and the mute answer wins.
  `:muted` is a human saying "hold this meeting"; `:no_content` is a
  heuristic saying "this utterance is not worth a model call". A muted
  meeting must skip EVERY chunk, substantive ones included, so the
  explicit instruction has to short-circuit before any heuristic can
  reclassify the skip under a different reason. It is also the cheaper
  test — one indexed context read versus tokenising and scanning the
  utterance — so nothing is paid to reach the answer that was already
  decided.

  Merge runs BEFORE the gate. That ordering is load bearing: several
  fragments the gate would reject on their own (`"and assign them."`,
  `"with the back end."`) are legitimate halves of a sentence that
  survives once merged.

  ## Why mute gates HERE and not at the dispatcher

  The requirement is a meeting without agents diving in to assume our
  intent. Gating at the classifier means a muted meeting costs no model
  call and writes no row — nothing lands in the intent rail or in the
  corrections corpus for a meeting nobody will action. Gating at
  `IntentDispatcher.dispatch_row/3` instead would keep classifying and
  keep filling the queue with rows the producer never asked for; that
  is a dry-run preview, not a mute.

  The lookup is one indexed primary-key read per chunk, on a path that
  already does a `Roles.assignee_for/1` and a `Repo.get(Agent, …)` per
  chunk. It is deliberately NOT cached or memoised per room: a stale
  cache is a mute that does not take effect mid-meeting, which is the
  one property the toggle exists to provide.

  `push_chunk_into_buffer/3` stays ABOVE every guard, mute included, so
  the context window keeps filling while muted — an unmute at minute 20
  classifies against real prior context instead of `(no prior context)`.

  ## Stage 4 pipeline (`classify_and_enqueue/3`)

  Runs the real classifier once the guard chain passes:

    1. Render the `"meetings.intent_classify.v1"` prompt template via
       `Platform.Orchestration.PromptTemplates.render_template/2`.
       If the template row is missing (upstream task
       `019f2451-b627-…` has not shipped), fall through to the
       module-attribute `@fallback_intent_prompt` — logged at
       `:warning` on the FIRST fallback per boot only and emitted as
       telemetry `[:platform, :meetings, :intent_classifier, :template_fallback]`.
    2. Call the LLM via the injected `state.provider_module` (default
       `Platform.Agents.Providers.Ollama`). THREE distinct failure
       names come out of the pipeline, and they must stay mutually
       exclusive — conflating them is exactly how the token-budget
       bug hid for weeks as a "flaky classifier" (task 01a03fb8):

         * `model_error` — the call itself failed (HTTP 500s,
           timeouts, connection refused, a raise/throw), OR the
           provider handed back a map the classifier does not
           recognise at all: no binary `content` key
           (`{:unexpected_shape, _}`). Emits
           `[:platform, :meetings, :intent_classifier, :model_error]`.
         * `truncated_output` — the call SUCCEEDED and returned no
           usable text: `content` is `""` or whitespace-only, whether
           or not `finish_reason` is `"length"`. That is the ~2B
           reasoning model spending its whole completion budget on
           `reasoning_content`, i.e. an exhausted TOKEN BUDGET, not a
           flaky model and not malformed JSON. Emits
           `[:platform, :meetings, :intent_classifier, :truncated_output]`
           with `room_id` and `finish_reason` in the metadata.
         * `parse_error` — see step 3: content was NON-EMPTY but not
           usable JSON.

       All three log at `:warning`, drop the chunk, and return `:ok`.
       No crash, no queue write, no restart loop.
    3. `Jason.decode/1` the (non-empty) response content. Bad JSON or
       missing required keys emit
       `[:platform, :meetings, :intent_classifier, :parse_error]`
       and drop the chunk. Empty content never reaches this step — it
       is intercepted as `truncated_output` in step 2, so a starved
       completion can never be mistaken for a malformed one.
    4. Compute a `sha256(intent <> target_role <> chunk_text)`
       dedupe key. That IS the idempotence semantic: two classifier
       passes over the same chunk collapse against the owning queue's
       `dedupe_key -> intent_id` index.
    5. Enqueue via `Platform.Meetings.IntentQueue.enqueue/2` — keyed by
       MEETING, not room (task 019f70b8) — and emit the terminal
       `[:platform, :meetings, :intent_classified]` telemetry event
       with `:inserted | :duplicate | :no_meeting | :queue_unavailable`
       derived from the enqueue return.

  Design choices baked in:

    * Classifier does NOT track dispatched state — the queue owns the
      status enum and the dispatcher drives it.
    * Confidence threshold is NOT enforced here — the dispatcher
      filters. Everything the model emits lands in the queue so
      downstream analytics can compare accepted-vs-dropped rates.
    * `Req` default receive timeout (~15s) is fine; a dropped chunk
      is fine, another arrives seconds later.

  Supervisor-level toggle:

    * `:start_meeting_intent_classifier` — supervisor gate. When
      `false` (default in `config/test.exs`) the classifier isn't
      booted at all. Tests start their own instance per-case for
      DataCase sandbox ownership.
  """

  use GenServer

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"
  @prompt_slug "meetings.intent_classify.v1"

  # The one spelling of "this intent reaches nobody" that the queue
  # carries. `target_role` is hashed into the dedupe key and stored on
  # the row, so it must be a binary; a second spelling would split the
  # dedupe key for identical utterances.
  @no_target_role "null"
  @default_context_window_size 3

  # Quiet window a chunk is held for before it classifies. Sized to sit
  # comfortably above a normal inter-breath gap and well below the
  # point where a producer would notice the intent strip lagging the
  # conversation. Overridable per-instance via `:debounce_ms` or
  # globally via `:intent_classifier_debounce_ms`; `0` disables holding.
  @default_debounce_ms 1_500

  # Ceiling on how long a single merged utterance may accumulate. A
  # speaker who never pauses would otherwise restart the debounce timer
  # forever and never classify.
  @default_max_hold_ms 4_000

  # Few-shot exemplar window (task 019f70b8 stage 6, AC16). Bounded so
  # the prompt cannot grow without limit as an org accumulates
  # corrections; overridable per-instance via the
  # `:correction_exemplar_limit` opt or globally via
  # `:intent_classifier_correction_exemplar_limit`.
  @default_correction_exemplar_limit 10

  # Fallback prompt used when the DB row for @prompt_slug hasn't been
  # seeded yet (upstream task 019f2451-b627 owns seeding). Keeps the
  # runtime unblocked during the rollout gap. Uses the same
  # `{{variable_name}}` mustache markers the DB templates use so the
  # rendering shape is identical.
  #
  # Stage 2 (task 019f474d) adds the `{{context_lines}}` block above the
  # current utterance so the classifier resolves pronouns/subjects
  # against the immediately-preceding chunks. Both `transcript_chunk`
  # (legacy) and `meeting_transcript_chunk` (DB template variable) are
  # rendered from the same value so the fallback matches the DB shape.
  #
  # Task 019f70b8 stage 6 adds `{{correction_exemplars}}` — the org's
  # accumulated few-shot corrections (AC16). It is carried here as well
  # as in the DB template so the fallback and the real prompt keep the
  # same variable set; a marker present in one and absent from the other
  # is how a rollout gap turns into a silently untuned classifier.
  # Task 01a03f57 stage 1 re-frames both this fallback and the DB row:
  # `off_topic` is the STATED DEFAULT, and any non-`off_topic` answer must
  # carry a verbatim `evidence_quote` from the current utterance. A
  # fallback that contradicts the row is how an earlier revision of this
  # work got written from the wrong source — keep the two in agreement.
  @fallback_intent_prompt """
  You are a meeting intent classifier. Given a transcript chunk, classify the intent and identify the target role.

  THE DEFAULT ANSWER IS `off_topic`. MOST MEETING SPEECH IS `off_topic` — that is the expected and correct outcome, not a failure to find something.

  The one question you are answering: is an AGENT being asked to do something? Do NOT ask "is this actionable?". Meetings are full of genuine requests aimed at PEOPLE, and those are `off_topic` for this classifier. Detection and addressing are ONE question.

  All of these are `off_topic`:
    - "Nah, I'm gonna get Harper in here."
    - "Try, can you try that link just to see what happened?"
    - "But I would just say, like, send it to us."
    - "Promote to prod. Yeah, I know, me too. Okay, so let's go."

  Respond ONLY with a JSON object matching this schema:
  {"intent": "<string>", "target_role": "<string>", "confidence": <float 0-1>, "evidence_quote": "<verbatim substring or empty string>"}

  For any non-`off_topic` answer, `evidence_quote` MUST be a verbatim substring of the CURRENT transcript chunk containing the ask. For `off_topic`, it MUST be the empty string `""`. If you cannot copy such a substring, the answer is `off_topic`.

  Room: {{room_id}}

  Prior producer corrections from this org — the meeting producer previously overrode the classifier on these utterances. Treat them as ground truth for this org's vocabulary.

  {{correction_exemplars}}

  Prior conversation context — DO NOT classify these lines; use only to resolve pronouns, subjects, and topical intent for the CURRENT utterance.

  {{context_lines}}

  Speaker: {{speaker}}
  Transcript chunk: {{transcript_chunk}}
  """

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervised shutdown and can
    # flush any held chunk. `:gen_server` intercepts the parent's
    # `{:EXIT, parent, reason}` ahead of `handle_info/2`, so the
    # catch-all clause below cannot swallow a shutdown signal.
    Process.flag(:trap_exit, true)

    :ok = MeetingsPubSub.subscribe_transcript_chunk()
    :ok = MeetingsPubSub.subscribe_meeting_finished()

    Logger.info(
      "[IntentClassifier] started — subscribed to meeting:transcript_chunk + meeting:finished"
    )

    provider_module =
      Keyword.get(opts, :provider_module, Platform.Agents.Providers.Ollama)

    context_window_size =
      Keyword.get(
        opts,
        :context_window_size,
        Application.get_env(
          :platform,
          :intent_classifier_context_window_size,
          @default_context_window_size
        )
      )

    correction_exemplar_limit =
      Keyword.get(
        opts,
        :correction_exemplar_limit,
        Application.get_env(
          :platform,
          :intent_classifier_correction_exemplar_limit,
          @default_correction_exemplar_limit
        )
      )

    debounce_ms =
      Keyword.get(
        opts,
        :debounce_ms,
        Application.get_env(:platform, :intent_classifier_debounce_ms, @default_debounce_ms)
      )

    max_hold_ms =
      Keyword.get(
        opts,
        :max_hold_ms,
        Application.get_env(:platform, :intent_classifier_max_hold_ms, @default_max_hold_ms)
      )

    {:ok,
     %{
       seen_rooms: MapSet.new(),
       provider_module: provider_module,
       recent_chunks: %{},
       context_window_size: context_window_size,
       correction_exemplar_limit: correction_exemplar_limit,
       debounce_ms: debounce_ms,
       max_hold_ms: max_hold_ms,
       pending: %{}
     }}
  end

  @impl GenServer
  def handle_info({:transcript_chunk, payload}, state) when is_map(payload) do
    room_id = Map.get(payload, :room_id)

    cond do
      # Unkeyable: no room means no debounce slot and no context buffer.
      # Delivers straight through, exactly as it did before the debounce
      # landed — a sparse cross-org broadcast must not be swallowed.
      not is_binary(room_id) ->
        {:noreply, deliver_chunk(payload, room_id, state)}

      state.debounce_ms <= 0 ->
        {:noreply, deliver_chunk(payload, room_id, state)}

      true ->
        {:noreply, hold_chunk(state, room_id, payload)}
    end
  end

  # Quiet-timeout boundary. The `ref` match discards timers whose hold
  # was already flushed by a speaker change or a max-hold cutoff — a
  # cancelled `Process.send_after/3` can still have its message in
  # flight.
  def handle_info({:intent_debounce_flush, room_id, ref}, state) do
    case Map.get(state.pending, room_id) do
      %{ref: ^ref} = held -> {:noreply, flush_pending(state, room_id, held)}
      _ -> {:noreply, state}
    end
  end

  # Cleanup: when a meeting finishes, drop the per-room buffer entry so
  # long-running nodes don't accumulate transcript windows for rooms
  # that have shut down. Scoped to the room_id in the payload — other
  # active rooms' buffers are untouched.
  #
  # The held chunk is FLUSHED (classified), not discarded, before the
  # buffer goes: the last thing said in a meeting is exactly the kind
  # of thing that carries an action item, and losing it silently would
  # be a worse bug than the noise the debounce exists to remove.
  def handle_info({:meeting_finished, %{room_id: room_id}}, state)
      when is_binary(room_id) do
    state = flush_room(state, room_id)
    {:noreply, %{state | recent_chunks: Map.delete(state.recent_chunks, room_id)}}
  end

  # Test-only seam: plants a stub fun in the classifier's own process
  # dictionary so the injected `provider_module` (also test-only) can
  # read it. Guarded by a `Mix.env() == :test` check so production
  # builds ignore stray messages of this shape.
  if Mix.env() == :test do
    def handle_info({:__test_plant_stub, from, ref, fun}, state) do
      Process.put(:intent_classifier_stub_fun, fun)
      send(from, {ref, :ok})
      {:noreply, state}
    end
  end

  # Tolerate mis-shaped events without crashing — the transcript-chunk
  # topic is shared with per-room subscribers and future producers may
  # broadcast slightly different payloads.
  def handle_info(_other, state), do: {:noreply, state}

  # Last-chance flush. Node draining, supervisor shutdown, a rolling
  # deploy: whatever the reason, anything still held classifies now.
  @impl GenServer
  def terminate(_reason, state) when is_map(state) do
    state
    |> Map.get(:pending, %{})
    |> Map.keys()
    |> Enum.reduce(state, fn room_id, acc -> flush_room(acc, room_id) end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Debounce / same-speaker merge ─────────────────────────────────────────

  defp hold_chunk(state, room_id, payload) do
    speaker = payload_speaker(payload)

    case Map.get(state.pending, room_id) do
      nil ->
        start_hold(state, room_id, payload, speaker)

      %{speaker: ^speaker} = held ->
        extend_hold(state, room_id, held, payload)

      held ->
        # A different speaker IS an utterance boundary — the held turn
        # is complete, so classify it now instead of waiting out a
        # timer that can only add latency.
        state
        |> flush_pending(room_id, held)
        |> start_hold(room_id, payload, speaker)
    end
  end

  defp start_hold(state, room_id, payload, speaker) do
    ref = make_ref()
    timer = Process.send_after(self(), {:intent_debounce_flush, room_id, ref}, state.debounce_ms)

    held = %{
      # The FIRST fragment's payload carries the merged utterance:
      # meeting_id / transcript_id are turn-invariant, and the segment
      # id names where the utterance BEGAN, which is the stable choice
      # when fragments are folded together.
      payload: payload,
      texts: [payload_text(payload)],
      speaker: speaker,
      ref: ref,
      timer: timer,
      held_since: System.monotonic_time(:millisecond)
    }

    %{state | pending: Map.put(state.pending, room_id, held)}
  end

  defp extend_hold(state, room_id, held, payload) do
    _ = Process.cancel_timer(held.timer)

    held = %{held | texts: held.texts ++ [payload_text(payload)]}
    elapsed = System.monotonic_time(:millisecond) - held.held_since

    if elapsed >= state.max_hold_ms do
      flush_pending(state, room_id, held)
    else
      ref = make_ref()
      wait = min(state.debounce_ms, state.max_hold_ms - elapsed)
      timer = Process.send_after(self(), {:intent_debounce_flush, room_id, ref}, wait)

      %{state | pending: Map.put(state.pending, room_id, %{held | ref: ref, timer: timer})}
    end
  end

  defp flush_room(state, room_id) do
    case Map.get(state.pending, room_id) do
      nil -> state
      held -> flush_pending(state, room_id, held)
    end
  end

  defp flush_pending(state, room_id, held) do
    _ = Process.cancel_timer(held.timer)

    %{state | pending: Map.delete(state.pending, room_id)}
    |> then(&deliver_chunk(merged_payload(held), room_id, &1))
  end

  # Fold the held fragments back into one payload. Fragments are joined
  # with a single space — VAD splits mid-sentence, so the pieces are
  # adjacent clauses, not separate sentences.
  defp merged_payload(%{payload: payload, texts: texts}) do
    merged =
      texts
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    segment = Map.get(payload, :segment) || %{}
    Map.put(payload, :segment, put_segment_text(segment, merged))
  end

  defp put_segment_text(segment, text) when is_map(segment) do
    if Map.has_key?(segment, "text") and not Map.has_key?(segment, :text) do
      Map.put(segment, "text", text)
    else
      Map.put(segment, :text, text)
    end
  end

  # ── Delivery (buffer push + guard chain) ──────────────────────────────────

  # Push into the per-room context buffer BEFORE the guard chain so the
  # window stays warm even when no assignee is set (and even when the
  # content gate rejects the chunk) — the moment a role lands,
  # subsequent chunks classify against real prior context, fragments
  # included, because a fragment is still useful for resolving a
  # pronoun in the NEXT utterance.
  #
  # The merged utterance enters the buffer as exactly ONE entry, which
  # is what keeps the `+1` head semantics below intact: the head is the
  # chunk about to be classified, no matter how many broadcasts it was
  # assembled from.
  defp deliver_chunk(payload, room_id, state) do
    state = push_chunk_into_buffer(state, room_id, payload)

    case Roles.assignee_for(@responsibility_key) do
      nil ->
        note_no_assignee(room_id, state)

      agent ->
        meeting_id = Map.get(payload, :meeting_id)

        # Guard 2 — per-meeting mute (task 019fbaac stage 2). Checked
        # AFTER the assignee guard so an unassigned responsibility still
        # reports `:no_assignee` (the actionable reason) rather than
        # being masked by a mute, and BEFORE the content gate so an
        # explicit human "hold this meeting" always reports `:muted` —
        # a muted meeting skips every chunk, however substantive, and
        # never has that skip relabelled `:no_content`. It is also the
        # cheaper check: one indexed read versus tokenising the
        # utterance. `intent_muted?/1` is total: nil, malformed and
        # unknown ids all answer `false`, which is the correct answer
        # for a chunk whose space has no meeting.
        if Meetings.intent_muted?(meeting_id) do
          note_muted(room_id, meeting_id, state)
        else
          chunk_text = payload_text(payload)

          if content_bearing?(chunk_text) do
            # `state.recent_chunks[room_id]` is stored newest-first with
            # the current chunk at the head; drop 1 removes the current,
            # take N bounds the window at exactly `context_window_size`.
            prior_chunks =
              state.recent_chunks
              |> Map.get(room_id, [])
              |> Enum.drop(1)
              |> Enum.take(state.context_window_size)

            classify_and_enqueue(payload, agent, prior_chunks, state)
            state
          else
            note_no_content(room_id, payload, chunk_text)
            state
          end
        end
    end
  end

  # ── Content gate ──────────────────────────────────────────────────────────

  # An utterance longer than this is ALWAYS classified. The gate's
  # rules below only ever look at short utterances, which is the whole
  # precision bias in one number: a dropped real item is invisible and
  # unrecoverable, a surviving noisy one costs one model call.
  @gate_short_utterance_words 5

  # Tokens that carry no proposition on their own: backchannels,
  # discourse markers, hedges, determiners, address terms. Used two
  # ways — an utterance made ENTIRELY of these is noise at any length,
  # and leading runs of them are stripped before looking for a verb.
  @filler_tokens MapSet.new(~w(
    a ah all alright also an anyway anyways
    basically cool dude er everybody everyone exactly
    folks good gotcha great guys her here hey hi his hm hmm huh
    i i'm im it it's its just k like literally man mhm mm mmhmm my
    nah nice no nope oh ok okay our please really right
    sorry sure team thank thanks that that's the their
    then there these this those totally uh uhm um well whatever
    y'know ya yah yeah yep yes you your yup
  ))

  # Tokens that open a subordinate or coordinate continuation. A SHORT
  # utterance starting with one of these is a clause that got cut off
  # from its head — `"and assign them."`, `"with the back end."` — not
  # a thought anybody can act on. The same words mid-sentence are
  # unremarkable, which is why only the first token is consulted.
  @continuation_starters MapSet.new(~w(
    about after although and at because before but by for from
    however in into nor of on onto or so than that though through
    to unless until when where whereas which while who whom whose with
  ))

  # Verbs and modals that signal something to be DONE. Deliberately
  # EXCLUDES perception and state verbs (see, look, think, know, feel,
  # seem, sound, be) — a four-word perception remark
  # (`"I didn't see this."`, `"Yeah, that looks good."`) is an
  # observation, never an action item, and letting those through was
  # most of the measured noise.
  @action_tokens MapSet.new(~w(
    add assign book build buy call cancel change check close
    configure confirm create cut deploy design do document draft drop
    email enable ensure explore file finish fix follow generate get
    give handle hire implement include invite launch let's lets
    make merge migrate move must need needs open own pay pick ping
    plan post prep prepare publish pull push put refactor release
    remove rename reply research reschedule review revise rewrite run
    schedule send set setup ship should split start stop submit
    summarise summarize swap sync take test track try update upgrade
    upload use validate verify want wants will wire write
  ))

  @doc """
  True when an utterance is worth spending a model call on.

  Pure — no state, no I/O — so the whole gate is testable against a
  transcript corpus without a running classifier.

  Biased hard toward PRECISION over recall. An utterance is dropped
  only when it is cheaply and obviously non-content:

    1. nothing but punctuation or whitespace;
    2. every token is a backchannel / discourse marker / address term
       (`"Yep."`, `"Mm-hmm."`, `"You guys?"`) — at any length;
    3. **more than #{@gate_short_utterance_words} words ⇒ always kept.**
       Every rule past this point applies to short utterances only;
    4. a short utterance opening on a continuation word
       (`"and assign them."`, `"with the back end."`) — a clause
       severed from its head;
    5. a short utterance with no action verb or modal once leading
       discourse markers are stripped (`"Skills."`, `"the problem."`,
       `"Yeah, that looks good."`).

  Anything else is kept, including short imperatives (`"ship it"`),
  because those are exactly the items that must never be lost.

  Note the known, accepted cost of rule 4: a short imperative opening
  on a discourse `"so"` (`"So ship it today."`) is dropped. In the live
  pipeline the same-speaker merge runs FIRST, so such a fragment is
  almost always folded into its neighbour and classified as part of a
  longer utterance well before it reaches this function alone.
  """
  @spec content_bearing?(term()) :: boolean()
  def content_bearing?(text) when is_binary(text) do
    tokens = tokenize(text)
    stripped = Enum.drop_while(tokens, &MapSet.member?(@filler_tokens, &1))

    cond do
      tokens == [] -> false
      Enum.all?(tokens, &MapSet.member?(@filler_tokens, &1)) -> false
      length(tokens) > @gate_short_utterance_words -> true
      continuation_fragment?(tokens, stripped) -> false
      true -> Enum.any?(stripped, &MapSet.member?(@action_tokens, &1))
    end
  end

  def content_bearing?(_), do: false

  defp continuation_fragment?(tokens, stripped) do
    starts_with_continuation?(tokens) or starts_with_continuation?(stripped)
  end

  defp starts_with_continuation?([head | _]), do: MapSet.member?(@continuation_starters, head)
  defp starts_with_continuation?([]), do: false

  # Lowercase, fold curly apostrophes to straight ones (so `didn't` and
  # `didn’t` tokenize identically), then split on anything that is not a
  # letter, digit or apostrophe. Contractions survive as single tokens;
  # hyphenated forms split, which is what makes `mm-hmm` read as two
  # backchannel tokens rather than one unknown word.
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[\x{2018}\x{2019}]/u, "'")
    |> String.replace(~r/[^\p{L}\p{N}']+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.trim(&1, "'"))
    |> Enum.reject(&(&1 == ""))
  end

  # ── Chunk buffer ──────────────────────────────────────────────────────────

  # Prepend the current chunk into `state.recent_chunks[room_id]` and
  # trim to `state.context_window_size + 1`. The +1 is deliberate: the
  # window head is the CURRENT chunk; stage 2 reads the prior context
  # as `Enum.drop(window, 1)`. Storing size+1 keeps a full N-chunk
  # window PLUS the current utterance available in one lookup.
  #
  # Silently no-ops when `room_id` is nil — cross-org broadcasts on the
  # canonical topic occasionally carry sparse payloads; we don't want
  # to grow a `nil` key.
  defp push_chunk_into_buffer(state, nil, _payload), do: state

  defp push_chunk_into_buffer(state, room_id, payload) when is_binary(room_id) do
    segment = Map.get(payload, :segment) || %{}

    entry = %{
      text: segment_text(segment),
      speaker: segment_speaker(segment, payload),
      timestamp_ms:
        Map.get(segment, :timestamp_ms) ||
          Map.get(segment, "timestamp_ms") ||
          Map.get(payload, :timestamp_ms) ||
          Map.get(payload, "timestamp_ms")
    }

    keep = state.context_window_size + 1

    window =
      [entry | Map.get(state.recent_chunks, room_id, [])]
      |> Enum.take(keep)

    %{state | recent_chunks: Map.put(state.recent_chunks, room_id, window)}
  end

  # ── Guard branches ────────────────────────────────────────────────────────

  defp note_no_assignee(room_id, state) do
    {log?, updated_state} =
      if is_binary(room_id) and not MapSet.member?(state.seen_rooms, room_id) do
        {true, %{state | seen_rooms: MapSet.put(state.seen_rooms, room_id)}}
      else
        {false, state}
      end

    if log? do
      Logger.info("[IntentClassifier] no assignee for meetings.intent_classify — room=#{room_id}")
    end

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :skipped],
      %{count: 1},
      %{reason: :no_assignee, room_id: room_id}
    )

    updated_state
  end

  # Mirror of `note_no_assignee/2` for the mute guard. Same
  # spam-suppressor SHAPE — the `state.seen_rooms` MapSet — but keyed
  # `{:muted, room_id}` rather than the bare `room_id` the no-assignee
  # branch uses, so a room that already logged one reason can still log
  # the other. They are different operator-facing facts.
  #
  # Returns the updated state (not `{:noreply, …}`): the guard chain
  # moved out of `handle_info/2` into `deliver_chunk/3` when the
  # debounce landed, and `deliver_chunk/3` is also reached from a
  # timer flush, where there is no `handle_info` return to piggyback on.
  defp note_muted(room_id, meeting_id, state) do
    key = {:muted, room_id}

    {log?, updated_state} =
      if is_binary(room_id) and not MapSet.member?(state.seen_rooms, key) do
        {true, %{state | seen_rooms: MapSet.put(state.seen_rooms, key)}}
      else
        {false, state}
      end

    if log? do
      Logger.info(
        "[IntentClassifier] intent muted for this meeting — room=#{room_id} meeting=#{meeting_id}"
      )
    end

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :skipped],
      %{count: 1},
      %{reason: :muted, room_id: room_id, meeting_id: meeting_id}
    )

    updated_state
  end

  # Distinct reason atom on the SAME `:skipped` event. `:no_content` is
  # not `:no_assignee` and not `:muted` — this module keeps refusal
  # reasons separable so a tuning session can tell "the classifier is
  # off" from "a human muted this meeting" from "the transcript said
  # nothing".
  defp note_no_content(room_id, payload, chunk_text) do
    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :skipped],
      %{count: 1},
      %{
        reason: :no_content,
        room_id: room_id,
        meeting_id: Map.get(payload, :meeting_id),
        chunk_excerpt: excerpt(chunk_text)
      }
    )
  end

  # ── Stage-4 pipeline ──────────────────────────────────────────────────────

  # 3-arity wrapper — retained so pre-stage-2 callers/tests that don't
  # thread prior context still compile. Delegates to /4 with an empty
  # prior-chunks list, producing the same rendered prompt shape as
  # before stage 2 (with `(no prior context)` substituted for the new
  # `{{context_lines}}` marker).
  @doc false
  @spec classify_and_enqueue(map(), map(), map()) :: :ok
  def classify_and_enqueue(payload, agent, state) do
    classify_and_enqueue(payload, agent, [], state)
  end

  # Public for testability — walks the whole prompt → LLM → parse →
  # enqueue path for a single chunk. Never raises; every failure path
  # logs + emits telemetry + returns `:ok`.
  #
  # `prior_chunks` is the sliding window of the previous N transcript
  # chunks for this room, newest-first, EXCLUDING the current chunk.
  # It's a prompt-render input only — it is NOT part of the dedupe key
  # (Rowan's idempotency requirement: same utterance dedupes regardless
  # of surrounding conversation).
  @doc false
  @spec classify_and_enqueue(map(), map(), [map()], map()) :: :ok
  def classify_and_enqueue(payload, agent, prior_chunks, state) do
    room_id = Map.get(payload, :room_id)
    segment = Map.get(payload, :segment) || %{}
    chunk_text = segment_text(segment)

    prompt =
      resolve_prompt(
        payload,
        segment,
        chunk_text,
        room_id,
        prior_chunks,
        correction_exemplars(payload, state)
      )

    decision =
      decide(%{
        provider_module: state.provider_module,
        agent: agent,
        prompt: prompt,
        chunk_text: chunk_text,
        room_id: room_id
      })

    case decision do
      {:ok, %{intent: intent, target_role: target_role, confidence: confidence}} ->
        dedupe_key = build_dedupe_key(intent, target_role, chunk_text)
        chunk_id = Map.get(segment, :id) || Map.get(payload, :transcript_id)
        meeting_id = Map.get(payload, :meeting_id)

        enqueue_result =
          enqueue_meeting_intent(%{
            meeting_id: meeting_id,
            room_id: room_id,
            dedupe_key: dedupe_key,
            intent: intent,
            target_role: target_role,
            confidence: confidence,
            chunk_id: chunk_id,
            chunk_text: chunk_text
          })

        :telemetry.execute(
          [:platform, :meetings, :intent_classified],
          %{count: 1},
          %{
            meeting_id: Map.get(payload, :meeting_id),
            room_id: room_id,
            intent: intent,
            target_role: target_role,
            confidence: confidence,
            dedupe_key: dedupe_key,
            dedupe_key_hit_or_new: enqueue_result
          }
        )

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @typedoc """
  Why a chunk produced no dispatchable intent.

    * `:empty_output`     — the provider answered with nothing usable
      (reasoning-model token budget exhausted).
    * `:model_error`      — the provider call failed, raised, exited, or
      returned an unrecognised shape.
    * `:parse_error`      — the completion was not decodable into the
      classifier's answer shape.
  A positive classification that fails the evidence gate (task 01a03f57)
  is NOT an error shape: it is DEMOTED to a well-formed `off_topic`
  decision and returned as `{:ok, _}`, so it still reaches the queue and
  the corrections corpus. Only the three reasons above end the run
  without a decision. A demoted decision is marked by a non-nil
  `:demoted_from` on the `{:ok, _}` map, naming the intent that was
  downgraded; there is no `{:error, {:demoted, _}}` shape and never was.
  """
  @type decide_error :: :empty_output | :model_error | :parse_error

  @doc """
  Run ONE chunk through provider-call → parse → evidence for a single
  prompt, and RETURN the outcome.

  This is the single classification code path. `classify_and_enqueue/4`
  calls it for its provider + parse step and adds only the dedupe /
  enqueue / telemetry work on top, so an offline harness that calls
  `decide/1` is exercising production behaviour rather than a
  reimplementation of it — a parallel harness-side copy is exactly how a
  JSON-null parse defect once split one population of declines across
  two different verdicts.

  Every failure path still logs and emits the same telemetry it always
  did; the ONLY difference from the in-pipeline behaviour is that the
  reason is returned instead of being collapsed to `:ok`, so a caller
  can count `:parse_error` separately from a genuine decline.
  """
  @spec decide(map()) :: {:ok, map()} | {:error, decide_error()}
  def decide(%{
        provider_module: provider_module,
        agent: agent,
        prompt: prompt,
        chunk_text: chunk_text,
        room_id: room_id
      }) do
    with {:ok, content} <- call_provider(provider_module, agent, prompt, chunk_text, room_id),
         # SINGLE call site for `parse_content`. Task 01a03f57 widened it
         # to /3, threading `chunk_text` through so the evidence gate can
         # check the model's citation against the chunk it classified.
         {:ok, parsed} <- parse_content(content, room_id, chunk_text) do
      {:ok,
       parsed
       |> Map.put_new(:evidence_quote, nil)
       |> Map.put_new(:demoted_from, nil)}
    end
  end

  # ── Per-meeting queue write (task 019f70b8 stage 2) ───────────────────────

  # Excerpt cap for `chunk_excerpt`. 280 chars is enough for the
  # collapse-bar row and the expanded table to show what was actually
  # said without carrying a whole transcript segment into a
  # meeting-lifetime ETS row (and, in stage 6, into a durable
  # correction row).
  @chunk_excerpt_limit 280

  # Write the intent into the per-meeting queue the dispatcher drains
  # and the live-tuning UI renders (`Platform.Meetings.IntentQueue`).
  #
  # As of task 019f70b8 stage 3 this is the ONLY enqueue path — the
  # legacy room-keyed global queue and this function's dual-write
  # partner are both deleted.
  #
  # Returns the classification outcome used as the
  # `dedupe_key_hit_or_new` telemetry tag:
  #
  #   * `:inserted`   — new row
  #   * `:duplicate`  — dedupe_key already had one; nothing written
  #   * `:no_meeting` — the room has no linked `Meeting` row, so there
  #     is no per-meeting queue to write into. Logged, not silently
  #     swallowed: this is a real gap in room↔meeting linkage and it
  #     should be visible in the classifier's telemetry stream.
  #   * `:queue_unavailable` — the queue owner died or could not start.
  defp enqueue_meeting_intent(%{meeting_id: meeting_id} = args) when is_binary(meeting_id) do
    {agent_id, agent_slug} = resolve_target_agent(args.target_role)

    result =
      IntentQueue.enqueue(meeting_id, %{
        room_id: args.room_id,
        dedupe_key: args.dedupe_key,
        classified_intent: args.intent,
        target_role: args.target_role,
        target_agent_id: agent_id,
        target_agent_slug: agent_slug,
        confidence: args.confidence,
        transcript_chunk_id: args.chunk_id,
        chunk_excerpt: excerpt(args.chunk_text)
      })

    case result do
      {:ok, _row} -> :inserted
      {:duplicate, _row} -> :duplicate
      {:error, _reason} -> :queue_unavailable
    end
  rescue
    # A crash here must never take down the classifier's transcript
    # subscription — supervisor not booted in a bare test, server dying
    # mid-call — so every failure degrades to "no row in the strip".
    error ->
      Logger.warning(
        "[IntentClassifier] per-meeting enqueue failed meeting_id=#{meeting_id} " <>
          "error=#{Exception.message(error)}"
      )

      :queue_unavailable
  catch
    :exit, reason ->
      Logger.warning(
        "[IntentClassifier] per-meeting enqueue exited meeting_id=#{meeting_id} " <>
          "reason=#{inspect(reason)}"
      )

      :queue_unavailable
  end

  defp enqueue_meeting_intent(args) do
    Logger.info(
      "[IntentClassifier] classified intent has no meeting_id — no per-meeting queue to " <>
        "write into room=#{inspect(Map.get(args, :room_id))} " <>
        "intent=#{inspect(Map.get(args, :intent))}"
    )

    :no_meeting
  end

  # Resolve `target_role` to the agent currently assigned to it.
  #
  # `Platform.Roles.agent_id_for_role/1` is guarded `when is_binary(role_key)`
  # — an atom role raises FunctionClauseError — so stringify first.
  #
  # Resolution is NON-FATAL by design: an unassigned role still enqueues
  # as `:queued` with a nil target and fails visibly at dispatch as
  # `:dispatch_failed`. Silently dropping the intent would hide exactly
  # the tuning signal this queue exists to surface.
  defp resolve_target_agent(nil), do: {nil, nil}

  defp resolve_target_agent(target_role) do
    case Roles.agent_id_for_role(to_string(target_role)) do
      nil -> {nil, nil}
      agent_id -> {agent_id, agent_slug(agent_id)}
    end
  rescue
    # Off-sandbox lookups (dispatch tasks in DataCase tests) and role
    # rows racing an agent delete both surface here.
    _ -> {nil, nil}
  end

  defp agent_slug(agent_id) do
    case Platform.Repo.get(Platform.Agents.Agent, agent_id) do
      %{slug: slug} -> slug
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp excerpt(nil), do: nil

  defp excerpt(text) when is_binary(text) do
    if String.length(text) > @chunk_excerpt_limit do
      String.slice(text, 0, @chunk_excerpt_limit)
    else
      text
    end
  end

  defp excerpt(other), do: excerpt(to_string(other))

  # ── Prompt resolution ─────────────────────────────────────────────────────

  defp resolve_prompt(payload, segment, chunk_text, room_id, prior_chunks, correction_exemplars) do
    assigns = %{
      # Stage 2: DB template uses `{{meeting_transcript_chunk}}`; keep
      # the legacy `{{transcript_chunk}}` marker rendering the same
      # value so the inline fallback prompt and pre-stage-2 tests still
      # interpolate correctly.
      meeting_transcript_chunk: chunk_text,
      transcript_chunk: chunk_text,
      speaker: segment_speaker(segment, payload),
      room_id: room_id,
      context_lines: format_context_lines(prior_chunks),
      context_present: prior_chunks != [],
      correction_exemplars: correction_exemplars
    }

    case PromptTemplates.render_template(@prompt_slug, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        log_fallback_once(room_id)

        :telemetry.execute(
          [:platform, :meetings, :intent_classifier, :template_fallback],
          %{count: 1},
          %{room_id: room_id, slug: @prompt_slug}
        )

        substitute(@fallback_intent_prompt, assigns)
    end
  end

  defp log_fallback_once(room_id) do
    if Process.get(:intent_classify_fallback_logged) do
      :ok
    else
      Process.put(:intent_classify_fallback_logged, true)

      Logger.warning(
        "[IntentClassifier] prompt template #{@prompt_slug} missing — using inline fallback (room=#{room_id})"
      )
    end
  end

  # Render the prior-N context window as chronological (oldest first)
  # `- [MM:SS] speaker: text` lines. Empty list → the sentinel
  # `(no prior context)` string so the rendered prompt is stable in
  # shape regardless of whether the buffer is warm.
  #
  # Buffer entries arrive newest-first (push_chunk_into_buffer/3
  # prepends); reverse before formatting so the LLM sees the
  # conversation in the direction it happened.
  # ── Few-shot correction exemplars (task 019f70b8 stage 6, AC16) ───────────

  # Fetch this org's most-recent corrections once per chunk and render
  # them for the prompt.
  #
  # Failure is NEVER fatal and never changes the prompt's SHAPE: any
  # error — no meeting_id on the payload, an unresolvable meeting, the
  # corpus query blowing up — degrades to the same
  # `(no prior corrections)` sentinel the empty case produces. A
  # classification must not be dropped because the tuning corpus was
  # briefly unreadable, and a prompt whose variable list changes when
  # the DB hiccups is a prompt nobody can reason about.
  defp correction_exemplars(payload, state) do
    limit = Map.get(state, :correction_exemplar_limit, @default_correction_exemplar_limit)

    payload
    |> Map.get(:meeting_id)
    |> IntentCorrections.exemplars_for_meeting(limit)
    |> format_correction_exemplars()
  rescue
    error ->
      Logger.warning(
        "[IntentClassifier] correction exemplar lookup failed — classifying without them " <>
          "error=#{Exception.message(error)}"
      )

      format_correction_exemplars([])
  end

  # Rendered oldest-first, mirroring `format_context_lines/1`, so the
  # MOST RECENT correction sits closest to the utterance being
  # classified — the strongest position in the prompt, and the one an
  # org's freshest vocabulary shift should occupy.
  defp format_correction_exemplars([]), do: "(no prior corrections)"

  defp format_correction_exemplars(exemplars) when is_list(exemplars) do
    exemplars
    |> Enum.reverse()
    |> Enum.map_join("\n", &format_correction_exemplar/1)
  end

  defp format_correction_exemplar(exemplar) do
    [~s(- utterance: "#{exemplar.transcript_chunk_excerpt || ""}")]
    |> append_line("  classified as: #{exemplar.classified_intent}")
    |> append_line("  producer verdict: #{exemplar.correction} (#{exemplar.reason})")
    |> maybe_append_line(exemplar.corrected_intent, &"  should have been: #{&1}")
    |> maybe_append_line(exemplar.dispatch_outcome, &"  outcome when corrected: #{&1}")
    |> Enum.join("\n")
  end

  defp append_line(lines, line), do: lines ++ [line]

  defp maybe_append_line(lines, nil, _formatter), do: lines
  defp maybe_append_line(lines, value, formatter), do: lines ++ [formatter.(value)]

  defp format_context_lines([]), do: "(no prior context)"

  defp format_context_lines(prior_chunks) when is_list(prior_chunks) do
    prior_chunks
    |> Enum.reverse()
    |> Enum.map_join("\n", fn entry ->
      speaker = to_string(Map.get(entry, :speaker) || "")
      text = to_string(Map.get(entry, :text) || "")
      "- [#{format_timestamp(Map.get(entry, :timestamp_ms))}] #{speaker}: #{text}"
    end)
  end

  defp format_timestamp(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    [minutes, seconds]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  defp format_timestamp(_), do: "??:??"

  # Minimal {{key}} substitution used only for the inline fallback
  # prompt. Same shape as `PromptTemplates.render_template/2` so
  # switching between DB and fallback is transparent to the LLM.
  defp substitute(template, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  # ── Provider call ─────────────────────────────────────────────────────────

  defp call_provider(provider_module, agent, prompt, chunk_text, room_id) do
    messages = [
      %{role: "system", content: prompt},
      %{role: "user", content: chunk_text}
    ]

    opts =
      [
        base_url: Map.get(agent, :base_url),
        model: Map.get(agent, :model),
        temperature: 0.0,
        max_tokens: 1024,
        # The classifier runs against a ~2B reasoning model. Left to its
        # own devices it spends the whole completion budget on
        # `reasoning_content` and returns `content: ""` with
        # `finish_reason: "length"` — a classification that never
        # arrives. llama.cpp honours `chat_template_kwargs` (the Ollama
        # provider's `think: false` is the Ollama-side equivalent and is
        # simply ignored by llama-server); with thinking off the model
        # answers in 17–29 completion tokens.
        chat_template_kwargs: %{"enable_thinking" => false}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    credentials = agent_credentials(agent)

    try do
      case provider_module.chat(credentials, messages, opts) do
        {:ok, result} ->
          case provider_content(result) do
            {:ok, content} ->
              # A SUCCESSFUL call that carried no usable text. Caught
              # HERE and never allowed to reach `parse_content/3`,
              # where `Jason.decode("")` would report it as a
              # `parse_error` and bury the real cause. Whitespace-only
              # counts as empty: a lone "\n" is no more classifiable
              # than "".
              if String.trim(content) == "" do
                emit_truncated_output(room_id, provider_finish_reason(result))
                {:error, :empty_output}
              else
                {:ok, content}
              end

            :error ->
              emit_model_error(room_id, {:unexpected_shape, result})
              {:error, :model_error}
          end

        {:error, reason} ->
          emit_model_error(room_id, reason)
          {:error, :model_error}
      end
    rescue
      exception ->
        emit_model_error(room_id, {:raised, Exception.message(exception)})
        {:error, :model_error}
    catch
      kind, reason ->
        emit_model_error(room_id, {:caught, kind, reason})
        {:error, :model_error}
    end
  end

  # Both provider response shapes — the atom-key map returned by
  # `Platform.Agents.Providers.Ollama.chat/3` and the string-key map a
  # raw OpenAI-compatible payload can produce — carry the completion
  # text under a `content` key. Normalise in ONE place so the
  # empty-output guard cannot be applied to one shape and silently
  # forgotten on the other. Anything without a BINARY `content` is not
  # a recognised shape at all and stays `{:unexpected_shape, _}`.
  defp provider_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp provider_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp provider_content(_), do: :error

  # `finish_reason` is already on the wire (`ollama.ex:72`) but was
  # thrown away by matching only on `:content`. Handle atom keys,
  # string keys, and its complete ABSENCE (test stubs and other
  # providers may omit it) — nil is a legal value, not a crash.
  defp provider_finish_reason(%{finish_reason: reason}), do: reason
  defp provider_finish_reason(%{"finish_reason" => reason}), do: reason
  defp provider_finish_reason(_), do: nil

  # The provider call SUCCEEDED and still handed back nothing usable.
  # This is the reasoning-model TOKEN BUDGET failure, not a flaky
  # classifier and not malformed JSON — the log line says "budget" out
  # loud so a human reading production logs triages it correctly.
  # Control flow is identical to every other failure branch: return
  # `:error`, `classify_and_enqueue/3` drops the chunk, no queue write,
  # no crash, no restart loop. Only the NAME changes.
  defp emit_truncated_output(room_id, finish_reason) do
    Logger.warning(
      "[IntentClassifier] model returned empty content — completion TOKEN BUDGET exhausted " <>
        "before any answer was produced room=#{inspect(room_id)} " <>
        "finish_reason=#{inspect(finish_reason)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :truncated_output],
      %{count: 1},
      %{room_id: room_id, finish_reason: finish_reason}
    )
  end

  defp emit_model_error(room_id, reason) do
    Logger.warning(
      "[IntentClassifier] LLM call failed room=#{inspect(room_id)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :model_error],
      %{count: 1},
      %{room_id: room_id, reason: inspect(reason)}
    )
  end

  # Agents may or may not carry a bearer credential. The Ollama
  # provider only inspects `:api_key` on the credentials map, so we
  # pass an empty map when nothing is set — mirrors the "no auth by
  # default" contract in `Platform.Agents.Providers.Ollama.request_headers/1`.
  defp agent_credentials(agent) do
    case Map.get(agent, :vault_key) do
      key when is_binary(key) and key != "" -> %{api_key: key}
      _ -> %{}
    end
  end

  # ── Response parsing ──────────────────────────────────────────────────────

  # A prompt instruction the runtime does not check is a suggestion.
  # Stage 1 told the model to cite the span it classified on; this is
  # where that citation is ENFORCED. An uncited (or fabricated-cite)
  # positive is DEMOTED to off_topic, never dropped: a dropped chunk
  # emits nothing and is indistinguishable from a model error, while a
  # demoted one still lands in the queue where `IntentRouting` routes
  # it to nobody and the corrections corpus keeps a row to learn from.
  defp parse_content(content, room_id, chunk_text) do
    case Jason.decode(content) do
      {:ok, %{"intent" => intent, "confidence" => confidence} = decoded}
      when is_binary(intent) and is_number(confidence) ->
        case normalise_target_role(decoded) do
          {:ok, target_role} ->
            confidence = confidence * 1.0
            quote_text = Map.get(decoded, "evidence_quote", "")

            case evidence_verdict(intent, quote_text, chunk_text) do
              :ok ->
                {:ok, %{intent: intent, target_role: target_role, confidence: confidence}}

              {:demote, reason} ->
                emit_evidence_missing(room_id, intent, reason)

                # `demoted_from` carries the intent that WAS downgraded.
                # Without it the returned map is byte-identical to a genuine
                # decline, so a caller counting demotions has nothing to
                # count — which is exactly how the eval harness reported a
                # permanent zero while 93 demotions fired on one cassette
                # (task 01a04379). Non-nil iff this decision was demoted.
                {:ok,
                 %{
                   intent: "off_topic",
                   target_role: @no_target_role,
                   confidence: confidence,
                   demoted_from: intent
                 }}
            end

          :invalid ->
            emit_parse_error(room_id, content, {:missing_or_invalid_keys, decoded})
            {:error, :parse_error}
        end

      {:ok, decoded} ->
        emit_parse_error(room_id, content, {:missing_or_invalid_keys, decoded})
        {:error, :parse_error}

      {:error, reason} ->
        emit_parse_error(room_id, content, reason)
        {:error, :parse_error}
    end
  end

  # The prompt's `target_role` enum is CLOSED and its last member is the
  # JSON literal `null` — the answer the model is instructed to give for
  # `off_topic`, which stage 1 made the stated default. An earlier guard
  # read `is_binary(target_role)`, so that instructed answer fell through
  # to the malformed-payload branch: a CORRECT decline enqueued nothing
  # and emitted `:parse_error`. That is precisely the conflated-failure-
  # name trap the module doc warns about — the counter operators read as
  # "the model is emitting garbage" was in fact counting the model
  # getting it right. Worse, it was asymmetric: the stage-2 demotion path
  # writes the STRING "null", which passed the guard, so demoted declines
  # were visible while genuine ones were not.
  #
  # `null` normalises to the same `@no_target_role` string the demotion
  # path already writes, so the queue has ONE spelling of "nobody" and
  # `IntentRouting` lands it `:no_target_role` exactly as its own comment
  # documents. The key must still be PRESENT and, when present, must be a
  # string or `null`: any other shape (number, list, object, absent) is a
  # structurally-invalid payload and still emits `:parse_error`.
  defp normalise_target_role(decoded) do
    case Map.fetch(decoded, "target_role") do
      {:ok, role} when is_binary(role) -> {:ok, role}
      {:ok, nil} -> {:ok, @no_target_role}
      _ -> :invalid
    end
  end

  # off_topic needs no citation — there is nothing to cite.
  defp evidence_verdict("off_topic", _quote_text, _chunk_text), do: :ok

  defp evidence_verdict(_intent, quote_text, chunk_text) when is_binary(quote_text) do
    trimmed = String.trim(quote_text)

    cond do
      trimmed == "" -> {:demote, :blank}
      substring?(chunk_text, trimmed) -> :ok
      true -> {:demote, :not_in_chunk}
    end
  end

  defp evidence_verdict(_intent, _quote_text, _chunk_text), do: {:demote, :blank}

  defp substring?(chunk_text, needle) when is_binary(chunk_text) do
    String.contains?(String.downcase(chunk_text), String.downcase(needle))
  end

  defp substring?(_chunk_text, _needle), do: false

  # DISTINCT from :parse_error / :model_error / :truncated_output on
  # purpose — the module doc is explicit that conflating failure names
  # is how the token-budget bug hid for weeks. Logged at :info because
  # an uncited positive is now an expected, common outcome, not an
  # incident.
  defp emit_evidence_missing(room_id, intent, reason) do
    Logger.info(
      "[IntentClassifier] uncited positive demoted to off_topic room=#{inspect(room_id)} " <>
        "intent=#{inspect(intent)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :evidence_missing],
      %{count: 1},
      %{room_id: room_id, intent: intent, reason: reason}
    )
  end

  defp emit_parse_error(room_id, raw, reason) do
    Logger.warning(
      "[IntentClassifier] classifier response parse failed room=#{inspect(room_id)} " <>
        "reason=#{inspect(reason)} preview=#{preview(raw)}"
    )

    :telemetry.execute(
      [:platform, :meetings, :intent_classifier, :parse_error],
      %{count: 1},
      %{room_id: room_id, raw_content: preview(raw)}
    )
  end

  defp preview(binary) when is_binary(binary), do: String.slice(binary, 0, 200)
  defp preview(other), do: inspect(other)

  # ── Dedupe key ────────────────────────────────────────────────────────────

  defp build_dedupe_key(intent, target_role, chunk_text) do
    :sha256
    |> :crypto.hash([intent, target_role, chunk_text || ""])
    |> Base.encode16(case: :lower)
  end

  # ── Payload accessors ─────────────────────────────────────────────────────

  defp segment_text(segment) when is_map(segment) do
    Map.get(segment, :text) || Map.get(segment, "text") || ""
  end

  defp segment_text(_), do: ""

  defp segment_speaker(segment, payload) when is_map(segment) do
    Map.get(segment, :speaker_name) ||
      Map.get(segment, "speaker_name") ||
      Map.get(segment, :participant_identity) ||
      Map.get(segment, "participant_identity") ||
      Map.get(segment, :speaker) ||
      Map.get(segment, "speaker") ||
      Map.get(payload, :speaker) ||
      Map.get(payload, "speaker") ||
      ""
  end

  defp segment_speaker(_, _), do: ""

  defp payload_text(payload) when is_map(payload) do
    payload
    |> Map.get(:segment)
    |> case do
      segment when is_map(segment) -> segment_text(segment)
      _ -> ""
    end
  end

  defp payload_speaker(payload) when is_map(payload) do
    segment = Map.get(payload, :segment) || %{}
    segment_speaker(segment, payload)
  end
end
