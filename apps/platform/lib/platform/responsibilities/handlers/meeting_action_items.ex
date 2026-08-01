defmodule Platform.Responsibilities.Handlers.MeetingActionItems do
  @moduledoc """
  `meetings.action_items` responsibility provider — the scribe's
  mid-meeting hand on the running commitments list.

  Fires when `Platform.Meetings.IntentClassifier` labels one live
  transcript utterance `action_items` and
  `Platform.Meetings.IntentDispatcher`'s responsibility fork routes it
  here instead of to a role's runtime. The chain is:

      transcript chunk
        -> Platform.Meetings.IntentClassifier   (cheap model: "is this about action items?")
        -> Platform.Meetings.IntentQueue.Server (serial cursor, one row in flight per meeting)
        -> Platform.Meetings.IntentDispatcher   (forks on classified_intent == "action_items")
        -> PubSub "meeting:action_item_intent"  ({:action_item_intent, payload})
        -> Platform.Responsibilities.Router     (event_match "action_item_intent")
        -> this handler

  ## The server-side reconciler is gone

  This key used to ship an 800-line canvas reconciler — the deleted
  module Platform.Meetings.ActionItemsCanvas — driven by an `operations`
  output contract: the model answered with a JSON list of add / update /
  remove verbs and a three-arity handle_output applied them to a blessed
  canvas.

  Traced on 2026-07-31: apply_operations was reachable only from that
  handle_output <- `Router.invoke_handle_output/3` <-
  `run_external_dispatch/5` — i.e. **only** when an external HTTP
  assignee returned a parseable body. This key resolves to a NATIVE
  assignee in production, so the reconciler never executed once. The
  recipient is an agent already holding `canvas_describe` /
  `canvas_create` / `canvas_patch`; re-implementing its judgement in
  Elixir, behind a JSON schema, was work the tools already did — and the
  schema was actively costly, because a model spending its answer on
  operation verbs is a model not spending it on the wording of the item.

  So the contract is the same small one every sibling intent handler
  now uses:

    * the platform supplies **what was said**, **what was said around
      it**, and **what is already in the meeting's space**;
    * the recipient decides what to create or change, and does it with
      its own tools.

  Per Rowan's ruling on the classifier (task `019fb90f-36e3`): the
  classifier is a cheap model and is *"not to be trusted"* to pick the
  operation. Its only job is to notice that an utterance is about
  commitments. Nothing in this handler's output contract asks it to do
  more, and item identity deliberately does not key off its
  `dedupe_key`.

  ## What did NOT go with the reconciler: `handle_refusal/3`

  The one piece of per-dispatch state this key holds is not the canvas —
  it is the `IntentQueue` row. `IntentDispatcher` marks it `:dispatched`
  before handing off, which pins the meeting's SERIAL cursor, and a
  refusal returns up through `Router.dispatch_external/5` without ever
  reaching an output callback. That gap shipped and was measured: one
  whitespace-only utterance held the meeting's cursor for the full
  90-second ack window while every intent behind it waited. See
  `handle_refusal/3` for the detail; it stays exactly as it shipped.

  The success side needs no equivalent. The recipient releases the
  cursor itself with `intent_ack`, which is why
  `IntentContext.ack_preamble/1` is composed onto the front of the
  system turn in code rather than left to the tunable template row.

  ## The prompt is the tuning surface

  `build_prompt/1` renders the `meetings.action_items.v1` **row**, not
  a compiled-in string — an operator retunes this responsibility with
  `prompt_template_update` and no deploy. The heredoc below is the
  rollout fallback for the window before the row exists, and is logged
  at `:warning` when it is used so a missing row is visible rather than
  silently degrading the prompt.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Meetings.IntentContext
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentRouting
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "meetings.action_items"
  @feature "meetings"
  @prompt_slug "meetings.action_items.v1"

  # Used only until the row carries this body. Same `{{marker}}` syntax
  # as the DB template so the rendering shape is identical and a rollout
  # gap cannot silently change the variable set.
  @fallback_prompt """
  You are the scribe on a live call. Someone just said something a cheap classifier thought was about commitments, and you are being handed that one line as it happens.

  Your job is to keep this meeting's action-items list correct while people are still talking — not to write it up afterwards.

  ## What is already in the space

  {{meeting_canvases}}

  This meeting keeps ONE running action-items canvas. If it is already there, patch it. If it is not, create it. Never open a second — the people in the room are watching the list they already have open, and a meeting that ends with four partial lists has no list at all.

  ## What was just said

  {{meeting_intent}}

  Read the excerpt, not the label. `classified_intent` is a cheap fast model's guess whose only job was to notice this line might be about commitments; it made no add, update or remove decision and it is routinely wrong about the details. The excerpt is the ground truth, and where the two disagree the excerpt wins. Speaker attribution is best-effort in the same way — when the line itself names an owner, the line wins.

  ## What was said around it

  {{transcript_window}}

  Use this only to resolve what "that", "she" and "by then" refer to. Do not mine these lines for commitments of their own; they have already been handled or deliberately not been.

  ## Org context

  {{org_identity}}

  Names and entities only. It carries no action items.

  ## How to work

  - **Reconcile, do not append.** Read what the list already holds before you add anything. Someone saying "I already did that" changes an existing item to done; a commitment that moves to a different owner or a different date changes that item rather than sitting next to its older self. Two entries describing one commitment is the failure this responsibility exists to avoid.
  - **Leave alone whatever the line did not touch.** An item nobody mentioned keeps its wording, its owner and its state.
  - **Changing nothing is a correct outcome, and for most utterances it is the right one.** Most of what gets flagged is discussion rather than commitment: "we should probably do something about that" is not an action item, and neither is a plan people are still arguing about. If the line turns out not to be about commitments at all, say so in one sentence and change nothing.
  - **Do not create the canvas for a line that adds no item.** An empty checklist appearing in a space because a classifier fired is noise the meeting has to clear up.
  - Write items so somebody who was not in the room can read them a week later: who committed, to what, and by when if a date was actually said. Invent none of the three — a guessed owner is worse than an unowned item.
  """

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Slug of the prompt template this key renders (drift guard)."
  @spec template_slug() :: String.t()
  def template_slug, do: @prompt_slug

  @doc "The inline prompt used only when the template row is absent."
  @spec fallback_prompt() :: String.t()
  def fallback_prompt, do: @fallback_prompt

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    entry = IntentRouting.entry_for_key(@key)

    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        # Read from `IntentRouting` rather than restated. The dispatcher
        # broadcasts on the same row, so the topic the Router subscribes
        # to at boot and the topic the signal is published on cannot
        # disagree — which is the failure that produces a dispatched row
        # nobody hears and a meeting cursor held for the full ack window.
        #
        # Note the deliberate singular in `action_item_intent` against
        # the plural `action_items` intent. That asymmetry shipped and
        # is load-bearing; `IntentRouting` owns it and warns against
        # normalising it.
        trigger_config: %{
          "topic" => entry.topic,
          "event_match" => Atom.to_string(entry.event)
        },
        scope: "per_meeting",
        context_provided: [
          "org_identity",
          "meeting_intent",
          "transcript_window",
          "meeting_canvases"
        ],
        # No structured contract. The recipient reconciles the canvas
        # with its own tools and answers in prose; there is nothing for
        # the platform to parse and apply. The `operations` contract
        # this replaces is the defect described in the moduledoc.
        #
        # `trigger_config`, `context_provided` and `output_contract` are
        # all in `Platform.Responsibilities.@upsert_replace_fields`, so
        # dropping the contract lands on the existing production row at
        # the next boot without a migration.
        output_contract: %{},
        default_prompt_template: @prompt_slug,
        cost_profile: "low_freq_capable",
        # `status` lives in `metadata` and not in `enabled` because
        # `@upsert_replace_fields` includes `metadata` and deliberately
        # EXCLUDES `enabled` (operator territory, preserved across
        # redeploys). A code-only `enabled` change would be a guaranteed
        # no-op against the existing production row.
        metadata: %{"owner" => "platform.meetings", "status" => "active"}
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    payload = Map.get(ctx, :payload) || Map.get(ctx, "payload") || %{}
    workspace_id = Map.get(payload, :workspace_id) || Map.get(payload, "workspace_id")
    base_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    # NOTE the deliberate absence of `Meetings.claim_router_dispatch/1`.
    # `MeetingSummarize.gather_context/2` claims because the
    # `meeting:finished` dispatch is once-per-transcript for THAT key.
    # The claim is keyed by transcript, not by responsibility, so
    # claiming here would make the two responsibilities race for a
    # single token — and this key fires many times per transcript, so it
    # would take the token on its first utterance and never give it back.
    with {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, base_opts) do
      {:ok,
       %{
         org_identity: identity,
         meeting_intent: IntentContext.meeting_intent(payload),
         transcript_window: IntentContext.transcript_window(payload),
         meeting_canvases: IntentContext.space_canvases(IntentContext.space_id(payload))
       }}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, :no_intent_text}
  def build_prompt(context) when is_map(context) do
    intent = Map.get(context, :meeting_intent) || %{}
    excerpt = intent |> Map.get(:chunk_excerpt) |> to_text()

    # The ONE refusal. A blank utterance has nothing to reconcile
    # against, and dispatching it would spend a model call to be told
    # so. Distinct atom per key so a reader can tell which path went
    # quiet — see `Router.@no_work_refusals`. A blank transcript WINDOW
    # is deliberately not a refusal: mid-meeting the first commitment
    # routinely lands before the transcript row exists.
    if String.trim(excerpt) == "" do
      {:error, :no_intent_text}
    else
      {:ok,
       %{
         # The ack contract is composed on in CODE, not carried in the
         # tunable template row — see `IntentContext.ack_preamble/1`.
         # The meeting's serial cursor is held until this recipient
         # acks, and on the native path nothing else can release it.
         system: IntentContext.with_ack(intent, system_prompt(context)),
         user: user_turn(intent, excerpt)
       }}
    end
  end

  def build_prompt(_), do: {:error, :no_intent_text}

  @doc """
  System prompt — the `#{@prompt_slug}` row rendered over the gathered
  slots, or `fallback_prompt/0` rendered over the same assigns when the
  row is missing.
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(context \\ %{}) when is_map(context) do
    assigns = prompt_assigns(context)

    case PromptTemplates.render_template(@prompt_slug, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, :not_found} ->
        Logger.warning(
          "[#{@key}] prompt template #{@prompt_slug} missing — using inline fallback"
        )

        substitute(@fallback_prompt, assigns)
    end
  end

  @doc """
  Required by the `Provider` behaviour; nothing to apply.

  This key's recipient writes to the canvas itself with its own tools,
  so there is no structured payload for the platform to persist. Logged
  at `:debug` rather than silently ignored: reaching here at all means
  the key was dispatched EXTERNALLY and a model answered, which is a
  configuration worth being able to see in a log.

  The queue row is NOT closed here. It was, while this handler owned a
  reconciler and the success path ran server-side; now the recipient is
  the only thing that knows whether it finished, and it says so with
  `intent_ack`. `handle_refusal/3` remains, because a refusal is the one
  outcome where no recipient was ever told about the row.
  """
  @impl true
  def handle_output(%Responsibility{} = _responsibility, _parsed) do
    Logger.debug("[#{@key}] handle_output — recipient owns the canvas write; nothing to apply")
    :ok
  end

  @doc """
  Close the intent row when the Router refused to dispatch at all
  (task 019fb90f-36e3 e2e fix).

  A refusal — `{:build_prompt_refused, :no_intent_text}` for a
  whitespace-only utterance — is the CORRECT decision and stays
  correct: no LLM call, nothing written. But `IntentDispatcher` had
  already moved the row to `:dispatched`, which pins the meeting's
  serial cursor to it, and the refusal returns up through
  `Router.dispatch_external/5` without ever reaching a recipient. So
  nothing acks, and the row sat in `:dispatched` until the 90-second
  claim watchdog released it as `:timed_out` — a blank utterance cost
  the meeting 90 seconds of queue, every intent behind it waited, and
  the row's final status told the operator the round trip had overrun
  when no round trip was ever made.

  The row lands `:dispatch_failed` with `dispatch_failure_reason` set
  to the INNER reason (`:no_intent_text`), not the
  `{:build_prompt_refused, _}` wrapper. The wrapper names the Router's
  seam, which the meeting UI's intent strip has no use for; the inner
  atom names what was wrong with the utterance, which is the thing an
  operator reading the strip is trying to learn.
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
      "[#{@key}] dispatch refused before the model call " <>
        "key=#{responsibility.key} meeting=#{inspect(meeting_id)} " <>
        "intent=#{inspect(intent_id)} reason=#{inspect(reason)}"
    )

    close_intent_row(meeting_id, intent_id, {:error, reason})
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # The user turn is the utterance and nothing else. Everything standing
  # — the window, the canvas inventory, the org identity — is in the
  # system turn, so the one thing being asked about is not competing
  # with it for attention.
  defp user_turn(intent, excerpt) do
    "This was just said on the call. Bring the action-items list up to date with it.\n\n" <>
      "#{speaker_label(intent)}: #{excerpt}"
  end

  # `speaker` is best-effort — the dispatcher recovers it by matching
  # excerpt text against transcript segments — so render the absence as
  # an absence; never attribute a line to nobody-in-particular by name.
  defp speaker_label(intent) do
    case intent |> Map.get(:speaker) |> to_text() |> String.trim() do
      "" -> "Unattributed speaker"
      speaker -> speaker
    end
  end

  defp prompt_assigns(context) do
    %{
      meeting_intent: IntentContext.format_intent(Map.get(context, :meeting_intent) || %{}),
      transcript_window: IntentContext.format_window(Map.get(context, :transcript_window) || %{}),
      meeting_canvases: IntentContext.format_canvases(Map.get(context, :meeting_canvases) || %{}),
      org_identity: IntentContext.format_identity(Map.get(context, :org_identity))
    }
  end

  defp substitute(template, assigns) do
    Enum.reduce(assigns, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(_), do: ""

  # Unwrap the Router's seam label. `failure_reason/1` downstream still
  # coerces anything non-atom/binary, so an unrecognised refusal shape
  # lands as readable text rather than as Elixir debug output in the
  # meeting's intent strip.
  defp refusal_reason({kind, reason})
       when kind in [:build_prompt_refused, :context_gather_refused],
       do: reason

  defp refusal_reason(other), do: other

  defp payload_of(%{payload: payload}) when is_map(payload), do: payload
  defp payload_of(%{"payload" => payload}) when is_map(payload), do: payload
  defp payload_of(meta) when is_map(meta), do: meta
  defp payload_of(_), do: %{}

  # The router hands `trigger_meta` through verbatim and both key
  # spellings occur in the wild: atom-keyed from an in-process
  # broadcast, string-keyed from anything that made a JSON round trip.
  defp payload_field(payload, key) when is_map(payload) and is_atom(key),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_field(_payload, _key), do: nil

  # ── closing the queue row ─────────────────────────────────────────────────
  #
  # The dispatcher moved this row to `:dispatched` and, in doing so,
  # pinned the meeting's serial cursor to it. On the refusal path
  # nothing else closes it: no recipient was told the row exists, so no
  # `intent_ack` is coming, and the only other exit is
  # `IntentQueue.Server`'s 90s claim watchdog, which lands `:timed_out`.
  defp close_intent_row(meeting_id, intent_id, result)
       when is_binary(meeting_id) and is_binary(intent_id) do
    case IntentQueue.get(meeting_id, intent_id) do
      {:ok, %{status: status}} ->
        # The terminal set is READ off the queue, not restated here. A
        # tenth terminal status added there and not here would make this
        # branch quietly stop protecting whatever it is.
        if status in IntentQueue.terminal_statuses() do
          # Already terminal — almost always `:timed_out`, i.e. the
          # watchdog released the cursor before this ran. Writing over
          # that would erase the timeout from the operator's view and
          # claim a punctuality the dispatch did not have; `transition/4`
          # does not police terminal→terminal, so it would succeed.
          Logger.info("[#{@key}] intent=#{intent_id} already #{status} — leaving the row alone")

          :ok
        else
          transition_intent_row(meeting_id, intent_id, result)
        end

      {:error, reason} ->
        # No queue server for this meeting (it ended), or no such row.
        # Nothing to close and nothing broken.
        Logger.info(
          "[#{@key}] intent row unavailable meeting=#{meeting_id} " <>
            "intent=#{intent_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp close_intent_row(_meeting_id, _intent_id, _result), do: :ok

  # `{:error, reason}` is the only shape that reaches here. There was a
  # `:ok -> :completed` clause beside it while this handler applied the
  # model's answer server-side; it is deleted rather than kept, because
  # the platform no longer has a success to report. A `:completed` this
  # module could write would say "the canvas is up to date" on the
  # strength of an HTTP 200, which is a claim only the recipient can
  # make — and it makes it with `intent_ack`.
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
      "[#{@key}] could not close intent row meeting=#{meeting_id} " <>
        "intent=#{intent_id} reason=#{inspect(reason)}"
    )

    :ok
  end
end
