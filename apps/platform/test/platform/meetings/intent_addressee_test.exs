defmodule Platform.Meetings.IntentAddresseeTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentAddressee` — the roster addressee
  gate (task `01a05997` stage 5), and for its wiring into
  `IntentClassifier.decide/1`.

  ## What each block is for

    * **the twin** — `"Harper, can you write that up?"` (the e2e
      reviewer's measured escape, which resolved onto Dalton) and
      `"Octavius file a ticket ..."` / `"Dalton file a ticket ..."`, a
      pair byte-identical but for the name. The pair is the whole point:
      a gate that rejects the first without passing the second has not
      learned the roster, it has learned to suppress.
    * **anti-vacuity** — `unaddressed_probe_12`'s shape (an
      agent-directed ask naming nobody) and `control_60`'s shape (an ask
      addressed by ROLE). These are legitimate positives and MUST
      survive. A gate that suppressed everything would pass the first
      block perfectly and is the obvious way this fix goes wrong.
    * **stopwords** — the discourse markers and pronouns that open a
      quarter of the recorded negatives. If these were treated as
      addressees the negatives number would improve for a reason that
      has nothing to do with the roster.
    * **end to end through `decide/1`** — the gate is only real if it
      is wired. Asserts the demotion shape, that it degrades to
      `off_topic` rather than raising, and that a gate-rejected row is
      distinguishable from a model-`off_topic` row.

  ## Named mutations — each was applied and reverted while writing this

    * **M1** — delete the `addressee_verdict/4` call from
      `gate_verdict/4` in `intent_classifier.ex` (i.e. disable the
      gate). Kills "the reviewer's measured escape is rejected", "the
      off-roster twin is rejected", and every `decide/1` test below.
      This is the disable-the-gate run pasted into the stage report.
    * **M2** — drop `String.split(role_key, "_")` from
      `roster_tokens/1`. Kills "an ask addressed by ROLE survives" —
      i.e. proves the control-slice positives depend on it.
    * **M3** — drop the `@stopwords` check from `reject_stopword/1`.
      Kills "a discourse marker is not an addressee".
    * **M4** — make `verdict/3` treat a `nil` roster as `[]`. Kills
      "a nil roster is inert".
    * **M5** — drop the `@imperative_verbs` branch from
      `bare_vocative/1`. Kills "the off-roster twin is rejected"
      (comma-less vocative), while leaving the comma cases green — which
      is what makes the two shapes separately tested rather than one
      test standing in for both.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentAddressee
  alias Platform.Meetings.IntentClassifier

  # The production roster as pinned in
  # priv/intent_eval/configs/agent_roster.json — the same one the e2e ran
  # against, so the rows below are the rows that were measured.
  @roster [
    %{role_key: "designer", agent_slug: "saru", agent_name: "Saru"},
    %{role_key: "historian", agent_slug: "higgins", agent_name: "Higgins"},
    %{role_key: "meeting_producer", agent_slug: "quickwit", agent_name: "QuickWit"},
    %{role_key: "meeting_scribe", agent_slug: "dalton", agent_name: "Dalton"},
    %{role_key: "security_guard", agent_slug: "saru", agent_name: "Saru"},
    %{role_key: "triage_officer", agent_slug: "dalton", agent_name: "Dalton"}
  ]

  describe "the twin" do
    test "the reviewer's measured escape is rejected" do
      # The exact row from e2e 01a05a10 at sha 6819cc15: classified
      # action_items / meeting_scribe / dalton at 0.9, stable 3/3.
      assert {:off_roster, "Harper"} =
               IntentAddressee.verdict(
                 "Harper, can you write that up?",
                 "write that up",
                 @roster
               )
    end

    test "the off-roster twin is rejected and its on-roster pair is not" do
      off = "Octavius file a ticket for the purse-based meeting problem."
      on = "Dalton file a ticket for the purse-based meeting problem."

      # Byte-identical but for the name. Both carry the same quote, so
      # nothing but the roster can separate them.
      quote_text = "file a ticket for the purse-based meeting problem"

      assert {:off_roster, "Octavius"} = IntentAddressee.verdict(off, quote_text, @roster)
      assert :ok = IntentAddressee.verdict(on, quote_text, @roster)
    end

    test "the remaining delegation_probe off-roster rows are rejected" do
      for text <- [
            "Chris, can you file a ticket for the purse-based meeting problem?",
            "Sam, open a task to track the flaky deploy, would you?",
            "Marcus, put together a ticket for that login timeout thing.",
            "Agent Voice, can you hear me?"
          ] do
        assert {:off_roster, _} = IntentAddressee.verdict(text, "", @roster),
               "expected #{inspect(text)} to be rejected as off-roster"
      end
    end

    test "an on-roster name in the comma-vocative position survives" do
      assert :ok =
               IntentAddressee.verdict(
                 "Dalton, we need a ticket for the way the purse thing broke the meeting.",
                 "we need a ticket",
                 @roster
               )
    end

    test "the addressee is located in the evidence_quote when the chunk hides it" do
      # The gate reads BOTH the utterance and the quote's leading
      # vocative. A quote that carries the address while the merged
      # chunk buries it must still be caught.
      assert {:off_roster, "Harper"} =
               IntentAddressee.verdict(
                 "so anyway we should probably do that. Harper, can you write that up?",
                 "Harper, can you write that up",
                 @roster
               )
    end
  end

  describe "anti-vacuity — legitimate positives must survive" do
    test "an ask that addresses nobody survives" do
      # Every row of unaddressed_probe_12. These name no agent at all;
      # suppressing them is the failure mode this gate is most likely
      # to have.
      for text <- [
            "Capture that as an action item: Rowan sends the SXI contract by Friday.",
            "Log an action item for Chris to stand up the podcast control center.",
            "Put that in the brief — Orion is SXI's brand strategy platform.",
            "Record the decision: we're shipping Tuesday.",
            "Write down that we decided not to swap models, the 2B stays.",
            "Track this open question: who owns the identity system story?",
            "Flag as an open question whether the podcast control center is in scope.",
            "Make that primary button teal instead of the blue.",
            "Bump the heading size up on the landing page, it's too small.",
            "Make the row expand on click instead of navigating away.",
            "Add a confirm step before the destructive delete.",
            "Note for the brief that the prompts live in the database, not the source."
          ] do
        assert :ok = IntentAddressee.verdict(text, "", @roster),
               "expected #{inspect(text)} to survive — it addresses nobody"
      end
    end

    test "a non-vocative person name inside the ask survives" do
      # "Chris" and "Rowan" are people and are NOT on the roster, but
      # they are the SUBJECT of the action item, not its addressee. A
      # gate that fired on any off-roster name anywhere would kill
      # both, and both are labelled positives.
      assert :ok =
               IntentAddressee.verdict(
                 "Log an action item for Chris to stand up the podcast control center.",
                 "Log an action item for Chris",
                 @roster
               )
    end

    test "an ask addressed by ROLE survives" do
      # control_60's positives. The roster block renders role keys, so a
      # name appearing in the block is addressable — see M2.
      for text <- [
            "Designer, make that primary button teal instead of the blue.",
            "Scribe, take an action item: Rowan to send the SXI contract by Friday.",
            "Historian, record the decision: we're shipping Tuesday.",
            "Triage, open question for someone: what happens to saved prompts?"
          ] do
        assert :ok = IntentAddressee.verdict(text, "", @roster),
               "expected #{inspect(text)} to survive — addressed by role key"
      end
    end

    test "an agent addressed by SLUG survives" do
      assert :ok = IntentAddressee.verdict("Quickwit, mute the room.", "", @roster)
    end
  end

  describe "stopwords" do
    test "a discourse marker is not an addressee" do
      # 26 of the 102 recorded negatives open with one of these. If the
      # gate treated them as off-roster addressees the negatives number
      # would improve without the roster doing any work.
      for text <- [
            "Yeah, but the interaction design part is probably wrong.",
            "No, actually, never mind. As an action item, Chris needs to start developing.",
            "Okay, so I think we need to build a live canvas.",
            "Um, wrong intent.",
            "Nah, I'm gonna get Harper in here.",
            "You can see tasks now.",
            "We can ask him to bring it in here.",
            "Let's put together some kind of plan here.",
            "One take. I'll break back."
          ] do
        assert IntentAddressee.addressees(text) == [],
               "expected no addressee in #{inspect(text)}"
      end
    end
  end

  describe "roster shape" do
    test "a nil roster is inert" do
      # An UNKNOWN roster is not an empty one. Gating on nil would
      # suppress every addressed utterance in the system on the strength
      # of a missing argument.
      assert :ok = IntentAddressee.verdict("Harper, can you write that up?", "", nil)
    end

    test "an empty roster rejects every addressed ask" do
      assert {:off_roster, "Dalton"} =
               IntentAddressee.verdict("Dalton file a ticket for the thing.", "", [])
    end

    test "matching is case insensitive on name and slug" do
      assert :ok = IntentAddressee.verdict("DALTON, file a ticket.", "", @roster)
      assert :ok = IntentAddressee.verdict("higgins, record the decision.", "", @roster)
    end
  end

  defmodule OffRosterProvider do
    @moduledoc false
    # The verbatim answer the deployed classifier gave for
    # "Harper, can you write that up?" — action_items, meeting_scribe,
    # 0.9, with a real verbatim citation. It passes the citation gate.
    def chat(_credentials, _messages, _opts) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": "meeting_scribe", ) <>
             ~s("confidence": 0.9, "evidence_quote": "write that up"})
       }}
    end
  end

  defmodule DeclineProvider do
    @moduledoc false
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "off_topic", "target_role": null, ) <>
             ~s("confidence": 0.9, "evidence_quote": ""})
       }}
    end
  end

  defp decide(chunk_text, roster) do
    IntentClassifier.decide(%{
      provider_module: OffRosterProvider,
      agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
      prompt: "unused — the provider is a stub",
      chunk_text: chunk_text,
      room_id: "addressee-test",
      roster: roster
    })
  end

  describe "decide/1 wiring" do
    test "an off-roster routable answer degrades to off_topic through the close path" do
      # NOT a raise, NOT an {:error, _}: the classifier's failure
      # contract is a closed skeleton, and a new crash path here would
      # take the transcript subscription down.
      assert {:ok, decision} = decide("Harper, can you write that up?", @roster)

      assert decision.intent == "off_topic"
      assert decision.evidence_quote == ""
      assert decision.demoted_from == "action_items"
      assert decision.demotion_reason == :off_roster_addressee
    end

    test "target_role is the pinned sentinel, not nil" do
      # `@no_target_role` is the string "null" and is hashed into
      # build_dedupe_key/3. A real nil here forks every historical
      # dedupe key. Commit d432067 pins it; this asserts the gate's
      # demotion path honours the same pin.
      assert {:ok, %{target_role: "null"}} = decide("Harper, can you write that up?", @roster)
    end

    test "a gate-rejected row is distinguishable from a model off_topic" do
      # Both predict off_topic. The ONLY thing telling them apart is
      # the demotion metadata — which is the point of recording it.
      {:ok, gated} = decide("Harper, can you write that up?", @roster)

      assert gated.demoted_from == "action_items"
      assert gated.demotion_reason == :off_roster_addressee

      # A genuine model decline carries neither.
      assert {:ok, declined} =
               IntentClassifier.decide(%{
                 provider_module: DeclineProvider,
                 agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
                 prompt: "unused",
                 chunk_text: "Is anything happening?",
                 room_id: "addressee-test",
                 roster: @roster
               })

      assert declined.intent == "off_topic"
      assert is_nil(declined.demoted_from)
      assert is_nil(declined.demotion_reason)
    end

    test "an on-roster routable answer is untouched" do
      assert {:ok, decision} =
               decide("Dalton, can you write that up?", @roster)

      assert decision.intent == "action_items"
      assert decision.target_role == "meeting_scribe"
      assert decision.evidence_quote == "write that up"
      assert is_nil(decision.demotion_reason)
    end

    test "an unaddressed routable answer is untouched" do
      assert {:ok, %{intent: "action_items", demotion_reason: nil}} =
               decide("Can somebody write that up?", @roster)
    end

    test "a caller that passes no roster at all is unaffected" do
      # Backwards compatibility for every existing decide/1 call site.
      assert {:ok, %{intent: "action_items"}} =
               IntentClassifier.decide(%{
                 provider_module: OffRosterProvider,
                 agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
                 prompt: "unused",
                 chunk_text: "Harper, can you write that up?",
                 room_id: "addressee-test"
               })
    end
  end
end
