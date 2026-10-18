defmodule Platform.Meetings.IntentUnaddressedActionItemTest do
  @moduledoc """
  Task 01a06575 stage 3 — an unaddressed action item KEEPS its intent.

  `20260826120000_force_update_intent_classify_prompt_off_topic_default`
  merged two questions into one and told the model, verbatim, that "if you
  cannot name the agent role being asked, there is no intent to report".
  Real meeting speech is almost never explicitly agent-addressed, so the
  classifier stopped firing (268 of 280 production candidates `off_topic`).
  `20260902140000_force_update_intent_classify_prompt_unmerge_intent_and_target`
  un-merges the questions. It does NOT revert the 26 Aug change: `off_topic`
  stays the stated default, the `evidence_quote` requirement is untouched,
  and no confidence number moves.

  ## READ THIS BEFORE ADDING AN ASSERTION — what these tests can and cannot prove

  The eval endpoint (`http://192.0.2.200:8085/v1`) was unreachable when
  this shipped, so there is NO before/after model comparison behind any of
  it. Nothing here observes a model. What it proves is exactly two things:

    1. the SEEDED ROW carries the un-merged framing — read through
       `PromptTemplates.get_template_by_slug/1` and
       `PromptTemplates.render_template/2`, never through source, because
       editing `do_default_templates/0` is a runtime no-op (`seed_defaults/0`
       is INSERT-only and `meetings.intent_classify.v1` is not in the source
       defaults at all — the row exists only because `20260707120000`
       inserted it); and
    2. the real `IntentClassifier.decide/1` pipeline — provider call, JSON
       parse, `normalise_target_role/1`, the evidence gate and the frame gate
       — carries an `action_items` answer with a JSON-`null` `target_role`
       all the way through WITHOUT demoting it.

  What it does NOT prove is that a model reading the new body actually
  answers differently. That claim is untested and must not be read into a
  green run here.

  ## Why `PromptDirectedProvider` is not a tautology, and where it stops

  The provider stub is handed the RENDERED PROMPT as its system message —
  the same message production sends — and answers what THAT PROMPT'S OWN
  EXEMPLAR TABLE prescribes for the utterance under test. The lookup
  (`prescribed_answer/2`) is a generic line parser: it reads
  `- "<utterance>"  -> \`<intent>\`[, \`target_role: <role>\`]` and is
  blind to which revision of the body it is reading. It was NOT written to
  favour the new text — point it at the 26 Aug body and it faithfully
  returns that body's `off_topic` answer for the same utterance, which is
  precisely why the mutation for this stage detonates here.

  So the stub simulates a perfectly instruction-following model, and the
  assertion is "the prompt now PRESCRIBES the right answer, and the
  pipeline does not destroy it on the way out". A real model is not
  perfectly instruction-following; that gap is the untested part.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings.IntentClassifier
  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "meetings.intent_classify.v1"

  @migration_module Platform.Repo.Migrations.ForceUpdateIntentClassifyPromptUnmergeIntentAndTarget

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260902140000_force_update_intent_classify_prompt_unmerge_intent_and_target.exs"
                  ])

  # The emblematic case: a concrete commitment whose owner is a PERSON and
  # whose exemplar line the 26 Aug body classified `off_topic`. Deliberately
  # chosen to be clean of the deterministic frame gate — it carries no
  # retraction, no `ask/tell him|her|them` delegation operator and no
  # taxonomy label — so a demotion here would be the prompt's doing and
  # not `IntentFrames`'.
  @unaddressed_action_item "Nah, I'm gonna get Sam in here."

  # The control. Present as an exemplar in BOTH revisions with the same
  # answer, so the mutation must leave this test green while turning the
  # one above red. A mutation that reddens both would prove only that the
  # body changed, not WHICH claim changed.
  @small_talk "did you catch the game last night?"

  # The passage this stage exists to delete.
  @merged_question "Detection and addressing are ONE question, not two: if you cannot name the agent role being asked, there is no intent to report."

  # Load-bearing for the demotion gate in `IntentClassifier.parse_content/3`
  # — pinned byte-for-byte so a future reword of the prompt cannot quietly
  # weaken the citation requirement the gate enforces.
  @evidence_requirement "`evidence_quote` — for ANY non-`off_topic` answer, a VERBATIM substring of the CURRENT utterance containing the ask. Copy the characters exactly; do not paraphrase, summarise, translate, or quote from the prior-context lines. For `off_topic`, `evidence_quote` MUST be the empty string `\"\"`."

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  # ── The prompt's own exemplar table, read generically ──────────────────────

  defmodule PromptDirectedProvider do
    @moduledoc """
    A perfectly instruction-following model: reads the exemplar table out of
    the system prompt it was handed and answers what that table prescribes
    for the user message (which is the chunk, verbatim — see
    `IntentClassifier.call_provider/5`).

    `prescribed_answer/2` is deliberately blind to which revision of the
    body it is reading — it parses a line shape both revisions share — so
    pointing it at the 26 Aug body returns that body's `off_topic` answer
    for the same utterance. That is what makes this stage's mutation
    detonate here rather than passing on a stub written to agree with the
    new text.

    A miss RAISES rather than guessing. `call_provider/5` wraps the call in
    a blanket rescue that would turn a guess into `{:error, :model_error}`,
    so a silent wrong answer here would be indistinguishable from a model
    failure. Every test pre-asserts the lookup before it gets here, so the
    raise is unreachable in a healthy run.
    """

    # Matches an exemplar line in either revision:
    #
    #   - "Nah, I'm gonna get Sam in here."  -> `off_topic` (a person is being pulled in)
    #   - "Nah, I'm gonna get Sam in here."  -> `action_items`, `target_role: null` (…)
    #   - "did you catch the game last night?"  -> `off_topic:small_talk`, evidence_quote `""`
    #
    # The intent is the first backticked token after the arrow, up to any
    # `:` (the dedupe-key form carries a subject there). `target_role` is
    # read only if the line states one; absent means `null`, which is the
    # correct reading for every `off_topic` line in both revisions.
    @exemplar_line ~r/^\s*-\s*"(?<utterance>[^"]*)"\s*->\s*`(?<intent>[^`]+)`(?<rest>.*)$/m
    @stated_role ~r/`target_role:\s*(?<role>[a-z_]+)`/

    @doc "What the given prompt body prescribes for `utterance`."
    def prescribed_answer(prompt, utterance) do
      matches =
        @exemplar_line
        |> Regex.scan(prompt, capture: :all_names)
        # `capture: :all_names` orders groups alphabetically: intent, rest, utterance.
        |> Enum.map(fn [intent, rest, line_utterance] ->
          %{utterance: line_utterance, intent: intent |> String.split(":") |> hd(), rest: rest}
        end)
        |> Enum.filter(&(String.downcase(&1.utterance) == String.downcase(utterance)))

      case matches do
        [one] ->
          role =
            case Regex.named_captures(@stated_role, one.rest) do
              %{"role" => "null"} -> nil
              %{"role" => role} -> role
              nil -> nil
            end

          {:ok, %{intent: one.intent, target_role: role}}

        [] ->
          {:miss, :no_exemplar}

        many ->
          {:miss, {:ambiguous, length(many)}}
      end
    end

    def chat(_credentials, messages, _opts) do
      system = role_content(messages, "system")
      chunk = role_content(messages, "user")

      case prescribed_answer(system, chunk) do
        {:ok, %{intent: "off_topic"}} ->
          {:ok, %{content: answer("off_topic", nil, 0.1, "")}}

        {:ok, %{intent: intent, target_role: role}} ->
          # The prompt's rule for a positive: a VERBATIM substring of the
          # current utterance containing the ask. The whole utterance is
          # the most conservative such substring.
          {:ok, %{content: answer(intent, role, 0.9, chunk)}}

        {:miss, reason} ->
          raise "no exemplar in the rendered prompt for #{inspect(chunk)} (#{inspect(reason)})"
      end
    end

    defp answer(intent, role, confidence, evidence) do
      Jason.encode!(%{
        "intent" => intent,
        "target_role" => role,
        "confidence" => confidence,
        "dedupe_key" => "#{intent}:test_subject",
        "evidence_quote" => evidence
      })
    end

    defp role_content(messages, role) do
      Enum.find_value(messages, "", fn message ->
        if Map.get(message, :role) == role, do: Map.get(message, :content)
      end)
    end
  end

  # Renders the LIVE ROW exactly as `IntentClassifier.resolve_prompt/6` does.
  # `render_template/2` returns `{:error, :not_found}` when the row is
  # absent, and that is the ONLY door to `@fallback_intent_prompt` — so
  # asserting `{:ok, _}` here is what guarantees these tests are measuring
  # the seeded row and not the in-source fallback.
  defp rendered_prompt!(chunk) do
    assert {:ok, prompt} =
             PromptTemplates.render_template(@slug, %{
               meeting_transcript_chunk: chunk,
               transcript_chunk: chunk,
               speaker: "alice",
               room_id: "room-unaddressed",
               context_lines: "(no prior context)",
               context_present: false,
               correction_exemplars: "(no prior corrections)"
             })

    prompt
  end

  defp decide!(chunk) do
    prompt = rendered_prompt!(chunk)

    IntentClassifier.decide(%{
      provider_module: PromptDirectedProvider,
      agent: %{model: "prompt-directed-stub"},
      prompt: prompt,
      chunk_text: chunk,
      room_id: "room-unaddressed"
    })
  end

  # ── The seeded row ────────────────────────────────────────────────────────

  describe "the live meetings.intent_classify.v1 row" do
    test "no longer tells the model an unaddressed ask has no intent" do
      %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      refute content =~ @merged_question,
             "the merged-question passage is what suppresses detection; it must be gone"

      refute content =~ "there is no intent to report"
      refute content =~ "Detection and addressing are ONE question"

      # The fallback rule carried the same claim in a second place. Deleting
      # only the headline passage would leave the model instructed to decline
      # a person-directed ask anyway.
      refute content =~ "OR the request is aimed at a person",
             "the fallback rules must stop routing person-directed asks to off_topic"

      assert content =~ "TWO questions, asked in this order"
    end

    test "still asks the addressing question — as question 2, about the TARGET" do
      %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # The 26 Aug framing is not deleted, it is DEMOTED to the target
      # question, which is the question it was always actually asking.
      assert content =~ "Question 2 — TARGET: is an AGENT being asked to do something?"

      assert content =~ "Question 1 — INTENT"

      assert content =~ "Answer question 1 WITHOUT looking at who was addressed",
             "the ordering is the whole fix; without it the two questions re-merge"
    end

    test "prescribes action_items + target_role null for a human-owned ask" do
      content = rendered_prompt!(@unaddressed_action_item)

      assert {:ok, %{intent: "action_items", target_role: nil}} =
               PromptDirectedProvider.prescribed_answer(content, @unaddressed_action_item)
    end

    test "still prescribes off_topic for small talk" do
      content = rendered_prompt!(@small_talk)

      assert {:ok, %{intent: "off_topic"}} =
               PromptDirectedProvider.prescribed_answer(content, @small_talk)
    end

    test "does NOT revert the 26 Aug change" do
      %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # off_topic stays the stated default.
      assert content =~ "THE DEFAULT ANSWER IS `off_topic`"
      assert content =~ "MOST MEETING SPEECH IS `off_topic`"

      # The evidence requirement is byte-identical — the demotion gate in
      # `parse_content/3` enforces exactly this.
      assert content =~ @evidence_requirement,
             "the verbatim evidence_quote requirement must survive this stage unchanged"

      # Both enums stay closed and complete.
      for intent <- [
            "off_topic",
            "visual_adjust",
            "interaction_design",
            "action_items",
            "brief_worthy",
            "decision_recorded",
            "open_question"
          ] do
        assert content =~ intent
      end

      for role <- ["designer", "meeting_scribe", "historian", "triage_officer"] do
        assert content =~ role
      end

      # Render markers survive, or the row interpolates to a broken prompt.
      for marker <- [
            "{{correction_exemplars}}",
            "{{context_lines}}",
            "{{speaker}}",
            "{{meeting_transcript_chunk}}"
          ] do
        assert content =~ marker
      end
    end

    test "moves no confidence number and adds no graduation threshold" do
      %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # The two thresholds the 26 Aug body set, unchanged.
      assert content =~ "`confidence < 0.5`"
      assert content =~ "`confidence >= 0.7`"

      # And no others. A threshold tuned to force graduation converts
      # silence into noise, which is a worse failure than silence: 268
      # off_topic at high confidence is a model that is confidently wrong.
      thresholds =
        ~r/`confidence\s*[<>]=?\s*[0-9.]+`/
        |> Regex.scan(content)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      assert thresholds == ["`confidence < 0.5`", "`confidence >= 0.7`"]
    end

    test "does not let the intent -> role mapping smuggle a target back in" do
      %{content: content} = PromptTemplates.get_template_by_slug(@slug)

      # `action_items -> meeting_scribe` is still in the mapping table, so
      # without this note the model could read every action item as
      # addressed to the scribe and `target_role: null` would never appear.
      assert content =~ "`action_items`, `brief_worthy`         -> `meeting_scribe`"

      assert content =~
               "It does not mean every `action_items` answer routes to `meeting_scribe`"
    end
  end

  # ── The real decide/1 pipeline ────────────────────────────────────────────

  describe "IntentClassifier.decide/1 on the rendered live row" do
    test "an unaddressed action item keeps its intent and carries a null target" do
      # Pre-assert the lookup so a table-shape change fails HERE, legibly,
      # rather than inside the stub where `call_provider/5`'s blanket rescue
      # would relabel it `:model_error`.
      assert {:ok, _} =
               PromptDirectedProvider.prescribed_answer(
                 rendered_prompt!(@unaddressed_action_item),
                 @unaddressed_action_item
               )

      assert {:ok, decision} = decide!(@unaddressed_action_item)

      assert decision.intent == "action_items",
             "an ask with a human owner must keep its intent; got #{inspect(decision.intent)}"

      assert decision.target_role == IntentClassifier.no_target_role(),
             "an unaddressed ask routes to nobody — the dispatcher drops it, " <>
               "so it cannot reach the wrong agent"

      # The evidence gate and the frame gate both had to pass. A demotion
      # would have rewritten intent to "off_topic" and set demoted_from,
      # producing a decision that is byte-identical to a genuine decline
      # apart from this field.
      assert decision.demoted_from == nil,
             "the positive must survive parse_content/3's demotion, not be laundered through it"

      assert decision.confidence >= 0.7,
             "the prompt's own no-role-maps rule pins this at >= 0.7"
    end

    test "small talk still declines, and declines cleanly" do
      assert {:ok, decision} = decide!(@small_talk)

      assert decision.intent == "off_topic"
      assert decision.target_role == IntentClassifier.no_target_role()

      assert decision.demoted_from == nil,
             "a genuine decline is NOT a demotion — conflating them is how the " <>
               "demotion counter reported a permanent zero"
    end

    test "the two cases are actually distinguished, not both answered the same way" do
      # Guards against a stub (or a prompt) that has collapsed to one answer.
      # Without this, both tests above could pass a body that says
      # `action_items` for everything, or a body that says `off_topic` for
      # everything would at least still fail the first — but the reverse
      # asymmetry is worth pinning explicitly.
      assert {:ok, positive} = decide!(@unaddressed_action_item)
      assert {:ok, decline} = decide!(@small_talk)

      refute positive.intent == decline.intent
    end
  end

  # ── The migration is the only thing that moves the row ────────────────────

  describe "up/0 against a deployed-shaped (26 Aug) row" do
    # The 26 Aug body's load-bearing claim, standing in for the whole
    # deployed body. A full copy would only assert that two literals in
    # this repo match each other.
    @stale_content """
    You are the Meeting Producer's `meetings.intent_classify` classifier.

    # The one question you are answering: is an AGENT being asked to do something?

    #{@merged_question}

    Negative exemplars — all of these are real requests, and all of them are `off_topic`:
      - "Nah, I'm gonna get Sam in here."                                 -> `off_topic` (a person is being pulled in)
      - "did you catch the game last night?"                              -> `off_topic` (small talk)
    """

    defp stale_the_row! do
      template = PromptTemplates.get_template_by_slug(@slug)
      refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

      {:ok, staled} = PromptTemplates.update_template(template, %{content: @stale_content})

      # Before-state, asserted rather than assumed — otherwise every
      # assertion below could be true of the row this test started with.
      assert staled.content =~ @merged_question
      refute staled.content =~ "TWO questions, asked in this order"

      staled
    end

    test "rewrites the row, deleting the merged-question claim" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      refute reloaded.content =~ @merged_question
      assert reloaded.content =~ "TWO questions, asked in this order"
      assert reloaded.content =~ @evidence_requirement
    end

    test "the classifier reads the migrated row, not the source fallback" do
      stale_the_row!()

      # A staled row is still a PRESENT row, so `render_template/2` serves
      # it and the in-source `@fallback_intent_prompt` is unreachable. This
      # is the check that makes the mutation for this stage meaningful: if
      # reverting the row did NOT change what the classifier answers, the
      # test would be reading source instead of the DB.
      assert {:ok, %{intent: "off_topic"}} =
               PromptDirectedProvider.prescribed_answer(
                 rendered_prompt!(@unaddressed_action_item),
                 @unaddressed_action_item
               )

      assert :ok = @migration_module.up()

      assert {:ok, %{intent: "action_items", target_role: nil}} =
               PromptDirectedProvider.prescribed_answer(
                 rendered_prompt!(@unaddressed_action_item),
                 @unaddressed_action_item
               )
    end

    test "seed_defaults/0 does NOT repair the stale row — the migration is load-bearing" do
      staled = stale_the_row!()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug(@slug)

      assert after_seed.content == staled.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only), which " <>
               "is exactly why editing do_default_templates/0 would ship as a no-op"

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content =~ "TWO questions"
    end

    test "is idempotent — a second up/0 changes nothing" do
      stale_the_row!()

      assert :ok = @migration_module.up()
      first = PromptTemplates.get_template_by_slug(@slug).content

      assert :ok = @migration_module.up()
      assert PromptTemplates.get_template_by_slug(@slug).content == first
    end

    test "skips an absent row rather than inserting one" do
      template = PromptTemplates.get_template_by_slug(@slug)
      refute is_nil(template)
      {:ok, _} = PromptTemplates.delete_template(template)

      assert :ok = @migration_module.up()

      assert is_nil(PromptTemplates.get_template_by_slug(@slug)),
             "up/0 must skip an absent row — 20260707120000 owns first insert"
    end
  end
end
