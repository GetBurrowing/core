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
