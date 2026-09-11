defmodule Platform.Repo.Migrations.SeedPromptTemplateIntentClassifyTest do
  @moduledoc """
  Regression coverage for `20260707120000_seed_prompt_template_intent_classify`
  (task 019f2451 stage 1).

  Migrations run to `:up` before ExUnit boots, so we assert the
  post-state: the `meetings.intent_classify.v1` prompt template exists
  with non-empty content that encodes the load-bearing pieces of the
  classifier contract:

    * the closed intent enum (spot-check three anchors)
    * the JSON output contract fields
    * the closed target-role roster (spot-check two anchors)

  Stage 2 of this task adds a `template_slug/0` accessor to the
  `Handlers.IntentClassify` module and extends this test file with the
  drift-guard block that mirrors `seed_designer_prompt_templates_test.exs`.
  Stage 1 keeps the assertions to what the migration alone can prove —
  no handler dependency.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.IntentClassify

  @slug "meetings.intent_classify.v1"

  describe "seeded meetings.intent_classify.v1 prompt template" do
    test "exists with non-empty content" do
      assert %{content: content, name: name} = PromptTemplates.get_template_by_slug(@slug)
      assert is_binary(name) and String.trim(name) != ""
      assert is_binary(content)
      assert String.trim(content) != ""
    end

    test "content references the closed intent enum" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # Spot-check three anchors covering the routable / capture / drop cases.
      for intent <- ["visual_adjust", "off_topic", "action_items"] do
        assert content =~ intent,
               "prompt content missing intent enum anchor #{inspect(intent)}"
      end
    end

    test "content references the JSON output contract fields" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      for field <- ["intent", "target_role", "confidence", "dedupe_key"] do
        assert content =~ field,
               "prompt content missing output contract field #{inspect(field)}"
      end
    end

    test "content references the closed target-role roster" do
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      for role <- ["designer", "meeting_scribe"] do
        assert content =~ role,
               "prompt content missing target-role anchor #{inspect(role)}"
      end
    end

    test "declares the {{meeting_transcript_chunk}} variable" do
      assert %{variables: variables} = PromptTemplates.get_template_by_slug(@slug)
      assert "meeting_transcript_chunk" in variables
    end

    test "stage-2 refresh: declares context/speaker/room variables and includes the do-not-classify framing" do
      # Task 019f474d stage 2 — the row is re-written in place by
      # `20260709120000_update_intent_classify_prompt_with_context`.
      # Assert the shape the classifier now depends on: extra
      # variables + the "Prior conversation context" framing block
      # with the `{{context_lines}}` marker + the `{{speaker}}` and
      # current-utterance markers around `{{meeting_transcript_chunk}}`.
      assert %{content: content, variables: variables} =
               PromptTemplates.get_template_by_slug(@slug)

      for var <- [
            "meeting_transcript_chunk",
            "context_lines",
            "context_present",
            "speaker",
            "room_id"
          ] do
        assert var in variables,
               "stage-2 template must declare #{inspect(var)} in variables"
      end

      assert content =~ "{{context_lines}}",
             "stage-2 template must include the {{context_lines}} marker"

      assert content =~ "{{meeting_transcript_chunk}}",
             "stage-2 template must include the {{meeting_transcript_chunk}} marker"

      assert content =~ "{{speaker}}",
             "stage-2 template must include the {{speaker}} marker"

      assert content =~ "DO NOT classify these lines",
             "stage-2 template must explicitly instruct the model NOT to classify prior context"
    end

    test "stage-1 (01a03f57) refresh: off_topic is the stated default and evidence_quote is required" do
      # `20260826120000_force_update_intent_classify_prompt_off_topic_default`
      # rewrites the row. These assertions read the LIVE ROW, not source —
      # editing `do_default_templates/0` is a runtime no-op, so a failure
      # here means the migration did not reach the DB.
      assert %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      assert content =~ "evidence_quote",
             "template must require the evidence_quote output field"

      assert content =~ "THE DEFAULT ANSWER IS `off_topic`",
             "template must state off_topic as the default answer"

      assert content =~ "MOST MEETING SPEECH IS `off_topic`",
             "template must state that most meeting speech is off_topic"

      assert content =~ "is an AGENT being asked to do something?",
             "template must re-frame the judgement as whether an AGENT is being asked"

      assert content =~ "Nah, I'm gonna get Harper in here.",
             "template must carry the human-request negative exemplars"

      # Existing contract must survive the rewrite: all four original
      # output-contract fields, every render marker, and the enum anchors.
      for field <- ["intent", "target_role", "confidence", "dedupe_key"] do
        assert content =~ field,
               "rewritten template dropped output contract field #{inspect(field)}"
      end

      for marker <- [
            "{{correction_exemplars}}",
            "{{context_lines}}",
            "{{speaker}}",
            "{{meeting_transcript_chunk}}"
          ] do
        assert content =~ marker,
               "rewritten template dropped render marker #{inspect(marker)}"
      end

      for intent <- [
            "visual_adjust",
            "interaction_design",
            "action_items",
            "brief_worthy",
            "decision_recorded",
            "open_question",
            "off_topic"
          ] do
        assert content =~ intent,
               "rewritten template dropped intent enum anchor #{inspect(intent)}"
      end
    end

    test "stage-3 (01a08f9f) refresh: the agent roster grounds the addressing rule" do
      # `20260911030000_force_update_intent_classify_prompt_agent_roster_on_unmerged`
      # adds the roster to the 09-02 UN-MERGED body. Reads the LIVE ROW: this
      # slug has no `do_default_templates/0` entry at all, so source cannot be
      # the oracle here — a failure means the migration did not reach the DB.
      #
      # Re-authored, not replayed, from task 01a05997's orphaned branch
      # (`rescue/01a05997-agent-roster-d3baf101`): that body merged detection
      # and addressing into "the one question you are answering", which
      # `20260902140000` deliberately reversed on a production measurement.
      # Every assertion below is pinned to a string the 09-11 migration
      # actually writes.
      assert %{content: content, variables: variables} =
               PromptTemplates.get_template_by_slug(@slug)

      assert "agent_roster" in variables,
             "stage-3 template must declare the agent_roster variable"

      assert content =~ "{{agent_roster}}",
             "stage-3 template must include the {{agent_roster}} render marker"

      assert content =~ "# Agents available in this org",
             "stage-3 template must carry the roster section"

      # The roster must sit ABOVE the addressing question, so the model has
      # the referent before the question is posed. The 08-31 body posed ONE
      # merged question; the shipped body poses TWO, and it is question 2 —
      # TARGET — that the roster has to precede.
      roster_at = :binary.match(content, "# Agents available in this org") |> elem(0)
      question_at = :binary.match(content, "## Question 2 — TARGET") |> elem(0)

      assert roster_at < question_at,
             "the roster section must precede the addressing question"

      # The addressing rule must be stated AGAINST the roster, in both
      # directions. The 08-31 body spelled this "NAME OR SLUG ON THE ROSTER
      # ABOVE"; the shipped body spells it as prose in Question 2.
      assert content =~
               "Decide agent-or-person against the roster above, not against how the name sounds.",
             "the addressing rule must be decided against the roster, not against the name"

      assert content =~
               "If the utterance addresses a name or a slug that IS on the roster, an agent is being asked",
             "an on-roster name must be stated to be an agent"

      assert content =~
               "A name or slug that does NOT appear in this list is a person, not an agent.",
             "a name absent from the roster must be stated to be a person"

      assert content =~
               "If it addresses a name that is NOT on the roster, a person is being asked: " <>
                 "question 2's answer is `null` and question 1's intent stands unchanged.",
             "an off-roster name must resolve to target_role null, not to a dropped intent"

      # The Harper exemplar is the one 08-31 assertion that is FALSE BY
      # DESIGN now. `20260902140000` moved it from an `off_topic` negative to
      # an intent-keeping `target_role: null` case, because an off-roster name
      # no longer implies "no intent". Asserting the 08-31 sentence here would
      # re-assert the merged framing the un-merge exists to remove.
      assert content =~ "- \"Nah, I'm gonna get Harper in here.\"" and
               content =~
                 "-> `action_items`, `target_role: null` " <>
                   "(a concrete commitment; the owner is a person)",
             "the Harper exemplar must keep its intent and take a null target"

      refute content =~ "Harper is NOT on the roster above, so Harper is a person",
             "the 08-31 off_topic framing of the Harper exemplar must not come back"

      # Rebalance discipline: adding the roster must not weaken the default
      # or the evidence requirement.
      for role <- ["designer", "meeting_scribe", "historian", "triage_officer"] do
        assert content =~ "`#{role}`",
               "stage-3 template dropped target_role enum member #{inspect(role)}"
      end

      # `@no_target_role` in `Platform.Meetings.IntentClassifier` is the
      # STRING "null" and `CandidateDisplay.role_label("null")` is written
      # against this exact spelling.
      assert content =~ "  - `null`             — no clean mapping; dispatcher drops",
             "the null sentinel must remain the enum's last member, spelled `null`"

      assert content =~ "MOST MEETING SPEECH IS `off_topic`"
      assert content =~ "THE DEFAULT ANSWER IS `off_topic`"
      assert content =~ "evidence_quote"

      for marker <- [
            "{{correction_exemplars}}",
            "{{context_lines}}",
            "{{speaker}}",
            "{{meeting_transcript_chunk}}"
          ] do
        assert content =~ marker,
               "stage-3 template dropped render marker #{inspect(marker)}"
      end
    end

    test "seeded slug matches IntentClassify.template_slug/0" do
      # Drift guard (mirrors seed_designer_prompt_templates_test.exs:53-63):
      # if the handler renames its template slug without a matching
      # migration content update, the router would 404 at render time.
      # This assertion pins the handler API to the seeded row.
      slug = IntentClassify.template_slug()

      assert slug == @slug,
             "IntentClassify.template_slug/0 = #{inspect(slug)} " <>
               "does not match the seeded slug #{inspect(@slug)}"

      assert PromptTemplates.get_template_by_slug(slug) != nil,
             "IntentClassify.template_slug/0 = #{inspect(slug)} " <>
               "has no matching prompt_templates row — seed migration drift"
    end
  end
end
