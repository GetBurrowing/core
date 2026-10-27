defmodule Platform.Meetings.PressCardTest do
  @moduledoc """
  The instant card a push-to-talk press puts on the board
  (task 01a03f4e, plan v2 stage 3).

  ## Why every assertion here reads `meeting_candidates`

  The ETS queue row is not the deliverable. The board renders candidate
  ROWS, so an assertion that stops at `IntentQueue.list/1` is an
  assertion about a table nobody looks at — and it stays green against
  an implementation whose mirror writes nothing at all. The first test
  below carries both assertions, in that order, so no-op'ing
  `mirror_enqueue` can be seen to redden one and not the other.

  ## The meeting_id trap

  Every `meeting_id` here is a real UUID. `meeting_candidates.meeting_id`
  is a `:binary_id`, and a non-UUID makes the changeset raise
  `Ecto.ChangeError` at DUMP time — which the mirror's non-fatal wrapper
  historically swallowed into a log line, leaving 96 tests across four
  files green while writing zero rows (ticket 01a04a36-643d). Fatality is
  armed in test now, but the id discipline is what keeps the symptom from
  ever looking like a bug in this module.

  ## This module renders nothing

  Presentation belongs to task 01a03f4e-78b1, shipped in #872. The
  second-participant visibility claim is asserted through a real mounted
  LiveView next door in
  `test/platform_web/live/meeting_press_card_visibility_test.exs`.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.PressCard
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"

  setup do
    meeting_id = Ecto.UUID.generate()
    room_id = Ecto.UUID.generate()
    identity = "user:#{Ecto.UUID.generate()}"

    on_exit(fn ->
      IntentQueue.stop(meeting_id)
      PressWindow.clear_meeting(meeting_id)
    end)

    %{meeting_id: meeting_id, room_id: room_id, identity: identity}
  end

  # ── The card exists before anything is said ──────────────────────────────

  describe "PressCard.open/3" do
    test "writes a meeting_candidates row — and the ETS row alone would not prove it",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      assert {:ok, opened} =
               PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id)

      # ── ETS. True whether or not anything reached Postgres: the queue
      # row is written by `do_enqueue/3` and the mirror runs after it, in
      # a wrapper that is allowed to fail. These assertions survive a
      # mirror that does nothing at all, which is exactly why they are
      # not the deliverable.
      assert [ets_row] = IntentQueue.list(meeting_id)
      assert ets_row.status == :queued
      assert ets_row.source == :push_to_talk

      # ── meeting_candidates. The deliverable: this is the row the board
      # renders, and the only one a participant can actually see.
      assert [card] = Candidates.open_for_meeting(meeting_id)
      assert card.state == :heard
      assert card.queue_status == "queued"
      assert card.intent_id == opened.intent.id
      assert card.meeting_id == meeting_id

      # And it is genuinely a PRE-utterance card: nothing has been said,
      # so there is no chunk and no quote on it yet. If these ever carry
      # a value, the card was not written by the press.
      assert card.transcript_chunk_id == nil
      assert card.evidence_quote == nil
      assert card.classified_intent == nil
    end

    test "opens the press window as well as the card",
         %{meeting_id: meeting_id, identity: identity} do
      assert {:ok, opened} = PressCard.open(meeting_id, identity, speaker: "alice")

      assert {:ok, window} = PressWindow.claim(meeting_id, identity)
      assert window.identity == identity
      assert window.card_intent_id == opened.intent.id
    end

    test "a repeated press event writes ONE card, not one per event",
         %{meeting_id: meeting_id, identity: identity} do
      # pointerdown + keydown for a single physical press, and a key
      # repeating while held.
      assert {:ok, first} = PressCard.open(meeting_id, identity, speaker: "alice")
      assert {:ok, second} = PressCard.open(meeting_id, identity, speaker: "alice")
      assert {:ok, third} = PressCard.open(meeting_id, identity, speaker: "alice")

      refute first.duplicate?
      assert second.duplicate?
      assert third.duplicate?

      assert length(Candidates.open_for_meeting(meeting_id)) == 1
      assert length(IntentQueue.list(meeting_id)) == 1
    end

    test "refuses a blank identity and writes nothing",
         %{meeting_id: meeting_id} do
      assert PressCard.open(meeting_id, "") == {:error, :invalid_identity}
      assert PressCard.open(meeting_id, nil) == {:error, :invalid_identity}

      assert Candidates.open_for_meeting(meeting_id) == []
      assert IntentQueue.list(meeting_id) == []
    end

    test "two speakers pressing get a card each, not one shared card",
         %{meeting_id: meeting_id, identity: identity} do
      other = "user:#{Ecto.UUID.generate()}"

      assert {:ok, a} = PressCard.open(meeting_id, identity, speaker: "alice")
      assert {:ok, b} = PressCard.open(meeting_id, other, speaker: "bob")

      refute a.intent.id == b.intent.id
      assert length(Candidates.open_for_meeting(meeting_id)) == 2
    end
  end

  # ── One card, not two, once the words actually arrive ────────────────────

  describe "when the presser's own utterance classifies" do
    setup do
      agent = create_agent!()
      {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

      target = create_agent!()
      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", target.id)

      :ok
    end

    test "it fills the press card in — exactly ONE row, not two",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      {:ok, opened} = PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id)
      assert [before_card] = all_rows(meeting_id)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, room_id, identity, "the nav bar contrast is too low on mobile")
      assert_receive {:intent_classified, _row}, 2_000

      # ONE row. Counted over EVERY row for the meeting, not just the
      # open ones — a second card that had already closed would still be
      # a second card, and `open_for_meeting/1` would hide it.
      assert [card] = all_rows(meeting_id)

      # And it is the SAME row the press opened, filled in — not a
      # replacement that happens to be alone because the first was
      # deleted.
      assert card.id == before_card.id
      assert card.evidence_quote == "the nav bar contrast is too low on mobile"
      assert card.classified_intent == "visual_adjust"

      # `heard_at` still marks the PRESS, not the sentence: the card
      # appeared when the key went down and the countdown ring has been
      # rendering from that instant.
      assert card.heard_at == before_card.heard_at
      assert opened.intent.id != nil
    end

    test "a NON-presser's utterance opens its own card, and does not eat the press card",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      {:ok, _} = PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id)
      assert [press_card] = all_rows(meeting_id)

      # Bob never pressed. His sentence must not be adopted by Alice's
      # waiting card — that would route his words to the agent because
      # she was holding the key.
      bob = "user:#{Ecto.UUID.generate()}"

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, room_id, bob, "we should rewrite the pricing copy")
      assert_receive {:intent_classified, _row}, 2_000

      rows = all_rows(meeting_id)
      assert length(rows) == 2

      # Alice's card is untouched and still waiting.
      reloaded = Enum.find(rows, &(&1.id == press_card.id))
      assert reloaded.transcript_chunk_id == nil
      assert reloaded.evidence_quote == nil

      # Bob's words are on Bob's card.
      bobs = Enum.find(rows, &(&1.id != press_card.id))
      assert bobs.evidence_quote == "we should rewrite the pricing copy"
    end

    test "a SECOND sentence during one press opens its own card",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      # Once the press card has taken an utterance it belongs to that
      # utterance. Continuing to pour a long press into one card is a
      # threading decision that belongs to the threading ticket, not to
      # this one, and quietly doing it here would change that contract.
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      {:ok, _} = PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, room_id, identity, "the nav bar contrast is too low on mobile")
      assert_receive {:intent_classified, _row}, 2_000

      broadcast_chunk(meeting_id, room_id, identity, "also the footer needs a dark variant")
      assert_receive {:intent_classified, _row}, 2_000

      assert length(all_rows(meeting_id)) == 2
    end
  end

  # ── A press with nothing said closes at release + grace ──────────────────

  describe "a press released with nothing said" do
    test "is closed as :unclassified / :timed_out once the grace elapses, and mints nothing",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      t0 = DateTime.utc_now()

      {:ok, opened} =
        PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id, at: t0)

      {:ok, released} = PressWindow.release(meeting_id, identity, DateTime.add(t0, 1, :second))

      assert PressWindow.claims(meeting_id, identity) == 0
      :ok = elapse_grace(meeting_id, identity, released.released_at)

      card = await_closed(opened.intent.id)
      assert card.state == :closed
      assert card.closed_reason == :unclassified
      assert card.disposition == :timed_out
      assert card.task_id == nil

      # And the sweeper has nothing left to graduate: the row is closed,
      # so neither the fire path nor the reaper touches it.
      assert Platform.Meetings.CandidateSweeper.sweep(now: DateTime.add(t0, 1, :hour)) == []
      assert Repo.reload!(card).task_id == nil
      assert Repo.reload!(card).state == :closed
    end

    @tag timeout: 10_000
    test "the REAL timer release/3 arms is what delivers the close — no injection",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      # The other tests in this block inject the timer's message, so
      # deleting `Process.send_after/3` from release/3 outright would
      # leave every one of them green. This one waits the grace out.
      {:ok, opened} = PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id)
      {:ok, _} = PressWindow.release(meeting_id, identity)

      # Poll on a WALL-CLOCK deadline instead of sleeping the grace out first.
      # The deadline is the one the old sleep plus `await_closed/2`'s 40 x 25 ms
      # gave (grace + 200 + 1000 ms); it returns as soon as the card closes. Not
      # `await_closed/2` with more tries: its bound is a try count, and each try
      # costs a query on top of the 25 ms, so a scaled count drifts past the
      # deadline (measured: a timer moved to grace + 1.5 s still passed).
      card =
        Platform.AsyncAssertions.assert_eventually(
          fn ->
            case Candidates.get_by_intent_id(opened.intent.id) do
              %MeetingCandidate{state: :closed} = card -> card
              _not_closed -> nil
            end
          end,
          PressWindow.release_grace_ms() + 1_200,
          25
        )

      assert card.state == :closed
      assert card.closed_reason == :unclassified
    end

    # The dispatcher is off in `config/test.exs`, which is the only reason
    # the cases above were ever green: with it running, the nil-intent
    # row the press enqueues used to be claimed on the next poll, failed
    # `:no_target_role`, and mirrored onto the card as `:dismissed` ~1ms
    # after open (task 01a06638 stage 5). This case boots one.
    test "WITH the dispatcher running, an empty press still closes :unclassified, never :dismissed",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      name = :"intent_dispatcher_press_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised(
          {Platform.Meetings.IntentDispatcher, name: name, tick_interval_ms: 60_000}
        )

      Process.sleep(20)

      t0 = DateTime.utc_now()

      {:ok, opened} =
        PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id, at: t0)

      # The enqueue notify has woken the dispatcher; drain again by hand
      # so the claim attempt is certain to have run before we look.
      assert Platform.Meetings.IntentDispatcher.drain(meeting_id, name) == :empty

      assert {:ok, %{status: :queued}} = IntentQueue.get(meeting_id, opened.intent.id)

      card = Candidates.get_by_intent_id(opened.intent.id)
      assert card.state != :closed, "dispatcher closed the press card: #{inspect(card)}"

      {:ok, released} = PressWindow.release(meeting_id, identity, DateTime.add(t0, 1, :second))
      :ok = elapse_grace(meeting_id, identity, released.released_at)

      card = await_closed(opened.intent.id)
      assert card.state == :closed
      assert card.closed_reason == :unclassified
      assert card.disposition == :timed_out
      refute card.closed_reason == :dismissed
    end

    test "control: a segment claimed inside the grace keeps the card open",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      t0 = DateTime.utc_now()

      {:ok, opened} =
        PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id, at: t0)

      {:ok, released} = PressWindow.release(meeting_id, identity, DateTime.add(t0, 1, :second))

      # The tail of the utterance, finalised after the key came up.
      assert {:ok, _} =
               PressWindow.claim(meeting_id, identity, DateTime.add(t0, 2, :second))

      assert PressWindow.claims(meeting_id, identity) == 1

      :ok = elapse_grace(meeting_id, identity, released.released_at)

      # Reachability: the same wait that finds the closed row in the
      # test above finds it still open here.
      card = await_closed(opened.intent.id, 8)
      assert card.state != :closed
      assert card.closed_reason == nil
      assert card.disposition == nil
    end

    test "a stale grace message from an earlier release leaves the new press alone",
         %{meeting_id: meeting_id, room_id: room_id, identity: identity} do
      t0 = DateTime.utc_now()

      {:ok, _first} =
        PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id, at: t0)

      {:ok, old} = PressWindow.release(meeting_id, identity, DateTime.add(t0, 1, :second))

      # Press again: a NEW window, with its own card and no released_at.
      t1 = DateTime.add(t0, 10, :second)

      {:ok, second} =
        PressCard.open(meeting_id, identity, speaker: "alice", room_id: room_id, at: t1)

      refute second.duplicate?
      assert PressWindow.get(meeting_id, identity).released_at == nil

      # Positive control for the stale message: released_at genuinely
      # differs, and the first release's timer is what is being replayed.
      refute PressWindow.get(meeting_id, identity).released_at == old.released_at
      :ok = elapse_grace(meeting_id, identity, old.released_at)

      card = await_closed(second.intent.id, 8)
      assert card.state != :closed
      assert card.closed_reason == nil
    end
  end

  # ── Harness ──────────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  # The grace timer's own message, injected. `release/3` arms it for
  # `release_grace_ms/0` (3s); sending it directly is how the empty-press
  # tests stay well under that without sleeping through it.
  defp elapse_grace(meeting_id, identity, released_at) do
    send(PressWindow, {:grace_elapsed, meeting_id, identity, released_at})
    # Synchronise on the GenServer so handle_info has run (and the Task
    # is started) before the caller polls.
    :sys.get_state(PressWindow)
    :ok
  end

  # The close runs in a supervised Task; poll the row with a short bound.
  defp await_closed(intent_id, tries \\ 40)

  defp await_closed(intent_id, 0), do: Candidates.get_by_intent_id(intent_id)

  defp await_closed(intent_id, tries) do
    case Candidates.get_by_intent_id(intent_id) do
      %MeetingCandidate{state: :closed} = card ->
        card

      _ ->
        Process.sleep(25)
        await_closed(intent_id, tries - 1)
    end
  end

  # EVERY candidate row for the meeting, open or closed. `open_for_meeting/1`
  # filters by state, so a duplicate that had already closed would be
  # invisible to it and a "exactly one" assertion built on it would be
  # weaker than it looks.
  defp all_rows(meeting_id) do
    MeetingCandidate
    |> where([c], c.meeting_id == ^meeting_id)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> Repo.all()
  end

  defp start_classifier! do
    name = :"press_card_#{System.unique_integer([:positive])}"

    {:ok, pid} = start_supervised({IntentClassifier, provider_module: StubProvider, name: name})

    {pid, name}
  end

  defp plant_ok_stub(pid) do
    ref = make_ref()

    fun = fn _creds, messages, _opts ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => "visual_adjust",
             "target_role" => "designer",
             "confidence" => 0.91,
             "evidence_quote" => echo_quote(messages)
           })
       }}
    end

    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp echo_quote(messages) do
    Enum.find_value(messages, "", fn message ->
      case message do
        %{role: "user", content: content} when is_binary(content) -> content
        %{"role" => "user", "content" => content} when is_binary(content) -> content
        _ -> nil
      end
    end)
  end

  defp broadcast_chunk(meeting_id, room_id, identity, text) do
    :ok =
      MeetingsPubSub.broadcast_transcript_chunk(room_id, %{
        room_id: room_id,
        transcript_id: Ecto.UUID.generate(),
        meeting_id: meeting_id,
        segment: %{
          id: Ecto.UUID.generate(),
          text: text,
          participant_identity: identity,
          speaker_name: "alice"
        }
      })
  end

  defp create_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "press-card-agent-#{System.unique_integer([:positive])}",
      name: "Press Card Agent",
      status: "active"
    })
    |> Repo.insert!()
  end
end
