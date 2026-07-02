defmodule Platform.Responsibilities.Handlers.IntentClassify do
  @moduledoc """
  Placeholder handler for `meetings.intent_classify` (task 019f2451 stage 3).

  Registration-only stub that gives the Meeting Producer role a real
  responsibility row to bind to. The classifier runtime, transcript
  event bus, dedupe queue, and downstream dispatcher land in the
  follow-up ticket `019f2452-0210-...`; keeping the row in the table
  now unblocks the role/bundle wiring (stage 4) without forcing the
  full runtime through the same review window.

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
  `missing?: true` — the router will not fire this row today because
  the trigger topic has no publisher, so this only exists to keep the
  M1 behaviour contract satisfied.

  `handle_output/2` and `handle_output/3` log a placeholder warning
  and return `:ok`. If a rogue call site fires this responsibility
  before the runtime ticket lands, the warning tells operators exactly
  which follow-up ticket to check. Logged at `Logger.warning` (not
  `info`) so the message survives production log-level tuning and the
  test-suite's `:warning` default.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "meetings.intent_classify"
  @feature "meetings"
  @runtime_task "019f2452-0210"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

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
        default_prompt_template: "meetings.intent_classify.v1",
        cost_profile: "high_freq_low_cost",
        metadata: %{
          "owner" => "platform.meetings",
          "status" => "placeholder",
          "runtime_task" => @runtime_task
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
      "[meetings.intent_classify] placeholder handler — dispatch not implemented; " <>
        "runtime task #{@runtime_task}"
    )

    :ok
  end
end
