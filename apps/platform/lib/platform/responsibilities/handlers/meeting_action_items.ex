defmodule Platform.Responsibilities.Handlers.MeetingActionItems do
  @moduledoc """
  `meetings.action_items` responsibility provider (ADR-0041 Meeting Scribe
  bundle stage 3, task 019f2455).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  per-meeting action-items extraction.

  ## Retargeted to fire DURING the meeting (task 019fb90f-36e3 stage 1)

  This key used to fire on `meeting:finished`, alongside
  `meetings.summarize`, off the broadcast
  `PlatformWeb.LivekitWebhookController` emits when a room closes. It
  no longer does. It now fires once per utterance the meeting's cheap
  intent classifier labelled `action_items`, so the action-items canvas
  is written while the meeting is still happening rather than
  reconstructed from a finished transcript.

  The chain is:

      transcript chunk
        -> Platform.Meetings.IntentClassifier   (cheap model: "is this about action items?")
        -> Platform.Meetings.IntentQueue.Server (serial cursor, one row in flight per meeting)
        -> Platform.Meetings.IntentDispatcher   (forks on classified_intent == "action_items")
        -> PubSub "meeting:action_item_intent"  ({:action_item_intent, payload})
        -> Platform.Responsibilities.Router     (event_match "action_item_intent")
        -> this handler

  The classifier stays deliberately dumb: its only job is noticing the
  text is about action items. Every add / update / remove decision is
  made downstream from the utterance and its surrounding context, and
  item identity deliberately does NOT depend on the classifier's
  `dedupe_key`.

  Two consequences of the retarget worth stating so nobody re-derives
  them:

    * The trigger is a GLOBAL topic, not the per-meeting
      `PubSub.intents_topic/1`. `Router.subscribe_event_topics/1`
      subscribes once at boot from the declared topic strings and
      cannot subscribe to a name containing a runtime meeting id.
    * Nothing was removed from the post-meeting path.
      `meetings.summarize` still fires on `meeting:finished`, and the
      opportunistic scribe dispatch
      (`Meetings.maybe_dispatch_scribe_attention/1` -> scribe ->
      `Meetings.on_scribe_canvas_created/2` -> `triage_officer`) is
      gated only on the `meeting_scribe` role being assigned and never
      touched this key. `event_topic_delivery_test.exs` holds that as a
      regression guard.

  ## Spec

    * `key` — `"meetings.action_items"` (deliberately NOT renamed to
      something intent-flavoured: the key is the stable identifier the
      `meeting_scribe` role bundle, the responsibility row, and the
      prompt-template slug all hang off)
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with
      `topic: "meeting:action_item_intent"` and
      `event_match: "action_item_intent"`
    * `scope` — `per_meeting`
    * `context_provided` — `["org_identity", "meeting_intent",
      "transcript_window", "action_items_canvas"]`
    * `output_contract` — a list of canvas operations (see `register/0`)

  ## The prompt body lives in the DB row (task 019fb90f-36e3 stage 3)

  `default_prompt_template` named `meetings.action_items.v1` from the
  day this key was registered, and until stage 3 that row was DORMANT.
  `Router.build_prompt_via_provider/2` uses the provider's messages and
  never renders `default_prompt_template` when the provider exports
  `build_prompt/1` — which this one does — so the live prompt was the
  hardcoded heredoc in `system_prompt/1` and an operator who edited the
  row through the `prompt_template_update` MCP tool observed exactly
  nothing. `build_prompt/1` now renders the row, with
  `@fallback_action_items_prompt` as the rollout fallback, so the two
  halves cannot drift apart again.

  Its body was also written for a key that fired once over a finished
  transcript ("A meeting just ended; you extract concrete action
  items"). `20260731194500_update_action_items_prompt_for_live_meeting`
  force-updates it: `PromptTemplates.seed_defaults/0` is INSERT-only and
  the row has existed since `20260703120200`, so editing the seed file
  would change nothing on any environment that has ever migrated.

  ## The context is live, not retrospective (task 019fb90f-36e3 stage 2)

  `meeting_transcript` — the whole transcript, loaded through
  `ContextProviders` — was the right slot for a key that fired once, at
  meeting end. Firing per utterance made it both the wrong unit and an
  unbounded cost: the model is being asked about ONE thing that was just
  said, and the transcript grows for the length of the meeting, so every
  utterance would pay for the whole of it again. It is replaced by three
  slots that are each bounded by construction:

    * `meeting_intent` — the classified utterance, read straight off the
      broadcast payload. `chunk_excerpt` is the ground truth here;
      `classified_intent` is a cheap fast model's label and
      `speaker` is best-effort (`IntentDispatcher.speaker_for/2`
      recovers it by matching excerpt text against transcript segments,
      newest-first, because the row has no speaker column).
    * `transcript_window` — the last `@transcript_window_size` segments,
      for resolving "that", "she" and "by then".
    * `action_items_canvas` — the current contents of the canvas being
      reconciled, via `Platform.Meetings.ActionItemsCanvas`.

  None of the three refuse. Mid-meeting, a transcript row that does not
  exist yet and a canvas that has not been created yet are the NORMAL
  state at a meeting's first action item; each slot reports its own
  `missing?` and stage 3 owns the single refusal (a blank chunk).

  ## Output handling: the canvas, and the queue row (task 019fb90f-36e3 stage 4)

  Task 019fa56b-c81f stage 3 gave this key its first real landing — it
  posted the extracted items to the meeting's chat space as a markdown
  checklist via `Platform.Meetings.post_action_items_to_space/3`. That
  was the right surface for a key that fired ONCE, at meeting end. Firing
  per utterance makes it the wrong one: that function renders the WHOLE
  list, so a meeting with a dozen action-item utterances would post the
  whole list a dozen times, each superseding the last. It is left in
  place, unchanged, for the post-meeting path.

  `handle_output/3` now reconciles `Platform.Meetings.ActionItemsCanvas`:

    * no canvas + at least one add → `create/3` writes one, with its
      companion canvas message as the single in-chat announcement
    * canvas exists → `apply_operations/2` patches it in place, so the
      canvas the meeting has open updates under them
    * zero operations → nothing written, canvas revision untouched. Most
      utterances change nothing.
    * no canvas + zero adds → no canvas is created. An empty checklist
      appearing in a space because somebody said "we should do something
      about that" is noise.

  And then it CLOSES THE QUEUE ROW, which is the half that is easy to
  forget and expensive to omit. `IntentDispatcher` moved the row to
  `:dispatched`, which pins the meeting's serial cursor to it; nothing
  else closes it except `IntentQueue.Server`'s 90-second claim watchdog.
  A handler that returns without transitioning costs the meeting 90
  seconds of queue and lands a row that reads `:timed_out` when the work
  actually succeeded. `:completed` on a landed write,
  `:dispatch_failed` with a `dispatch_failure_reason` otherwise.

  `handle_output/3` only ever runs when a model answered, so it closes
  the row on every outcome EXCEPT the one where the Router declined to
  dispatch. That gap shipped and was caught by the e2e review: a
  whitespace-only utterance refuses at `build_prompt/1` with
  `:no_intent_text` — correctly, no LLM call, no canvas write — and the
  refusal returns straight up through `Router.dispatch_external/5`,
  never reaching `handle_output/3`. The row stayed `:dispatched` until
  the 90s watchdog released it as `:timed_out`, stalling every intent
  behind it. `handle_refusal/3` is the seam that closes it; see its own
  docs.

  A row that is ALREADY terminal is left alone. Terminal rows are
  retained rather than deleted and `transition/4` does not police
  terminal→terminal, so writing `:completed` over a `:timed_out` row
  would succeed — and erase, from the operator's view, the fact that the
  round trip overran its ack window. The canvas write still stands; the
  row's story is simply already told.

  `extract_items/1` became `extract_operations/1` and returns
  `{:ok, operations} | {:error, reason}` rather than a bare list. The
  distinction is load-bearing: the old function answered `[]` both for
  "the model said nothing was actionable" and for "the model's answer was
  unreadable", and those two now have to land the row on different
  statuses.

  ## Why the string/map fix is here and not in `ContractValidator` (019fa56b-c81f)

  Stage 3's posting code was correct; the key still delivered nothing,
  because nothing ever reached it in the right shape. The root cause is
  one level up: `ContractValidator.classify/1` has no clause for the
  field-map contract shape (`%{"action_items" => "list[string]"}`), so
  it lands on `:unknown`, which is deliberately treated as freeform, so
  `validate/2` returns the raw response STRING.

  Fixing `classify/1` looks like the root fix and is the wrong move.
  EVERY responsibility in the tree declares its contract in that shape —
  `meetings.summarize`, `daily_summary`, `dreaming`, all four
  `security.*`, all four `design.*`, all three `architecture.*`. They
  are all being handed a binary today and the string-typed ones all
  work, because their extractors carry a binary clause. Teaching
  `classify/1` to read a field map as `:json` would route all of them
  through `Jason.decode/1`, and any model that answered a `"string"`
  contract with prose — which is exactly what
  `meetings.summarize` asks for and gets — would stop being a summary
  and start being `{:error, {:contract_violation, :invalid_json}}`. The
  "root fix" would turn a working summariser into a hard failure.

  A softer classifier (try JSON, fall back to the string) avoids that
  but still changes the argument type of every handler in the tree from
  binary to map-when-parseable, and each one would need re-proving. That
  is not this task.

  So the boundary is here: each handler owns the shape it can consume,
  which is the contract `MeetingSummarize` has always honoured. The
  classifier gap is real and worth a follow-up — `propose_long_term`'s
  `extract_proposals/1` has the identical missing binary clause and is
  silently broken the same way — but it is a separate change with a
  blast radius this fix does not need.

  There is deliberately no schema migration: `meeting_transcripts` has a
  `summary` column but no `action_items` column, and the seeded
  `meetings.action_items.v1` prompt promises the model extraction, not
  storage. The space post is the visible delivery; persistence is
  additive later if wanted.

  ## Why there is no `topic_pattern` any more

  The old registration carried `topic_pattern: "meeting:finished:*"`
  alongside its topic. It was always advisory — Phoenix.PubSub has no
  wildcard subscribe and `Router.subscribe_event_topics/1` reads
  `trigger_config["topic"]` only — so it described a subscription that
  never existed. `meeting:action_item_intent` has no per-room mirror at
  all, so the key is simply gone rather than restated with a new
  prefix.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.ActionItemsCanvas
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "meetings.action_items"
  @feature "meetings"
  @prompt_slug "meetings.action_items.v1"

  # How many transcript segments of surrounding context ride along with
  # the classified utterance. Mirrors `IntentClassifier`'s
  # `@default_context_window_size` in kind — a fixed, small tail rather
  # than the whole transcript — but is deliberately larger than the
  # classifier's 3. The classifier only has to decide "is this about
  # action items"; this key has to work out an owner and a deadline that
  # may have been stated a couple of turns earlier.
  @transcript_window_size 8

  # Inline body used when the `meetings.action_items.v1` row is missing —
  # a fresh DB that has not migrated, or one where an operator deleted
  # the row. Mirrors `IntentClassifier`'s fallback and inherits its rule:
  # the `{{marker}}` set here and in the DB body must be IDENTICAL. A
  # marker present in one and absent from the other is how a rollout gap
  # turns into a silently untuned prompt — the model would be handed a
  # section heading with nothing under it, or an assign with nowhere to
  # go, and nothing would fail. `meeting_action_items_test.exs` extracts
  # both sets with the same regex and asserts equality rather than
  # listing the members, so a fifth slot added to one side and not the
  # other is caught mechanically.
  #
  # This is deliberately shorter than the DB body: it is the degraded
  # path, and it carries the load-bearing clauses (excerpt over label,
  # reconcile rather than append, the operations shape, empty-is-valid)
  # rather than the full guidance.
  @fallback_action_items_prompt """
  You are the Meeting Scribe's `meetings.action_items` responsibility, working DURING a live meeting.

  A meeting is happening right now. One thing was just said, a cheap fast model flagged it as being about action items, and your job is to work out what that ONE utterance changes about the meeting's action-items canvas. You are not summarising a meeting and you are not reading a finished transcript.

  # The utterance you are acting on

  {{meeting_intent}}

  Read the excerpt before the label. `classified_intent` is a cheap fast model's guess whose only job was to notice this text might be about action items. The excerpt is the ground truth; where the two disagree, the excerpt wins and returning no operations is the right answer.

  # What was said just before

  {{transcript_window}}

  Context only — use it to resolve "that", "she", and "by then". Do not mine it for action items of its own.

  # The canvas you are reconciling against

  {{action_items_canvas}}

  This is the CURRENT contents of this meeting's action-items canvas. Create it when it is absent; MODIFY it when it is present. Reconcile — mark an item complete when someone says they already did it, amend an owner or a due date when it changes, remove an item that was retracted — rather than appending blindly. An item the utterance does not touch is left exactly as it is.

  # Output

  Return ONLY a single JSON object — no markdown fence, no prose:

      {"operations": [{"op": "add", "label": "<owner> <commitment> (<due when stated>)", "state": "pending"},
                      {"op": "update", "match": "<text of the existing item>", "label": "<new text>", "state": "complete"},
                      {"op": "remove", "match": "<text of the existing item>"}]}

  Match an existing item by quoting enough of its label back in `match` to identify it. `state` is one of `pending`, `active`, `complete`. Invent nothing. `{"operations": []}` is a correct and expected answer — most utterances change nothing.

  # Grounding context

  {{org_identity}}

  Platform context for entity names only. Not meeting content; it contains no action items.
  """

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          # Global topic `Platform.Meetings.IntentDispatcher` publishes
          # on when it claims a row the classifier labelled
          # `action_items`. NOT `meeting:finished` any more, and NOT
          # the per-meeting `PubSub.intents_topic/1` (see moduledoc).
          #
          # No migration is needed to land this change on an existing
          # row: `Platform.Responsibilities.@upsert_replace_fields`
          # includes `trigger_config` and `context_provided`, so
          # re-registration on the next boot rewrites both. (`enabled`
          # is deliberately excluded from that list — operator
          # territory — which is why status lives in `metadata` below.)
          "topic" => "meeting:action_item_intent",
          "event_match" => "action_item_intent"
        },
        scope: "per_meeting",
        # Three live slots replace `meeting_transcript` (task
        # 019fb90f-36e3 stage 2). The key no longer works from "a
        # finished transcript"; it works from ONE classified utterance,
        # the handful of lines around it, and the canvas it is
        # reconciling against.
        #
        # This list is DECLARATIVE ONLY for this key. Nothing validates
        # slot names against a roster: `Responsibility.changeset/2`
        # casts `context_provided` as a bare `{:array, :string}` with no
        # `validate_inclusion`, and the only consumer that resolves the
        # names — `ContextGatherer.gather/2` — is reached exclusively
        # through `Router.gather_context/2`'s fallback arm, which is
        # skipped whenever the provider exports `gather_context/2`.
        # `Providers.Meetings` does export it, so for this key the list
        # is documentation that the module below is obliged to honour by
        # hand, not a contract `lib` enforces.
        #
        # It IS enforced from a TEST, though — the first draft of this
        # comment said no roster existed anywhere and was wrong.
        # `architecture_context_bridge_test.exs` asserts set equality
        # between every provider's declared-but-unresolved slot names
        # and its own `@unresolved_slots` map, so a name added here with
        # no `ContextProviders` clause has to be registered there with a
        # reason. All four are.
        context_provided: [
          "org_identity",
          "meeting_intent",
          "transcript_window",
          "action_items_canvas"
        ],
        # Task 019fb90f-36e3 stage 3. The key no longer answers with a
        # list of items to post; it answers with what to CHANGE about a
        # canvas that already exists, so the contract is a list of
        # operations. Values in this map must be strings —
        # `Responsibility.changeset/2` casts `output_contract` as a bare
        # `:map` into JSONB and every other key in the tree declares
        # itself as a type NAME, so the shape is spelled out in one
        # string rather than nested.
        #
        # `ContractValidator.classify/1` is deliberately NOT taught to
        # read this shape: it has no clause for a field map, lands on
        # `:unknown`, and hands the handler the raw response STRING.
        # That is true of every responsibility in the tree and the
        # reasoning against "fixing" it is at length below.
        output_contract: %{
          "operations" =>
            "list[object{op:add|update|remove, match:string, label:string, state:pending|active|complete}]"
        },
        default_prompt_template: @prompt_slug,
        cost_profile: "low_freq_capable",
        # `status: "active"` declares this key live now that it has a real
        # landing. It is expressed in `metadata` — not `enabled` — because
        # `Platform.Responsibilities.@upsert_replace_fields` includes
        # `metadata` and deliberately EXCLUDES `enabled` (operator
        # territory, preserved across redeploys). A code-only `enabled`
        # change would be a guaranteed no-op against the existing
        # production row; a `metadata` change propagates on next boot.
        metadata: %{"owner" => "platform.meetings", "status" => "active"}
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    # Task 019fa56b-c81f e2e fix, defect 2.
    #
    # This used to return `{:ok, %{}}` on the belief that "the router
    # still resolves the shared meetings context slots via the provider
    # shim". It does not. `Router.gather_context_via_provider/3` calls
    # the PROVIDER's `gather_context/2` when one is exported and only
    # falls back to its own `context_provided`-driven slot resolution
    # when it is not — and `Providers.Meetings` does export it. So the
    # empty map WAS the context: `build_prompt/1` had nothing to render
    # over, the Router fell back to the `default_prompt_template` render
    # path, and the un-seeded template name went out as the literal user
    # turn. The live capture is unambiguous:
    #
    #     messages == [{"role":"user","content":"meetings.action_items.v1"}]
    #
    # Task 019fb90f-36e3 stage 2 retargets what is gathered.
    #
    # `meeting_transcript` — the WHOLE transcript — was the right slot
    # for a key that fired once, at meeting end. This key now fires per
    # utterance, mid-meeting, so the whole transcript is both the wrong
    # unit (the model is being asked about one thing that was just said)
    # and an unbounded cost (it grows for the length of the meeting, and
    # every utterance would pay for the whole of it again). It is
    # replaced by three slots:
    #
    #   * `meeting_intent`       — the classified utterance itself
    #   * `transcript_window`    — the last few lines around it
    #   * `action_items_canvas`  — what we are reconciling against
    #
    # `org_identity` is gathered exactly as before.
    #
    # NONE of the three refuse. Mid-meeting the utterance is the ground
    # truth and everything else is enrichment: a transcript row that
    # does not exist yet, or a canvas that has not been created yet, are
    # both the NORMAL state at the first action item of a meeting. Each
    # slot reports its own `missing?` and stage 3's `build_prompt/1`
    # owns the single refusal (a blank chunk).
    #
    # NOTE the deliberate absence of `Meetings.claim_router_dispatch/1`.
    # `MeetingSummarize.gather_context/2` claims because stage 2 of task
    # 019fa56b-c81f made the `meeting:finished` dispatch
    # once-per-transcript for THAT key. The claim is keyed by
    # transcript, not by responsibility, so claiming here as well would
    # make the two responsibilities race for a single token and starve
    # whichever one lost. That is still true after the retarget — more
    # so, since this key now fires many times per transcript and would
    # take the token on its first utterance and never give it back.
    payload = Map.get(ctx, :payload) || Map.get(ctx, "payload") || %{}
    workspace_id = payload_field(payload, :workspace_id)

    base_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    with {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, base_opts) do
      {:ok,
       %{
         org_identity: identity,
         meeting_intent: meeting_intent_slot(payload),
         transcript_window: transcript_window_slot(payload),
         action_items_canvas: action_items_canvas_slot(payload)
       }}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  # ── slot: meeting_intent ──────────────────────────────────────────────────
  #
  # Read straight off the payload `IntentDispatcher.action_item_payload/2`
  # broadcasts. Nothing is defaulted except `chunk_excerpt`, which is
  # normalised to `""` so the refusal check downstream is a string
  # operation rather than a nil check. `speaker` in particular is left
  # as-is including nil: the dispatcher recovers it heuristically by
  # matching excerpt text against transcript segments, so it is
  # best-effort, and "we could not attribute this line" must not be
  # rendered as an attribution to someone.
  defp meeting_intent_slot(payload) do
    excerpt = payload |> payload_field(:chunk_excerpt) |> normalize_text()

    %{
      intent_id: payload_field(payload, :intent_id),
      meeting_id: payload_field(payload, :meeting_id),
      room_id: payload_field(payload, :room_id),
      classified_intent: payload_field(payload, :classified_intent),
      confidence: payload_field(payload, :confidence),
      chunk_excerpt: excerpt,
      speaker: payload_field(payload, :speaker),
      missing?: String.trim(excerpt) == ""
    }
  end

  # ── slot: transcript_window ───────────────────────────────────────────────
  #
  # The tail of the room's in-progress transcript, so the model can
  # resolve "that", "she", and "by then" against what was actually said
  # just before. Bounded at @transcript_window_size for the same reason
  # `IntentClassifier` bounds its own context window: the cost of this
  # slot has to be a constant, not a function of how long the meeting
  # has been running.
  #
  # A missing or empty transcript is `missing?: true` with an empty
  # window, NOT an error. Mid-meeting, the very first action item can
  # legitimately land before the transcript row has been written.
  defp transcript_window_slot(payload) do
    transcript_id = payload_field(payload, :transcript_id)

    case fetch_transcript(transcript_id) do
      %{} = transcript ->
        window = Enum.take(transcript.segments || [], -@transcript_window_size)
        formatted = SummaryPrompt.format_segments(window)

        %{
          transcript_id: transcript.id,
          segments: window,
          formatted_text: formatted,
          missing?: window == [] or String.trim(formatted) == ""
        }

      nil ->
        %{transcript_id: transcript_id, segments: [], formatted_text: "", missing?: true}
    end
  end

  defp fetch_transcript(nil), do: nil

  defp fetch_transcript(transcript_id) when is_binary(transcript_id) do
    Meetings.get_transcript(transcript_id)
  rescue
    error ->
      Logger.warning(
        "[meetings.action_items] transcript window failed id=#{transcript_id} " <>
          "reason=#{inspect(error)}"
      )

      nil
  end

  defp fetch_transcript(_), do: nil

  # ── slot: action_items_canvas ─────────────────────────────────────────────
  #
  # What is already on the meeting's action-items canvas, so stage 3's
  # prompt can instruct the model to reconcile rather than append. Absent
  # canvas is `missing?: true` with `canvas_id: nil` — the ordinary state
  # before the meeting's first action item, and stage 4's cue to create
  # one.
  defp action_items_canvas_slot(payload) do
    meeting_id = payload_field(payload, :meeting_id)

    with space_id when is_binary(space_id) <- canvas_space_id(payload, meeting_id),
         {:ok, canvas} <- ActionItemsCanvas.locate(space_id, meeting_id) do
      %{
        canvas_id: canvas.id,
        title: canvas.title,
        revision: ActionItemsCanvas.revision(canvas),
        items: ActionItemsCanvas.summarize(canvas),
        missing?: false
      }
    else
      _ -> %{canvas_id: nil, title: nil, revision: nil, items: [], missing?: true}
    end
  end

  # The three-way ladder from the plan, in priority order: the meeting's
  # own `chat_space_id` is the authoritative binding, the payload's
  # `space_id` is what the dispatcher managed to resolve off the
  # transcript at broadcast time, and the transcript row is the last
  # resort. It leads with the meeting because a canvas belongs to a
  # MEETING, and reaching it via the transcript is an inference where
  # `chat_space_id` is a fact.
  #
  # Used by BOTH halves now (task 019fb90f-36e3 stage 4): the gatherer
  # resolves the canvas to read, `handle_output/3` resolves the canvas to
  # write. Two ladders would be one way to write to a canvas the prompt
  # never saw.
  defp canvas_space_id(payload, meeting_id) do
    meeting_space_id(meeting_id) ||
      present(payload_field(payload, :space_id)) ||
      transcript_space_id(payload_field(payload, :transcript_id))
  end

  defp meeting_space_id(meeting_id) when is_binary(meeting_id) and meeting_id != "" do
    case Meetings.get_meeting(meeting_id) do
      %{chat_space_id: space_id} -> present(space_id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp meeting_space_id(_), do: nil

  defp transcript_space_id(transcript_id) do
    case fetch_transcript(transcript_id) do
      %{space_id: space_id} -> present(space_id)
      _ -> nil
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # The router hands `trigger_meta` through verbatim and both key
  # spellings occur in the wild: atom-keyed from an in-process
  # broadcast, string-keyed from anything that made a JSON round trip.
  defp payload_field(payload, key) when is_map(payload) and is_atom(key),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_field(_payload, _key), do: nil

  defp normalize_text(value) when is_binary(value), do: value
  defp normalize_text(_), do: ""

  @doc "Slug of the prompt template this key renders (drift guard)."
  @spec template_slug() :: String.t()
  def template_slug, do: @prompt_slug

  @doc """
  The inline prompt body used when the `#{@prompt_slug}` row is absent.

  Exposed so a test can compare its `{{marker}}` set against the DB
  row's without going through a render (a rendered body has no markers
  left to compare).
  """
  @spec fallback_prompt() :: String.t()
  def fallback_prompt, do: @fallback_action_items_prompt

  @doc """
  Render the prompt for this responsibility.

  `{:ok, %{system:, user:}}` when there is an utterance to act on,
  `{:error, :no_intent_text}` otherwise. The Router hands the returned
  pair to the Dispatcher as an explicit `messages` list, which is what
  stops the `default_prompt_template` NAME from being sent as the
  prompt.

  ## The refusal moved from the transcript to the chunk (task 019fb90f-36e3 stage 3)

  This used to refuse `{:error, :no_transcript_text}` on a blank
  transcript, which was right for a key that fired once over a finished
  meeting: no transcript meant nothing to extract from. Mid-meeting it
  is wrong in both directions. The transcript window is routinely thin —
  the first action item of a meeting can legitimately land before the
  transcript row exists — while the utterance itself is right there, so
  a blank window is now an ordinary render. And an empty chunk is the
  one case where the round-trip has nothing to be about.

  `:no_transcript_text` is DELETED rather than kept alongside the new
  atom. Two refusal paths answering the same atom is exactly how a
  refusal stops being diagnosable: the sibling finding on task 019fb8ed
  was a refusal rendering as a bare envelope, indistinguishable from a
  render failure. One reason, one atom.

  ## The body comes from the DB row, not from here

  The rendered system turn is `#{@prompt_slug}` interpolated with the
  four gathered slots, exactly like
  `Platform.Meetings.IntentClassifier` renders its own. Before this
  stage the live body was the hardcoded heredoc below and the DB row
  was DORMANT — `Router.build_prompt_via_provider/2` never renders
  `default_prompt_template` when the provider exports `build_prompt/1`,
  so anyone who iterated the wording through `prompt_template_update`
  observed exactly nothing. Now the row is the body and the heredoc is
  the rollout fallback.
  """
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, :no_intent_text}
  def build_prompt(context) when is_map(context) do
    intent = Map.get(context, :meeting_intent) || %{}
    excerpt = intent |> Map.get(:chunk_excerpt) |> normalize_text()

    if String.trim(excerpt) == "" do
      {:error, :no_intent_text}
    else
      {:ok, %{system: system_prompt(context), user: user_turn(intent, excerpt)}}
    end
  end

  def build_prompt(_), do: {:error, :no_intent_text}

  @doc """
  System prompt for the reconciliation turn — the `#{@prompt_slug}` row
  rendered over the gathered slots, or `fallback_prompt/0` rendered over
  the same assigns when that row is missing.
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(context \\ %{}) when is_map(context) do
    assigns = prompt_assigns(context)

    case PromptTemplates.render_template(@prompt_slug, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        Logger.warning(
          "[meetings.action_items] prompt template #{@prompt_slug} missing — using inline fallback"
        )

        substitute(@fallback_action_items_prompt, assigns)
    end
  end

  # The user turn is the utterance and nothing else. Everything that is
  # standing context — the window, the canvas, the org identity — is in
  # the system turn, so the one thing the model is being asked about is
  # not competing with it for attention.
  defp user_turn(intent, excerpt) do
    "This was just said in the meeting. Reconcile the action-items canvas against it.\n\n" <>
      "#{speaker_label(intent)}: #{excerpt}"
  end

  # `speaker` is best-effort and may be nil — see the moduledoc. Render
  # the absence as an absence; never attribute a line to nobody-in-
  # particular by name.
  defp speaker_label(intent) do
    case intent |> Map.get(:speaker) |> normalize_text() |> String.trim() do
      "" -> "Unattributed speaker"
      speaker -> speaker
    end
  end

  # ── prompt assigns ────────────────────────────────────────────────────────
  #
  # One assign per declared template variable, each rendered to a
  # non-empty string. The sentinels matter: a marker that interpolates
  # to "" leaves its heading in the prompt with nothing under it, which
  # reads to a model as a section that was cut off rather than a section
  # with nothing in it.
  defp prompt_assigns(context) do
    %{
      meeting_intent: format_intent(Map.get(context, :meeting_intent) || %{}),
      transcript_window: format_window(Map.get(context, :transcript_window) || %{}),
      action_items_canvas: format_canvas(Map.get(context, :action_items_canvas) || %{}),
      org_identity: format_identity(Map.get(context, :org_identity))
    }
  end

  defp format_intent(intent) do
    excerpt = intent |> Map.get(:chunk_excerpt) |> normalize_text() |> String.trim()

    [
      "Speaker (best-effort attribution): #{speaker_label(intent)}",
      "classified_intent (cheap fast model's label): #{format_value(Map.get(intent, :classified_intent))}",
      "confidence: #{format_value(Map.get(intent, :confidence))}",
      "Utterance (ground truth):",
      if(excerpt == "", do: "(no utterance text)", else: excerpt)
    ]
    |> Enum.join("\n")
  end

  defp format_window(%{missing?: true}), do: "(no surrounding transcript captured yet)"

  defp format_window(window) do
    case window |> Map.get(:formatted_text) |> normalize_text() |> String.trim() do
      "" -> "(no surrounding transcript captured yet)"
      text -> text
    end
  end

  # Items are rendered by LABEL and state only. Node ids are deliberately
  # withheld: item identity is matched on label text downstream, and a
  # model that has seen a node id will start quoting node ids back.
  defp format_canvas(%{missing?: false, items: items}) when is_list(items) and items != [] do
    header = "The meeting's action-items canvas currently holds #{length(items)} item(s):"

    lines =
      Enum.map(items, fn item ->
        state = item |> Map.get(:state) |> normalize_text()
        state = if state == "", do: "pending", else: state
        "- [#{state}] #{item |> Map.get(:label) |> normalize_text()}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp format_canvas(%{missing?: false}),
    do: "The meeting's action-items canvas exists but is empty."

  defp format_canvas(_),
    do: "No action-items canvas exists for this meeting yet. Anything you add creates it."

  defp format_identity(%{content: content, missing?: false}) when is_binary(content) do
    case String.trim(content) do
      "" -> "(no org identity available)"
      trimmed -> trimmed
    end
  end

  defp format_identity(_), do: "(no org identity available)"

  defp format_value(nil), do: "(unknown)"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: to_string(value)

  # Minimal `{{key}}` substitution for the inline fallback only. Same
  # regex and same lookup order as `PromptTemplates.render_template/2`,
  # so switching between the DB body and the fallback is transparent to
  # the model.
  defp substitute(template, assigns) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _match, key ->
      value =
        try do
          Map.get(assigns, String.to_existing_atom(key)) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  @doc """
  Land the model's answer on the meeting's action-items canvas and close
  the intent row.

  Returns `:ok` when the canvas write landed (including the zero-
  operation case, where nothing is written), `{:error, reason}`
  otherwise. Either way the queue row is moved off `:dispatched` —
  `:completed` on success, `:dispatch_failed` carrying the reason on
  failure — because a row this handler leaves in flight holds the
  meeting's serial cursor until the 90s ack window expires, and every
  intent behind it waits.

  ## Why this does not post a markdown checklist

  It used to. `Meetings.post_action_items_to_space/3` was the delivery
  surface when this key fired once, at meeting end. Firing per utterance
  makes it the wrong surface: it renders the WHOLE list, so a meeting
  with a dozen action-item utterances would post the whole list a dozen
  times. The canvas is the durable object and the companion canvas
  message (posted once, by `create/3`) is the in-chat announcement.
  `post_action_items_to_space/3` stays where it is for the post-meeting
  path.
  """
  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    payload = payload_of(trigger_meta)
    meeting_id = payload_field(payload, :meeting_id)
    intent_id = payload_field(payload, :intent_id)

    result = write_canvas(responsibility, payload, meeting_id, parsed)

    close_intent_row(meeting_id, intent_id, result)

    result
  end

  @doc """
  Close the intent row when the Router refused to dispatch at all
  (task 019fb90f-36e3 e2e fix).

  `handle_output/3` closes the row on every outcome that reached the
  model. This closes it on the one outcome that did not. A refusal —
  `{:build_prompt_refused, :no_intent_text}` for a whitespace-only
  utterance — is the CORRECT decision and stays correct: no LLM call,
  no canvas write. But `IntentDispatcher` had already moved the row to
  `:dispatched`, which pins the meeting's serial cursor to it, and the
  refusal returned up through `Router.dispatch_external/5` without ever
  reaching `handle_output/3`. The row sat in `:dispatched` until the
  90-second claim watchdog released it as `:timed_out` — so a blank
  utterance cost the meeting 90 seconds of queue and every intent
  behind it waited, and the row's final status told the operator the
  round trip had overrun when no round trip was ever made.

  The row lands `:dispatch_failed` with `dispatch_failure_reason` set
  to the INNER reason (`:no_intent_text`), not the
  `{:build_prompt_refused, _}` wrapper. The wrapper names the Router's
  seam, which the meeting UI's intent strip has no use for; the inner
  atom names what was wrong with the utterance, which is the thing an
  operator reading the strip is trying to learn.

  Row closing goes through the same `close_intent_row/3` as the output
  path, so the terminal-row guard and the no-queue-server case are
  honoured identically and cannot drift.
  """
  @impl true
  @spec handle_refusal(Responsibility.t(), {atom(), term()} | term(), map()) :: :ok
  def handle_refusal(%Responsibility{} = responsibility, refusal, trigger_meta)
      when is_map(trigger_meta) do
    payload = payload_of(trigger_meta)
    meeting_id = payload_field(payload, :meeting_id)
    intent_id = payload_field(payload, :intent_id)
    reason = refusal_reason(refusal)

    Logger.info(
      "[meetings.action_items] dispatch refused before the model call " <>
        "key=#{responsibility.key} meeting=#{inspect(meeting_id)} " <>
        "intent=#{inspect(intent_id)} reason=#{inspect(reason)}"
    )

    close_intent_row(meeting_id, intent_id, {:error, reason})
  end

  # Unwrap the Router's seam label. `failure_reason/1` downstream still
  # coerces anything non-atom/binary, so an unrecognised refusal shape
  # lands as readable text rather than as Elixir debug output in the
  # meeting's intent strip.
  defp refusal_reason({kind, reason})
       when kind in [:build_prompt_refused, :context_gather_refused],
       do: reason

  defp refusal_reason(other), do: other

  # ── internals ─────────────────────────────────────────────────────────────

  defp write_canvas(responsibility, payload, meeting_id, parsed) do
    with {:ok, meeting_id} <- require_meeting_id(responsibility, meeting_id),
         {:ok, space_id} <- require_space_id(payload, meeting_id),
         {:ok, operations} <- extract_operations(parsed) do
      reconcile(space_id, meeting_id, operations)
    end
  end

  defp require_meeting_id(_responsibility, meeting_id)
       when is_binary(meeting_id) and meeting_id != "",
       do: {:ok, meeting_id}

  defp require_meeting_id(responsibility, _meeting_id) do
    Logger.warning(
      "[meetings.action_items] no meeting_id in trigger payload — cannot reconcile " <>
        "key=#{responsibility.key}"
    )

    {:error, :missing_meeting_id}
  end

  defp require_space_id(payload, meeting_id) do
    case canvas_space_id(payload, meeting_id) do
      space_id when is_binary(space_id) and space_id != "" ->
        {:ok, space_id}

      _ ->
        Logger.warning(
          "[meetings.action_items] no space for meeting=#{meeting_id} — " <>
            "nowhere to put the action-items canvas"
        )

        {:error, :missing_space_id}
    end
  end

  # The create/modify fork the prompt promises the model. `locate/2`
  # answering `:missing` is the ordinary state at a meeting's first
  # action item, not a failure.
  defp reconcile(space_id, meeting_id, operations) do
    case ActionItemsCanvas.locate(space_id, meeting_id) do
      {:ok, canvas} ->
        case ActionItemsCanvas.apply_operations(canvas, operations) do
          {:ok, _canvas} ->
            :ok

          {:error, :canvas_conflict} ->
            {:error, :canvas_conflict}

          {:error, reason} ->
            Logger.warning(
              "[meetings.action_items] canvas patch failed meeting=#{meeting_id} " <>
                "canvas=#{canvas.id} reason=#{inspect(reason)}"
            )

            {:error, :canvas_patch_failed}
        end

      :missing ->
        create_canvas(space_id, meeting_id, operations)
    end
  end

  defp create_canvas(space_id, meeting_id, operations) do
    case ActionItemsCanvas.items_for_create(operations) do
      [] ->
        # No canvas and nothing to put on one. Creating an empty canvas
        # here would mean every meeting where somebody said "we should
        # probably do something about that" ends with a blank checklist
        # in its space.
        Logger.info(
          "[meetings.action_items] nothing to add and no canvas yet meeting=#{meeting_id} — " <>
            "not creating one"
        )

        :ok

      items ->
        case ActionItemsCanvas.create(space_id, meeting_id, items) do
          {:ok, canvas} ->
            Logger.info(
              "[meetings.action_items] created action-items canvas=#{canvas.id} " <>
                "meeting=#{meeting_id} items=#{length(items)}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[meetings.action_items] canvas create failed meeting=#{meeting_id} " <>
                "space=#{space_id} reason=#{inspect(reason)}"
            )

            {:error, :canvas_create_failed}
        end
    end
  end

  # ── closing the queue row ─────────────────────────────────────────────────
  #
  # The dispatcher moved this row to `:dispatched` and, in doing so,
  # pinned the meeting's serial cursor to it. Nothing else closes it: the
  # only other exit is `IntentQueue.Server`'s 90s claim watchdog, which
  # lands `:timed_out`. So a handler that returns without transitioning
  # costs the meeting 90 seconds of queue.
  defp close_intent_row(meeting_id, intent_id, result)
       when is_binary(meeting_id) and is_binary(intent_id) do
    case IntentQueue.get(meeting_id, intent_id) do
      {:ok, %{status: status}} ->
        # The terminal set is READ off the queue, not restated here. A
        # tenth terminal status added there and not here would make this
        # branch quietly stop protecting whatever it is.
        if status in IntentQueue.terminal_statuses() do
          # Already terminal — almost always `:timed_out`, i.e. the model
          # round trip overran the ack window and the watchdog released
          # the cursor. Writing `:completed` over that would erase the
          # timeout from the operator's view and claim a punctuality the
          # dispatch did not have. The canvas write still happened and
          # still stands; only the row's story is already told.
          Logger.info(
            "[meetings.action_items] intent=#{intent_id} already #{status} — " <>
              "leaving the row alone"
          )

          :ok
        else
          transition_intent_row(meeting_id, intent_id, result)
        end

      {:error, reason} ->
        # No queue server for this meeting (it ended), or no such row.
        # Nothing to close and nothing broken.
        Logger.info(
          "[meetings.action_items] intent row unavailable meeting=#{meeting_id} " <>
            "intent=#{intent_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp close_intent_row(_meeting_id, _intent_id, _result), do: :ok

  defp transition_intent_row(meeting_id, intent_id, :ok) do
    log_transition(
      meeting_id,
      intent_id,
      IntentQueue.transition(meeting_id, intent_id, :completed)
    )
  end

  defp transition_intent_row(meeting_id, intent_id, {:error, reason}) do
    log_transition(
      meeting_id,
      intent_id,
      IntentQueue.transition(meeting_id, intent_id, :dispatch_failed, %{
        dispatch_failure_reason: failure_reason(reason)
      })
    )
  end

  # The row's `dispatch_failure_reason` is typed `atom | binary | nil` and
  # is rendered straight into the meeting UI's intent strip. Coerce here
  # rather than trusting every caller upstream to have kept to that: a
  # tuple reason reaching the strip renders as Elixir debug output at a
  # person mid-meeting.
  defp failure_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp failure_reason(reason), do: inspect(reason)

  defp log_transition(_meeting_id, _intent_id, {:ok, _row}), do: :ok

  defp log_transition(meeting_id, intent_id, {:error, reason}) do
    Logger.info(
      "[meetings.action_items] could not close intent row meeting=#{meeting_id} " <>
        "intent=#{intent_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp payload_of(%{payload: payload}) when is_map(payload), do: payload
  defp payload_of(%{"payload" => payload}) when is_map(payload), do: payload
  defp payload_of(meta) when is_map(meta), do: meta
  defp payload_of(_), do: %{}

  # ── extracting the operations ─────────────────────────────────────────────
  #
  # Renamed from `extract_items/1` in task 019fb90f-36e3 stage 4: the key
  # no longer answers with a list of items to post, it answers with what
  # to CHANGE about a canvas.
  #
  # The return type changed with it, and that change is load-bearing.
  # `extract_items/1` answered `[]` both for "the model said nothing was
  # actionable" and for "the model's answer was unreadable", so the two
  # were indistinguishable downstream — and now that this handler closes
  # the queue row, they must land the row on DIFFERENT statuses.
  # `{:ok, []}` is a quiet meeting and completes the row; `{:error,
  # reason}` is a broken answer and fails it.
  defp extract_operations(%{"operations" => list}) when is_list(list),
    do: {:ok, normalize_operations(list)}

  defp extract_operations(%{operations: list}) when is_list(list),
    do: {:ok, normalize_operations(list)}

  # ── the string/map seam (task 019fa56b-c81f e2e fix, defect 1) ───────────
  #
  # This clause is why the key was unfireable. In production the handler
  # is reached only via `Router.invoke_handle_output/3`, whose `parsed`
  # comes from `ContractValidator.validate/2`. `classify/1` has no clause
  # for the field-map contract shape this responsibility declares
  # (`%{"action_items" => "list[string]"}`), so it falls to `:unknown`,
  # which is treated as freeform, which returns the RAW STRING. The map
  # clauses above are therefore unreachable in production — they only
  # ever matched because all 19 tests in `meeting_action_items_test.exs`
  # call `handle_output/3` directly with a map.
  #
  # `MeetingSummarize.extract_summary/1` has exactly this binary clause,
  # which is the entire reason the summarizer posts and this key did not.
  # Live proof, `server3.log:1392`:
  #
  #     [warning] [meetings.action_items] handler received unexpected
  #     output shape — expected %{action_items: [string]}; got
  #     "{\"action_items\": [\"Ship the adapter fix\", ...]}"
  #
  # ## The rule, pinned
  #
  # A summary is one string so the summarizer can take its whole body
  # verbatim. Operations are plural and structured, so a string has to be
  # decoded or split. In order:
  #
  #   1. If the string parses as JSON carrying the contract shape
  #      (`{"operations": [...]}` or a bare `[...]`), use that. This is
  #      the common case — the model honoured the contract and only the
  #      validator failed to decode it.
  #   2. If it parses as JSON that does NOT carry that shape, it is a
  #      contract violation, NOT prose. Sending a decoded JSON object to
  #      the prose splitter would shred its punctuation into invented
  #      action items, which is worse than refusing, so it refuses.
  #   3. If it does not parse as JSON at all, treat it as prose and split
  #      on newlines. Every line becomes an ADD — a model answering in
  #      prose has not told us which items it means to update or remove,
  #      and inferring that from prose is exactly the guess the
  #      label-matching rule exists to avoid.
  #      a. If ANY line carries a list marker (`-`, `*`, `+`, `•`, `1.`,
  #         `1)`), keep ONLY the marked lines. This drops the "Here are
  #         the action items:" preamble and any markdown heading without
  #         needing to guess at their content.
  #      b. If NO line carries a marker, keep every non-blank line.
  #   4. Strip the marker, trim, drop blanks. Markers are stripped once,
  #      not repeatedly, so a literal item like "- see - the doc" keeps
  #      its inner hyphen.
  #
  # An empty result is not an error: a meeting where nothing actionable
  # was said is the common case, and `handle_output/3` completes the row
  # with nothing written.
  defp extract_operations(text) when is_binary(text) do
    case decode_contract_shape(text) do
      {:ok, list} ->
        {:ok, normalize_operations(list)}

      :not_json ->
        {:ok, text |> split_prose() |> clean() |> Enum.map(&add_operation/1)}

      :error ->
        Logger.warning(
          "[meetings.action_items] model answered JSON that is not the operations " <>
            "contract — got " <> inspect(String.slice(text, 0, 240))
        )

        {:error, :unexpected_operations_shape}
    end
  end

  defp extract_operations(other) do
    Logger.warning(
      "[meetings.action_items] handler received unexpected output shape — " <>
        "expected %{operations: [...]}; got " <> inspect(other)
    )

    {:error, :unexpected_output_shape}
  end

  # Three outcomes, not two. `:not_json` is prose and falls through to the
  # splitter; `:error` is structured output that missed the contract and
  # must NOT be split.
  defp decode_contract_shape(text) do
    case Jason.decode(text) do
      {:ok, %{"operations" => list}} when is_list(list) -> {:ok, list}
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _other} -> :error
      {:error, _} -> :not_json
    end
  end

  # A bare string in the operations list is an add of that label — the
  # old `list[string]` contract read as the new one, so a model still
  # answering the pre-stage-3 shape adds items instead of failing.
  defp normalize_operations(list) when is_list(list) do
    list
    |> Enum.map(&normalize_operation/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_operation(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> add_operation(trimmed)
    end
  end

  # The VERB is passed through verbatim rather than classified here.
  # `ActionItemsCanvas.operation_kinds/0` owns the verb roster, and owning
  # it in one place is the point: two rosters drift, and the failure they
  # drift into is silent — an operation this module called a remove and
  # the canvas called nothing at all.
  #
  # The one inference made here is the MISSING verb, because it depends on
  # the rest of the operation rather than on the verb: a model that
  # quotes an existing item back without saying what to do with it means
  # update; one that supplies only a label means add.
  defp normalize_operation(%{} = op) do
    label = op_string(op, :label)
    match = op_string(op, :match)
    verb = op_string(op, :op) |> default_verb(match)

    if blank?(verb) or (blank?(label) and blank?(match)) do
      nil
    else
      %{op: verb, label: label, match: match, state: op_string(op, :state)}
    end
  end

  defp normalize_operation(_), do: nil

  defp default_verb(verb, match) do
    cond do
      not blank?(verb) -> String.trim(verb)
      blank?(match) -> "add"
      true -> "update"
    end
  end

  defp add_operation(label),
    do: %{op: "add", label: label, match: nil, state: "pending"}

  defp op_string(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  # Markers stripped exactly once — see the rule in `extract_operations/1`.
  @list_marker ~r/^\s*(?:[-*+•]|\d+[.)])\s+/

  defp split_prose(text) do
    lines = String.split(text, ~r/\r?\n/)

    case Enum.filter(lines, &Regex.match?(@list_marker, &1)) do
      [] -> lines
      marked -> marked
    end
    |> Enum.map(&String.replace(&1, @list_marker, "", global: false))
  end

  defp clean(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
