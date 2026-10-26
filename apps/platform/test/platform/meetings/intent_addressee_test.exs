defmodule Platform.Meetings.IntentAddresseeTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentAddressee` — the roster addressee
  gate (task `01a05997` stage 5), and for its wiring into
  `IntentClassifier.decide/1`.

  ## What each block is for

    * **the twin** — `"Blake, can you write that up?"` (the e2e
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

  ## Reported speech (task `01a0e58f`, acceptance 1(a))

  An addressed name on neither the agent roster nor the meeting's
  participant list means the speaker is REPORTING speech aimed at
  someone who is not in the room. The shape was filed from the
  2026-09-14 one-to-one; every row is synthesised, and every name in it
  is invented.

    * **M-a1** — make `participant_tokens/1` inert for every list.
      Measured: 4 failures of 195 — "an addressee who is not in the room
      is absent", "a participant's user name and its tokens count as
      present", and the two `:reported_speech` tests in
      `intent_classifier_test.exs` (`decide/1` and `classify_and_enqueue`).
    * **M-a2** — map `{:absent, _}` to the null path in
      `IntentClassifier.addressee_verdict` instead of the demotion.
      Measured: 2 failures of 195 — the same two classifier tests. This
      file stays green, as it should: `verdict/4` still answers
      `{:absent, _}`; only the classifier's mapping changed.
    * **M-a3** — drop `participants:` from the `decide/1` call in
      `classify_and_enqueue/4`. Measured: 1 failure of 195 — the
      `classify_and_enqueue` reported-speech test, the only one that
      exercises the real participant read.
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
      assert {:off_roster, "Blake"} =
               IntentAddressee.verdict(
                 "Blake, can you write that up?",
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
            "Casey, can you file a ticket for the purse-based meeting problem?",
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
      assert {:off_roster, "Blake"} =
               IntentAddressee.verdict(
                 "so anyway we should probably do that. Blake, can you write that up?",
                 "Blake, can you write that up",
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
            "Capture that as an action item: Alex sends the Globex contract by Friday.",
            "Log an action item for Casey to stand up the podcast control center.",
            "Put that in the brief — Atlas is Globex's brand strategy platform.",
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
      # "Casey" and "Alex" are people and are NOT on the roster, but
      # they are the SUBJECT of the action item, not its addressee. A
      # gate that fired on any off-roster name anywhere would kill
      # both, and both are labelled positives.
      assert :ok =
               IntentAddressee.verdict(
                 "Log an action item for Casey to stand up the podcast control center.",
                 "Log an action item for Casey",
                 @roster
               )
    end

    test "an ask addressed by ROLE survives" do
      # control_60's positives. The roster block renders role keys, so a
      # name appearing in the block is addressable — see M2.
      for text <- [
            "Designer, make that primary button teal instead of the blue.",
            "Scribe, take an action item: Alex to send the Globex contract by Friday.",
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
            "No, actually, never mind. As an action item, Casey needs to start developing.",
            "Okay, so I think we need to build a live canvas.",
            "Um, wrong intent.",
            "Nah, I'm gonna get Sam in here.",
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
      assert :ok = IntentAddressee.verdict("Blake, can you write that up?", "", nil)
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
    # "Blake, can you write that up?" — action_items, meeting_scribe,
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

  defmodule ModelNullProvider do
    @moduledoc false
    # The answer 20260902140000 instructs for an ask aimed at nobody in
    # particular: a routable intent, a real citation, and the JSON
    # literal `null` for the role. This is the row the gate's output
    # must be indistinguishable from (bar the marker).
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": null, ) <>
             ~s("confidence": 0.9, "evidence_quote": "write that up"})
       }}
    end
  end

  defmodule ModelNullStringProvider do
    @moduledoc false
    # ModelNullProvider with the role spelled as the STRING "null".
    # `normalise_target_role/1` folds JSON null onto this same string, so
    # both spellings must reach the addressee gate as one value.
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": "null", ) <>
             ~s("confidence": 0.9, "evidence_quote": "write that up"})
       }}
    end
  end

  defmodule UncitedProvider do
    @moduledoc false
    # A routable answer with a BLANK citation: the citation gate's
    # demotion path, used as the anti-vacuity partner for "the addressee
    # gate no longer demotes".
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": "meeting_scribe", ) <>
             ~s("confidence": 0.9, "evidence_quote": ""})
       }}
    end
  end

  defp decide(chunk_text, roster, provider \\ OffRosterProvider) do
    IntentClassifier.decide(%{
      provider_module: provider,
      agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
      prompt: "unused — the provider is a stub",
      chunk_text: chunk_text,
      room_id: "addressee-test",
      roster: roster
    })
  end

  @off_roster_event [:platform, :meetings, :intent_classifier, :off_roster_addressee]
  @room_id "addressee-test"

  defp attach_off_roster_telemetry! do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @off_roster_event,
        # Telemetry handlers are global and this file is async: only
        # forward events from THIS file's room, or a concurrent harness
        # test's off-roster row (room "intent-eval") lands in the
        # refute_receive below.
        fn _event, measurements, %{room_id: @room_id} = meta, _config ->
          send(parent, {:off_roster_addressee, measurements, meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "decide/1 wiring" do
    # RULING (task 01a08fde, 2026-09-11, Alex: gate). Migration
    # 20260902140000 says an ask aimed at a person KEEPS its intent and
    # takes `target_role: null`; the gate now applies that rule instead
    # of demoting to off_topic. Every test in this block pins one half
    # of that contract.

    test "an off-roster routable answer keeps its intent and quote and routes to nobody" do
      # NOT a raise, NOT an {:error, _}: the classifier's failure
      # contract is a closed skeleton, and a new crash path here would
      # take the transcript subscription down.
      assert {:ok, decision} = decide("Blake, can you write that up?", @roster)

      # The model's own answer survives ...
      assert decision.intent == "action_items"
      assert decision.evidence_quote == "write that up"
      assert decision.confidence == 0.9
      # ... only the role is rewritten, and the marker says which one was.
      assert decision.target_role == "null"
      assert decision.addressee_nulled_from == "meeting_scribe"
      # Nothing was demoted.
      assert is_nil(decision.demoted_from)
      assert is_nil(decision.demotion_reason)
    end

    test "target_role is the pinned sentinel, not nil" do
      # `@no_target_role` is the string "null" and is hashed into
      # build_dedupe_key/3. A real nil here forks every historical
      # dedupe key. Commit d432067 pins it; this asserts the gate's
      # null path honours the same pin.
      assert {:ok, %{target_role: "null"}} = decide("Blake, can you write that up?", @roster)
    end

    test "a gate-nulled row is distinguishable from the model's own null" do
      # Both are action_items routed to nobody. The ONLY thing telling
      # them apart is `addressee_nulled_from` — which is the point of
      # recording it, and the strongest claim this stage makes: the
      # gate's output differs from the model-null answer by exactly
      # that key.
      {:ok, gated} = decide("Blake, can you write that up?", @roster)
      {:ok, model_null} = decide("Can somebody write that up?", @roster, ModelNullProvider)

      assert gated.intent == "action_items"
      assert model_null.intent == "action_items"
      assert gated.target_role == "null"
      assert model_null.target_role == "null"

      assert gated.addressee_nulled_from == "meeting_scribe"
      assert is_nil(model_null.addressee_nulled_from)

      # Key-set and value diff: same keys, one differing value.
      assert Map.keys(gated) |> Enum.sort() == Map.keys(model_null) |> Enum.sort()

      differing =
        gated
        |> Map.keys()
        |> Enum.filter(&(Map.fetch!(gated, &1) != Map.fetch!(model_null, &1)))

      assert differing == [:addressee_nulled_from]
    end

    test "an on-roster routable answer is untouched" do
      assert {:ok, decision} =
               decide("Dalton, can you write that up?", @roster)

      assert decision.intent == "action_items"
      assert decision.target_role == "meeting_scribe"
      assert decision.evidence_quote == "write that up"
      assert is_nil(decision.addressee_nulled_from)
      assert is_nil(decision.demotion_reason)
    end

    test "an unaddressed routable answer is untouched" do
      assert {:ok, %{intent: "action_items", demotion_reason: nil, addressee_nulled_from: nil}} =
               decide("Can somebody write that up?", @roster)
    end

    test "a caller that passes no roster at all is unaffected" do
      # Backwards compatibility for every existing decide/1 call site.
      assert {:ok, %{intent: "action_items", target_role: "meeting_scribe"}} =
               IntentClassifier.decide(%{
                 provider_module: OffRosterProvider,
                 agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
                 prompt: "unused",
                 chunk_text: "Blake, can you write that up?",
                 room_id: "addressee-test"
               })
    end

    test "the off_roster_addressee telemetry still fires, carrying the model's intent and the overwritten role" do
      # The production-side half of the distinction: an operator
      # counting off-roster asks still gets one event per rewrite, and
      # the event names the role the gate threw away.
      attach_off_roster_telemetry!()

      assert {:ok, _} = decide("Blake, can you write that up?", @roster)

      assert_receive {:off_roster_addressee, %{count: 1}, meta}
      assert meta.intent == "action_items"
      assert meta.raw_target_role == "meeting_scribe"
      assert meta.reason == :off_roster_addressee
      assert meta.room_id == "addressee-test"
      # Exactly one.
      refute_receive {:off_roster_addressee, _, _}, 50
    end

    test "the on-roster twin fires no off_roster_addressee event" do
      # Anti-vacuity partner: a gate that nulled every addressed ask
      # would pass the Blake case and fail here.
      attach_off_roster_telemetry!()

      assert {:ok, %{target_role: "meeting_scribe"}} =
               decide("Dalton, can you write that up?", @roster)

      refute_receive {:off_roster_addressee, _, _}, 50
    end

    test "the demotion path no longer fires for an off-roster addressee" do
      assert {:ok, decision} = decide("Blake, can you write that up?", @roster)
      assert is_nil(decision.demoted_from)
      assert is_nil(decision.demotion_reason)

      # Anti-vacuity: an uncited positive on the SAME call path still
      # comes back demoted, so this cannot pass because demotion is
      # broken globally.
      assert {:ok, demoted} = decide("Blake, can you write that up?", @roster, UncitedProvider)
      assert demoted.intent == "off_topic"
      assert demoted.demoted_from == "action_items"
      assert demoted.demotion_reason == :blank
      assert is_nil(demoted.addressee_nulled_from)
    end

    # Task 01a0919d. An off-roster ask whose model answer ALREADY routes to
    # nobody has nothing for the gate to rewrite: no marker, no event. The
    # OffRosterProvider tests above are the anti-vacuity partner — the
    # same Blake chunk with a real role still gets both.

    test "an off-roster ask the model already routed to nobody (JSON null) is not marked or counted" do
      attach_off_roster_telemetry!()

      assert {:ok, decision} =
               decide("Blake, can you write that up?", @roster, ModelNullProvider)

      assert decision.intent == "action_items"
      assert decision.target_role == "null"
      assert decision.evidence_quote == "write that up"
      assert is_nil(decision.addressee_nulled_from)
      assert is_nil(decision.demoted_from)
      assert is_nil(decision.demotion_reason)

      refute_receive {:off_roster_addressee, _, _}, 100
    end

    test "an off-roster ask the model already routed to nobody (string \"null\") is not marked or counted" do
      attach_off_roster_telemetry!()

      assert {:ok, decision} =
               decide("Blake, can you write that up?", @roster, ModelNullStringProvider)

      assert decision.intent == "action_items"
      assert decision.target_role == "null"
      assert decision.evidence_quote == "write that up"
      assert is_nil(decision.addressee_nulled_from)
      assert is_nil(decision.demoted_from)
      assert is_nil(decision.demotion_reason)

      refute_receive {:off_roster_addressee, _, _}, 100
    end

    test "a model-null answer to an off-roster ask equals the model-null answer to an unaddressed ask" do
      {:ok, off_roster} = decide("Blake, can you write that up?", @roster, ModelNullProvider)
      {:ok, unaddressed} = decide("Can somebody write that up?", @roster, ModelNullProvider)

      assert off_roster == unaddressed
    end
  end

  # ── REPORTED SPEECH (task 01a0e58f) ───────────────────────────────
  #
  # Shape filed from the 2026-09-14 one-to-one. Rows are synthesised;
  # names are invented.
  describe "verdict/4 — an addressee who is not in the room" do
    @participants [
      %{display_name: "Priya", user: %{name: "Priya Okafor"}, agent: nil},
      %{display_name: "Dana", user: nil, agent: nil}
    ]

    @scribe_roster [
      %{role_key: "meeting_scribe", agent_slug: "rafe", agent_name: "Rafe"}
    ]

    @absent_line "Tobias, can you send the deck over by Friday?"

    # M-a1 kills this.
    test "an addressee who is not in the room is absent" do
      assert {:absent, "Tobias"} =
               IntentAddressee.verdict(
                 @absent_line,
                 "send the deck over by Friday",
                 @roster,
                 @participants
               )
    end

    # Ruling 01a08fde is unchanged for people in the room: a present
    # human who is not an agent keeps the null-role path.
    test "the same line with the addressee in the room is off_roster, not absent" do
      participants = [%{display_name: "Tobias", user: nil, agent: nil} | @participants]

      assert {:off_roster, "Tobias"} =
               IntentAddressee.verdict(
                 @absent_line,
                 "send the deck over by Friday",
                 @roster,
                 participants
               )
    end

    test "a participant's user name and its tokens count as present" do
      participants = [%{display_name: nil, user: %{name: "Kasia Nowak"}, agent: nil}]

      assert {:off_roster, "Kasia"} =
               IntentAddressee.verdict(
                 "Kasia, can you send the deck over?",
                 "",
                 @roster,
                 participants
               )

      assert {:absent, "Marcus"} =
               IntentAddressee.verdict(
                 "Marcus, can you send the deck over?",
                 "",
                 @roster,
                 participants
               )
    end

    test "an ask addressed to an agent by role is untouched" do
      assert :ok =
               IntentAddressee.verdict(
                 "Scribe, log that Dana owns the deck",
                 "log that Dana owns the deck",
                 @scribe_roster,
                 @participants
               )
    end

    test "an unaddressed ask is untouched" do
      assert :ok =
               IntentAddressee.verdict(
                 "Record the decision: we ship Tuesday.",
                 "Record the decision: we ship Tuesday.",
                 @roster,
                 @participants
               )
    end

    # A live utterance implies at least one participant row, so an empty
    # list is a failed read, not a fact — and nil is no read at all.
    # Both must behave exactly as `verdict/3`.
    test "nil and [] participants are inert and match verdict/3 exactly" do
      for participants <- [nil, []] do
        assert {:off_roster, "Tobias"} =
                 IntentAddressee.verdict(@absent_line, "", @roster, participants)

        assert IntentAddressee.verdict(@absent_line, "", @roster, participants) ==
                 IntentAddressee.verdict(@absent_line, "", @roster)

        assert :ok =
                 IntentAddressee.verdict(
                   "Record the decision: we ship Tuesday.",
                   "",
                   @roster,
                   participants
                 )
      end
    end

    test "a nil roster is inert whatever the participants" do
      assert :ok = IntentAddressee.verdict(@absent_line, "", nil, @participants)
    end
  end
end
