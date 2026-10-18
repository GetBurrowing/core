defmodule Platform.Meetings.IntentAddresseeRoutingTest do
  @moduledoc """
  Task 01a08fde stage 2 — a gate-nulled row and a model-null row are the
  SAME row to everything downstream of `IntentClassifier.decide/1`.

  Stage 1 made the addressee gate stop demoting: an ask aimed at someone
  off the roster (`"Sam, can you write that up?"`) now keeps its
  intent and takes `target_role: "null"` — the same string
  `normalise_target_role/1` writes when the model itself answers the JSON
  literal `null` for an unaddressed ask (`"Can somebody please write that
  up?"`). Migration `20260902140000` intended both to route the same way.

  This file changes NO production code. It pins the equivalence at every
  layer that reads `target_role`, so a later change to either spelling
  cannot silently reintroduce a difference:

    1. `IntentRouting.routable?/2`
    2. `Candidates.routable_attrs?/1` (arms/disarms the countdown card)
    3. the `IntentQueue` row `classify_and_enqueue/4` writes, field by
       field against the model-null twin
    4. `IntentDispatcher`'s fork: an `action_items`/`"null"` row takes the
       responsibility path; a `pull_numbers`/`"null"` row (no
       responsibility row) fails `:no_target_role`

  ## Named mutations — each applied and reverted while writing this

    * **M1** — in `normalise_target_role/1`, `{:ok, nil} -> {:ok, "none"}`.
      The two spellings of nobody diverge. Kills the `target_role`
      equality in block 1 and the field-by-field diff in block 3. NB
      `IntentRouting.routable?/2` alone would NOT catch this: for an
      intent with a responsibility row the role is never consulted, so
      the routing answer is `true` for `"null"` and `"none"` alike. The
      spelling assertion is what carries the detection.
    * **M2** — in stage 1's `{:null_role, :off_roster_addressee}` clause,
      `target_role: nil` instead of `@no_target_role`. Kills block 1
      (`nil != "null"`) and block 3: `build_dedupe_key/3` hashes an
      iolist and `nil` is not iodata, so the classifier never enqueues.

  ## Why `async: false` and `DataCase`

  Blocks 3 and 4 boot a real `IntentClassifier` / `IntentDispatcher`
  under `start_supervised/1`; both subscribe to application-global PubSub
  topics and the per-meeting queue supervisor is global. Blocks 1 and 2
  need neither, but one module cannot be half-async.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentRouting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  @off_roster "Sam, can you write that up?"
  # Six tokens, so `content_bearing?/1` keeps it on word count alone and
  # the model-null twin cannot be dropped before the model is asked.
  @unaddressed "Can somebody please write that up?"

  # An intent with NO responsibility row that is not `off_topic`. Both
  # halves are asserted in the blocks that use it.
  @unrouted_intent "pull_numbers"

  @responsibility_key "meetings.intent_classify"

  # The roster `decide/1` is handed directly in blocks 1 and 2. Sam is
  # not on it; the scribe is, so a gate-nulled row cannot be explained by
  # an empty roster rejecting everything.
  @roster [
    %{role_key: "meeting_scribe", agent_slug: "dalton", agent_name: "Dalton"},
    %{role_key: "designer", agent_slug: "saru", agent_name: "Saru"}
  ]

  # ── Stub providers ────────────────────────────────────────────────────────

  defmodule OffRosterProvider do
    @moduledoc false
    # The deployed classifier's verbatim answer for @off_roster: a
    # routable intent, a real role, a verbatim citation. The gate is the
    # only thing that touches it.
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": "meeting_scribe", ) <>
             ~s("confidence": 0.9, "evidence_quote": "write that up"})
       }}
    end
  end

  defmodule ModelNullProvider do
    @moduledoc false
    # What 20260902140000 instructs for an ask aimed at nobody: the same
    # intent and citation with the JSON literal `null` for the role.
    def chat(_c, _m, _o) do
      {:ok,
       %{
         content:
           ~s({"intent": "action_items", "target_role": null, ) <>
             ~s("confidence": 0.9, "evidence_quote": "write that up"})
       }}
    end
  end

  # ONE stub for the booted classifier in block 3, branching on the chunk
  # it is shown so both rows come off the same code path.
  defmodule BranchingProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      shown =
        Enum.find_value(messages, "", fn message ->
          role = Map.get(message, :role) || Map.get(message, "role")
          if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
        end)

      if String.contains?(shown, "Sam") do
        Platform.Meetings.IntentAddresseeRoutingTest.OffRosterProvider.chat(
          credentials,
          messages,
          opts
        )
      else
        Platform.Meetings.IntentAddresseeRoutingTest.ModelNullProvider.chat(
          credentials,
          messages,
          opts
        )
      end
    end
  end

  defp decide(chunk_text, provider) do
    IntentClassifier.decide(%{
      provider_module: provider,
      agent: %{base_url: "http://stub", model: "classifier", vault_key: nil},
      prompt: "unused — the provider is a stub",
      chunk_text: chunk_text,
      room_id: "addressee-routing-test",
      roster: @roster
    })
  end

  # The two decisions this whole file is about. Pre-asserted here so a
  # block that reads them cannot be vacuously comparing two failures.
  defp twins! do
    assert {:ok, gated} = decide(@off_roster, OffRosterProvider)
    assert {:ok, model_null} = decide(@unaddressed, ModelNullProvider)

    assert gated.addressee_nulled_from == "meeting_scribe",
           "the gate did not fire on #{inspect(@off_roster)}; nothing below measures it"

    assert is_nil(model_null.addressee_nulled_from)

    {gated, model_null}
  end

  defp attrs_for(%{intent: intent, target_role: target_role}) do
    %{classified_intent: intent, target_role: target_role}
  end

  # ── 1. IntentRouting ──────────────────────────────────────────────────────

  describe "IntentRouting" do
    test "gate-nulled and model-null decisions are indistinguishable to IntentRouting" do
      {gated, model_null} = twins!()

      # The spelling is the load-bearing half (see M1 in the moduledoc):
      # both must be THE sentinel, not merely something routable.
      assert gated.target_role == IntentClassifier.no_target_role()
      assert model_null.target_role == IntentClassifier.no_target_role()
      assert gated.target_role == model_null.target_role

      gated_routable = IntentRouting.routable?(gated.intent, gated.target_role)
      model_null_routable = IntentRouting.routable?(model_null.intent, model_null.target_role)

      assert gated_routable == model_null_routable
      assert gated_routable == true

      # Routable BECAUSE of the responsibility row, not because "null" is
      # a role. The sentinel itself resolves nobody.
      assert IntentRouting.responsibility_key("action_items") == "meetings.action_items"
      assert IntentRouting.routable_role?(IntentClassifier.no_target_role()) == false
      assert IntentRouting.routable_role?(gated.target_role) == false
    end

    test "an intent with no responsibility row routes to nobody in both spellings" do
      # Premise: unrouted AND not unroutable, or the control proves nothing.
      assert IntentRouting.entry(@unrouted_intent) == nil
      refute IntentRouting.unroutable_intent?(@unrouted_intent)

      {gated, model_null} = twins!()

      assert IntentRouting.routable?(@unrouted_intent, gated.target_role) == false
      assert IntentRouting.routable?(@unrouted_intent, model_null.target_role) == false
    end
  end

  # ── 2. Candidates.routable_attrs?/1 ───────────────────────────────────────

  describe "Candidates.routable_attrs?/1" do
    test "arms both shapes the same way" do
      {gated, model_null} = twins!()

      assert Candidates.routable_attrs?(attrs_for(gated)) == true
      assert Candidates.routable_attrs?(attrs_for(model_null)) == true

      # Both spellings the arming path sees — `mirror_enqueue/3` writes
      # atoms, `put_derived_org_id/1`'s callers can write strings.
      assert Candidates.routable_attrs?(%{
               "classified_intent" => gated.intent,
               "target_role" => gated.target_role
             }) == true
    end

    test "an intent with no responsibility row disarms both shapes" do
      # This is the intended "nobody" outcome for a runtime-served intent
      # that named no role, NOT a defect of the gate: with no
      # responsibility row the only remaining route is the role's
      # runtime, and "null" is nobody's runtime. A card for it must not
      # count down towards a dispatch that cannot happen.
      assert IntentRouting.entry(@unrouted_intent) == nil

      {gated, model_null} = twins!()

      assert Candidates.routable_attrs?(%{
               classified_intent: @unrouted_intent,
               target_role: gated.target_role
             }) == false

      assert Candidates.routable_attrs?(%{
               classified_intent: @unrouted_intent,
               target_role: model_null.target_role
             }) == false
    end
  end

  # ── 3. The queue row ──────────────────────────────────────────────────────

  defp create_agent!(prefix, name) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{prefix}-#{System.unique_integer([:positive])}",
      name: name,
      status: "active"
    })
    |> Repo.insert!()
  end

  # Seeds the roster the booted classifier renders and the gate judges
  # against: `resolve_prompt/6` reads `Roles.assigned_agents/0`, which
  # joins role_assignments to agents. The scribe is ON the roster, under
  # a name that is not Sam, so `target_agent_id == nil` below is the
  # sentinel's doing and not an unassigned role's.
  defp seed_roster! do
    classifier_agent = create_agent!("intent-agent-routing", "Classifier")
    {:ok, _} = Roles.set_override(@responsibility_key, classifier_agent.id)

    scribe = create_agent!("intent-scribe-routing", "Dalton")
    :ok = Roles.unassign_role("meeting_scribe")
    {:ok, _} = Roles.assign_role("meeting_scribe", scribe.id)

    roster = Roles.assigned_agents()
    assert Enum.any?(roster, &(&1.role_key == "meeting_scribe" and &1.agent_name == "Dalton"))
    refute Enum.any?(roster, &(&1.agent_name == "Sam" or &1.agent_slug == "sam"))

    scribe
  end

  defp start_classifier! do
    name = :"addressee_routing_classifier_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {IntentClassifier, [provider_module: BranchingProvider, debounce_ms: 150, name: name]}
      )

    pid
  end

  defp say!(meeting_id, room_id, speaker, text) do
    chunk_id = Ecto.UUID.generate()

    :ok =
      MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
        room_id: room_id,
        meeting_id: meeting_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{id: chunk_id, text: text, speaker_name: speaker}
      })

    assert_receive {:intent_classified, %{transcript_chunk_id: ^chunk_id} = row}, 3_000
    row
  end

  # Everything that MUST differ between two rows built from two different
  # utterances: identity, ordering, timestamps, and the fields that are
  # (or hash) the chunk text itself. Note this list is wider than
  # "dedupe_key and ids/timestamps": `chunk_excerpt` IS the text,
  # `transcript_chunk_id` is per chunk, and `speaker` differs because the
  # two lines are said by two people so `ThreadResolver` cannot fold them.
  @necessarily_different [
    :id,
    :seq,
    :enqueued_at,
    :dedupe_key,
    :chunk_excerpt,
    :transcript_chunk_id,
    :speaker
  ]

  describe "the queue row" do
    test "carries the kept intent and the sentinel role, and no agent" do
      scribe = seed_roster!()

      for text <- [@off_roster, @unaddressed] do
        assert IntentClassifier.content_bearing?(text),
               "#{inspect(text)} never reaches the classifier; the scenario is vacuous"
      end

      meeting_id = Ecto.UUID.generate()
      room_id = Ecto.UUID.generate()
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      start_classifier!()
      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      gated = say!(meeting_id, room_id, "alice", @off_roster)
      model_null = say!(meeting_id, room_id, "bruno", @unaddressed)

      refute gated.id == model_null.id

      # The gate-nulled row, on its own terms.
      assert gated.classified_intent == "action_items"
      assert gated.target_role == IntentClassifier.no_target_role()
      assert gated.target_role == "null"
      assert is_nil(gated.target_agent_id)
      assert is_nil(gated.target_agent_slug)
      assert is_nil(gated.demoted_from)
      assert is_binary(gated.chunk_excerpt) and gated.chunk_excerpt != ""
      assert gated.chunk_excerpt =~ "Sam"
      assert gated.confidence == 0.9

      # The scribe IS assigned — so nil above is the sentinel resolving
      # nobody, not a missing fixture.
      assert Roles.agent_id_for_role("meeting_scribe") == scribe.id

      # And the twin agrees on every field that does not encode which
      # utterance it was. Computed as a diff rather than asserted
      # field-by-field so a NEW field on the row is caught the moment it
      # diverges rather than the next time someone lists it here.
      assert Map.keys(gated) |> Enum.sort() == Map.keys(model_null) |> Enum.sort()

      differing =
        gated
        |> Map.keys()
        |> Enum.filter(&(Map.fetch!(gated, &1) != Map.fetch!(model_null, &1)))
        |> Enum.sort()

      assert differing == Enum.sort(@necessarily_different),
             "gate-nulled and model-null rows differ on #{inspect(differing -- @necessarily_different)}"

      # The read-back, not the broadcast: the rows the queue holds.
      assert {:ok, ^gated} = IntentQueue.get(meeting_id, gated.id)
      assert {:ok, ^model_null} = IntentQueue.get(meeting_id, model_null.id)
    end
  end

  # ── 4. IntentDispatcher ───────────────────────────────────────────────────

  defp new_meeting! do
    meeting_id = Platform.Types.UUIDv7.generate()
    {:ok, _pid} = IntentQueue.ensure_started(meeting_id)
    on_exit(fn -> IntentQueue.stop(meeting_id) end)
    meeting_id
  end

  defp start_dispatcher! do
    name = :"addressee_routing_dispatcher_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({IntentDispatcher, name: name, tick_interval_ms: 60_000})
    # Let `init/1` finish subscribing before the enqueue, or the first
    # notify lands in nobody's mailbox.
    Process.sleep(20)
    name
  end

  defp enqueue!(meeting_id, attrs) do
    {:ok, row} =
      IntentQueue.enqueue(
        meeting_id,
        Map.merge(
          %{
            room_id: "room-#{System.unique_integer([:positive])}",
            dedupe_key: "dk-#{System.unique_integer([:positive])}",
            chunk_excerpt: @off_roster,
            confidence: 0.9,
            transcript_chunk_id: "chunk-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    row
  end

  defp await_status(meeting_id, intent_id, expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_status(meeting_id, intent_id, expected, deadline)
  end

  defp do_await_status(meeting_id, intent_id, expected, deadline) do
    {:ok, row} = IntentQueue.get(meeting_id, intent_id)

    cond do
      row.status == expected ->
        row

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "expected intent #{intent_id} to reach #{inspect(expected)}, got #{inspect(row.status)}"
        )

      true ->
        Process.sleep(10)
        do_await_status(meeting_id, intent_id, expected, deadline)
    end
  end

  describe "IntentDispatcher" do
    setup do
      # Shared sandbox so the queue supervisor's children can see this
      # test's schema — mirrors `IntentDispatcherTest`.
      Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})
      :ok
    end

    test "an action_items row with the sentinel role takes the responsibility fork" do
      # A scribe is assigned so the fork has an assignee to stamp; the
      # role was never consulted to get there.
      scribe = create_agent!("intent-scribe-dispatch", "Dalton")
      :ok = Roles.unassign_role("meeting_scribe")
      {:ok, _} = Roles.assign_role("meeting_scribe", scribe.id)

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:action_item_intent")

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: "action_items",
          target_role: IntentClassifier.no_target_role()
        })

      assert_receive {:action_item_intent, payload}, 1_000
      assert payload.intent_id == row.id
      assert payload.classified_intent == "action_items"

      dispatched = await_status(meeting_id, row.id, :dispatched)
      assert dispatched.target_role == "null"
      assert is_nil(dispatched.dispatch_failure_reason)
      # Stamped from the RESPONSIBILITY's assignee at dispatch time — the
      # one place an agent is attached to a "null" row, and it is the
      # same place a model-null row gets one.
      assert dispatched.target_agent_id == scribe.id
    end

    test "an unrouted intent with the sentinel role fails :no_target_role" do
      assert IntentRouting.entry(@unrouted_intent) == nil
      refute IntentRouting.unroutable_intent?(@unrouted_intent)

      meeting_id = new_meeting!()
      start_dispatcher!()

      row =
        enqueue!(meeting_id, %{
          classified_intent: @unrouted_intent,
          target_role: IntentClassifier.no_target_role()
        })

      failed = await_status(meeting_id, row.id, :dispatch_failed)
      assert failed.dispatch_failure_reason == :no_target_role
      assert is_nil(failed.target_agent_id)

      # Retained, cursor free.
      assert [^failed] = IntentQueue.list(meeting_id)
      assert IntentQueue.cursor(meeting_id) == nil
    end
  end
end
