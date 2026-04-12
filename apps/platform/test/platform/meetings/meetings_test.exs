defmodule Platform.MeetingsTest do
  @moduledoc false
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.Transcript

  defp unique_room_id, do: Platform.Types.UUIDv7.generate()
  defp unique_space_id, do: Platform.Types.UUIDv7.generate()

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{room_id: unique_room_id(), space_id: unique_space_id()},
      overrides
    )
  end

  defp create_transcript!(overrides \\ %{}) do
    {:ok, transcript} = Meetings.create_transcript(valid_attrs(overrides))
    transcript
  end

  describe "create_transcript/1" do
    test "creates a transcript with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %Transcript{} = transcript} = Meetings.create_transcript(attrs)
      assert transcript.room_id == attrs.room_id
      assert transcript.space_id == attrs.space_id
      assert transcript.status == "recording"
      assert transcript.segments == []
      assert transcript.summary == nil
      assert transcript.started_at != nil
    end

    test "requires room_id" do
      assert {:error, changeset} = Meetings.create_transcript(%{space_id: unique_space_id()})
      assert %{room_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid status" do
      attrs = valid_attrs(%{status: "invalid"})
      assert {:error, changeset} = Meetings.create_transcript(attrs)
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "auto-sets started_at if not provided" do
      {:ok, transcript} = Meetings.create_transcript(valid_attrs())
      assert transcript.started_at != nil
    end

    test "respects explicit started_at" do
      explicit = ~U[2026-01-01 12:00:00.000000Z]
      {:ok, transcript} = Meetings.create_transcript(valid_attrs(%{started_at: explicit}))
      assert transcript.started_at == explicit
    end
  end

  describe "get_transcript/1" do
    test "returns transcript by ID" do
      transcript = create_transcript!()
      assert Meetings.get_transcript(transcript.id) == transcript
    end

    test "returns nil for missing ID" do
      assert Meetings.get_transcript(Platform.Types.UUIDv7.generate()) == nil
    end
  end

  describe "get_transcript_for_room/1" do
    test "returns the active transcript for a room" do
      room_id = unique_room_id()
      transcript = create_transcript!(%{room_id: room_id})
      assert Meetings.get_transcript_for_room(room_id).id == transcript.id
    end

    test "returns nil when no active transcript exists" do
      assert Meetings.get_transcript_for_room(unique_room_id()) == nil
    end

    test "ignores non-recording transcripts" do
      room_id = unique_room_id()
      transcript = create_transcript!(%{room_id: room_id})
      {:ok, _} = Meetings.finalize_transcript(transcript.id)
      assert Meetings.get_transcript_for_room(room_id) == nil
    end
  end

  describe "get_transcript_with_segments/1" do
    test "returns transcript with segments" do
      transcript = create_transcript!()
      assert Meetings.get_transcript_with_segments(transcript.id).id == transcript.id
    end
  end

  describe "ensure_transcript/1" do
    test "creates a new transcript when none exists" do
      attrs = valid_attrs()
      assert {:ok, %Transcript{}} = Meetings.ensure_transcript(attrs)
    end

    test "returns existing transcript when one exists" do
      room_id = unique_room_id()
      existing = create_transcript!(%{room_id: room_id})

      assert {:ok, found} = Meetings.ensure_transcript(%{room_id: room_id})
      assert found.id == existing.id
    end
  end

  describe "append_segment/2" do
    test "appends a segment to the transcript" do
      transcript = create_transcript!()

      segment = %{
        "participant_identity" => "user-123",
        "speaker_name" => "Alice",
        "text" => "Hello, world!",
        "start_time" => 1000,
        "end_time" => 2000,
        "language" => "en"
      }

      assert {:ok, updated} = Meetings.append_segment(transcript.id, segment)
      assert length(updated.segments) == 1
      assert hd(updated.segments)["text"] == "Hello, world!"
    end

    test "appends multiple segments sequentially" do
      transcript = create_transcript!()

      for i <- 1..3 do
        segment = %{
          "participant_identity" => "user-#{i}",
          "text" => "Segment #{i}",
          "start_time" => i * 1000,
          "end_time" => (i + 1) * 1000
        }

        {:ok, _} = Meetings.append_segment(transcript.id, segment)
      end

      updated = Meetings.get_transcript(transcript.id)
      assert length(updated.segments) == 3
    end

    test "returns error for non-existent transcript" do
      segment = %{"text" => "test", "start_time" => 0, "end_time" => 1000}

      assert {:error, :not_found} =
               Meetings.append_segment(Platform.Types.UUIDv7.generate(), segment)
    end
  end

  describe "finalize_transcript/1" do
    test "transitions status to processing" do
      transcript = create_transcript!()
      assert {:ok, finalized} = Meetings.finalize_transcript(transcript.id)
      assert finalized.status == "processing"
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} = Meetings.finalize_transcript(Platform.Types.UUIDv7.generate())
    end
  end

  describe "complete_transcript/2" do
    test "marks transcript as complete with summary" do
      transcript = create_transcript!()
      {:ok, _} = Meetings.finalize_transcript(transcript.id)

      summary = "## Meeting Summary\n- Discussed project timeline"
      assert {:ok, completed} = Meetings.complete_transcript(transcript.id, summary)
      assert completed.status == "complete"
      assert completed.summary == summary
      assert completed.completed_at != nil
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} =
               Meetings.complete_transcript(Platform.Types.UUIDv7.generate(), "summary")
    end
  end

  describe "update_transcript_summary/2" do
    test "updates the summary text" do
      transcript = create_transcript!()
      assert {:ok, updated} = Meetings.update_transcript_summary(transcript.id, "New summary")
      assert updated.summary == "New summary"
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} =
               Meetings.update_transcript_summary(Platform.Types.UUIDv7.generate(), "summary")
    end
  end

  describe "fail_transcript/1" do
    test "marks transcript as failed" do
      transcript = create_transcript!()
      assert {:ok, failed} = Meetings.fail_transcript(transcript.id)
      assert failed.status == "failed"
      assert failed.completed_at != nil
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} = Meetings.fail_transcript(Platform.Types.UUIDv7.generate())
    end
  end

  describe "Transcript schema" do
    test "valid statuses" do
      assert Transcript.statuses() == ~w(recording processing complete failed)
    end

    test "changeset validates status inclusion" do
      changeset =
        %Transcript{}
        |> Transcript.changeset(%{room_id: unique_room_id(), status: "bogus"})

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end
end
