defmodule Platform.Meetings.PressChunkIdTest do
  @moduledoc """
  Task 01a1265f stage 1 — every press in one transcript folded onto the
  first press's card.

  ## The fault

  `Meetings.append_segment/2` mints the segment id under the STRING key
  `"id"`, and that is the only shape production broadcasts. The
  classifier read `Map.get(segment, :id)`, which is therefore always nil
  in production, so `chunk_id` fell back to the transcript id. Every
  chunk of one transcript then shared one chunk id, and
  `Candidates.record_heard/1` answered every later press with the first
  card, which already "owned" that id.

  ## Why the older tests never saw it

  They hand-build ATOM-keyed segments and mint a fresh `transcript_id`
  per chunk. Either choice on its own hides the fold. This file does
  neither: segments go through `Meetings.append_segment/2` on one real
  transcript bound to a real meeting, so the key shape comes from the
  code under test and all four presses share one transcript id.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Meetings
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

  @sentences [
    "first, the nav bar contrast is too low",
    "second, the footer needs a dark variant",
    "third, the pricing copy reads too long",
    "fourth, the login page button is misaligned"
  ]

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
    agent = create_agent!()
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

    target = create_agent!()
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", target.id)

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Press Chunk Id #{System.unique_integer([:positive])}"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Press Chunk Id"})

    room_id = "room-press-chunk-id-#{System.unique_integer([:positive])}"

    {:ok, transcript} =
      Meetings.ensure_transcript(%{room_id: room_id, space_id: meeting.chat_space_id})

    identity = "user:#{Ecto.UUID.generate()}"

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    {pid, _name} = start_classifier!()
    plant_ok_stub(pid)

    :ok = MeetingsPubSub.subscribe_intents(meeting.id)

    %{meeting: meeting, transcript: transcript, room_id: room_id, identity: identity}
  end

  describe "four presses in ONE transcript, production-shape segments" do
    test "give four rows, each keyed by its own segment's id", ctx do
      presses = run_four_presses!(ctx)

      # The segments really are the production shape: string-keyed, and
      # all four share one transcript. If either stops holding, this
      # test is no longer measuring the fault it was written for.
      for %{segment: segment} <- presses do
        assert is_binary(segment["id"])
        refute Map.has_key?(segment, :id)
        refute segment["id"] == ctx.transcript.id
      end

      rows = all_rows(ctx.meeting.id)
      assert length(rows) == 4

      chunk_ids = Enum.map(rows, & &1.transcript_chunk_id)
      expected = Enum.map(presses, & &1.segment["id"])

      assert Enum.sort(chunk_ids) == Enum.sort(expected)
      refute ctx.transcript.id in chunk_ids

      # One row per press card: the row each press opened is the row
      # that holds that press's segment.
      for %{card_id: card_id, segment: segment} <- presses do
        card = Enum.find(rows, &(&1.id == card_id))
        assert card, "press card #{card_id} has no row"
        assert card.transcript_chunk_id == segment["id"]
      end
    end

    test "each card holds that press's own words and no other press's", ctx do
      presses = run_four_presses!(ctx)
      rows = all_rows(ctx.meeting.id)

      for %{card_id: card_id, text: text} <- presses do
        card = Enum.find(rows, &(&1.id == card_id))
        assert card, "press card #{card_id} has no row"
        assert card.evidence_quote == text
      end

      quotes = rows |> Enum.map(& &1.evidence_quote) |> Enum.sort()
      assert quotes == Enum.sort(@sentences)
    end
  end

  describe "a segment that carries no id at all" do
    test "falls back to the transcript id, so the fallback stays live", ctx do
      fallback_transcript_id = Ecto.UUID.generate()

      {:ok, _opened} =
        PressCard.open(ctx.meeting.id, ctx.identity, speaker: "alice", room_id: ctx.room_id)

      :ok =
        MeetingsPubSub.broadcast_transcript_chunk(ctx.room_id, %{
          room_id: ctx.room_id,
          transcript_id: fallback_transcript_id,
          meeting_id: ctx.meeting.id,
          segment: %{
            "text" => "the settings page needs a search box",
            "participant_identity" => ctx.identity,
            "speaker_name" => "alice"
          }
        })

      await_classified!("the settings page needs a search box")

      assert [card] = all_rows(ctx.meeting.id)
      assert card.transcript_chunk_id == fallback_transcript_id
      assert card.evidence_quote == "the settings page needs a search box"
    end
  end

  # ── Harness ──────────────────────────────────────────────────────────────

  # Press, speak through the real producer entry point, wait for the
  # classification, release. Released after classifying so the claim has
  # already landed and the grace timer has nothing to close.
  defp run_four_presses!(ctx) do
    Enum.map(@sentences, fn text ->
      {:ok, opened} =
        PressCard.open(ctx.meeting.id, ctx.identity, speaker: "alice", room_id: ctx.room_id)

      refute opened.duplicate?

      # The row this press put on the board, read by its ROW id: the
      # classification that fills the card in may re-key `intent_id`.
      assert %MeetingCandidate{id: card_id, transcript_chunk_id: nil} =
               Candidates.get_by_intent_id(opened.intent.id)

      {:ok, updated} =
        Meetings.append_segment(ctx.transcript.id, %{
          "participant_identity" => ctx.identity,
          "speaker_name" => "alice",
          "text" => text,
          "start_time" => 0,
          "end_time" => 1000
        })

      assert updated.id == ctx.transcript.id
      segment = List.last(updated.segments)
      assert segment["text"] == text

      await_classified!(text)

      {:ok, _} = PressWindow.release(ctx.meeting.id, ctx.identity)

      %{card_id: card_id, segment: segment, text: text}
    end)
  end

  # Wait for THIS utterance's classification. The intents topic also
  # carries the queue row `PressCard.open/3` enqueues (no excerpt yet),
  # so an unpinned match would return on the press, not on the words.
  defp await_classified!(text) do
    assert_receive {:intent_classified, %{chunk_excerpt: ^text}}, 2_000
  end

  defp all_rows(meeting_id) do
    MeetingCandidate
    |> where([c], c.meeting_id == ^meeting_id)
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> Repo.all()
  end

  defp start_classifier! do
    name = :"press_chunk_id_#{System.unique_integer([:positive])}"
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

  defp create_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "press-chunk-id-agent-#{System.unique_integer([:positive])}",
      name: "Press Chunk Id Agent",
      status: "active"
    })
    |> Repo.insert!()
  end
end
