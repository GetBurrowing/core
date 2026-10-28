defmodule Platform.Meetings.MeetingBriefingsBuildTest do
  @moduledoc """
  `Platform.Meetings.MeetingBriefings.build/1` (task 01a1694a stage 1): one
  row per meeting, its items, and the pure-merge contract — a rebuild adds
  what is new and never overwrites an item or a receipt.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.CompletionRun
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.Transcript
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp meeting_fixture!(name) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Briefing Project #{n}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Scribe",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => meeting.chat_space_id,
        "created_by" => participant.id,
        "title" => "Bucket policy #{n}"
      })

    %{meeting: meeting, project: project, canvas: canvas}
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp go_live!(%Meeting{} = meeting, started_at) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: started_at}) |> Repo.update()

    live
  end

  defp end!(%Meeting{} = meeting) do
    {:ok, ended} =
      meeting
      |> Meeting.status_changeset("ended", %{ended_at: DateTime.utc_now()})
      |> Repo.update()

    ended
  end

  # Historical live-minted task fixture; live code must no longer create it.
  defp graduate!(meeting, quote) do
    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: meeting.project_id,
        title: quote,
        metadata: %{
          "source" => "meetings.candidate",
          "meeting_id" => meeting.id,
          "candidate_id" => Ecto.UUID.generate()
        }
      })

    task
  end

  defp file!(canvas, project, title) do
    {:ok, %{filed: [%TaskRecord{} = task]}} =
      Triage.file_tasks_from_canvas(canvas,
        project_id: project.id,
        action_items: [%{title: title}]
      )

    task
  end

  defp artifact_candidate!(%Meeting{} = meeting, canvas) do
    %MeetingCandidate{}
    |> MeetingCandidate.changeset(%{
      meeting_id: meeting.id,
      state: :closed,
      closed_reason: :done,
      outcome_kind: :artifact,
      canvas_id: canvas.id,
      evidence_quote: "let us draft the bucket policy"
    })
    |> Repo.insert!()
  end

  defp items(%MeetingBriefing{items: items}),
    do: Map.delete(items, MeetingBriefings.content_key())

  defp refs_by_kind(briefing) do
    briefing
    |> items()
    |> Map.values()
    |> Enum.group_by(& &1["kind"], & &1["ref"])
    |> Map.new(fn {kind, refs} -> {kind, Enum.sort(refs)} end)
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  test "builds one item per filed task and created canvas, with the right kinds" do
    %{meeting: meeting, project: project, canvas: canvas} = meeting_fixture!("Four items")
    meeting = go_live!(meeting, ago(60))

    live_a = graduate!(meeting, "somebody should rotate the S3 keys")
    live_b = graduate!(meeting, "somebody should renew the TLS certs")
    triaged = file!(canvas, project, "Draft the rollback runbook")
    artifact_candidate!(meeting, canvas)

    meeting = end!(meeting)

    assert {:ok, %MeetingBriefing{} = briefing, delta} = MeetingBriefings.build(meeting)

    assert refs_by_kind(briefing) == %{
             "task" =>
               Enum.sort(["task:" <> live_a.id, "task:" <> live_b.id, "task:" <> triaged.id]),
             "canvas" => ["canvas:" <> canvas.id]
           }

    assert map_size(items(briefing)) == 4
    assert Enum.sort(delta.new_keys) == Enum.sort(Map.keys(items(briefing)))

    # Keys are the ref digest, so a rebuild finds the same key.
    for {key, item} <- items(briefing) do
      assert key == MeetingBriefings.node_key(item["ref"])
    end

    assert items(briefing)[MeetingBriefings.node_key("task:" <> live_a.id)]["filed_status"] ==
             live_a.status

    assert briefing.items["_content"]["transcript_url"] == "/meetings/" <> meeting.slug
    assert Repo.aggregate(where(MeetingBriefing, meeting_id: ^meeting.id), :count) == 1
  end

  test "a rebuild adds a newly filed task and leaves an existing receipt byte-equal" do
    %{meeting: meeting} = meeting_fixture!("Rebuild")
    meeting = go_live!(meeting, ago(60))
    first = graduate!(meeting, "somebody should rotate the S3 keys")
    meeting = end!(meeting)

    {:ok, briefing, _} = MeetingBriefings.build(meeting)
    first_key = MeetingBriefings.node_key("task:" <> first.id)
    first_item = briefing.items[first_key]

    receipt = %{
      "verb" => "confirmed",
      "at" => "2026-10-23T12:00:00.000000Z",
      "by" => Ecto.UUID.generate(),
      "ref" => "task:" <> first.id,
      "kind" => "task"
    }

    briefing
    |> Ecto.Changeset.change(receipts: %{first_key => receipt})
    |> Repo.update!()

    second = graduate!(meeting, "somebody should renew the TLS certs")

    {:ok, rebuilt, delta} = MeetingBriefings.build(meeting)
    second_key = MeetingBriefings.node_key("task:" <> second.id)

    assert delta.new_keys == [second_key]
    assert rebuilt.id == briefing.id
    assert rebuilt.receipts == %{first_key => receipt}
    assert rebuilt.items[first_key] == first_item
    assert rebuilt.items[second_key]["ref"] == "task:" <> second.id

    reread = Repo.get!(MeetingBriefing, briefing.id)
    assert reread.receipts == %{first_key => receipt}
  end

  test "an existing item is kept when its task stops matching the rule" do
    %{meeting: meeting} = meeting_fixture!("Keep items")
    meeting = go_live!(meeting, ago(60))
    task = graduate!(meeting, "somebody should rotate the S3 keys")
    meeting = end!(meeting)

    {:ok, _briefing, _} = MeetingBriefings.build(meeting)

    task |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, rebuilt, delta} = MeetingBriefings.build(meeting)
    assert delta.new_keys == []
    assert Map.has_key?(rebuilt.items, MeetingBriefings.node_key("task:" <> task.id))
  end

  test "a meeting that is not ended returns :not_concluded and writes nothing" do
    %{meeting: meeting} = meeting_fixture!("Still live")
    meeting = go_live!(meeting, ago(10))
    graduate!(meeting, "somebody should rotate the S3 keys")

    assert MeetingBriefings.build(meeting) == {:error, :not_concluded}
    assert Repo.aggregate(where(MeetingBriefing, meeting_id: ^meeting.id), :count) == 0

    # Positive control: the same meeting, ended, does build.
    assert {:ok, %MeetingBriefing{}, _} = meeting |> end!() |> MeetingBriefings.build()
  end

  test "a soft-deleted task is excluded" do
    %{meeting: meeting} = meeting_fixture!("Soft delete")
    meeting = go_live!(meeting, ago(60))
    kept = graduate!(meeting, "somebody should rotate the S3 keys")
    gone = graduate!(meeting, "somebody should renew the TLS certs")
    gone |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
    meeting = end!(meeting)

    {:ok, briefing, _} = MeetingBriefings.build(meeting)

    assert refs_by_kind(briefing) == %{"task" => ["task:" <> kept.id]}
  end

  test "content lists open questions and unfiled action items, and the summary comes from the transcript" do
    %{meeting: meeting} = meeting_fixture!("Content")
    meeting = go_live!(meeting, ago(60))

    question =
      Repo.insert!(%MeetingCandidate{
        meeting_id: meeting.id,
        state: :heard,
        outcome_kind: :task,
        disposition: :accepted,
        classified_intent: "open_question",
        evidence_quote: "who owns the bucket policy?"
      })

    _retracted =
      Repo.insert!(%MeetingCandidate{
        meeting_id: meeting.id,
        state: :closed,
        closed_reason: :retracted,
        outcome_kind: :task,
        disposition: :accepted,
        classified_intent: "open_question",
        evidence_quote: "never mind that"
      })

    unfiled =
      Repo.insert!(%MeetingCandidate{
        meeting_id: meeting.id,
        state: :closed,
        closed_reason: :dismissed,
        outcome_kind: :task,
        disposition: :accepted,
        classified_intent: "action_items",
        evidence_quote: "someone should check the quotas"
      })

    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "room-#{Ecto.UUID.generate()}",
      space_id: meeting.chat_space_id,
      status: "complete",
      summary: "We agreed on the bucket policy.",
      completed_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    meeting = end!(meeting)
    {:ok, briefing, _} = MeetingBriefings.build(meeting)

    content = briefing.items["_content"]
    assert Enum.map(content["open_questions"], & &1["id"]) == [question.id]
    assert Enum.map(content["unfiled_action_items"], & &1["id"]) == [unfiled.id]
    assert briefing.summary == "We agreed on the bucket policy."
    assert is_binary(briefing.transcript_id)
  end

  defp content_candidate!(meeting, intent, disposition, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        MeetingCandidate,
        Map.merge(
          %{
            meeting_id: meeting.id,
            state: :closed,
            closed_reason: :done,
            classified_intent: intent,
            disposition: disposition,
            evidence_quote: "#{intent} #{inspect(disposition)}"
          },
          attrs
        )
      )
    )
  end

  test "content admits only accepted verdicts and still excludes withdrawn accepted candidates" do
    %{meeting: meeting} = meeting_fixture!("Officer verdicts")
    meeting = meeting |> go_live!(ago(60)) |> end!()

    accepted =
      for intent <- ["open_question", "action_items"] do
        kept = content_candidate!(meeting, intent, :accepted)

        for disposition <- [:rejected, :timed_out, nil] do
          content_candidate!(meeting, intent, disposition)
        end

        for reason <- [:retracted, :duplicate, :vetoed] do
          content_candidate!(meeting, intent, :accepted, %{closed_reason: reason})
        end

        kept
      end

    [question, action] = accepted
    {:ok, briefing, _} = MeetingBriefings.build(meeting)

    assert briefing.items["_content"]["open_questions"] ==
             [%{"id" => question.id, "text" => question.evidence_quote}]

    assert briefing.items["_content"]["unfiled_action_items"] ==
             [%{"id" => action.id, "text" => action.evidence_quote}]
  end

  test "completion ledger reconciles a filed action by stable identity without a task backlink" do
    %{meeting: meeting, project: project, canvas: canvas} = meeting_fixture!("Filed identity")
    meeting = meeting |> go_live!(ago(60)) |> end!()
    candidate = content_candidate!(meeting, "action_items", :accepted)

    unrelated =
      content_candidate!(meeting, "action_items", :accepted, %{
        evidence_quote: candidate.evidence_quote,
        canvas_id: canvas.id
      })

    task = file!(canvas, project, "Normalized action title")

    canvas
    |> Chat.Canvas.changeset(%{
      document: %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "type" => "stack",
          "id" => "final-actions",
          "children" => [
            %{
              "type" => "checklist_item",
              "id" => candidate.id,
              "props" => %{"label" => "Normalized action title"}
            }
          ]
        }
      }
    })
    |> Repo.update!()

    Repo.insert!(%CompletionRun{
      meeting_id: meeting.id,
      canvas_id: canvas.id,
      status: "filed",
      item_results: %{candidate.id => %{"status" => "processed", "task_ids" => [task.id]}}
    })

    {:ok, briefing, _} = MeetingBriefings.build(meeting)
    assert is_nil(Repo.get!(MeetingCandidate, candidate.id).task_id)
    assert refs_by_kind(briefing)["task"] == ["task:" <> task.id]

    assert Enum.map(briefing.items["_content"]["unfiled_action_items"], & &1["id"]) ==
             [unrelated.id]

    # A ledger reference to a deleted task cannot hide an unfiled action.
    task |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
    {:ok, rebuilt, _} = MeetingBriefings.build(meeting)

    assert Enum.sort(Enum.map(rebuilt.items["_content"]["unfiled_action_items"], & &1["id"])) ==
             Enum.sort([candidate.id, unrelated.id])
  end
end
