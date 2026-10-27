defmodule Platform.Meetings.TranscriptOwnershipTest do
  use Platform.DataCase, async: false

  alias Platform.{Meetings, Repo, Tasks}
  alias Platform.Meetings.{Completion, CompletionRun, Transcript}

  setup do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Transcript ownership #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
        repo_url: "https://github.com/test/transcript-ownership"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Capture #{n}"})
    now = DateTime.utc_now()

    meeting =
      meeting
      |> Ecto.Changeset.change(status: "live", started_at: DateTime.add(now, -60))
      |> Repo.update!()

    %{meeting: meeting, now: now}
  end

  test "new transcripts stamp the meeting at capture start for atom and string attrs", ctx do
    for attrs <- [
          %{room_id: "atom-room", space_id: ctx.meeting.chat_space_id},
          %{"room_id" => "string-room", "space_id" => ctx.meeting.chat_space_id}
        ] do
      assert {:ok, transcript} = Meetings.create_transcript(attrs)
      assert transcript.meeting_id == ctx.meeting.id
    end
  end

  test "invalid ownership attributes return changeset errors, never query cast exceptions" do
    assert {:error, %Ecto.Changeset{}} =
             Meetings.create_transcript(%{room_id: "invalid-space", space_id: "garbage"})

    assert {:error, %Ecto.Changeset{}} =
             Meetings.create_transcript(%{room_id: "invalid-time", started_at: "garbage"})
  end

  test "an empty room-start capture binds when its first segment follows the live transition",
       ctx do
    transcript =
      Repo.insert!(%Transcript{
        room_id: ctx.meeting.livekit_room_name,
        space_id: ctx.meeting.chat_space_id,
        started_at: DateTime.add(ctx.now, -120)
      })

    assert {:ok, updated} =
             Meetings.append_segment(transcript.id, %{"text" => "First real speech"})

    assert updated.meeting_id == ctx.meeting.id
  end

  test "a failed prior capture is not reused, while same-meeting reconnect is", ctx do
    prior =
      Repo.insert!(%Transcript{
        room_id: ctx.meeting.livekit_room_name,
        space_id: ctx.meeting.chat_space_id,
        status: "failed",
        started_at: DateTime.add(ctx.now, -3600),
        segments: [%{"id" => Ecto.UUID.generate(), "text" => "Prior meeting"}]
      })

    attrs = %{room_id: ctx.meeting.livekit_room_name, space_id: ctx.meeting.chat_space_id}
    assert {:ok, current} = Meetings.ensure_transcript(attrs)
    assert current.id != prior.id
    assert current.meeting_id == ctx.meeting.id
    assert {:ok, reconnected} = Meetings.ensure_transcript(attrs)
    assert reconnected.id == current.id
    assert Repo.get!(Transcript, prior.id).status == "failed"
  end

  test "finished capture is not held by recording file processing", ctx do
    room =
      Repo.insert!(%Meetings.Room{
        space_id: ctx.meeting.chat_space_id,
        livekit_room_name: ctx.meeting.livekit_room_name,
        status: "idle"
      })

    Repo.insert!(%Meetings.Recording{
      room_id: room.id,
      space_id: ctx.meeting.chat_space_id,
      status: "processing"
    })

    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: ctx.meeting.livekit_room_name,
        space_id: ctx.meeting.chat_space_id,
        status: "complete",
        completed_at: ctx.now,
        segments: [%{"id" => Ecto.UUID.generate(), "text" => "Final agreed action"}]
      })

    {:ok, meeting} = Meetings.end_meeting(ctx.meeting)
    Completion.capture_finished_for_space(meeting.chat_space_id)
    run = Repo.get_by!(CompletionRun, meeting_id: meeting.id)
    assert run.snapshot["source_transcript_ids"] == [transcript.id]
    assert run.status != "waiting"
  end

  test "prior summary finishing during a meeting does not enter its snapshot", ctx do
    prior =
      Repo.insert!(%Transcript{
        room_id: ctx.meeting.livekit_room_name,
        space_id: ctx.meeting.chat_space_id,
        status: "complete",
        started_at: DateTime.add(ctx.now, -3600),
        completed_at: ctx.now,
        segments: [%{"id" => Ecto.UUID.generate(), "text" => "Prior meeting"}]
      })

    assert {:ok, current} =
             Meetings.create_transcript(%{
               room_id: ctx.meeting.livekit_room_name,
               space_id: ctx.meeting.chat_space_id,
               status: "complete",
               completed_at: ctx.now,
               segments: [%{"id" => Ecto.UUID.generate(), "text" => "Current meeting"}]
             })

    meeting =
      ctx.meeting
      |> Ecto.Changeset.change(status: "ended", ended_at: DateTime.utc_now())
      |> Repo.update!()

    Completion.resume(meeting.id)
    Completion.capture_finished_for_space(meeting.chat_space_id)
    run = Repo.get_by!(CompletionRun, meeting_id: meeting.id)
    assert run.snapshot["source_transcript_ids"] == [current.id]
    refute prior.id in run.snapshot["source_transcript_ids"]
  end
end
