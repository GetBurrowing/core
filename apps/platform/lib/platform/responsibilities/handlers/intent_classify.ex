defmodule Platform.Responsibilities.Handlers.IntentClassify do
  @moduledoc """
  The registration row for `meetings.intent_classify`. **The Router does
  not fire it — `Platform.Meetings.IntentClassifier` does.**

  ## The runtime landed, and it is not the Router

  This began as a registration-only stub (task 019f2451 stage 3) whose
  moduledoc said the classifier runtime "lands in the follow-up ticket".
  It landed — as a **GenServer**, subscribed to
  `meeting:transcript_chunk` directly
  (`Platform.Meetings.IntentClassifier`, `intent_classifier.ex:332`).
  Nobody came back and told this row, so both consumers stayed
  subscribed to the same topic.

  The Router therefore fired this row on **every transcript chunk**,
  and firing is not free: `Providers.Meetings.build_prompt/1`
  short-circuits this key to `{:error, :no_build_prompt}`, so the Router
  fell back to rendering `default_prompt_template` — which for this key
  IS seeded, and IS the real classifier prompt — and dispatched it to
  whoever holds the role. So every utterance in every meeting was
  classified **twice**: once by the GenServer, which used the answer,
  and once by the Router, whose answer arrived here and was dropped on
  the floor with a `:ok`.

  Found while chasing why a correctly-classified `action_items` never
  became a card. It was not the cause of that — but it was billing for
  a duplicate model call per chunk and reporting success for work it
  discarded.

  ## Why `dispatch: "inert"` rather than deleting the row

  **The row is load-bearing and must stay.** Guard 2 of the classifier's
  own chain (`intent_classifier.ex:600`) is
  `Platform.Roles.assignee_for("meetings.intent_classify")`, and its
  doc is explicit: *"Assignment IS the enable signal — no env-var
  double-gate."* Delete the responsibility and every chunk is dropped
  before any model is consulted. The row is not vestigial; it is the
  on-switch.

  So the row keeps `enabled: true` and keeps its assignee, and declares
  `dispatch: "inert"` — read directly by `Router.dispatch_inert?/1`,
  its only reader, with exactly one meaning. It also declares
  `executor: "platform.meetings.intent_classifier"`, the same shape the
  `security.*` keys use for their sweeper, so
  `Platform.Responsibilities.Reachability` reports "something else runs
  this" rather than "nothing runs this" — different facts, and the
  distinction is the whole reason that field exists.

  ## Why `metadata` and not `enabled: false`

  `Platform.Responsibilities.@upsert_replace_fields` deliberately
  EXCLUDES `enabled` — operator territory, preserved across upserts so
  admin-UI toggles survive redeploys. A code-only `enabled: false` would
  be a guaranteed no-op against the row already in production.
  `metadata` IS in the replace list, so this declaration propagates on
  the next boot's `upsert_by_key/1`. Same reasoning, same words, as
  `Handlers.MeetingAttendanceFollowup`, which is the precedent this
  follows rather than a second invention.

  `status: "placeholder"` is retained deliberately and is NOT what the
  Router vetoes on: eleven rows carry it and seven of them dispatch, so
  a veto keyed on `status` would silently break those seven. See
  `Router.dispatch_inert?/1`'s own comment.

  ## How to re-enable

  Delete `"dispatch" => "inert"` from `register/0` — a deliberate source
  edit in the same file as the `handle_output/3` that would first have
  to be implemented, not a config toggle someone can flip without
  reading the handler. Doing so without also retiring the GenServer
  restores the double-classification.

  ## Spec

    * `key` — `"meetings.intent_classify"`
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with `topic:
      "meeting:transcript_chunk"` (placeholder — the real event bus
      contract lands in the runtime ticket)
    * `scope` — `per_meeting`
    * `context_provided` — `["meeting_transcript_chunk"]`
    * `cost_profile` — `high_freq_low_cost` (classifier runs every
      transcript chunk, not once per meeting; this is the cheap tier
      per `Responsibility.cost_profiles/0`)

  ## Output contract

  Declared as a map-of-strings to satisfy the M1 schema invariant
  (`Responsibility.changeset/2` rejects non-string values in the JSONB
  `output_contract` column). The runtime ticket materialises the actual
  parser + dispatcher against this shape.

  ## Provider callback stubs

  `gather_context/2` returns a `:meeting_transcript_chunk` slot marked
  `missing?: true`. Its original note — "the router will not fire this
  row today because the trigger topic has no publisher" — **was false by
  the time anyone read it**: `Meetings.append_segment/2` broadcasts on
  that topic for every segment. The slot stays `missing?: true` because
  it genuinely is; the Router simply must not be firing this row at all,
  which `dispatch: "inert"` now enforces.

  `handle_output/2` and `handle_output/3` return
  `{:error, :not_implemented}`, NOT `:ok`. If this row ever does fire —
  an inert declaration removed without the work, or a direct
  `fire_trigger/3` in a test — ADR-0046's `outcome/1` maps the error to
  `:failed`, so it is recorded as a failure rather than quietly counted
  as a completed step. Returning `:ok` for output it discards is what
  made the duplicate dispatch invisible for as long as it was.

  ## Stall-guard contract

  Task 019f2566 stage 6 shipped
  `Platform.Responsibilities.StallRegistry` as the seam for periodic
  stall-guard sweeps. When the actual chunk-dispatcher lands (see task
  `019f2452`), the follow-up runtime MUST:

    1. Stamp a `router_dispatched_at`-equivalent timestamp on whatever
       record represents the queue entry (mirror what stage 1 did for
       `meeting_transcripts` — a durable "we handed off to the router
       at this moment" marker).

    2. Register its zero-arity sweep function with StallRegistry at
       boot:

           Platform.Responsibilities.StallRegistry.register(
             {MyIntentClassifyRuntime, :sweep_meetings_intent_classify}
           )

       Registration is idempotent (MapSet-backed) and belongs in the
       runtime's own boot path — not in this handler and not in
       `Platform.Application`. `Platform.Meetings.SummarizerSweeper`
       will invoke it inside a supervised task on each tick.

    3. In `sweep_meetings_intent_classify/0`, walk the runtime's own
       queue records past a stall window, fire a fallback path (drop,
       requeue, or synchronous re-classify — whatever the runtime's
       failure mode calls for), and post a completion notice via
       `Platform.Meetings.post_fallback_notice/3` with
       `dispatch_kind: "meetings.intent_classify"` in the metadata so
       operators can distinguish it from the summarize fallback.

    4. Emit a matching telemetry event
       (`[:platform, :meetings, :intent_classify_fallback_fired]` or
       similar) so `Platform.Responsibilities.CutoverMonitor` and
       downstream dashboards can count fallback firings the same way
       they already count summarize-fallback firings.

  See `Platform.Meetings.SummarizerSweeper` (task 019f2566) for the
  reference pattern — the runtime should mirror that shape, not
  reinvent it.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "meetings.intent_classify"
  @feature "meetings"
  @template_slug "meetings.intent_classify.v1"
  @runtime_task "019f2452-0210"
  @executor "Platform.Meetings.IntentClassifier"

  @doc "The runtime that actually fires this key. NOT the Router."
  @spec executor() :: String.t()
  def executor, do: @executor

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          "topic" => "meeting:transcript_chunk",
          "event_match" => "transcript_chunk"
        },
        scope: "per_meeting",
        context_provided: ["meeting_transcript_chunk"],
        output_contract: %{
          "intent" => "string",
          "target_role" => "string",
          "confidence" => "float",
          "dedupe_key" => "string"
        },
        default_prompt_template: @template_slug,
        cost_profile: "high_freq_low_cost",
        metadata: %{
          "owner" => "platform.meetings",
          "status" => "placeholder",
          "runtime_task" => @runtime_task,
          # Read DIRECTLY by `Router.dispatch_inert?/1`, which is its
          # only reader and has exactly one meaning: the Router does not
          # fire this row. See the moduledoc — the runtime landed, and
          # it is not the Router.
          "dispatch" => "inert",
          # The same shape the `security.*` keys use for their sweeper.
          # `Reachability` reports this verbatim as `declared_executor`,
          # so an audit can tell "nothing runs this" from "something
          # else runs this" without reading either module.
          "executor" => "platform.meetings.intent_classifier"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx) do
    {:ok,
     %{
       meeting_transcript_chunk: %{
         missing?: true,
         note: "runtime not yet implemented — task #{@runtime_task}"
       }
     }}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[meetings.intent_classify] Router fired an inert row — the classifier runtime is " <>
        "#{@executor}, not the Router. Output discarded."
    )

    {:error, :not_implemented}
  end
end
