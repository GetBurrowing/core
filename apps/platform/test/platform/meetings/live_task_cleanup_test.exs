defmodule Platform.Meetings.LiveTaskCleanupTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  alias Platform.{Audit.Event, Meetings, Repo, Tasks}
  alias Platform.Meetings.{MeetingCandidate, Triage}
  alias Platform.Tasks.Task

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "cleanup #{System.unique_integer([:positive])}",
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Cleanup",
        slug: "cleanup-#{System.unique_integer([:positive])}"
      })

    %{project: project, meeting: meeting}
  end

  defp task!(ctx, metadata, status \\ "backlog") do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: ctx.project.id,
        title: "cleanup fixture #{System.unique_integer([:positive])}",
        metadata: metadata
      })

    task = task |> Ecto.Changeset.change(status: status) |> Repo.update!()
    task
  end

  defp live!(ctx, via, status \\ "backlog") do
    candidate =
      Repo.insert!(%MeetingCandidate{
        meeting_id: ctx.meeting.id,
        org_id: ctx.project.org_id,
        outcome_kind: :task,
        state: :heard
      })

    task =
      task!(
        ctx,
        %{
          "source" => "meetings.candidate",
          "meeting_id" => ctx.meeting.id,
          "candidate_id" => candidate.id,
          "completed_via" => via
        },
        status
      )

    Repo.update!(Ecto.Changeset.change(candidate, task_id: task.id))
    task
  end

  defp apply_opts(extra \\ []),
    do:
      Keyword.merge(
        [
          dry_run: false,
          actor_id: "01a13fd8-a480-7000-93a3-7a5c68a769af",
          operation_id: "cleanup-test"
        ],
        extra
      )

  defp audits, do: Repo.all(from(e in Event, where: e.event_type == "meetings.live_tasks.junked"))

  test "bounded dry-run and apply include done/cancelled, preserve same-meeting officer/manual and evidence",
       ctx do
    ack = live!(ctx, "meeting_intent_ack", "done")
    sweep = live!(ctx, "countdown", "cancelled")
    deleted = live!(ctx, "countdown")
    Repo.update!(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))

    officer =
      task!(ctx, %{
        "source" => "meetings.triage",
        "source_canvas_id" => Ecto.UUID.generate(),
        "meeting_id" => ctx.meeting.id
      })

    manual = task!(ctx, %{"meeting_id" => ctx.meeting.id})

    briefing =
      Repo.insert!(%Platform.Meetings.MeetingBriefing{
        meeting_id: ctx.meeting.id,
        items: %{
          "ack" => %{"kind" => "task", "ref" => "task:" <> ack.id},
          "officer" => %{"kind" => "task", "ref" => "task:" <> officer.id},
          "_content" => %{"open_questions" => []}
        },
        receipts: %{"old" => %{"verb" => "reverted"}}
      })

    assert {:ok, %{selected: 1, changed: 0, eligible_before: 2}} =
             Triage.junk_live_tasks(limit: 1)

    assert audits() == []
    assert is_nil(Repo.get!(Task, ack.id).deleted_at)

    assert {:ok, %{changed: 1, remaining: 1, task_ids: first}} =
             Triage.junk_live_tasks(apply_opts(limit: 1))

    assert {:ok, %{changed: 1, remaining: 0, task_ids: second}} =
             Triage.junk_live_tasks(apply_opts(limit: 1))

    assert Enum.sort(first ++ second) == Enum.sort([ack.id, sweep.id])
    assert {:ok, %{changed: 0}} = Triage.junk_live_tasks(apply_opts())
    assert length(audits()) == 2
    refreshed = Repo.get!(Platform.Meetings.MeetingBriefing, briefing.id)
    refute Map.has_key?(refreshed.items, "ack")
    assert Map.has_key?(refreshed.items, "officer")
    assert refreshed.items["_content"] == %{"open_questions" => []}
    assert refreshed.receipts == briefing.receipts

    assert Enum.sort(Enum.flat_map(audits(), & &1.metadata["task_ids"])) ==
             Enum.sort([ack.id, sweep.id])

    assert Enum.all?(
             audits(),
             &(&1.resource_id == "cleanup-test" and &1.actor_id == apply_opts()[:actor_id])
           )

    assert is_nil(Repo.get!(Task, officer.id).deleted_at)
    assert is_nil(Repo.get!(Task, manual.id).deleted_at)

    assert Repo.aggregate(
             from(c in MeetingCandidate, where: c.meeting_id == ^ctx.meeting.id),
             :count
           ) == 3
  end

  test "a backlink is proof for unstamped historical tasks, but officer and inconsistent identities refuse the batch",
       ctx do
    task = task!(ctx, %{})

    candidate =
      Repo.insert!(%MeetingCandidate{
        meeting_id: ctx.meeting.id,
        outcome_kind: :task,
        state: :heard,
        task_id: task.id
      })

    assert {:ok, %{changed: 1}} = Triage.junk_live_tasks(apply_opts())

    conflict =
      task!(ctx, %{"source" => "meetings.triage", "source_canvas_id" => Ecto.UUID.generate()})

    Repo.update!(Ecto.Changeset.change(candidate, task_id: conflict.id))
    live = live!(ctx, "meeting_intent_ack")
    assert {:error, {:conflicting_live_provenance, ids}} = Triage.junk_live_tasks(apply_opts())
    assert conflict.id in ids
    assert is_nil(Repo.get!(Task, live.id).deleted_at)

    Repo.update!(
      Ecto.Changeset.change(conflict,
        metadata: %{"source" => "meetings.candidate", "meeting_id" => Ecto.UUID.generate()}
      )
    )

    assert {:error, {:conflicting_live_provenance, _}} = Triage.junk_live_tasks(apply_opts())
  end

  test "audit failure rolls back soft deletes", ctx do
    task = live!(ctx, "meeting_intent_ack")

    assert {:error, {:audit_failed, _}} =
             Triage.junk_live_tasks(apply_opts(actor_type: "invalid"))

    assert is_nil(Repo.get!(Task, task.id).deleted_at)
    assert audits() == []
  end

  test "limits and apply identity are mandatory", ctx do
    live!(ctx, "countdown")
    assert {:error, :invalid_limit} = Triage.junk_live_tasks(limit: 0)
    assert {:error, :invalid_limit} = Triage.junk_live_tasks(limit: 501)
    assert {:error, :actor_and_operation_required} = Triage.junk_live_tasks(dry_run: false)
  end

  test "pre-deployment release adapter runs the same validated cleanup boundary", ctx do
    live = live!(ctx, "meeting_intent_ack")
    File.cp!("lib/platform/meetings/triage.ex", "/tmp/meeting-live-cleanup-triage.ex")
    Code.eval_file("priv/measurements/meeting_live_cleanup/run_release.exs")

    assert {:ok, %{changed: 1, task_ids: [id]}} =
             apply(Platform.Meetings.LiveTaskCleanupOneOff, :junk_live_tasks, [apply_opts()])

    assert id == live.id
    assert length(audits()) == 1
  end

  test "source-only history is selectable but a named candidate pointing elsewhere is a conflict",
       ctx do
    orphan = task!(ctx, %{"source" => "meetings.candidate"})
    assert {:ok, %{changed: 1, task_ids: [id]}} = Triage.junk_live_tasks(apply_opts())
    assert id == orphan.id
    live = live!(ctx, "countdown")
    conflicting = task!(ctx, live.metadata)
    assert {:error, {:conflicting_live_provenance, ids}} = Triage.junk_live_tasks(apply_opts())
    assert conflicting.id in ids
    assert is_nil(Repo.get!(Task, live.id).deleted_at)
    assert is_nil(Repo.get!(Task, conflicting.id).deleted_at)
  end
end
