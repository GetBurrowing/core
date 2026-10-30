defmodule Platform.Meetings.CompletionTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  alias Platform.{Chat, Federation, Meetings, Repo, Roles, Tasks}
  alias Platform.Agents.Agent
  alias Platform.Meetings.{Completion, CompletionRun, Transcript}
  alias Platform.Tasks.Task

  setup do
    fixture!()
  end

  def fixture! do
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

  def canvas!(space_id, agent) do
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

  def params(meeting, run, canvas) do
    %{
      "meeting_id" => meeting.id,
      "run_id" => run.id,
      "transcript_id" => run.transcript_id,
      "canvas_id" => canvas.id,
      "snapshot_hash" => run.snapshot_hash
    }
  end

  defp complete_current!(id, summary) do
    input = Meetings.get_transcript(id)
    Meetings.complete_transcript(id, summary, Transcript.summary_fingerprint(input))
  end

  def ready!(meeting) do
    seg =
      segment("We agreed to repair the completion callback and verify the replay behavior.", 1)

    transcript = transcript!(meeting, [seg])
    {:ok, ended} = Meetings.end_meeting(meeting)
    Completion.capture_finished_for_space(meeting.chat_space_id)
    {:ok, _} = complete_current!(transcript.id, "Agreed callback repair")
    {ended, run!(meeting), seg}
  end

  test "empty and all-excluded filing passes trigger briefing only after committed final ledger",
       ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert is_nil(Repo.get_by(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id))
    Completion.scribe_complete(ctx.scribe.id, args)

    assert run!(meeting).synthesis == %{
             "snapshot_hash" => run.snapshot_hash,
             "status" => "pending"
           }

    assert "synthesis" in Platform.Meetings.MeetingBriefings.readiness(meeting).missing
    assert is_nil(Repo.get_by(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id))

    for items <- [
          [
            %{
              "item_id" => "conflict",
              "decision" => "exclude",
              "source_segment_ids" => [seg["id"]]
            }
          ],
          []
        ] do
      assert {:ok, %{status: "filed"}} =
               Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", items))

      assert Repo.get_by!(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id).summary ==
               "Agreed callback repair"

      assert run!(meeting).status == "filed"
      assert run!(meeting).synthesis["status"] == "complete"
    end
  end

  test "an initially empty full filing pass completes and builds the briefing", ctx do
    {meeting, run, _seg} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    Completion.scribe_complete(ctx.scribe.id, args)
    assert is_nil(Repo.get_by(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id))

    assert {:ok, %{status: "filed", task_ids: []}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", []))

    assert Repo.get_by!(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id).summary ==
             "Agreed callback repair"
  end

  test "late appended speech blocks briefing until a fresh producer summary and full filing",
       ctx do
    {meeting, original_run, _} = ready!(ctx.meeting)
    original = Meetings.get_transcript(original_run.transcript_id)
    old_hash = original.summary_input_hash

    {:ok, changed} =
      Meetings.append_segment(original.id, %{
        "text" => "Late decision absent from the old summary",
        "start_time" => 90
      })

    assert changed.status == "processing"
    refute Platform.Meetings.MeetingBriefings.readiness(meeting).ready?

    assert {:error, :stale_summary} =
             Meetings.complete_transcript(original.id, "Stale summary", old_hash)

    assert is_nil(Repo.get_by(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id))

    {:ok, _} =
      Meetings.complete_transcript(
        original.id,
        "Summary including late decision",
        Transcript.summary_fingerprint(changed)
      )

    run = run!(meeting)
    refute run.snapshot_hash == original_run.snapshot_hash
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, %{status: "triage_dispatched"}} = Completion.scribe_complete(ctx.scribe.id, args)

    assert {:ok, %{status: "filed"}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", []))

    assert Platform.Meetings.MeetingBriefings.readiness(meeting).ready?

    assert Repo.get_by!(Platform.Meetings.MeetingBriefing, meeting_id: meeting.id).summary ==
             "Summary including late decision"
  end

  test "reordered summary success/failure callbacks and callbacks before reopen cannot overwrite current input",
       ctx do
    transcript = transcript!(ctx.meeting, [segment("Original", 1)])
    old_hash = Transcript.summary_fingerprint(transcript)

    {:ok, changed} =
      Meetings.append_segment(transcript.id, %{"text" => "New speech", "start_time" => 2})

    current_hash = Transcript.summary_fingerprint(changed)
    assert {:ok, _} = Meetings.complete_transcript(transcript.id, "Current summary", current_hash)

    assert {:error, :stale_summary} =
             Meetings.complete_transcript(transcript.id, "Old summary", old_hash)

    assert {:error, :stale_summary} =
             Meetings.fail_summary_input(transcript.id, old_hash, :old_failure)

    assert {:error, :stale_summary} =
             Meetings.fail_summary_input(transcript.id, current_hash, :late_failure)

    assert {:error, :summary_provenance_required} =
             Meetings.complete_transcript(transcript.id, "Unversioned callback")

    assert Meetings.get_transcript(transcript.id).summary == "Current summary"
    {:ok, reopened} = Meetings.reopen_transcript(Meetings.get_transcript(transcript.id))
    refute Transcript.summary_fingerprint(reopened) == current_hash

    assert {:error, :stale_summary} =
             Meetings.complete_transcript(transcript.id, "Before reopen", current_hash)

    refute Transcript.summary_current?(Meetings.get_transcript(transcript.id))
  end

  test "meeting reopen fences old completion callbacks even if the transcript has not changed",
       ctx do
    {meeting, original_run, _} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    old_args = params(meeting, original_run, canvas)
    {:ok, live} = Meetings.resume_meeting(meeting)
    {:ok, ended} = Meetings.end_meeting(live)
    Completion.capture_finished_for_space(ended.chat_space_id)
    refreshed = run!(ended)
    assert refreshed.generation == original_run.generation + 1
    refute refreshed.snapshot_hash == original_run.snapshot_hash
    assert {:error, :run_mismatch} = Completion.scribe_complete(ctx.scribe.id, old_args)
    refute Platform.Meetings.MeetingBriefings.readiness(ended).ready?
    args = params(ended, refreshed, canvas)
    assert {:ok, %{status: "triage_dispatched"}} = Completion.scribe_complete(ctx.scribe.id, args)

    assert {:ok, %{status: "filed"}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", []))

    assert Platform.Meetings.MeetingBriefings.readiness(ended).ready?
  end

  test "summary and append entry points preserve malformed-id miss behavior" do
    assert {:error, :not_found} = Meetings.append_segment("malformed", %{"text" => "Ignored"})
    assert {:error, :not_found} = Meetings.complete_transcript("malformed", "Ignored", "old")
    assert {:error, :not_found} = Meetings.fail_summary_input("malformed", "old", :ignored)
  end

  test "end before transcription waits for capture fence and final transcript", %{
    meeting: meeting
  } do
    transcript = transcript!(meeting, [segment("We need a follow-up.", 1)])
    {:ok, _} = Meetings.end_meeting(meeting)
    assert run!(meeting).status == "waiting"
    {:ok, _} = complete_current!(transcript.id, "Follow-up")
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
    {:ok, _} = complete_current!(transcript.id, "Action")
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
    {:ok, _} = complete_current!(old.id, "Earlier")
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
    {:ok, _} = complete_current!(first.id, "First")
    {:ok, _} = Meetings.end_meeting(ctx.meeting)
    Completion.capture_finished_for_space(ctx.meeting.chat_space_id)
    assert run!(ctx.meeting).status == "waiting"
    {:ok, _} = complete_current!(second.id, "Second")
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

  # Task 01a18ab4 stage 2. The channel plugins read a frame's body from
  # `message.content ?? signal.prompt`; these frames carry no message, so a
  # frame without a rendered `:prompt` is dropped and the run never files.
  describe "the completion frames carry a rendered prompt" do
    test "the scribe frame's prompt names the run, the meeting and every segment by id", ctx do
      {meeting, run, seg} = ready!(ctx.meeting)

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{signal: %{reason: "meeting_scribe_completion", prompt: prompt}}
      }

      assert is_binary(prompt) and String.trim(prompt) != ""
      assert prompt =~ run.id
      assert prompt =~ meeting.id
      assert prompt =~ run.snapshot_hash
      assert prompt =~ seg["text"]
      assert prompt =~ seg["id"] <> " | 00:00:00 | Unknown: " <> seg["text"]
      assert prompt =~ "meeting_scribe_complete"
      refute prompt =~ "{{run_id}}"
    end

    test "the triage frame's prompt names the run, the scribe canvas and meeting_triage_file",
         ctx do
      {meeting, run, _seg} = ready!(ctx.meeting)
      canvas = canvas!(meeting.chat_space_id, ctx.scribe)

      assert {:ok, %{status: "triage_dispatched"}} =
               Completion.scribe_complete(ctx.scribe.id, params(meeting, run, canvas))

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{signal: %{reason: "meeting_triage_dispatch", prompt: prompt}}
      }

      assert String.trim(prompt) != ""
      assert prompt =~ run.id
      assert prompt =~ canvas.id
      assert prompt =~ "meeting_triage_file"
      refute prompt =~ "{{canvas_id}}"
    end

    test "federation refuses a missing or blank prompt before anything is broadcast", ctx do
      for {fun, agent, reason} <- [
            {&Federation.dispatch_scribe_attention/2, ctx.scribe, "meeting_scribe_completion"},
            {&Federation.dispatch_triage_attention/2, ctx.triage, "meeting_triage_dispatch"}
          ],
          payload <- [
            %{reason: reason, run_id: "x"},
            %{reason: reason, run_id: "x", prompt: "   "},
            %{reason: reason, run_id: "x", prompt: nil}
          ] do
        assert {:error, :empty_prompt} = fun.(agent.id, payload)
        refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 50
      end
    end

    test "a run whose capture never finished stays waiting and sends no frame", ctx do
      transcript = transcript!(ctx.meeting, [segment("Speech with capture still open", 1)])
      {:ok, _} = Meetings.end_meeting(ctx.meeting)
      {:ok, _} = complete_current!(transcript.id, "Capture open")
      assert is_nil(run!(ctx.meeting).capture_finished_at)

      Completion.resume(ctx.meeting.id)

      run = run!(ctx.meeting)
      assert run.status == "waiting"
      assert run.last_error == "capture_active"
      assert is_nil(run.capture_finished_at)
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 50
    end
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

    {:ok, _} =
      Meetings.append_segment(run.transcript_id, %{
        "text" => "A late final clarification",
        "start_time" => 4
      })

    complete_current!(run.transcript_id, "Summary including the late final clarification")
    refreshed = run!(meeting)
    assert refreshed.canvas_id == canvas.id
    assert refreshed.status == "scribe_dispatched"
    replacement_canvas = canvas!(meeting.chat_space_id, ctx.scribe)

    assert {:error, :canvas_mismatch} =
             Completion.scribe_complete(
               ctx.scribe.id,
               params(meeting, refreshed, replacement_canvas)
             )

    refreshed_args = params(meeting, refreshed, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, refreshed_args)

    assert {:ok, %{task_ids: [^task_id]}} =
             Completion.triage_file(
               ctx.triage.id,
               Map.put(refreshed_args, "action_items", [item])
             )

    assert Repo.aggregate(
             from(t in Task, where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id),
             :count
           ) == 1
  end

  test "a missing officer recovers and repeated filing creates no additional task", ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    :ok = Roles.unassign_role("triage_officer")
    assert {:ok, %{status: "triage_pending"}} = Completion.scribe_complete(ctx.scribe.id, args)
    assert run!(meeting).last_error =~ "role_unassigned"
    {:ok, _} = Roles.assign_role("triage_officer", ctx.triage.id)
    assert {:ok, %{status: "triage_dispatched"}} = Completion.resume(meeting.id)

    item = %{
      "item_id" => "repair-completion",
      "title" => "Repair the completion callback",
      "description" => "Repair the callback agreed in the cited segment.",
      "source_segment_ids" => [seg["id"]]
    }

    args = Map.put(args, "action_items", [item])

    results = for _ <- 1..2, do: Completion.triage_file(ctx.triage.id, args)

    assert [{:ok, %{task_ids: [id]}}, {:ok, %{task_ids: [id]}}] = results

    assert Repo.aggregate(
             from(t in Task, where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id),
             :count
           ) == 1
  end

  def completion_canvas!(space_id, agent) do
    canvas = canvas!(space_id, agent)

    document =
      Platform.Chat.CanvasDocument.new()
      |> put_in(["root", "children"], [
        %{
          "id" => "actions",
          "type" => "checklist",
          "props" => %{"title" => "actions"},
          "children" =>
            Enum.map(~w(repair-completion invalid duplicate conflict), fn id ->
              %{"id" => id, "type" => "checklist_item", "props" => %{"label" => id}}
            end)
        },
        %{"id" => "unrelated", "type" => "text", "props" => %{"value" => "Keep these notes"}}
      ])

    canvas |> Ecto.Changeset.change(document: document) |> Repo.update!()
  end

  def junk_controls!(canvas) do
    {:ok, %{document: doc}} = Platform.Chat.Canvas.Server.describe(canvas.id)

    Enum.filter(doc["root"]["children"], fn node ->
      node["type"] == "action_row" and
        get_in(node, ["props", "actions"]) == [
          %{
            "label" => "Junk this batch",
            "value" => "junk_batch:#{canvas.id}",
            "variant" => "danger"
          }
        ]
    end)
  end

  defp batch_items(seg) do
    Enum.zip(~w(repair-completion invalid duplicate conflict), [
      "Repair completion callbacks",
      "Onboard the new meeting participant",
      "Document billing handover decisions",
      "Rotate the release signing certificate"
    ])
    |> Enum.map(fn {id, title} ->
      %{
        "item_id" => id,
        "title" => title,
        "description" => "Follow the action agreed in the cited segment.",
        "source_segment_ids" => [seg["id"]]
      }
    end)
  end

  defp authenticated_file(ctx, args) do
    scope = %Platform.Access.Scope{actor: :system, permissions: %{"meetings.join" => :all}}

    Platform.Federation.ToolArguments.dispatch("meeting_triage_file", args, %{
      agent_id: ctx.triage.id,
      access_scope: scope
    })
  end

  test "four authenticated items and two replays retain one run control and all canonical nodes",
       ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = completion_canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
    args = Map.put(args, "action_items", batch_items(seg))

    assert {:ok, %{status: "filed", task_ids: ids}} = authenticated_file(ctx, args)
    assert length(ids) == 4
    assert Enum.all?(ids, &Repo.get!(Task, &1))

    assert [%{"id" => control_id, "props" => %{"label" => "Meeting triage"}}] =
             junk_controls!(canvas)

    assert control_id == "triage-junk-actions-#{run.id}"
    assert {:ok, %{task_ids: ^ids}} = authenticated_file(ctx, args)
    Repo.get!(Task, hd(ids)) |> Ecto.Changeset.change(status: "done") |> Repo.update!()
    assert {:ok, %{task_ids: ^ids}} = authenticated_file(ctx, args)
    assert length(junk_controls!(canvas)) == 1

    assert Repo.aggregate(
             from(t in Task, where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id),
             :count
           ) == 4

    {:ok, %{document: document}} = Platform.Chat.Canvas.Server.describe(canvas.id)

    for id <- ~w(repair-completion invalid duplicate conflict unrelated) do
      assert Platform.Chat.CanvasDocument.get_node(document, id) ==
               Platform.Chat.CanvasDocument.get_node(canvas.document, id)
    end
  end

  test "incremental same-run filing retains a single batch control", ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = completion_canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
    [first | remaining] = batch_items(seg)

    assert {:ok, %{task_ids: [first_id]}} =
             authenticated_file(ctx, Map.put(args, "action_items", [first]))

    assert length(junk_controls!(canvas)) == 1

    assert {:ok, %{task_ids: ids}} =
             authenticated_file(ctx, Map.put(args, "action_items", remaining))

    assert length(ids) == 4
    assert first_id in ids
    assert length(junk_controls!(canvas)) == 1
  end

  test "declined canvas patches retain the ledger and an item-free replay repairs the control",
       ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = completion_canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
    {:ok, _} = Platform.Chat.Canvas.Server.describe(canvas.id)
    server = {:via, Registry, {Platform.Chat.Registry, {:canvas, canvas.id}}}
    # A real CanvasServer schema rejection: text cannot receive action_row children.
    :sys.replace_state(server, fn state ->
      %{state | document: put_in(state.document, ["root", "type"], "text")}
    end)

    assert {:ok, %{status: "triage_pending", task_ids: [task_id]}} =
             authenticated_file(ctx, Map.put(args, "action_items", [hd(batch_items(seg))]))

    assert junk_controls!(canvas) == []
    assert run!(meeting).last_error =~ "batch control"
    assert map_size(run!(meeting).item_results) == 1

    :sys.replace_state(server, fn state ->
      %{state | document: put_in(state.document, ["root", "type"], "stack")}
    end)

    assert {:ok, %{status: "filed", task_ids: [^task_id]}} =
             authenticated_file(ctx, Map.put(args, "action_items", []))

    assert length(junk_controls!(canvas)) == 1
    assert run!(meeting).last_error == nil
  end

  test "empty and all-excluded runs add no batch controls", ctx do
    {meeting, run, _seg} = ready!(ctx.meeting)
    canvas = completion_canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
    assert {:ok, %{task_ids: []}} = authenticated_file(ctx, Map.put(args, "action_items", []))

    decisions =
      Enum.map(
        ~w(repair-completion invalid duplicate conflict),
        &%{"item_id" => &1, "decision" => "exclude"}
      )

    assert {:ok, %{task_ids: []}} =
             authenticated_file(ctx, Map.put(args, "action_items", decisions))

    assert junk_controls!(canvas) == []
  end

  for priority <- ["high", "low", "medium", "critical", nil] do
    @priority priority
    test "authenticated filing persists priority #{inspect(priority)}", ctx do
      {meeting, run, seg} = ready!(ctx.meeting)
      canvas = canvas!(meeting.chat_space_id, ctx.scribe)
      args = params(meeting, run, canvas)
      assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)

      item = %{
        "item_id" => "repair-completion",
        "title" => "Preserve meeting action priority",
        "description" => "Preserve priority as agreed in the cited transcript segment.",
        "source_segment_ids" => [seg["id"]],
        "candidate_ids" => []
      }

      item = if @priority, do: Map.put(item, "priority", @priority), else: item
      scope = %Platform.Access.Scope{actor: :system, permissions: %{"meetings.join" => :all}}

      assert {:ok, %{status: "filed", task_ids: [task_id]}} =
               Platform.Federation.ToolArguments.dispatch(
                 "meeting_triage_file",
                 Map.put(args, "action_items", [item]),
                 %{agent_id: ctx.triage.id, access_scope: scope}
               )

      assert Repo.get!(Task, task_id).priority == (@priority || "medium")
    end
  end

  test "invalid explicit priorities reject the entire authenticated batch before creating tasks",
       ctx do
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)

    item = %{
      "item_id" => "repair-completion",
      "title" => "Preserve valid priority",
      "description" => "Preserve priority from the cited segment.",
      "source_segment_ids" => [seg["id"]],
      "priority" => "high"
    }

    scope = %Platform.Access.Scope{actor: :system, permissions: %{"meetings.join" => :all}}

    for priority <- ["urgent", "HIGH", "", nil, 5] do
      invalid = item |> Map.put("item_id", "invalid") |> Map.put("priority", priority)

      assert {:error, _} =
               Platform.Federation.ToolArguments.dispatch(
                 "meeting_triage_file",
                 Map.put(args, "action_items", [item, invalid]),
                 %{agent_id: ctx.triage.id, access_scope: scope}
               )

      assert run!(meeting).item_results == %{}

      assert Repo.aggregate(
               from(t in Task, where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id),
               :count
             ) == 0
    end
  end

  test "resuming a meeting clears the old capture fence", ctx do
    {meeting, run, _} = ready!(ctx.meeting)
    assert run.capture_finished_at
    {:ok, resumed} = Meetings.resume_meeting(meeting)
    assert run!(meeting).capture_finished_at == nil
    {:ok, _} = Meetings.end_meeting(resumed)
    assert run!(meeting).status == "waiting"
    assert run!(meeting).id == run.id
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

  test "authenticated tool dispatch rejects a foreign tenant and accepts the same finalized run",
       ctx do
    {meeting, run, _} = ready!(ctx.meeting)
    canvas = canvas!(meeting.chat_space_id, ctx.scribe)
    args = params(meeting, run, canvas)
    foreign_org = Platform.TenancyFixtures.tenant_org_id("completion-foreign")

    scope = %Platform.Access.Scope{
      actor: %{id: Ecto.UUID.generate(), org_memberships: []},
      permissions: %{"orgs.read" => [foreign_org], "meetings.join" => :all}
    }

    assert {:error, %{code: :unauthorized}} =
             Platform.Federation.ToolArguments.dispatch(
               "meeting_scribe_complete",
               args,
               %{agent_id: ctx.scribe.id, access_scope: scope}
             )

    assert run!(meeting).canvas_id == nil
    scope = %Platform.Access.Scope{actor: :system, permissions: %{"meetings.join" => :all}}

    assert {:ok, %{status: "triage_dispatched"}} =
             Platform.Federation.ToolArguments.dispatch(
               "meeting_scribe_complete",
               args,
               %{agent_id: ctx.scribe.id, access_scope: scope}
             )
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

  defp accepted_action!(meeting, disposition \\ :accepted) do
    Repo.insert!(%Platform.Meetings.MeetingCandidate{
      meeting_id: meeting.id,
      state: :closed,
      closed_reason: :done,
      disposition: disposition,
      classified_intent: "action_items",
      evidence_quote: "I'll repair the callback."
    })
  end

  defp provenance_canvas!(ctx) do
    {:ok, participant} = Chat.add_agent_participant(ctx.meeting.chat_space_id, ctx.scribe.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => ctx.meeting.chat_space_id,
        "created_by" => participant.id,
        "title" => "Reviewed final actions",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{
                "id" => "repair-completion",
                "type" => "checklist_item",
                "props" => %{"label" => "Repair the callback"}
              }
            ]
          }
        }
      })

    canvas
  end

  test "accepted candidate identity survives supported dispatch and real filing without backlink",
       ctx do
    candidate = accepted_action!(ctx.meeting)
    rejected = accepted_action!(ctx.meeting, :rejected)
    {meeting, run, seg} = ready!(ctx.meeting)
    candidate_id = candidate.id

    assert_receive %Phoenix.Socket.Broadcast{
      payload: %{
        signal: %{
          reason: "meeting_scribe_completion",
          accepted_action_candidates: [%{id: ^candidate_id}]
        }
      }
    }

    payload = Completion.dispatch_payload(run.transcript_id)

    assert payload.accepted_action_candidates ==
             [%{id: candidate.id, quote: candidate.evidence_quote, canvas_id: nil}]

    assert payload.candidate_provenance_instructions =~ "candidate_ids"
    refute Enum.any?(payload.accepted_action_candidates, &(&1.id == rejected.id))

    canvas = provenance_canvas!(ctx)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)

    item = %{
      "item_id" => "repair-completion",
      "candidate_ids" => [candidate.id],
      "title" => "Repair the callback",
      "description" => "Implement the agreed callback repair.",
      "source_segment_ids" => [seg["id"]]
    }

    assert {:ok, %{task_ids: [task_id]}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", [item]))

    assert run!(meeting).item_results["repair-completion"]["candidate_ids"] == [candidate.id]
    assert is_nil(Repo.get!(Platform.Meetings.MeetingCandidate, candidate.id).task_id)

    assert {:ok, %{task_ids: [^task_id]}} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", [item]))

    assert {:error, :invalid_candidate_provenance} =
             Completion.triage_file(
               ctx.triage.id,
               Map.put(args, "action_items", [Map.put(item, "candidate_ids", [])])
             )

    {:ok, brief, _} = Platform.Meetings.MeetingBriefings.build(meeting)
    assert brief.items["_content"]["unfiled_action_items"] == []

    assert brief.items[Platform.Meetings.MeetingBriefings.node_key("task:" <> task_id)]["ref"] ==
             "task:" <> task_id
  end

  test "triage refuses absent invalid rejected foreign and uncovered candidate identities", ctx do
    candidate = accepted_action!(ctx.meeting)
    rejected = accepted_action!(ctx.meeting, :rejected)

    {:ok, foreign_meeting} =
      Meetings.create_meeting(%{project_id: ctx.project.id, name: "Other meeting"})

    foreign = accepted_action!(foreign_meeting)
    {meeting, run, seg} = ready!(ctx.meeting)
    canvas = provenance_canvas!(ctx)
    args = params(meeting, run, canvas)
    assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)

    item = %{
      "item_id" => "repair-completion",
      "title" => "Repair callback",
      "description" => "Repair the agreed callback.",
      "source_segment_ids" => [seg["id"]]
    }

    for ids <- [nil, [], "not-a-list", [Ecto.UUID.generate()], [rejected.id], [foreign.id]] do
      input = if is_nil(ids), do: item, else: Map.put(item, "candidate_ids", ids)

      assert {:error, :invalid_candidate_provenance} =
               Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", [input]))
    end

    assert {:error, :invalid_candidate_provenance} =
             Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", []))

    assert run!(meeting).item_results == %{}

    assert {:ok, %{task_ids: []}} =
             Completion.triage_file(
               ctx.triage.id,
               Map.put(args, "action_items", [
                 %{
                   "item_id" => "repair-completion",
                   "candidate_ids" => [candidate.id],
                   "decision" => "exclude"
                 }
               ])
             )

    {:ok, brief, _} = Platform.Meetings.MeetingBriefings.build(meeting)
    assert Enum.map(brief.items["_content"]["unfiled_action_items"], & &1["id"]) == [candidate.id]
  end
end

defmodule Platform.Meetings.CompletionIndependentConnectionsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Platform.{Repo, Roles}
  alias Platform.Meetings.{Completion, CompletionTest}
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Recorder do
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      send(:persistent_term.get({__MODULE__, :owner}), {:notif, user_id, payload})
      :ok
    end
  end

  @tag timeout: 60_000
  test "simultaneous filing and delivery on distinct PostgreSQL connections each arbitrate once" do
    Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    previous = Map.new(~w(meeting_scribe triage_officer), &{&1, Roles.agent_id_for_role(&1)})
    ctx = CompletionTest.fixture!()

    owned_audit =
      from(e in Platform.Audit.Event,
        where: fragment("?->>'meeting_id'", e.metadata) == ^ctx.meeting.id
      )

    resources =
      Enum.map([ctx.scribe, ctx.triage], fn agent ->
        agent = Repo.get!(Platform.Agents.Agent, agent.id)
        runtime = Repo.get!(Platform.Agents.AgentRuntime, agent.runtime_id)
        {agent.id, runtime.id, runtime.owner_user_id}
      end)

    try do
      {meeting, run, segment} = CompletionTest.ready!(ctx.meeting)
      canvas = CompletionTest.completion_canvas!(meeting.chat_space_id, ctx.scribe)
      args = CompletionTest.params(meeting, run, canvas)
      assert {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
      {:ok, _server} = Platform.Chat.Canvas.Server.start_server(canvas.id)
      Platform.Chat.Canvas.Server.describe(canvas.id)

      args =
        Map.put(args, "action_items", [
          %{
            "item_id" => "repair-completion",
            "title" => "Repair concurrent meeting completion",
            "description" => "Repair the completion callback agreed in the cited segment.",
            "source_segment_ids" => [segment["id"]]
          }
        ])

      parent = self()

      workers =
        for _ <- 1..2 do
          Elixir.Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:ready, self(), backend})

              receive do
                :file -> Completion.triage_file(ctx.triage.id, args)
              end
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      assert_receive {:ready, first, backend_a}, 5_000
      assert_receive {:ready, second, backend_b}, 5_000
      refute backend_a == backend_b
      send(first, :file)
      send(second, :file)
      results = Enum.map(workers, &Elixir.Task.await(&1, 30_000))
      assert [{:ok, %{task_ids: [task_id]}}, {:ok, %{task_ids: [task_id]}}] = results

      assert Repo.aggregate(
               from(t in Platform.Tasks.Task,
                 where: fragment("?->>'completion_run_id'", t.metadata) == ^run.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in owned_audit,
                 where: e.event_type in ["meetings.triage.dispatch", "meetings.tasks_created"]
               ),
               :count
             ) == 2

      assert length(CompletionTest.junk_controls!(canvas)) == 1

      # Filing above and delivery below run on independent, committed connections.
      # The shared DataCase sandbox cannot exercise PostgreSQL row-lock arbitration.
      room =
        Repo.insert!(%Platform.Meetings.Room{
          space_id: meeting.chat_space_id,
          livekit_room_name: "race-#{meeting.id}"
        })

      attendee_ids = Enum.map(resources, fn {_, _, user_id} -> user_id end)

      for user_id <- attendee_ids do
        Repo.insert!(%Platform.Meetings.Participant{
          room_id: room.id,
          user_id: user_id,
          display_name: "Race attendee",
          joined_at: DateTime.add(meeting.ended_at, -10)
        })
      end

      recorder = Recorder
      previous_notifications = Application.get_env(:platform, :notifications_module)
      Application.put_env(:platform, :notifications_module, recorder)
      recorder.install(self())

      try do
        deliveries =
          for _ <- 1..3 do
            Elixir.Task.async(fn ->
              :ok = Sandbox.checkout(Repo, sandbox: false)

              try do
                [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {:delivery_ready, self(), backend})

                receive do
                  :deliver -> Platform.Meetings.MeetingBriefings.deliver(meeting)
                end
              after
                Sandbox.checkin(Repo)
              end
            end)
          end

        connections =
          for _ <- deliveries do
            assert_receive {:delivery_ready, pid, backend}, 5_000
            {pid, backend}
          end

        assert connections |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 3
        Enum.each(connections, fn {pid, _} -> send(pid, :deliver) end)
        results = Enum.map(deliveries, &Elixir.Task.await(&1, 30_000))
        assert Enum.count(results, &match?({:ok, %{created: 2}}, &1)) == 1
        assert Enum.count(results, &match?({:ok, %{created: 0}}, &1)) == 2

        for user_id <- attendee_ids do
          assert Repo.aggregate(
                   from(i in Platform.Inbox.Item,
                     where: i.user_id == ^user_id and i.kind == "meeting_briefing"
                   ),
                   :count
                 ) == 1

          assert_received {:notif, ^user_id, _}
          refute_received {:notif, ^user_id, _}
        end

        assert {:ok, %{created: 0}} = Platform.Meetings.MeetingBriefings.deliver(meeting)
        refute_received {:notif, _, _}
      after
        if previous_notifications do
          Application.put_env(:platform, :notifications_module, previous_notifications)
        else
          Application.delete_env(:platform, :notifications_module)
        end

        :persistent_term.erase({recorder, :owner})
        Repo.delete_all(from(i in Platform.Inbox.Item, where: i.user_id in ^attendee_ids))
      end

      Platform.Chat.Canvas.Server.stop(canvas.id)
    after
      for {role, agent_id} <- previous do
        :ok = Roles.unassign_role(role)
        if agent_id, do: Roles.assign_role(role, agent_id)
      end

      # These connections intentionally bypass sandbox rollback. Their telemetry
      # audit rows must be removed with the fixture, not leak into later modules.
      Repo.delete_all(owned_audit)
      assert Repo.aggregate(owned_audit, :count) == 0

      Repo.delete_all(from(t in Platform.Tasks.Task, where: t.project_id == ^ctx.project.id))
      Repo.delete_all(from(m in Platform.Meetings.Meeting, where: m.id == ^ctx.meeting.id))

      Repo.delete_all(
        from(t in Platform.Meetings.Transcript, where: t.space_id == ^ctx.meeting.chat_space_id)
      )

      Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^ctx.meeting.chat_space_id))
      Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^ctx.project.id))

      for {agent_id, runtime_id, user_id} <- resources do
        Repo.update_all(from(a in Platform.Agents.Agent, where: a.id == ^agent_id),
          set: [runtime_id: nil]
        )

        Repo.delete_all(from(r in Platform.Agents.AgentRuntime, where: r.id == ^runtime_id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent_id))
        Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user_id))
      end

      Sandbox.checkin(Repo)
      Sandbox.mode(Repo, :manual)
    end
  end
end

