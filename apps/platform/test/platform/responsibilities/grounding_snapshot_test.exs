defmodule Platform.Responsibilities.GroundingSnapshotTest do
  @moduledoc """
  ADR-0041 M8 stage 5 — grounding snapshot diff.

  The whole point of the new `meetings.summarize` responsibility is
  that summaries **ground in entity names the org actually controls**.
  This test captures the difference between the legacy ungrounded
  summarizer and the new grounded handler as a side-by-side textual
  snapshot a human can inspect (`tmp/grounding_snapshot.txt`), then
  asserts the entity names land in the grounded summary and are missing
  from the ungrounded one.

  ## Why no live LLM call

  Per the stage plan, **this test does NOT exercise a live LLM**. It:

    1. Seeds the fixture `ORG_IDENTITY.md` and a transcript via the
       real DB-backed contexts (so `ContextProviders.gather_context/2`
       is exercised end-to-end).
    2. Builds the two LLM message lists — legacy (no grounding) vs new
       (with `## Grounding context` block).
    3. Runs each message list through a tiny in-process **fake
       provider** that simulates the two failure / success modes:

         * `ungrounded_provider/2` — represents the legacy path's
           behaviour when the model has nothing besides the
           transcript and base prompt: it paraphrases entity names
           because it doesn't have a verbatim reference.
         * `grounded_provider/2` — represents what happens when the
           model *can see* a grounding section: it lifts the entity
           names from the system prompt directly.

  The fake providers don't pretend to be Claude. They're a controlled
  contract test: "given the prompt assembly, do the entity names reach
  the model's context window?". The live hallucination-vs-real-name
  proof is the e2e_behavior step at task review time.

  ## Why direct-handler invocation, not the router

  Stage-3 drift notes flagged that the router's `provider_module_for/1`
  resolves `feature == "meetings"` to
  `Platform.Responsibilities.Providers.Meetings`, a shim that doesn't
  exist yet — so a router-fired path would log `"no output handler for
  meetings.summarize"` and never invoke `MeetingSummarize`. We call
  `MeetingSummarize.build_messages/1` directly: that's the proper unit
  of the grounding payoff and matches the stage's explicit
  "does not exercise a live LLM" intent.

  ## Tag

  Tagged `:grounding_snapshot` so a future suite-level grounding
  regression sweep can `mix test --only grounding_snapshot` without
  picking up the rest of the responsibilities tests.
  """
  use Platform.DataCase, async: false

  @moduletag :grounding_snapshot

  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.MeetingSummarize

  import Ecto.Query

  # The fixture module ships as a `.exs` per the stage plan (mirrors
  # ExUnit's convention of `.exs` for test-only Elixir code that isn't
  # auto-compiled into the app). `Code.require_file/2` is idempotent —
  # if a sibling test already loaded it the second require is a no-op.
  Code.require_file(
    "../../support/fixtures/meeting_transcript_grounding_fixture.exs",
    __DIR__
  )

  alias Platform.Test.Fixtures.MeetingTranscriptGroundingFixture, as: Fixture

  @snapshot_path Path.expand("../../../tmp/grounding_snapshot.txt", __DIR__)

  # Clear any seeded ORG_IDENTITY.md variant before each test so the
  # fixture's identity content is the only version the context provider
  # can read. Mirrors the helper in context_providers_test.exs.
  defp drop_org_identity_files do
    Repo.delete_all(
      from(p in WikiPage,
        where:
          p.file_key in [
            "ORG_IDENTITY.md",
            "org/identity.md",
            "org/page/identity.md"
          ]
      )
    )
  end

  defp seed_fixture! do
    drop_org_identity_files()

    {:ok, _page} =
      OrgContext.upsert_file(%{
        file_key: "ORG_IDENTITY.md",
        content: Fixture.org_identity_md()
      })

    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: Platform.Types.UUIDv7.generate(),
        space_id: Platform.Types.UUIDv7.generate(),
        segments: Fixture.transcript_segments()
      })

    transcript
  end

  # Legacy message-list shape — matches `Summarizer.run_summary_legacy/3`
  # (see `apps/platform/lib/platform/meetings/summarizer.ex:152-159`).
  # System prompt is the canonical `SummaryPrompt.system_prompt/0` body
  # WITHOUT any grounding section appended.
  defp legacy_messages(segments) do
    formatted = SummaryPrompt.format_segments(segments)

    [
      %{
        role: "system",
        content: SummaryPrompt.system_prompt()
      },
      %{
        role: "user",
        content: "Please summarize the following meeting transcript:\n\n#{formatted}"
      }
    ]
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Fake providers
  #
  # Both providers receive the full message list + a list of "candidate"
  # entity names that the grounded path may legitimately echo. They emit
  # plain markdown shaped like a real summary so the snapshot file is
  # easy to read.
  # ─────────────────────────────────────────────────────────────────────────

  # Simulates an ungrounded model: it only sees the user message
  # (transcript text). It produces a plausible summary BUT
  # systematically paraphrases entity names — the project becomes
  # "the project" / "the launch", and people are reduced to first
  # names (this is the failure mode the M8 grounding payoff fixes).
  defp ungrounded_provider(messages, _candidates) do
    user_message =
      messages
      |> Enum.find(fn m -> m.role == "user" end)
      |> Map.get(:content, "")

    has_decision? = user_message =~ "cut the Tuesday demo"
    has_telemetry? = user_message =~ "telemetry"
    has_qa? = user_message =~ "wait for QA"

    """
    ### Overview
    The engineering leads synced on the upcoming product launch and
    discussed near-term release blockers.

    ### Key Topics
    - Firmware build slipped due to a driver regression; the console
      build has recovered.
    - Staging promotion is gated on QA sign-off.
    - The Tuesday investor demo was discussed and dropped.
    - A telemetry-pipeline regression was opened against the platform.

    ### Decisions Made
    #{if has_decision?, do: "- The team agreed to cancel the Tuesday investor demo to protect launch reliability.", else: "- (none captured)"}
    #{if has_qa?, do: "- Staging deploy of the console must wait for QA sign-off.", else: ""}

    ### Action Items
    - **Harper**: draft the investor talking points by lunch.
    - **Mira**: send the investor note this afternoon and own the staging-promotion call.
    - **Alex**: chase down the #{if has_telemetry?, do: "telemetry pipeline regression", else: "console rollout"}.
    """
  end

  # Simulates a grounded model: it scans the SYSTEM message for the
  # candidate entity names and, if it finds them, lifts them verbatim
  # into its output. This is the contract `build_messages/1` is
  # supposed to make possible — the entity names have to actually reach
  # the system message for any downstream model to be able to use them.
  defp grounded_provider(messages, candidates) do
    system_message =
      messages
      |> Enum.find(fn m -> m.role == "system" end)
      |> Map.get(:content, "")

    user_message =
      messages
      |> Enum.find(fn m -> m.role == "user" end)
      |> Map.get(:content, "")

    visible = Enum.filter(candidates, &String.contains?(system_message, &1))

    project = Enum.find(visible, &(&1 == "Helios")) || "the project"
    person = Enum.find(visible, &(&1 == "Mira Chen")) || "Mira"

    has_decision? = user_message =~ "cut the Tuesday demo"
    has_telemetry? = user_message =~ "telemetry"

    """
    ### Overview
    The #{project} engineering leads synced on near-term launch
    blockers and staging-promotion decisions. #{person} chaired the
    release-readiness portion of the call.

    ### Key Topics
    - #{project} firmware build slipped two days due to an NVENC
      driver regression; the fleet console build has recovered.
    - Staging promotion of the #{project} console is gated on QA
      sign-off; #{person} retains final call on staging promotion
      until the launch window freezes.
    - The Tuesday investor demo was discussed in light of #{project}
      reliability concerns.
    - A telemetry-pipeline regression was opened against #{project}.

    ### Decisions Made
    #{if has_decision?, do: "- The team agreed to cancel the Tuesday investor demo so a stable #{project} build can be the next external touchpoint.", else: "- (none captured)"}
    - Staging deploys of the #{project} console must wait for QA sign-off.

    ### Action Items
    - **Harper Park**: draft #{project} investor talking points by
      lunch ("#{project} reliability over investor optics").
    - **#{person}**: send the investor note this afternoon; owns
      #{project} staging-promotion calls.
    - **Alex Reyes**: chase the #{if has_telemetry?, do: "#{project} telemetry pipeline regression", else: "console rollout"}.
    """
  end

  defp write_snapshot!(summary_a, summary_b) do
    body = """
    === UNGROUNDED (legacy Summarizer.run_summary path) ===

    #{summary_a}

    === GROUNDED (Handlers.MeetingSummarize.build_messages path) ===

    #{summary_b}
    """

    File.mkdir_p!(Path.dirname(@snapshot_path))
    File.write!(@snapshot_path, body)
    @snapshot_path
  end

  describe "grounded vs ungrounded summary snapshot" do
    test "grounded path preserves entity names; ungrounded path does not" do
      transcript = seed_fixture!()
      candidates = [Fixture.entity_project(), Fixture.entity_person()]

      # ── A. Ungrounded path ──────────────────────────────────────────
      #
      # Build the legacy message list (no grounding block in system
      # prompt) and run it through the paraphrasing fake provider.
      messages_a = legacy_messages(transcript.segments)
      summary_a = ungrounded_provider(messages_a, candidates)

      # ── B. Grounded path ────────────────────────────────────────────
      #
      # Use the handler's own `gather_context/2` so the grounding
      # context map is built from the seeded DB rows (not from a
      # hand-rolled stub). This proves the gather + build_messages
      # pipeline together actually deliver the entity names into the
      # system prompt.
      {:ok, context} =
        MeetingSummarize.gather_context(
          %Platform.Responsibilities.Responsibility{
            key: MeetingSummarize.key(),
            feature: "meetings",
            context_provided: ["org_identity", "recent_journal", "meeting_transcript"]
          },
          %{payload: %{transcript_id: transcript.id}}
        )

      messages_b = MeetingSummarize.build_messages(context)
      summary_b = grounded_provider(messages_b, candidates)

      snapshot_file = write_snapshot!(summary_a, summary_b)

      # The whole point — assertions on the diff. If these flip, the
      # grounding payload regressed. The snapshot file is the
      # human-readable artefact a reviewer can grep when this fails.
      project = Fixture.entity_project()
      person = Fixture.entity_person()

      assert summary_b =~ project,
             "expected grounded summary to mention #{inspect(project)} verbatim — " <>
               "snapshot at #{snapshot_file}"

      assert summary_b =~ person,
             "expected grounded summary to mention #{inspect(person)} verbatim — " <>
               "snapshot at #{snapshot_file}"

      refute summary_a =~ project,
             "expected ungrounded summary to NOT mention #{inspect(project)} — " <>
               "the legacy paraphrasing failure mode is what M8 grounding fixes. " <>
               "Snapshot at #{snapshot_file}"

      refute summary_a =~ person,
             "expected ungrounded summary to NOT mention #{inspect(person)} verbatim " <>
               "(first-name-only references are fine). Snapshot at #{snapshot_file}"

      # Belt-and-braces — the grounded system prompt itself must carry
      # both names. If `build_messages/1` regresses (e.g. someone
      # strips the grounding block again) the fake provider's
      # `visible` filter would silently fall back to paraphrases and
      # the assertions above could still pass. Lock the prompt shape.
      system_b =
        messages_b
        |> Enum.find(fn m -> m.role == "system" end)
        |> Map.fetch!(:content)

      assert system_b =~ "## Grounding context"
      assert system_b =~ project
      assert system_b =~ person
    end
  end
end
