defmodule Platform.Responsibilities.Handlers.MeetingAttendanceFollowup do
  @moduledoc """
  `meetings.attendance_followup` responsibility provider (ADR-0041
  Meeting Scribe bundle stage 3, task 019f2455).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the per-meeting attendance-followup drafting that fires alongside
  `meetings.summarize` and `meetings.action_items` on the canonical
  `meeting:finished` event.

  ## Spec

    * `key` — `"meetings.attendance_followup"`
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with `topic: "meeting:finished"`
      (same fan-in topic the other Meeting Scribe responsibilities use —
      all three co-subscribe and all three fire per meeting)
    * `scope` — `per_meeting`
    * `context_provided` — `["org_identity", "meeting_transcript"]`
    * `output_contract` — `%{"followups" => "list[string]"}`

  ## DECLARED INERT — `metadata["dispatch"] == "inert"`

  This key is registered but deliberately **not dispatchable** (task
  `019fa56b-c81f` stage 4). The Router refuses to fire any row whose
  `metadata["dispatch"]` is `"inert"`
  (`Platform.Responsibilities.Router.fire_trigger/3`), so with the
  event_topic adapter repaired in stage 1 this key stays silent on
  every `meeting:finished` broadcast while its siblings fire.

  ### Why `dispatch` and not `status`

  The stage brief specified gating on `metadata["status"] == "placeholder"`.
  That is NOT safe: eleven rows already carry that marker
  (`meetings.intent_classify`, `tasks.triage`, `tasks.weekly_review`,
  `tasks.unblock`, the three `design.*` keys, the four `security.*` keys)
  and for them it means "registered ahead of its own runtime, grep-able
  by an operator" — NOT "never dispatch". Seven of them fire today, and
  `meetings.intent_classify` is the transcript-chunk key this task's
  stage 1 just repaired. A Router veto keyed on `status` would silently
  re-break it.

  `Platform.Responsibilities.Reachability` (sibling task 019fa510) reads
  the same field and is explicit about the distinction: it names its
  output `declared_inert?` rather than `inert?` because "it reports what
  the row *declares*". So this row keeps `status: "placeholder"` — which
  earns the `declared_inert_reason: :placeholder_status` classification
  there for free — and adds a separate, single-meaning `dispatch: "inert"`
  that the Router enforces. Both live in `metadata`, so both propagate
  (see below).

  ### Why inert rather than shipped

  Its output contract is not currently satisfiable. The seeded prompt
  (`priv/repo/migrations/20260703120200_seed_prompt_templates_meeting_scribe.exs:42`)
  promises "short follow-ups for expected attendees who did not join",
  which needs an EXPECTED-attendee set diffed against actual joiners.
  Both halves exist in pieces — `Platform.Meetings.MeetingNotifier`
  derives invitees as chat-space user participants minus the host, and
  `Platform.Meetings.active_participants_for_space/1` gives joiners —
  but nothing assembles them into a context slot: `gather_context/2`
  below returns `%{}`, `context_provided` declares no attendance slot,
  and there is no delivery surface for a per-absentee follow-up (unlike
  action items, which post to the meeting space). Firing anyway would
  dispatch a model with no attendance data to answer a question about
  attendance, and bill for it once per meeting.

  ### Why `metadata` and not `enabled: false`

  `Platform.Responsibilities.@upsert_replace_fields` deliberately
  EXCLUDES `enabled` — that is operator territory, preserved across
  upserts so admin-UI toggles survive redeploys. A code-only
  `enabled: false` here would therefore be a guaranteed no-op against
  the row already sitting in production. `metadata` IS in the replace
  list, so this declaration propagates on the next boot's
  `upsert_by_key/1`.

  The row also stays `enabled: true` and keeps its assignee, so role
  resolution does not silently rot while the key waits.

  ### How to re-enable

  Delete `"dispatch" => "inert"` from `register/0` below — a deliberate
  source edit in the same file as the `handle_output/3` that must first
  be implemented, not a config toggle someone can flip without reading
  the handler.

  ## Output handling

  `handle_output/3` returns `{:error, :not_implemented}`. If this key
  ever does fire — a placeholder declaration removed without the work,
  or a direct `fire_trigger/3` call in a test — the outcome is recorded
  as a FAILURE rather than a success, so ADR-0046's `outcome/1` maps it
  to `:failed` instead of quietly reporting a complete step.

  ## Wildcard-topic note

  Same as `MeetingSummarize` and `MeetingActionItems` —
  `topic_pattern: "meeting:finished:*"` is advisory; the router listens
  on the canonical topic and PubSub fans out on broadcast.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Responsibility

  @key "meetings.attendance_followup"
  @feature "meetings"

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
          "topic" => "meeting:finished",
          "topic_pattern" => "meeting:finished:*",
          "event_match" => "meeting_finished"
        },
        scope: "per_meeting",
        context_provided: ["org_identity", "meeting_transcript"],
        output_contract: %{"followups" => "list[string]"},
        default_prompt_template: "meetings.attendance_followup.v1",
        cost_profile: "low_freq_capable",
        # `dispatch: "inert"` is read DIRECTLY by
        # `Router.fire_trigger/3` and is the ONLY thing that stops this
        # row firing. `status: "placeholder"` is the pre-existing
        # operator/reporting marker eleven other rows already carry and
        # is NOT a dispatch veto — see the moduledoc for why these are
        # two fields, and for why both are metadata and not
        # `enabled: false`.
        metadata: %{
          "owner" => "platform.meetings",
          "status" => "placeholder",
          "dispatch" => "inert"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, _ctx) do
    {:ok, %{}}
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    followups = extract_followups(parsed)

    Logger.warning(
      "[meetings.attendance_followup] fired while DECLARED INERT — " <>
        "received #{length(followups)} followup(s) responsibility=#{responsibility.key} " <>
        "trigger_kind=#{inspect(Map.get(trigger_meta, :kind))}; the attendance context " <>
        "chain is not built, so the output is discarded and the fire is recorded as failed"
    )

    {:error, :not_implemented}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp extract_followups(%{"followups" => list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_followups(%{followups: list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_followups(other) do
    Logger.warning(
      "[meetings.attendance_followup] handler received unexpected output shape — " <>
        "expected %{followups: [string]}; got " <> inspect(other)
    )

    []
  end
end
