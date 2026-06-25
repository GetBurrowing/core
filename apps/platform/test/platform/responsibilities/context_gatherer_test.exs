defmodule Platform.Responsibilities.ContextGathererTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.ContextGatherer` (ADR-0041 M6
  stage 6).

  Covers each built-in symbolic name + unknown-name handling +
  defensive degradation when upstream lookups can't resolve the
  resource (missing id, nil module, etc.).
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Responsibilities.ContextGatherer

  describe "gather/2 — happy paths" do
    test "returns an empty map for an empty name list" do
      assert ContextGatherer.gather([], %{}) == %{}
    end

    test ":trigger_payload pulls the payload key out of trigger_meta" do
      payload = %{"event" => "test", "value" => 42}

      assert %{trigger_payload: ^payload} =
               ContextGatherer.gather([:trigger_payload], %{payload: payload})
    end

    test ":trigger_payload tolerates string keys in trigger_meta" do
      payload = %{"hello" => "world"}

      assert %{trigger_payload: ^payload} =
               ContextGatherer.gather([:trigger_payload], %{"payload" => payload})
    end

    test ":current_message resolves to a real Chat.Message when message_id is set" do
      slug = "ctxgather-#{System.unique_integer([:positive])}"

      {:ok, space} =
        Chat.create_space(%{name: "Ctx Gather #{slug}", slug: slug, kind: "channel"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Ctx Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "context-gather test message"
        })

      assert %{current_message: %Platform.Chat.Message{id: id}} =
               ContextGatherer.gather([:current_message], %{message_id: message.id})

      assert id == message.id
    end
  end

  describe "gather/2 — missing-id paths" do
    test ":current_message with no :message_id yields nil" do
      assert %{current_message: nil} = ContextGatherer.gather([:current_message], %{})
    end

    test ":current_message with a non-binary :message_id yields nil" do
      assert %{current_message: nil} =
               ContextGatherer.gather([:current_message], %{message_id: 42})
    end

    test ":current_message with an unknown UUID yields nil" do
      bogus_id = Ecto.UUID.generate()

      assert %{current_message: nil} =
               ContextGatherer.gather([:current_message], %{message_id: bogus_id})
    end

    test ":current_meeting with no :meeting_id yields nil" do
      assert %{current_meeting: nil} = ContextGatherer.gather([:current_meeting], %{})
    end

    test ":current_meeting with an unknown UUID yields nil" do
      bogus_id = Ecto.UUID.generate()

      assert %{current_meeting: nil} =
               ContextGatherer.gather([:current_meeting], %{meeting_id: bogus_id})
    end
  end

  describe "gather/2 — org context paths" do
    # Org.Context lookups against an empty wiki simply return nil (the
    # canonical "missing file" / "no recent memory" state). We assert
    # the keys land in the map without raising; the value being nil is
    # the documented degradation contract.
    test ":org_identity returns a key even when ORG_IDENTITY.md isn't seeded" do
      gathered = ContextGatherer.gather([:org_identity], %{})

      assert Map.has_key?(gathered, :org_identity)
      # Don't assert the value — an empty wiki returns nil, a seeded one
      # returns a %WikiPage{}. The gather contract is "always a map with
      # the key present".
    end

    test ":recent_journal returns a key with an empty list against an empty wiki" do
      gathered = ContextGatherer.gather([:recent_journal], %{})

      assert Map.has_key?(gathered, :recent_journal)
      # Same shape contract — recent_memory/2 returns [] for an empty
      # wiki, which we accept as the steady-state.
    end
  end

  describe "gather/2 — :meeting_transcript paths" do
    test ":meeting_transcript with no :transcript_id yields nil" do
      assert %{meeting_transcript: nil} = ContextGatherer.gather([:meeting_transcript], %{})
    end

    test ":meeting_transcript with an unknown UUID yields nil" do
      assert %{meeting_transcript: nil} =
               ContextGatherer.gather([:meeting_transcript], %{
                 transcript_id: Ecto.UUID.generate()
               })
    end

    test ":meeting_transcript materialises formatted_text + counts when transcript exists" do
      segments = [
        %{
          "participant_identity" => "user_1",
          "speaker_name" => "Mira Chen",
          "text" => "Helios kickoff.",
          "start_time" => 0,
          "end_time" => 2500
        }
      ]

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: segments
        })

      assert %{meeting_transcript: payload} =
               ContextGatherer.gather([:meeting_transcript], %{transcript_id: transcript.id})

      assert payload.transcript_id == transcript.id
      assert payload.segment_count == 1
      assert payload.duration_ms == 2500
      assert payload.formatted_text =~ "Mira Chen"
      assert payload.formatted_text =~ "Helios kickoff."
    end

    test ":meeting_transcript tolerates a string-keyed transcript_id in trigger_meta" do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          segments: []
        })

      assert %{meeting_transcript: payload} =
               ContextGatherer.gather([:meeting_transcript], %{
                 "transcript_id" => transcript.id
               })

      assert payload.transcript_id == transcript.id
    end
  end

  describe "gather/2 — unknown names" do
    test "unknown atom name logs a warning and resolves to nil" do
      log =
        capture_log([level: :warning], fn ->
          assert %{this_is_not_real: nil} =
                   ContextGatherer.gather([:this_is_not_real], %{})
        end)

      assert log =~ "[ContextGatherer] unknown name=:this_is_not_real"
    end

    test "unknown string name that has no existing atom logs a warning and is dropped" do
      bogus_string = "not_an_existing_atom_#{System.unique_integer([:positive])}"

      log =
        capture_log([level: :warning], fn ->
          gathered = ContextGatherer.gather([bogus_string], %{})

          # Unknown-string coercion drops the entry entirely (no atom is
          # created, so we can't key the map on it).
          assert gathered == %{}
        end)

      assert log =~ "[ContextGatherer] unknown symbolic name"
    end

    test "known string name is coerced to its atom and resolved" do
      # :trigger_payload is guaranteed to exist (declared above as a
      # resolver pattern), so the string form resolves cleanly.
      assert %{trigger_payload: "hi"} =
               ContextGatherer.gather(["trigger_payload"], %{payload: "hi"})
    end
  end

  describe "gather/2 — multiple names" do
    test "fans out across multiple symbolic names into one map" do
      payload = %{"hello" => "world"}

      gathered =
        ContextGatherer.gather(
          [:trigger_payload, :current_message, :org_identity],
          %{payload: payload}
        )

      assert gathered[:trigger_payload] == payload
      assert gathered[:current_message] == nil
      assert Map.has_key?(gathered, :org_identity)
    end
  end

  describe "gather/2 — defensive guards" do
    test "non-list symbolic_names returns empty map without raising" do
      assert ContextGatherer.gather(nil, %{}) == %{}
      assert ContextGatherer.gather(:not_a_list, %{}) == %{}
    end
  end
end
