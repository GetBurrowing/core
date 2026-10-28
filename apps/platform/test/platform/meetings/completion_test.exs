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

  def ready!(meeting) do
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

    {:ok, _} =
      Meetings.append_segment(run.transcript_id, %{
        "text" => "A late final clarification",
        "start_time" => 4
      })

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
end

defmodule Platform.Meetings.CompletionIndependentConnectionsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Platform.{Repo, Roles}
  alias Platform.Meetings.{Completion, CompletionTest}
  alias Ecto.Adapters.SQL.Sandbox

  @tag timeout: 60_000
  test "simultaneous filing on distinct PostgreSQL connections returns one task" do
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
      canvas = CompletionTest.canvas!(meeting.chat_space_id, ctx.scribe)
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
