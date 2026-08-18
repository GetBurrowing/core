defmodule Platform.Regression.MeetingsTopicScopeLeakTest do
  @moduledoc """
  Task 019ffca8 stage 5 — scoped leak tests for the `Platform.Meetings.PubSub`
  topics that have both a bare and a room-scoped arity.

  ## What this file generalises

  On 2026-08-06, PR core#676 fixed a `transcript_chunk` broadcast on an unscoped
  topic that let a subscriber receive a sibling's chunk. The fix bound the refute
  to `%{transcript_id: ^id}`. One instance found and closed; nobody had asked
  since whether it was the only one. This file asks, for every meetings topic
  built the same way. They are the highest-yield targets in stage 2's inventory
  because `broadcast_transcript_chunk/2` and `broadcast_meeting_finished/2`
  publish the SAME event term on a canonical topic AND a per-room one from a
  single call, which is the construction core#676 got wrong.

  The sibling file `global_topic_scope_leak_test.exs` covers the chat and audit
  topics; `Platform.PubSubLeakHelpers` carries the machinery both use and
  explains the watcher-process design.

  ## The anti-vacuity contract

  A test asserting "no message leaked" passes trivially against a system that
  delivered nothing at all: a broken broadcast would read as a security pass. So
  EVERY refute here is paired, IN THE SAME TEST, with a positive control proving
  the legitimate subscriber DID receive what it was entitled to.

  For the bare-vs-scoped topics that is the core#676 shape exactly: a `watcher/2`
  process holds the scoped subscription while the test process holds the bare
  one, the foreign event is broadcast inline, the test process `assert_receive`s
  it on the bare topic (proof it really was on the wire), the scoped watcher is
  refuted, and then the scoped watcher's OWN event is asserted on the SAME
  subscription (proof that subscription delivers at all).

  `meeting:intent_enqueued` has no scoped sibling by design, so its test pins the
  payload keyset instead. `meeting:<id>:intents` has no bare sibling, so its
  wire-proof comes from the entitled subscriber.

  ## async: false

  These tests hold subscriptions on process-global topics that every other test
  in the run broadcasts onto. Assertions are scoped by fixture id wherever an id
  exists, so the sync setting is belt and braces rather than the load-bearing
  part, but the mailbox is cleaner for it.

  ## What is deliberately NOT here

  Changing any topic's design, and adding any guard. This stage writes tests.
  """
  use Platform.DataCase, async: false

  import Platform.PubSubLeakHelpers

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Transcript

  defp unique, do: System.unique_integer([:positive])

  defp transcript_for_new_room! do
    {:ok, transcript} =
      Meetings.create_transcript(%{room_id: "space-#{Ecto.UUID.generate()}", status: "recording"})

    transcript
  end

  defp segment(text) do
    %{
      "participant_identity" => "user-#{unique()}",
      "text" => text,
      "start_time" => 0,
      "end_time" => 500
    }
  end

  # ── meeting:transcript_chunk — the core#676 shape itself ───────────────────

  describe "meeting:transcript_chunk vs meeting:transcript_chunk:<room_id>" do
    test "a room-scoped subscriber never receives a sibling room's chunk, and does receive its own" do
      ours = transcript_for_new_room!()
      theirs = transcript_for_new_room!()
      our_id = ours.id
      their_id = theirs.id

      # The scoped subscription — what a per-room consumer holds.
      watcher(:room_ours, fn -> MeetingsPubSub.subscribe_transcript_chunk(ours.room_id) end)

      # The bare subscription, for this process, purely to prove the wire.
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      # Foreign traffic, through the real production path.
      assert {:ok, %Transcript{}} =
               Meetings.append_segment(theirs.id, segment("sibling-room-speech"))

      # PROOF THE EVENT WAS ON THE WIRE. Scoped to `their_id` because the bare
      # topic is process-global: every append anywhere in the run lands here.
      assert_receive {:transcript_chunk, %{transcript_id: ^their_id}}, 1_000

      # THE LEAK ASSERTION: the other room's consumer got none of it.
      refute_receive {:room_ours, {:transcript_chunk, %{transcript_id: ^their_id}}}, 300

      # POSITIVE CONTROL on the SAME subscription that was just refuted.
      # Without it the refute above also passes on a build where
      # `subscribe_transcript_chunk/1` silently subscribes to nothing.
      assert {:ok, %Transcript{}} = Meetings.append_segment(ours.id, segment("our own room"))

      assert_receive {:room_ours, {:transcript_chunk, %{transcript_id: ^our_id}}},
                     1_000,
                     "the room-scoped subscription delivered nothing even for its OWN room, " <>
                       "so the refute above was passing for the wrong reason"

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end

    test "the sibling room's speech text is not derivable from anything the scoped subscriber holds" do
      ours = transcript_for_new_room!()
      theirs = transcript_for_new_room!()
      our_id = ours.id
      secret = "verbatim-speech-#{unique()}"

      watcher(:room_ours, fn -> MeetingsPubSub.subscribe_transcript_chunk(ours.room_id) end)
      assert :ok = MeetingsPubSub.subscribe_transcript_chunk()

      assert {:ok, %Transcript{}} = Meetings.append_segment(theirs.id, segment(secret))

      # POSITIVE CONTROL, and the fact that makes this topic worth testing at
      # all: the canonical topic carries the utterance TEXT verbatim, so a
      # per-user subscriber on it would be a content leak rather than a metadata
      # one. Stage 2's verdict rests on the only subscribers being supervised
      # singletons, and `pubsub_topic_inventory_audit_test.exs` pins that set.
      assert_receive {:transcript_chunk, %{segment: %{"text" => ^secret}}}, 1_000

      # Same subscription, its own room, so the scoped watcher is proven live
      # before anything is refuted about it.
      assert {:ok, %Transcript{}} = Meetings.append_segment(ours.id, segment("our own room"))
      assert_receive {:room_ours, {:transcript_chunk, %{transcript_id: ^our_id}}}, 1_000

      # THE LEAK ASSERTION: nothing the scoped watcher relayed contains the
      # foreign text, in any field, at any depth. `assert_receive` leaves
      # non-matching messages in the mailbox, so a leaked copy — broadcast
      # BEFORE the positive control — is still queued here to be found.
      relayed = for {:room_ours, msg} <- collect(300), do: msg

      refute_any_mentions(
        relayed,
        secret,
        "the room-scoped transcript subscription relayed a sibling room's utterance text:"
      )

      MeetingsPubSub.unsubscribe_transcript_chunk()
    end
  end

  # ── meeting:finished — the same dual-publish shape ─────────────────────────

  describe "meeting:finished vs meeting:finished:<room_id>" do
    test "a room-scoped subscriber never receives a sibling room's finish, and does receive its own" do
      our_room = "space-#{Ecto.UUID.generate()}"
      their_room = "space-#{Ecto.UUID.generate()}"
      our_transcript = Ecto.UUID.generate()
      their_transcript = Ecto.UUID.generate()

      watcher(:room_ours, fn -> MeetingsPubSub.subscribe_meeting_finished(our_room) end)
      assert :ok = MeetingsPubSub.subscribe_meeting_finished()

      # `broadcast_meeting_finished/2` IS the dual-publish seam under test. The
      # production callers (LiveKit webhook, transcript finaliser) reach it
      # through layers that add nothing to the topic contract.
      MeetingsPubSub.broadcast_meeting_finished(their_room, %{
        transcript_id: their_transcript,
        room_id: their_room,
        space_id: Ecto.UUID.generate()
      })

      assert_receive {:meeting_finished, %{transcript_id: ^their_transcript}}, 1_000

      refute_receive {:room_ours, {:meeting_finished, %{transcript_id: ^their_transcript}}}, 300

      MeetingsPubSub.broadcast_meeting_finished(our_room, %{
        transcript_id: our_transcript,
        room_id: our_room,
        space_id: Ecto.UUID.generate()
      })

      assert_receive {:room_ours, {:meeting_finished, %{transcript_id: ^our_transcript}}},
                     1_000,
                     "the room-scoped meeting_finished subscription delivered nothing even for " <>
                       "its OWN room, so the refute above was passing for the wrong reason"

      MeetingsPubSub.unsubscribe_meeting_finished()
    end
  end

  # ── meeting:intent_enqueued — global with NO scoped sibling ────────────────

  describe "meeting:intent_enqueued" do
    # `intent_enqueued_topic/0` has no per-meeting mirror, deliberately: the
    # consumer is the IntentDispatcher singleton (see the @doc on
    # `intent_enqueued_topic/0`). So there is no scoped subscription to refute
    # against and the protection has to be the payload. It is a drain wake-up:
    # the keys the dispatcher drains BY, and nothing about what was said.
    test "the drain wake-up carries only routing keys, never utterance content" do
      meeting_id = Ecto.UUID.generate()
      room_id = "space-#{Ecto.UUID.generate()}"

      assert :ok = MeetingsPubSub.subscribe_intent_enqueued()

      MeetingsPubSub.broadcast_intent_enqueued(%{meeting_id: meeting_id, room_id: room_id})

      # POSITIVE CONTROL: the wake-up is on the wire and reaches the global
      # subscriber. Bound to `^meeting_id` on purpose — this is a process-global
      # topic and `IntentQueue.Server.notify_drain/1` fires on cursor release
      # from any queue server still alive in the run, so an unbound receive
      # would occasionally bind a foreign meeting's wake-up and fail the next
      # line for a reason it does not assert.
      assert_receive {:intent_enqueued, %{meeting_id: ^meeting_id} = payload}, 1_000

      # THE LEAK ASSERTION. Not "the excerpt is absent from this fixture" —
      # this fixture never had one. The claim is about the CONTRACT: the keyset
      # the dispatcher is entitled to is exactly these two, so a future change
      # that rides an excerpt, a speaker or a transcript id along on the global
      # wake-up fails here.
      assert MapSet.subset?(
               payload |> Map.keys() |> MapSet.new(),
               MapSet.new([:meeting_id, :room_id])
             ),
             """
             `meeting:intent_enqueued` is a GLOBAL topic with no per-meeting
             mirror, so every subscriber sees every meeting's wake-up. Its
             payload grew a key beyond the two the dispatcher drains by:

               #{deep_inspect(Map.keys(payload))}

             Per-row content belongs on `intents_topic/1`, which is per-meeting
             and has a scoped-leak test below. If the new key is genuinely
             routing-only, widen the set here and say why in the commit.
             """

      MeetingsPubSub.unsubscribe_intent_enqueued()
    end

    test "per-meeting intent events do not cross between meetings, and do arrive for their own" do
      ours = Ecto.UUID.generate()
      theirs = Ecto.UUID.generate()
      secret = "their-utterance-#{unique()}"

      watcher(:meeting_ours, fn -> MeetingsPubSub.subscribe_intents(ours) end)
      watcher(:meeting_theirs, fn -> MeetingsPubSub.subscribe_intents(theirs) end)

      # This topic carries `chunk_excerpt` — real speech — so a cross-meeting
      # delivery here would be a content leak, which is why it gets a second
      # watcher rather than a payload-shape pin.
      MeetingsPubSub.broadcast_intent_classified(theirs, %{
        id: Ecto.UUID.generate(),
        chunk_excerpt: secret
      })

      # PROOF THE EVENT WAS ON THE WIRE, taken from the entitled subscriber
      # because this topic has no bare sibling to watch instead.
      assert_receive {:meeting_theirs, {:intent_classified, %{chunk_excerpt: ^secret}}}, 1_000

      # POSITIVE CONTROL on the subscription about to be refuted.
      own = "our-utterance-#{unique()}"

      MeetingsPubSub.broadcast_intent_classified(ours, %{
        id: Ecto.UUID.generate(),
        chunk_excerpt: own
      })

      assert_receive {:meeting_ours, {:intent_classified, %{chunk_excerpt: ^own}}},
                     1_000,
                     "the per-meeting subscription delivered nothing even for its OWN meeting, " <>
                       "so the refute below would be passing for the wrong reason"

      # THE LEAK ASSERTION.
      relayed = for {:meeting_ours, msg} <- collect(300), do: msg

      refute_any_mentions(
        relayed,
        secret,
        "the per-meeting intent subscription relayed another meeting's utterance:"
      )
    end

    test "no user-facing process reaches for a globally-fanned intent topic" do
      # The six classified-intent topics (`meeting:action_item_intent` and
      # siblings) are global on purpose: the Responsibilities Router subscribes
      # once at boot from the topic strings its enabled DB rows declare, and
      # PubSub has no wildcard match. Their payloads carry `chunk_excerpt`,
      # `speaker` and `transcript_id` — the highest-content global topics in
      # stage 2's inventory. That is acceptable only while the subscriber is a
      # supervised singleton. A LiveView or Channel joining one would put a
      # user's socket on every meeting's speech in the install.
      #
      # The alternation covers the helper names AND the two spellings that
      # bypass them: a bare `IntentRouting.topic/1` call (which is what
      # `intent_topic/1` itself delegates to) and a literal topic string handed
      # straight to `Phoenix.PubSub.subscribe/2`.
      offenders = matching_sources(web_sources(), intent_topic_regex())

      assert offenders == [], """
      A module under platform_web now reaches for a global classified-intent
      topic:

      #{Enum.map_join(offenders, "\n", &"  #{&1}")}

      Those topics carry meeting speech across every room and org in the
      install. The per-meeting `MeetingsPubSub.subscribe_intents/1` is the
      subscription a mounted view is entitled to — `meeting_live.ex` uses it,
      and the cross-meeting test above binds its scoping.
      """

      # POSITIVE CONTROL for the OFFENDER regex itself, not merely for the glob:
      # the same pattern over the whole lib tree must find the module that
      # declares these topics. Without this, a rename of every token in the
      # alternation would leave the assertion above green forever.
      assert matching_sources(lib_sources(), intent_topic_regex()) != [], """
      The intent-topic pattern matches nothing anywhere in lib, including
      `platform/meetings/pub_sub.ex` which declares these topics. The pattern is
      broken, so the platform_web assertion above is reporting "no offenders"
      for every possible input rather than a real absence.
      """
    end
  end

  defp intent_topic_regex do
    ~r/subscribe_action_item_intent|intent_topic\(|action_item_intent_topic\(|IntentRouting\.topic\(|"meeting:\w+_intent"/
  end
end
