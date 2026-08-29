defmodule Platform.Meetings.CandidateSkeletonTest do
  @moduledoc """
  Tests for the pre-classification candidate write (task 01a04a7f).

  The behaviour under test: a transcript chunk that clears the content
  gate gets a `meeting_candidates` row the moment it is HEARD, before
  the model is asked anything. That row carries the utterance and no
  classification. When the classifier answers 1.5-3s later the row is
  RECONCILED in place — same row, classified fields filled in — and when
  the classifier never produces a queue row the skeleton is CLOSED
  instead. A card that appears and never resolves is the failure this
  whole file exists to rule out.

  ## Why the row count is the assertion, not "a card exists"

  Every "it worked" assertion here is paired with a count. The two
  failure modes this change can produce are both invisible to a
  presence check:

    * `create_or_attach/1` failing to find the skeleton writes a SECOND
      row — one shimmering skeleton and one real card for one sentence.
    * `create_or_attach/1` finding the skeleton but writing nothing
      leaves ONE row that never classifies — the permanent ghost.

  A `Candidates.get(...)` that merely returns something passes in both.

  ## The non-fatal mirror

  Both write paths are wrapped so a Postgres failure degrades to a log
  line (`IntentQueue.Server`'s `mirror/1`, and `record_heard/5` +
  `close_skeleton/4` in `IntentClassifier`). A green run therefore
  proves nothing unless it ASSERTS THE ROWS. Nothing below asserts the
  absence of an error.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"

  # Utterances. Every one has to clear `content_bearing?/1` or the
  # classifier never runs and the scenario is vacuous — asserted, with a
  # positive control, in the first test below.
  @dashboard "we should make the dashboard load faster"
  @follow_up "make that mobile only"
  @unrelated "can someone book the offsite room"
  @filler "yeah"

  defmodule StubProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  setup do
    agent = create_agent!("intent-agent-skeleton")
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

    target = create_agent!("intent-target-skeleton")
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", target.id)

    meeting_id = Ecto.UUID.generate()
    room_id = Ecto.UUID.generate()
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    %{meeting_id: meeting_id, room_id: room_id, agent: agent, target: target}
  end

  defp create_agent!(prefix) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{prefix}-#{System.unique_integer([:positive])}",
      name: "Intent Agent",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp start_classifier!(opts \\ []) do
    name = :"candidate_skeleton_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {IntentClassifier,
         opts
         |> Keyword.put_new(:provider_module, StubProvider)
         |> Keyword.put_new(:debounce_ms, 150)
         |> Keyword.put(:name, name)}
      )

    pid
  end

  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  # The classifier demotes any non-off_topic classification whose
  # `evidence_quote` is not a verbatim span of the chunk, so a fixed
  # stub has to echo the chunk it was shown.
  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
    end)
  end

  defp classification(messages, overrides \\ %{}) do
    {:ok,
     %{
       content:
         %{
           "intent" => "visual_adjust",
           "target_role" => "designer",
           "confidence" => 0.91,
           "evidence_quote" => echo_quote(messages)
         }
         |> Map.merge(overrides)
         |> Jason.encode!()
     }}
  end

  defp say(context, speaker, text, chunk_id \\ nil) do
    chunk_id = chunk_id || Ecto.UUID.generate()

    :ok =
      MeetingsPubSub.broadcast_transcript_chunk(context.room_id, %{
        room_id: context.room_id,
        meeting_id: context.meeting_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{id: chunk_id, text: text, speaker_name: speaker}
      })

    chunk_id
  end

  # Broadcast and wait for the classified intent the chunk produced.
  defp say!(context, speaker, text, chunk_id \\ nil) do
    chunk_id = say(context, speaker, text, chunk_id)
    assert_receive {:intent_classified, row}, 3_000
    {chunk_id, row}
  end

  defp rows(context), do: Candidates.list_for_meeting(context.meeting_id)

  # ── the scenario's own premise ────────────────────────────────────────────

  test "every scenario utterance clears the content gate, and the gate can say no" do
    for text <- [@dashboard, @follow_up, @unrelated] do
      assert IntentClassifier.content_bearing?(text),
             "#{inspect(text)} never reaches the classifier, so any scenario built " <>
               "on it is green and meaningless"
    end

    # POSITIVE CONTROL on the gate: it is capable of answering false, so
    # the three assertions above are not trivially true — and this is
    # the utterance the "no skeleton for a filtered chunk" test uses.
    refute IntentClassifier.content_bearing?(@filler)
  end

  # ── S1: the skeleton exists BEFORE the classifier answers ────────────────

  describe "the skeleton write" do
    test "a heard chunk gets a row while the model call is still in flight", context do
      pid = start_classifier!()
      test_pid = self()

      # The stub BLOCKS inside the classifier's own process. Everything
      # asserted between `:classifier_called` and `:release` is a fact
      # about the world while the model has not answered — which is the
      # only window in which the claim "a skeleton exists" means
      # anything at all.
      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:classifier_called, messages})

        receive do
          :release -> classification(messages)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
      chunk_id = say(context, "alice", @dashboard)

      assert_receive {:classifier_called, _messages}, 3_000

      # THE ASSERTION. One row, and it does not know what it is yet.
      assert [skeleton] = rows(context),
             "expected exactly one skeleton while the classifier was blocked"

      assert skeleton.state == :heard
      assert skeleton.transcript_chunk_id == chunk_id
      assert skeleton.transcript_chunk_ids == [chunk_id]
      assert skeleton.evidence_quote == @dashboard
      assert skeleton.speaker == "alice"
      assert skeleton.heard_at
      assert skeleton.last_utterance_at == skeleton.heard_at

      # CATCHES THE VACUOUS VERSION. Every one of these is nil, so this
      # really is a pre-classification row and not the classified row
      # the shipped mirror already wrote. Without this block the test
      # passes unchanged against `main`, where the row appears a couple
      # of seconds later carrying all six fields.
      refute skeleton.classified_intent
      refute skeleton.classifier_confidence
      refute skeleton.classifier_model
      refute skeleton.target_role
      refute skeleton.assigned_agent_id
      refute skeleton.intent_id

      # The queue really is empty at this instant — the row above cannot
      # be a mirror of something already enqueued.
      assert IntentQueue.list(context.meeting_id) == []

      send(pid, :release)
      assert_receive {:intent_classified, _row}, 3_000
    end

    test "a chunk the content gate rejects gets NO row", context do
      pid = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:classifier_called, messages})
        classification(messages)
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      say(context, "alice", @filler)
      refute_receive {:classifier_called, _}, 800

      assert rows(context) == [],
             "a chunk that never reaches the classifier must not open a card"

      # POSITIVE CONTROL, same meeting and same run: the identical call
      # shape DOES produce a row for an utterance that clears the gate.
      # Without it, a `record_heard/1` that had simply stopped writing
      # would pass the assertion above.
      {_chunk_id, _row} = say!(context, "alice", @dashboard)
      assert [row] = rows(context)
      assert row.evidence_quote == @dashboard
    end

    test "replaying the same chunk id does not open a second card", context do
      pid = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts -> classification(messages) end)
      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      chunk_id = Ecto.UUID.generate()
      {^chunk_id, first} = say!(context, "alice", @dashboard, chunk_id)

      # Same chunk id, DIFFERENT text — so the resolver's topic overlap
      # cannot be what collapses this to one row. The chunk-id key is
      # the only thing that can.
      _ = say(context, "bruno", @unrelated, chunk_id)
      Process.sleep(600)

      assert [only] = rows(context),
             "the same transcript chunk must never produce two cards"

      # Positive control that the replay was actually PROCESSED and not
      # simply dropped upstream: the queue holds the second intent.
      assert length(IntentQueue.list(context.meeting_id)) == 2

      # The card still belongs to the FIRST classification. A replayed
      # chunk id must not let a second intent relabel somebody else's
      # card — which is exactly what a reconcile keyed on the chunk id
      # alone, with no "is this still a skeleton" check, would do.
      assert only.intent_id == first.id
      assert only.evidence_quote == @dashboard
      assert only.speaker == "alice"
    end
  end

  # ── S2: reconcile in place, do not open a second row ─────────────────────

  describe "reconciliation" do
    test "the classifier's answer lands on the SAME row the skeleton opened", context do
      pid = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:classifier_called, messages})

        receive do
          :release -> classification(messages)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
      chunk_id = say(context, "alice", @dashboard)

      assert_receive {:classifier_called, _}, 3_000
      assert [before] = rows(context)
      refute before.classified_intent

      send(pid, :release)
      assert_receive {:intent_classified, intent}, 3_000

      # ONE row, and it is the SAME row. Identity is the assertion:
      # "a classified card exists" is also true of an implementation
      # that ignored the skeleton and inserted alongside it, and that
      # implementation is the ghost this ticket exists to prevent.
      assert [reconciled] = rows(context),
             "the classifier's answer must update the skeleton, not open a second card"

      assert reconciled.id == before.id
      assert reconciled.transcript_chunk_id == chunk_id

      # All six classified fields, by value.
      assert reconciled.classified_intent == "visual_adjust"
      assert reconciled.classifier_confidence == 0.91
      assert reconciled.target_role == "designer"
      assert reconciled.assigned_agent_id == context.target.id
      assert reconciled.assigned_agent_slug == context.target.slug

      assert reconciled.intent_id == intent.id
      assert reconciled.queue_status == "queued"

      # PRE-EXISTING HOLE, recorded rather than glossed. `classifier_model`
      # mirrors the queue row's `model_used`, and NOTHING in the
      # classifier ever writes that field — it is nil on `main` too. So
      # "all six classified fields" is really five plus this. Asserted
      # against the queue row so the day somebody starts populating it,
      # this line keeps telling the truth instead of going stale.
      assert reconciled.classifier_model == intent.model_used
      refute intent.model_used

      # THE ACCEPTED COST, recorded rather than left to be discovered.
      # `heard_at` now stamps ARRIVAL, not enqueue: the card's first
      # sight is when the human spoke, which is strictly earlier than
      # the moment the model answered. Anything reading `heard_at` as
      # "when the queue row was made" is reading it wrong from here on.
      assert DateTime.compare(reconciled.heard_at, intent.enqueued_at) == :lt
      assert reconciled.heard_at == before.heard_at

      # And the skeleton's accretion columns survived the reconcile —
      # they are NOT overwritten with the create-shaped values the
      # mirror builds.
      assert reconciled.transcript_chunk_ids == [chunk_id]
      assert reconciled.threading_events == []

      # Still findable the way every downstream transition finds it.
      assert Candidates.get_by_intent_id(intent.id).id == before.id
    end

    test "a decline reconciles onto the skeleton and then closes it", context do
      pid = start_classifier!()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        text = echo_quote(messages)

        if String.contains?(text, "offsite") do
          classification(messages, %{
            "intent" => "off_topic",
            "target_role" => nil,
            "confidence" => 0.12
          })
        else
          classification(messages)
        end
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      {_fired_chunk, fired} = say!(context, "alice", @dashboard)
      {declined_chunk, declined} = say!(context, "bruno", @unrelated)

      assert length(rows(context)) == 2

      declined_row = Candidates.get_by_intent_id(declined.id)
      assert declined_row.transcript_chunk_id == declined_chunk
      assert declined_row.classified_intent == "off_topic"

      # The decline's terminal arc, driven through the queue transition
      # the dispatcher uses. Nothing new is built here — this asserts
      # the SHIPPED close still reaches the skeleton now that the row
      # was opened by a different writer.
      {:ok, _} =
        IntentQueue.transition(context.meeting_id, declined.id, :dispatch_failed, %{
          dispatch_error: "no target role"
        })

      declined_row = Repo.get!(MeetingCandidate, declined_row.id)
      assert declined_row.state == :closed
      assert declined_row.disposition == :rejected
      assert declined_row.closed_reason == :dismissed
      assert declined_row.closed_at

      # CATCHES THE VACUOUS VERSION, same meeting and same run: the
      # utterance that FIRED did not take that path. An implementation
      # that closed every skeleton on classifier return passes every
      # assertion above and fails here.
      fired_row = Candidates.get_by_intent_id(fired.id)
      assert fired_row.state == :heard
      refute fired_row.closed_reason
      refute fired_row.closed_at
      refute fired_row.disposition
      assert fired_row.classified_intent == "visual_adjust"
    end
  end

  # ── S3: threading survived moving to the arrival clock ───────────────────

  describe "threading through the skeleton path" do
    test "PROVES IT WORKS: two related utterances from one speaker yield ONE card", context do
      pid = start_classifier!()
      plant_stub_fun(pid, fn _creds, messages, _opts -> classification(messages) end)
      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      {first_chunk, first} = say!(context, "alice", @dashboard)
      {second_chunk, second} = say!(context, "alice", @follow_up)

      # The queue still holds two intents — threading is a decision
      # about the candidate mirror, not about the queue.
      assert length(IntentQueue.list(context.meeting_id)) == 2
      refute first.id == second.id

      assert [card] = rows(context),
             "the follow-up must accrete onto the first card, not open a second"

      # THE assertion is the chunk id list. "One row exists" is also
      # true of an implementation that dropped the second utterance's
      # write altogether, which is worse than the bug.
      assert card.transcript_chunk_ids == [first_chunk, second_chunk]
      assert [event] = card.threading_events
      assert event["reason"]["rule"] == "anaphoric_fragment"
      assert event["transcript_chunk_id"] == second_chunk

      # Attaching is not lifecycle progress, and the host keeps its own
      # classification — the attached utterance does not overwrite it.
      assert card.state == :heard
      assert card.intent_id == first.id
      assert card.evidence_quote == @dashboard
      refute Candidates.get_by_intent_id(second.id)

      # The clock moved, and it moved to the ARRIVAL of the second
      # utterance — earlier than the moment its classification landed.
      assert DateTime.compare(card.last_utterance_at, card.heard_at) == :gt
      assert DateTime.compare(card.last_utterance_at, second.enqueued_at) == :lt
    end

    test "CATCHES THE VACUOUS VERSION: two unrelated utterances from one speaker yield TWO cards",
         context do
      pid = start_classifier!()
      plant_stub_fun(pid, fn _creds, messages, _opts -> classification(messages) end)
      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      {first_chunk, first} = say!(context, "alice", @dashboard)
      {second_chunk, second} = say!(context, "alice", @unrelated)

      assert length(rows(context)) == 2,
             "same speaker inside the window must not be enough to thread"

      dashboard = Candidates.get_by_intent_id(first.id)
      offsite = Candidates.get_by_intent_id(second.id)

      assert dashboard.transcript_chunk_ids == [first_chunk]
      assert offsite.transcript_chunk_ids == [second_chunk]
      assert dashboard.threading_events == []
      assert offsite.threading_events == []

      # POSITIVE CONTROLS that the :new answer came from the
      # relatedness floor and not from a broken scenario: the speaker
      # gate and the window gate were both satisfied.
      assert dashboard.speaker == "alice"
      assert offsite.speaker == "alice"
      assert DateTime.diff(offsite.heard_at, dashboard.heard_at, :second) <= 60
    end
  end

  # ── the ticket's S3, and why it is not built ─────────────────────────────

  describe "an unclassified skeleton is never offered to the resolver" do
    test "no chunk can be processed while another chunk's model call is in flight", context do
      pid = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        send(test_pid, {:classifier_called, echo_quote(messages)})

        receive do
          :release -> classification(messages)
        after
          5_000 -> {:error, :never_released}
        end
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
      first_chunk = say(context, "alice", @dashboard)
      assert_receive {:classifier_called, @dashboard}, 3_000

      # A skeleton exists and it is UNCLASSIFIED. This is the row the
      # ticket's stage 3 proposed filtering out of `open_for_meeting/1`.
      assert [skeleton] = rows(context)
      refute skeleton.classified_intent

      # Now say something else while that model call is still blocked.
      second_chunk = say(context, "alice", @follow_up)

      # THE ASSERTION, and the reason stage 3 is not built: the
      # classifier is ONE GenServer and `decide/1` is a synchronous call
      # inside `handle_info/2`, so the second chunk cannot be looked at
      # until the first one's model call returns. There is no instant at
      # which the resolver is handed an unclassified skeleton, so a
      # filter excluding one would have nothing to exclude — and it
      # would have to exclude ordinary `:heard` rows too, which are
      # legitimate attachment targets that task 01a03fb9 shipped.
      refute_receive {:classifier_called, @follow_up}, 500

      assert [^skeleton] = rows(context),
             "a second chunk must not be able to open a card while the first " <>
               "chunk's classification is still in flight"

      send(pid, :release)
      assert_receive {:classifier_called, @follow_up}, 3_000
      send(pid, :release)

      assert_receive {:intent_classified, _}, 3_000
      assert_receive {:intent_classified, _}, 3_000

      # POSITIVE CONTROL that the second chunk was real and was
      # eventually processed — otherwise the refute above would pass for
      # a chunk that was simply dropped. It threaded onto the first
      # card, which is exactly what it should do once that card knows
      # what it is.
      assert [card] = rows(context)
      assert card.id == skeleton.id
      assert card.classified_intent == "visual_adjust"
      assert card.transcript_chunk_ids == [first_chunk, second_chunk]
    end
  end

  # ── S5: nothing downstream can close it, so the classifier does ──────────

  describe "skeletons the queue will never see" do
    test "a classifier error closes the skeleton as timed_out/dismissed", context do
      pid = start_classifier!()
      test_pid = self()

      plant_stub_fun(pid, fn _creds, messages, _opts ->
        text = echo_quote(messages)
        send(test_pid, {:classifier_called, text})

        # Undecodable completion — the classifier's `:parse_error` arm.
        if String.contains?(text, "dashboard"),
          do: {:ok, %{content: "not json at all"}},
          else: classification(messages)
      end)

      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
      broken_chunk = say(context, "alice", @dashboard)
      assert_receive {:classifier_called, _}, 3_000

      # No queue row will ever exist for this chunk, so nothing
      # downstream can move its card. This is the entire ghost surface.
      wait_for(fn ->
        row = Enum.find(rows(context), &(&1.transcript_chunk_id == broken_chunk))
        row && row.state == :closed
      end)

      broken = Enum.find(rows(context), &(&1.transcript_chunk_id == broken_chunk))

      assert broken.state == :closed
      assert broken.closed_reason == :dismissed
      # NOT `:rejected` — nobody rejected anything, the model failed to
      # answer. A measurement query counting human rejections must not
      # see this row.
      assert broken.disposition == :timed_out
      assert broken.closed_note =~ "parse_error"
      assert broken.closed_at
      refute broken.classified_intent

      # Positive control on the premise: the queue really is empty for
      # this chunk, so the close came from the classifier and not from
      # a queue transition.
      assert IntentQueue.list(context.meeting_id) == []

      # CATCHES THE VACUOUS VERSION, same meeting and same run: a chunk
      # whose classification SUCCEEDS is not closed. An implementation
      # that closed every skeleton passes everything above.
      {_ok_chunk, ok_intent} = say!(context, "bruno", @unrelated)
      ok_row = Candidates.get_by_intent_id(ok_intent.id)
      assert ok_row.state == :heard
      refute ok_row.closed_reason
      refute ok_row.closed_at
    end

    test "a deduped utterance closes its skeleton as a duplicate", context do
      pid = start_classifier!()
      plant_stub_fun(pid, fn _creds, messages, _opts -> classification(messages) end)
      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      # SAME text, DIFFERENT speaker. Different speaker means the
      # resolver refuses to thread, so a second skeleton really is
      # opened — and the dedupe key (intent + role + text) is
      # speaker-independent, so the queue refuses the second intent.
      # Both halves are asserted below rather than assumed.
      {first_chunk, first} = say!(context, "alice", @dashboard)
      second_chunk = say(context, "bruno", @dashboard)

      wait_for(fn ->
        row = Enum.find(rows(context), &(&1.transcript_chunk_id == second_chunk))
        row && row.state == :closed
      end)

      assert length(rows(context)) == 2,
             "a different speaker must open its own card, or this test proves nothing " <>
               "about dedupe"

      duplicate = Enum.find(rows(context), &(&1.transcript_chunk_id == second_chunk))
      assert duplicate.state == :closed
      assert duplicate.closed_reason == :duplicate
      assert duplicate.closed_note =~ "deduped"
      refute duplicate.disposition

      # Positive control on the premise: the queue holds ONE intent, so
      # the second really was a dedupe hit.
      assert [only] = IntentQueue.list(context.meeting_id)
      assert only.id == first.id

      # And the original card is untouched.
      original = Enum.find(rows(context), &(&1.transcript_chunk_id == first_chunk))
      assert original.state == :heard
      refute original.closed_reason
      assert original.classified_intent == "visual_adjust"
    end

    test "THE ACCEPTED COST: a chunk with no usable id keeps the old behaviour exactly",
         context do
      pid = start_classifier!()
      plant_stub_fun(pid, fn _creds, messages, _opts -> classification(messages) end)
      :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

      # A non-UUID segment id cannot be a reconciliation key, so no
      # skeleton is opened for it and the row appears only when the
      # classifier answers — `main`'s behaviour, unchanged. This is a
      # real gap (LiveKit segments that are not UUIDs get no early
      # card), and it is recorded here rather than left to be found.
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk(context.room_id, %{
          room_id: context.room_id,
          meeting_id: context.meeting_id,
          transcript_id: "transcript-not-a-uuid",
          segment: %{id: "seg-not-a-uuid", text: @dashboard, speaker_name: "alice"}
        })

      assert_receive {:intent_classified, intent}, 3_000

      assert [row] = rows(context)
      assert row.intent_id == intent.id
      assert row.classified_intent == "visual_adjust"
      # The tell: `heard_at` is the ENQUEUE clock, because no skeleton
      # ever stamped an arrival.
      assert row.heard_at == intent.enqueued_at
      refute row.transcript_chunk_id
    end
  end

  # Polls rather than sleeping a fixed amount: the close happens inside
  # the classifier's own process after the model call returns, and there
  # is no message to wait on because a failed classification emits no
  # `intent_classified`.
  defp wait_for(fun, attempts \\ 60) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && wait_for(fun, attempts - 1)
    end
  end
end
