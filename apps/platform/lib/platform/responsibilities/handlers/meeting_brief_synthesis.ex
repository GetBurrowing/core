defmodule Platform.Responsibilities.Handlers.MeetingBriefSynthesis do
  @moduledoc """
  Native `meetings.brief_synthesis` responsibility. Completion invokes this
  handler after the filed transaction commits, keyed by snapshot_hash.
  Context gathering refuses agent dispatch: only Synthesis's direct provider
  call may consume the recipient-filtered source text. Task 01a16974 stage 3.
  """
  @behaviour Platform.Responsibilities.Provider
  def key, do: "meetings.brief_synthesis"

  @impl true
  def register do
    [
      %{
        key: "meetings.brief_synthesis",
        feature: "meetings",
        trigger_kind: "event_topic",
        trigger_config: %{
          "topic" => "meeting:triage_filed",
          "event_match" => "meeting_triage_filed"
        },
        scope: "per_meeting",
        context_provided: [],
        output_contract: %{},
        default_prompt_template: "meetings.brief_synthesis.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"execution" => "native_direct_provider", "owner" => "platform.meetings"}
      }
    ]
  end

  def run(meeting_id), do: Platform.Meetings.Synthesis.maybe_start(meeting_id)
  @impl true
  def gather_context(_, _), do: {:error, :native_direct_provider_only}
  @impl true
  def handle_output(_, _), do: {:error, :native_direct_provider_only}
end
