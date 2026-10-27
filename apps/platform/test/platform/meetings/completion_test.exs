defmodule Platform.Meetings.CompletionTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  alias Platform.{Chat, Federation, Meetings, Repo, Roles, Tasks}
  alias Platform.Agents.Agent
  alias Platform.Meetings.{Completion, CompletionRun, Transcript}
  alias Platform.Tasks.Task

  setup do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "Completion #{n}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
        repo_url: "https://github.com/test/completion"
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Finalization #{n}"})

    meeting =
      meeting
      |> Ecto.Changeset.change(status: "live", started_at: DateTime.add(DateTime.utc_now(), -60))
      |> Repo.update!()

    scribe = role_agent!("meeting_scribe")
    triage = role_agent!("triage_officer")
    %{project: project, meeting: meeting, scribe: scribe, triage: triage}
  end

  defp role_agent!(role) do
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "completion-#{role}-#{n}", name: role, status: "active"})

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "completion-#{n}@example.com",
        oidc_sub: "completion-#{n}",
        name: "Completion Owner"
      })

    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "completion-#{n}"})
    {:ok, _} = Federation.link_agent(runtime, agent)
    :ok = Roles.unassign_role(role)
    {:ok, _} = Roles.assign_role(role, agent.id)
    PlatformWeb.Endpoint.subscribe("runtime:completion-#{n}")
    agent
  end

  defp transcript!(meeting, segments, status \\ "processing") do
    Repo.insert!(%Transcript{
      space_id: meeting.chat_space_id,
      room_id: meeting.livekit_room_name,
      started_at: DateTime.add(DateTime.utc_now(), -30),
      segments: segments,
      status: status
    })
  end

  defp segment(text, start) do
    %{"id" => Ecto.UUID.generate(), "text" => text, "start_time" => start}
  end

  defp run!(meeting), do: Repo.get_by!(CompletionRun, meeting_id: meeting.id)

  defp canvas!(space_id, agent) do
    {:ok, participant} = Chat.add_agent_participant(space_id, agent.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => participant.id,
        "title" => "Final meeting actions"
      })

    document = %{
      "type" => "stack",
      "children" =>
        Enum.map(~w(repair-completion invalid duplicate conflict), fn id ->
          %{"type" => "checklist_item", "id" => id, "label" => id}
        end)
    }

    canvas |> Ecto.Changeset.change(document: document) |> Repo.update!()
  end

  defp params(meeting, run, canvas) do
    %{
      "meeting_id" => meeting.id,
      "run_id" => run.id,
      "transcript_id" => run.transcript_id,
      "canvas_id" => canvas.id,
      "snapshot_hash" => run.snapshot_hash
    }
  end

  defp ready!(meeting) do
    seg =
      segment("We agreed to repair the completion callback and verify the replay behavior.", 1)

    transcript = transcript!(meeting, [seg])
    {:ok, ended} = Meetings.end_meeting(meeting)
    Completion.capture_finished_for_space(meeting.chat_space_id)
    {:ok, _} = Meetings.complete_transcript(transcript.id, "Agreed callback repair")
    {ended, run!(meeting), seg}
  end

  test "end before transcription waits for capture fence and final transcript", %{
    meeting: meeting
  } do
    transcript = transcript!(meeting, [segment("We need a follow-up.", 1)])
    {:ok, _} = Meetings.end_meeting(meeting)
    assert run!(meeting).status == "waiting"
    {:ok, _} = Meetings.complete_transcript(transcript.id, "Follow-up")
    assert run!(meeting).status == "waiting"

    refute_receive %Phoenix.Socket.Broadcast{
                     payload: %{signal: %{reason: "meeting_scribe_completion"}}
                   },
                   30

    Completion.capture_finished_for_space(meeting.chat_space_id)
    assert run!(meeting).status == "scribe_dispatched"

    assert_receive %Phoenix.Socket.Broadcast{
      payload: %{signal: %{reason: "meeting_scribe_completion"}}
    }
  end

  test "transcription before end never dispatches until ended and capture finished", %{
    meeting: meeting
  } do
    transcript = transcript!(meeting, [segment("File the real action.", 1)])
    {:ok, _} = Meetings.complete_transcript(transcript.id, "Action")
    assert Repo.get_by(CompletionRun, meeting_id: meeting.id) == nil

    refute_receive %Phoenix.Socket.Broadcast{
                     payload: %{signal: %{reason: "meeting_scribe_completion"}}
                   },
                   30

    {:ok, _} = Meetings.end_meeting(meeting)
    assert run!(meeting).status == "waiting"
    Completion.capture_finished_for_space(meeting.chat_space_id)
    assert run!(meeting).status == "scribe_dispatched"
  end

  test "a recording transcript remains unfinished even after the room fence", %{meeting: meeting} do
    old = transcript!(meeting, [segment("Earlier segment", 1)])
    {:ok, _} = Meetings.complete_transcript(old.id, "Earlier")
    transcript!(meeting, [segment("Still being recorded", 2)], "recording")
    {:ok, _} = Meetings.end_meeting(meeting)
    Completion.capture_finished_for_space(meeting.chat_space_id)
    assert run!(meeting).status == "waiting"

    refute_receive %Phoenix.Socket.Broadcast{
                     payload: %{signal: %{reason: "meeting_scribe_completion"}}
                   },
                   30
  end

  test "the snapshot includes every segment across transcripts and late edits invalidate the callback",
       ctx do
    first_seg = segment("First recording decision", 1)
    second_seg = segment("Second recording decision", 2)
    first = transcript!(ctx.meeting, [first_seg])
    second = transcript!(ctx.meeting, [second_seg])
    {:ok, _} = Meetings.complete_transcript(first.id, "First")
    {:ok, _} = Meetings.end_meeting(ctx.meeting)
    Completion.capture_finished_for_space(ctx.meeting.chat_space_id)
    assert run!(ctx.meeting).status == "waiting"
    {:ok, _} = Meetings.complete_transcript(second.id, "Second")
    run = run!(ctx.meeting)
    assert Enum.map(run.snapshot["segments"], & &1["id"]) == [first_seg["id"], second_seg["id"]]
    canvas = canvas!(ctx.meeting.chat_space_id, ctx.scribe)
    late = segment("Late finalized segment", 3)
    second |> Ecto.Changeset.change(segments: [second_seg, late]) |> Repo.update!()

    assert {:error, :transcript_changed} =
             Completion.scribe_complete(ctx.scribe.id, params(ctx.meeting, run, canvas))

    Completion.resume(ctx.meeting.id)

    assert Enum.map(run!(ctx.meeting).snapshot["segments"], & &1["id"]) == [
             first_seg["id"],
             second_seg["id"],
             late["id"]
           ]

    assert {:error, :run_mismatch} =
             Completion.scribe_complete(ctx.scribe.id, params(ctx.meeting, run, canvas))
  end

  test "the scribe callback dispatches triage and normalized filing is stable after task completion",
       ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, %{status: "triage_dispatched"}} = Completion.scribe_complete(ctx.scribe.id, args)

    assert_receive %Phoenix.Socket.Broadcast{
      payload: %{signal: %{reason: "meeting_triage_dispatch", run_id: run_id}}
    }

    assert run_id == run.id

    item = %{
      "item_id" => "repair-completion",
      "title" => "Repair the completion callback",
      "description" =>
        "Repair final meeting processing and verify replay behavior, as agreed in the cited segment.",
      "source_segment_ids" => [seg["id"]]
    }

    args = Map.put(args, "action_items", [item])

    assert {:ok, %{status: "filed", task_ids: [task_id]}} =
             Completion.triage_file(ctx.triage.id, args)

    task = Repo.get!(Task, task_id)
    assert task.title == "Repair the completion callback"
    assert task.description =~ "verify replay behavior"
    assert task.metadata["source"] == "meetings.triage"
    assert task.metadata["completion_run_id"] == run.id
    task |> Ecto.Changeset.change(status: "done") |> Repo.update!()
    assert {:ok, %{task_ids: [^task_id]}} = Completion.triage_file(ctx.triage.id, args)

    assert Repo.aggregate(
             from(t in Task, where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id),
             :count
           ) == 1
  end

  test "wrong role, live state and foreign canvas cannot file", ctx do
    {meeting, run, _} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:error, :unauthorized_role} = Completion.scribe_complete(ctx.triage.id, args)

    {:ok, foreign_space} =
      Chat.create_space(%{
        name: "Foreign",
        slug: "foreign-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    foreign_canvas = canvas!(foreign_space.id, ctx.scribe)

    assert {:error, :foreign_canvas} =
             Completion.scribe_complete(
               ctx.scribe.id,
               Map.put(args, "canvas_id", foreign_canvas.id)
             )

    meeting |> Ecto.Changeset.change(status: "live") |> Repo.update!()
    assert {:error, :meeting_not_finalized} = Completion.scribe_complete(ctx.scribe.id, args)
    assert run!(meeting).item_results == %{}
  end

  test "duplicate and conflict decisions file nothing and ungrounded work is rejected", ctx do
    {meeting, run, _} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)

    invalid = %{
      "item_id" => "invalid",
      "title" => "Invent work",
      "description" => "No source",
      "source_segment_ids" => [Ecto.UUID.generate()]
    }

    assert {:error, :ungrounded_action_item} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", [invalid]))

    decisions = [
      %{"item_id" => "duplicate", "decision" => "duplicate"},
      %{"item_id" => "conflict", "decision" => "conflict"}
    ]

    assert {:ok, %{task_ids: []}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", decisions))

    assert run!(meeting).item_results["duplicate"]["status"] == "duplicate"
    assert run!(meeting).item_results["conflict"]["status"] == "conflict"
  end

  test "unassigned and offline roles leave retryable failures on the same run", ctx do
    :ok = Roles.unassign_role("meeting_scribe")
    {meeting, run, _} = ready!(ctx.meeting)
    assert run.status == "scribe_pending"
    assert run.last_error =~ "role_unassigned"

    offline =
      Repo.insert!(%Agent{
        slug: "offline-#{System.unique_integer([:positive])}",
        name: "Offline",
        status: "active"
      })

    {:ok, _} = Roles.assign_role("meeting_scribe", offline.id)
    assert {:error, :runtime_unresolvable} = Completion.resume(meeting.id)
    assert run!(meeting).id == run.id
    assert run!(meeting).last_error =~ "runtime_unresolvable"
    :ok = Roles.unassign_role("meeting_scribe")
    {:ok, _} = Roles.assign_role("meeting_scribe", ctx.scribe.id)

    assert {:ok, %{status: "scribe_dispatched", run_id: recovered_id}} =
             Completion.resume(meeting.id)

    assert recovered_id == run.id
  end
end
