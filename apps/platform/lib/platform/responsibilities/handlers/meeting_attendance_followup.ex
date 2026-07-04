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

  ## Output handling

  Registration-only handler for the M8 stage 3 wiring pass — mirrors
  `MeetingActionItems`. Downstream side-effects (send DMs to absent
  attendees, post to chat, etc.) land in a follow-up ticket;
  `handle_output` is a benign log-and-return-`:ok`.

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
        metadata: %{"owner" => "platform.meetings"}
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

    Logger.info(
      "[meetings.attendance_followup] received #{length(followups)} followup(s) " <>
        "responsibility=#{responsibility.key} trigger_kind=#{inspect(Map.get(trigger_meta, :kind))}"
    )

    :ok
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
