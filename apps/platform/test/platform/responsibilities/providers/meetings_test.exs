defmodule Platform.Responsibilities.Providers.MeetingsTest do
  @moduledoc """
  Tests for the M8 stage 6 shim
  `Platform.Responsibilities.Providers.Meetings` — the seam that lets
  the M6 Router's `provider_module_for("meetings")` lookup resolve the
  meeting-summary handler. Without this shim, router-fired
  `meetings.summarize` dispatches log "no output handler" and the
  legacy bridge does the work alone.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities.Handlers.MeetingSummarize
  alias Platform.Responsibilities.Providers.Meetings, as: MeetingsProvider
  alias Platform.Responsibilities.Responsibility

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: MeetingSummarize.key(),
      feature: "meetings",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "meeting:finished"},
      scope: "per_meeting",
      context_provided: ["org_identity", "recent_journal", "meeting_transcript"],
      enabled: true
    }
  end

  defp create_space! do
    {:ok, space} = Chat.create_space(%{kind: "execution"})
    space
  end

  defp create_transcript!(space_id) do
    {:ok, t} =
      Meetings.create_transcript(%{
        room_id: unique_id(),
        space_id: space_id,
        segments: [
          %{
            "speaker_name" => "Hal",
            "text" => "We should ship the shim.",
            "start_time" => 0,
            "end_time" => 1000,
            "final" => true
          }
        ]
      })

    t
  end

  describe "register/0" do
    test "delegates to the handler's register spec" do
      assert MeetingsProvider.register() == MeetingSummarize.register()
    end
  end

  describe "handle_output/3" do
    test "delegates the canonical event_topic payload to the handler" do
      space = create_space!()
      transcript = create_transcript!(space.id)
      _ = ExecutionSpace.ensure_system_participant(space.id)

      trigger_meta = %{
        kind: :event_topic,
        topic: "meeting:finished",
        payload: %{
          transcript_id: transcript.id,
          room_id: transcript.room_id,
          space_id: space.id
        }
      }

      assert :ok =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "## Overview\nWe shipped the shim.",
                 trigger_meta
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "shipped the shim"
    end

    test "normalises a flat trigger_meta (transcript_id at top level) into :payload" do
      # This is the operator-from-iex shape: `Router.fire(:meetings_summarize,
      # %{transcript_id: id, space_id: sid})`. Without the shim's
      # normalize_meta the handler's accessors return nil for both
      # transcript_id and space_id and the dispatch errors out.
      space = create_space!()
      transcript = create_transcript!(space.id)
      _ = ExecutionSpace.ensure_system_participant(space.id)

      flat_meta = %{
        kind: :cron,
        transcript_id: transcript.id,
        space_id: space.id
      }

      assert :ok =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "Flat-meta dispatch summary.",
                 flat_meta
               )

      reloaded = Meetings.get_transcript(transcript.id)
      assert reloaded.status == "complete"
      assert reloaded.summary =~ "Flat-meta dispatch summary"
    end

    test "rejects missing transcript_id with :missing_transcript_id" do
      assert {:error, :missing_transcript_id} =
               MeetingsProvider.handle_output(
                 responsibility(),
                 "no transcript id at all",
                 %{kind: :event_topic, payload: %{}}
               )
    end
  end

  describe "handle_output/2" do
    test "delegates the arity-2 form to the handler (defaults trigger_meta)" do
      # The handler rejects when no transcript_id is present, so arity-2
      # naturally returns :missing_transcript_id. We're proving the
      # shim doesn't crash on this code path and the same error
      # surfaces.
      assert {:error, :missing_transcript_id} =
               MeetingsProvider.handle_output(responsibility(), %{"summary" => "x"})
    end
  end
end
