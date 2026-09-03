defmodule Platform.Meetings.PressWindowTaggingTest do
  @moduledoc """
  Tags a transcript segment that arrived inside its speaker's push-to-talk
  window with `source: :push_to_talk` on the intent-queue row
  (task 01a03f4e, plan v2 stage 2).

  ## Why every assertion here reads the row back

  `IntentQueue.Server.do_enqueue/3` builds the row as

      attrs |> writable() |> Map.merge(...) |> then(&Map.merge(default_row(), &1))

  and `writable/1` is `Map.take(attrs, @writable_fields)`. A key that is
  not in `@writable_fields` is dropped silently, between the caller's map
  and the ETS row, with no error and no log. So an assertion made against
  the map that was PASSED IN is an assertion about the test's own literal
  — it passes identically whether the field was stored or thrown away.

  The first test below writes both assertions side by side and says which
  is which, so the split is demonstrable rather than claimed. Removing
  `:source` from `@writable_fields` must redden the read-back one and
  leave the pass-in one green; if both move together, the test is not
  discriminating and that is a finding, not something to tune.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"

  # Identities in the shape the transcriber actually sends — see
  # `PlatformWeb.MeetingAgentController.normalize_segment/1`.
  @alice "user:#{Ecto.UUID.generate()}"
  @bob "user:#{Ecto.UUID.generate()}"

  setup do
    meeting_id = Ecto.UUID.generate()

    on_exit(fn ->
      IntentQueue.stop(meeting_id)
      PressWindow.clear_meeting(meeting_id)
    end)

    %{meeting_id: meeting_id}
  end

  # ── The plumbing: does :source survive the enqueue at all ─────────────────

  describe "source on the intent-queue row" do
    test "read-back sees it — and the pass-in assertion is shown to be worthless",
         %{meeting_id: meeting_id} do
      attrs = sample_attrs(%{source: :push_to_talk})

      assert {:ok, _row} = IntentQueue.enqueue(meeting_id, attrs)

      # ── PASS-IN. Deliberately included, deliberately useless. It reads
      # the map this test just built and never touches the queue, so it
      # is green against a correct implementation, against one that
      # drops the field on the floor, and against no implementation at
      # all. It is here only so the asymmetry under mutation can be
      # SEEN rather than asserted.
      assert attrs.source == :push_to_talk

      # ── READ-BACK. The actual deliverable. This is the only one of
      # the two that can distinguish "stored" from "silently dropped by
      # Map.take/2".
      assert [row] = IntentQueue.list(meeting_id)
      assert row.source == :push_to_talk
    end

    test "an ordinary enqueue reads back a nil source, not a missing key",
         %{meeting_id: meeting_id} do
      # `default_row/0` must carry the field so downstream code can
      # pattern-match `%{source: source}` without `Map.get/3`
      # defensiveness — the reason that function exists at all.
      assert {:ok, _row} = IntentQueue.enqueue(meeting_id, sample_attrs(%{}))

      assert [row] = IntentQueue.list(meeting_id)
      assert Map.has_key?(row, :source)
      assert row.source == nil
    end

    test "a junk source value is stored as given, not silently normalised",
         %{meeting_id: meeting_id} do
      # Pins the current contract: the queue is a carrier here, not a
      # validator. If a later stage adds validation this test is the
      # thing that should fail and be updated deliberately.
      assert {:ok, _row} = IntentQueue.enqueue(meeting_id, sample_attrs(%{source: :nonsense}))

      assert [row] = IntentQueue.list(meeting_id)
      assert row.source == :nonsense
    end
  end

  # ── End to end: arrival inside a window reaches the row ───────────────────

  describe "a chunk arriving inside a press window" do
    setup do
      agent = create_agent!()
      {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

      target = create_agent!()
      :ok = Roles.unassign_role("designer")
      {:ok, _} = Roles.assign_role("designer", target.id)

      %{agent: agent, target: target}
    end

    test "is tagged :push_to_talk on the row read back from list/1",
         %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      # Alice is holding the talk key right now.
      {:ok, _} = PressWindow.press(meeting_id, @alice)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, @alice, "the nav bar contrast is too low on mobile")

      assert_receive {:intent_classified, _row}, 2_000

      assert [row] = IntentQueue.list(meeting_id)
      assert row.source == :push_to_talk
    end

    test "from a DIFFERENT speaker inside A's window is NOT tagged",
         %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      # Alice presses; Bob talks over her.
      {:ok, _} = PressWindow.press(meeting_id, @alice)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, @bob, "the nav bar contrast is too low on mobile")

      assert_receive {:intent_classified, _row}, 2_000

      # Reachability: a row DID reach the queue, so the nil below is the
      # tagging declining to fire and not the chunk having been dropped
      # somewhere upstream. Without this the assertion would pass just as
      # well against a pipeline that enqueued nothing at all.
      assert [row] = IntentQueue.list(meeting_id)
      assert row.chunk_excerpt == "the nav bar contrast is too low on mobile"
      assert row.source == nil

      # And the window really was open at the time — Alice would have
      # been tagged for the same instant.
      assert {:ok, %{identity: @alice}} = PressWindow.claim(meeting_id, @alice)
    end

    test "after the window has closed is NOT tagged", %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      now = DateTime.utc_now()
      {:ok, _} = PressWindow.press(meeting_id, @alice, DateTime.add(now, -60, :second))
      {:ok, _} = PressWindow.release(meeting_id, @alice, DateTime.add(now, -30, :second))

      # Released 30s ago against a 3s grace — long shut.
      assert PressWindow.claim(meeting_id, @alice) == :none

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, @alice, "the nav bar contrast is too low on mobile")

      assert_receive {:intent_classified, _row}, 2_000

      assert [row] = IntentQueue.list(meeting_id)
      assert row.chunk_excerpt == "the nav bar contrast is too low on mobile"
      assert row.source == nil
    end

    test "with no press window at all is NOT tagged", %{meeting_id: meeting_id} do
      {pid, _name} = start_classifier!()
      plant_ok_stub(pid)

      assert PressWindow.list(meeting_id) == []

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)
      broadcast_chunk(meeting_id, @alice, "the nav bar contrast is too low on mobile")

      assert_receive {:intent_classified, _row}, 2_000

      assert [row] = IntentQueue.list(meeting_id)
      assert row.source == nil
    end
  end

  # ── Harness ───────────────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  defp start_classifier! do
    name = :"press_window_tagging_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({IntentClassifier, provider_module: StubProvider, name: name})

    {pid, name}
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

  # A classification that always lands a row. The evidence gate demotes
  # any non-off_topic verdict whose quote is not a verbatim span of the
  # chunk, so the stub echoes the chunk text back as its citation.
  defp plant_ok_stub(pid) do
    plant_stub_fun(pid, fn _creds, messages, _opts ->
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
    end)
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

  defp broadcast_chunk(meeting_id, identity, text) do
    room_id = "room-#{System.unique_integer([:positive])}"

    payload = %{
      room_id: room_id,
      transcript_id: Ecto.UUID.generate(),
      meeting_id: meeting_id,
      segment: %{
        id: Ecto.UUID.generate(),
        text: text,
        # BOTH keys, as the transcriber sends them. `participant_identity`
        # is the one the press window keys on; `speaker_name` exists so
        # the row's `speaker` field is populated the way production
        # populates it and the payload is not artificially sparse.
        participant_identity: identity,
        speaker_name: "speaker-#{identity}"
      }
    }

    :ok = MeetingsPubSub.broadcast_transcript_chunk(room_id, payload)
    payload
  end

  defp create_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "ptt-agent-#{System.unique_integer([:positive])}",
      name: "PTT Agent",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp sample_attrs(overrides) do
    Map.merge(
      %{
        room_id: Ecto.UUID.generate(),
        classified_intent: "create_task",
        target_role: "engineering",
        confidence: 0.87,
        transcript_chunk_id: Ecto.UUID.generate(),
        chunk_excerpt: "we should file a task for the billing bug",
        speaker: "alice",
        dedupe_key: "ptt-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end
end
