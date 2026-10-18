defmodule Platform.Test.Fixtures.MeetingTranscriptGroundingFixture do
  @moduledoc """
  Realistic meeting-transcript fixture used by the M8 grounding snapshot
  test (`Platform.Responsibilities.GroundingSnapshotTest`).

  The fixture's whole job is to encode a transcript that
  **mentions two named entities verbatim** that an LLM with no
  org-context grounding would otherwise paraphrase or omit:

    * `"Helios"` — a project codename. A naive summarizer will reach for
      generic phrases like "the platform" or "the launch" instead.
    * `"Mira Chen"` — a person's full name. A naive summarizer that
      respects only the speaker-attribution header tends to drop the
      surname or compress to first-name-only.

  Both names appear inside the transcript SPEECH (not just the speaker
  header) AND inside the seeded `ORG_IDENTITY.md`. That second copy is
  the part the grounding block carries into the system prompt, and is
  what the grounded LLM mock will "see" and echo verbatim.

  The transcript runs ~6 minutes (12 segments) — long enough to
  exercise the real-world prompt envelope without making the test
  ledger noisy.
  """

  @entity_project "Helios"
  @entity_person "Mira Chen"

  @doc "Project codename that must survive grounded summarization verbatim."
  @spec entity_project() :: String.t()
  def entity_project, do: @entity_project

  @doc "Person's full name that must survive grounded summarization verbatim."
  @spec entity_person() :: String.t()
  def entity_person, do: @entity_person

  @doc """
  The full ORG_IDENTITY.md body the snapshot test seeds before gathering
  context. Mentions both named entities so the `## Grounding context`
  block the new handler builds will actually carry them to the LLM.
  """
  @spec org_identity_md() :: String.t()
  def org_identity_md do
    """
    # Acme Robotics — Organization Identity

    ## Mission
    Ship the next generation of autonomous kitchen robotics under the
    **#{@entity_project}** product line. #{@entity_project} is the
    umbrella codename for both the firmware platform AND the customer-
    facing fleet management console — when summarising any meeting
    that mentions "the project", "the launch", "the platform", or
    "the rollout", prefer the verbatim name **#{@entity_project}**.

    ## Key People
    - **#{@entity_person}** — VP Engineering. Owns the #{@entity_project}
      delivery roadmap. Frequently introduced as just "Mira" in
      conversation; full-name **#{@entity_person}** should be preserved
      in written summaries so external readers can follow up.
    - **Sam Park** — Director of Robotics. Owns hardware integration.
    - **Alex Reyes** — Engineering Manager, fleet management console.

    ## Product Summary
    #{@entity_project} ships a thin Linux runtime onto a custom
    NVIDIA Jetson SoM, plus a SaaS control plane for fleet operators.
    The Q3 launch covers the QSR (quick-service restaurant) vertical
    with three pilot customers.
    """
  end

  @doc """
  Twelve speaker-attributed transcript segments shaped like the real
  rows the LiveKit webhook persists. The transcript:

    * Mentions `"#{@entity_project}"` verbatim in five separate
      utterances by three different speakers.
    * Mentions `"#{@entity_person}"` (full name) verbatim in two
      utterances, plus two further first-name-only references — so a
      naive summarizer might collapse to "Mira" while a grounded one
      preserves the full surname.
    * Includes a clear decision (`"we're cutting the Tuesday demo"`)
      and an explicit action item with an assignee, so the legacy
      `SummaryPrompt` body's "Decisions Made" / "Action Items"
      sections have material to populate. This ensures the ungrounded
      summary is **plausible** — the test isn't comparing a real summary
      to garbage; it's comparing two real summaries that differ only in
      whether they preserved the entity names.
  """
  @spec transcript_segments() :: [map()]
  def transcript_segments do
    [
      %{
        "participant_identity" => "user_sam",
        "speaker_name" => "Sam Park",
        "text" =>
          "Morning everyone — quick standup on the #{@entity_project} pilot rollout. " <>
            "We've got two weeks until the QSR partners get their first units.",
        "start_time" => 0,
        "end_time" => 8_500,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_mira",
        "speaker_name" => "Mira Chen",
        "text" =>
          "Thanks Sam. I want to flag that the firmware build for #{@entity_project} " <>
            "is two days behind because the NVENC driver bump pulled in a regression. " <>
            "Alex, did your team get the patch?",
        "start_time" => 9_000,
        "end_time" => 22_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_alex",
        "speaker_name" => "Alex Reyes",
        "text" =>
          "Yeah, we landed it last night. Console build is green again. " <>
            "Mira, want me to push the staging deploy now or wait for QA?",
        "start_time" => 22_500,
        "end_time" => 31_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_mira",
        "speaker_name" => "Mira Chen",
        "text" =>
          "Wait for QA. I don't want to burn our pilot customers' trust on " <>
            "a half-tested console. Push it once QA signs off.",
        "start_time" => 31_500,
        "end_time" => 41_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_sam",
        "speaker_name" => "Sam Park",
        "text" =>
          "Agreed. Mira Chen has final call on staging promotion until the launch " <>
            "freezes — that's been the working agreement since the Q2 retro.",
        "start_time" => 41_500,
        "end_time" => 53_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_alex",
        "speaker_name" => "Alex Reyes",
        "text" =>
          "Sounds good. Separately — the Tuesday investor demo. I think we should " <>
            "cut it. We don't have a stable #{@entity_project} build to show off " <>
            "and a bad demo is worse than no demo.",
        "start_time" => 53_500,
        "end_time" => 68_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_mira",
        "speaker_name" => "Mira Chen",
        "text" =>
          "I agree. Let's cut the Tuesday demo. I'll send the note to the investors " <>
            "this afternoon. Sam — can you draft the talking points so I'm not " <>
            "writing from a cold start?",
        "start_time" => 68_500,
        "end_time" => 82_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_sam",
        "speaker_name" => "Sam Park",
        "text" =>
          "Yep, I'll have a draft to you by lunch. We can frame it as " <>
            "\"#{@entity_project} reliability over investor optics\" — that's a " <>
            "story we can defend.",
        "start_time" => 82_500,
        "end_time" => 96_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_alex",
        "speaker_name" => "Alex Reyes",
        "text" =>
          "One more thing on #{@entity_project} — the fleet telemetry pipeline " <>
            "started dropping events overnight. Looks like the Kafka consumer " <>
            "group rebalanced and didn't recover. I've got an oncall page open.",
        "start_time" => 96_500,
        "end_time" => 112_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_mira",
        "speaker_name" => "Mira Chen",
        "text" =>
          "Page me if you need help. I want telemetry green before the pilot units " <>
            "ship — that's a hard blocker for #{@entity_project} launch readiness.",
        "start_time" => 112_500,
        "end_time" => 124_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_sam",
        "speaker_name" => "Sam Park",
        "text" =>
          "Okay. Recap: Alex pushes console to staging after QA, Mira drafts " <>
            "the investor note, I draft talking points, Alex chases telemetry. " <>
            "Anything else?",
        "start_time" => 124_500,
        "end_time" => 142_000,
        "language" => "en",
        "final" => true
      },
      %{
        "participant_identity" => "user_alex",
        "speaker_name" => "Alex Reyes",
        "text" => "Nope, that's it. Thanks all.",
        "start_time" => 142_500,
        "end_time" => 146_000,
        "language" => "en",
        "final" => true
      }
    ]
  end

  @doc """
  Convenience: returns `{org_identity_md/0, transcript_segments/0,
  entity_project/0, entity_person/0}` so test setup can destructure once.
  """
  @spec all() :: %{
          org_identity: String.t(),
          segments: [map()],
          entity_project: String.t(),
          entity_person: String.t()
        }
  def all do
    %{
      org_identity: org_identity_md(),
      segments: transcript_segments(),
      entity_project: entity_project(),
      entity_person: entity_person()
    }
  end
end
