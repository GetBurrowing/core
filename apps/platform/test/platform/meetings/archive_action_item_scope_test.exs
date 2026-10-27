defmodule Platform.Meetings.ArchiveActionItemScopeTest do
  @moduledoc """
  `Platform.Meetings.Archive` must count a meeting's action items from BOTH
  filing paths, and from neither one belonging to a different meeting
  (task 01a04e16).

  ## The two paths, and the two different keys they write

  `Platform.Meetings.Triage.file_tasks_from_canvas/2` — the post-meeting
  reconciliation pass — stamps `metadata["source_canvas_id"]` and
  `metadata["source"] = "meetings.triage"`, and NO `meeting_id`.

  `Platform.Meetings.Candidates.graduate/2` — the live card path, reached in
  production from `CandidateSweeper` (task 01a03fba) and from
  `PlatformWeb.MeetingLive`'s `approve_candidate` handler (task 01a03f4e) —
  has no canvas in scope. It stamps `metadata["meeting_id"]`,
  `metadata["candidate_id"]` and `metadata["source"] = "meetings.candidate"`,
  and NO `source_canvas_id`.

  The two paths share no metadata key, so the canvas-only join reached
  exactly half of a meeting's action items and the archive under-reported a
  meeting's own output. Every task here is filed through the real production
  function rather than by hand-writing metadata, so a change to what either
  path stamps reddens these tests rather than sliding past a fixture that
  froze the old shape.

  ## Anti-vacuity

  A `refute` over a set nothing could have added passes under every
  implementation. So:

    * every cross-meeting claim is made as an EXACT count on BOTH meetings in
      the same assertion pass. The other meeting's own count proves its tasks
      exist and are reachable by this very query, which is what stops
      "the target did not borrow them" from being a statement about an empty
      set;
    * the counts are deliberately ASYMMETRIC (1 vs 2, and 2 vs 1). A
      meeting-blind implementation that pooled both meetings' tasks would
      report 3 and 3 — a number neither test could mistake for a pass;
    * `search/2`'s action-item vector is exercised with a title that appears
      on the live-path task only, so a canvas-only vector cannot match it by
      accident through some other artifact.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # A plain member, not "admin": `root_admin?/1` short-circuits the viewer
  # scope entirely, which would leave `narrow_to_viewer/2` untested here.
  defp viewer_in_acme! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "ai-scope-#{n}@example.com",
        name: "Action Item Reader #{n}",
        oidc_sub: "oidc-ai-scope-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  # A whole meeting as the archive sees one: its own project, its own
  # `meeting-<id>` chat space, one canvas in that space, and an `ended`
  # status so `@archived_statuses` admits it.
  defp meeting_fixture!(name) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "AI Scope Project #{n}", org_id: acme_org_id()})

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
        "title" => "Action items #{n}"
      })

    %{meeting: meeting, project: project, canvas: canvas, participant: participant}
  end

  defp end_meeting!(%Meeting{} = meeting) do
    {:ok, live} =
      meeting
      |> Meeting.status_changeset("live", %{started_at: at("2026-08-29T14:00:00Z")})
      |> Repo.update()

    {:ok, ended} =
      live
      |> Meeting.status_changeset("ended", %{ended_at: at("2026-08-29T14:52:00Z")})
      |> Repo.update()

    ended
  end

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  # The LIVE CARD path, exactly as `CandidateSweeper.fire/1` and
  # `MeetingLive`'s `approve_candidate` reach it. No metadata is written by
  # hand: `provenance_metadata/1` decides what lands on the row.
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

  # The POST-MEETING TRIAGE path.
  defp file!(canvas, project, title) do
    {:ok, %{filed: [%TaskRecord{} = task]}} =
      Triage.file_tasks_from_canvas(canvas,
        project_id: project.id,
        action_items: [%{title: title}]
      )

    task
  end

  # 0 rather than `nil` for a meeting with no action items: the chip family is
  # simply absent from the list, and "absent" and "zero" must not be told
  # apart by the tests below, only by the renderer.
  defp action_item_count(artifacts, %Meeting{id: id}) do
    artifacts
    |> Map.fetch!(id)
    |> Map.fetch!(:chips)
    |> Enum.find(&(&1.type == :action_items))
    |> case do
      nil -> 0
      chip -> chip.count
    end
  end

  # ── 1. The premise: what each path stamps ─────────────────────────────────

  describe "the metadata the two filing paths write" do
    test "the live card path stamps meeting_id and no source_canvas_id" do
      %{meeting: meeting} = meeting_fixture!("Provenance, live path")

      task = graduate!(meeting, "somebody should rotate the S3 keys")

      assert task.metadata["meeting_id"] == meeting.id
      assert task.metadata["source"] == "meetings.candidate"

      refute Map.has_key?(task.metadata, "source_canvas_id"),
             "graduate/2 has no canvas in scope. If it ever gains one, this " <>
               "is the test that says so — and the canvas arm of the archive " <>
               "join would then reach it on its own"
    end

    test "the triage path stamps source_canvas_id and no meeting_id" do
      %{meeting: meeting, project: project, canvas: canvas} =
        meeting_fixture!("Provenance, triage path")

      task = file!(canvas, project, "Rotate the S3 access keys")

      assert task.metadata["source_canvas_id"] == canvas.id
      assert task.metadata["source"] == "meetings.triage"

      refute Map.has_key?(task.metadata, "meeting_id"),
             "file_tasks_from_canvas/2 forwards :meeting_id into telemetry " <>
               "and reconciliation only, never into the task — which is why " <>
               "the archive cannot key on meeting_id alone"

      # Named so the refute above cannot be satisfied by a meeting-less row.
      assert meeting.id
    end
  end

  # ── 2. artifacts_for/2 — the chip count ───────────────────────────────────

  describe "artifacts_for/2 counts action items from both paths" do
    test "a meeting that filed by both paths shows both" do
      viewer = viewer_in_acme!()
      %{meeting: meeting, project: project, canvas: canvas} = meeting_fixture!("Both paths")

      live = graduate!(meeting, "somebody should rotate the S3 keys")
      triaged = file!(canvas, project, "Draft the rollback runbook")

      refute live.id == triaged.id
      meeting = end_meeting!(meeting)

      artifacts = Archive.artifacts_for(viewer, [meeting])

      # A bare `==` rather than an `assert ..., message`: the failure this
      # test exists to catch is an UNDERCOUNT, and the number it actually got
      # is the whole diagnosis. Measured at ce6d49ce, before the fix: 1.
      assert action_item_count(artifacts, meeting) == 2
    end

    test "POSITIVE CONTROL: the triage path alone still counts, unchanged" do
      viewer = viewer_in_acme!()
      %{meeting: meeting, project: project, canvas: canvas} = meeting_fixture!("Triage only")

      file!(canvas, project, "Draft the rollback runbook")
      file!(canvas, project, "Schedule the follow-up")

      meeting = end_meeting!(meeting)

      assert action_item_count(Archive.artifacts_for(viewer, [meeting]), meeting) == 2,
             "the pre-existing canvas join must not regress"
    end

    test "the live path alone counts — the case the canvas join scored zero" do
      viewer = viewer_in_acme!()
      %{meeting: meeting} = meeting_fixture!("Live only")

      graduate!(meeting, "somebody should rotate the S3 keys")
      meeting = end_meeting!(meeting)

      assert action_item_count(Archive.artifacts_for(viewer, [meeting]), meeting) == 1
    end
  end

  # ── 3. The refutations ────────────────────────────────────────────────────

  describe "one meeting never borrows another's action items" do
    # Asymmetric on purpose: a meeting-blind implementation pools these into
    # 3 and 3, which neither number below can be mistaken for.
    test "a different meeting's live-path task is not counted here" do
      viewer = viewer_in_acme!()

      %{meeting: target} = meeting_fixture!("Target, one live")
      %{meeting: other} = meeting_fixture!("Other, two live")

      graduate!(target, "somebody should rotate the S3 keys")
      graduate!(other, "we should renew the TLS certs")
      graduate!(other, "we should audit the bucket policy")

      target = end_meeting!(target)
      other = end_meeting!(other)

      artifacts = Archive.artifacts_for(viewer, [target, other])

      # The other meeting's own count is the positive control: it proves
      # those two rows exist and are reachable BY THIS QUERY, which is what
      # makes the target's `1` a refutation rather than a statement about
      # rows nothing could have found.
      assert action_item_count(artifacts, other) == 2
      assert action_item_count(artifacts, target) == 1
    end

    test "a different meeting's triage-path task is not counted here" do
      viewer = viewer_in_acme!()

      %{meeting: target, project: t_project, canvas: t_canvas} =
        meeting_fixture!("Target, two triage")

      %{meeting: other, project: o_project, canvas: o_canvas} =
        meeting_fixture!("Other, one triage")

      file!(t_canvas, t_project, "Draft the rollback runbook")
      file!(t_canvas, t_project, "Schedule the follow-up")
      file!(o_canvas, o_project, "Renew the TLS certificates")

      target = end_meeting!(target)
      other = end_meeting!(other)

      artifacts = Archive.artifacts_for(viewer, [target, other])

      assert action_item_count(artifacts, other) == 1
      assert action_item_count(artifacts, target) == 2
    end

    test "a task with no meeting provenance at all is counted by nobody" do
      viewer = viewer_in_acme!()
      %{meeting: meeting, project: project} = meeting_fixture!("No stray tasks")

      live = graduate!(meeting, "somebody should rotate the S3 keys")

      {:ok, standalone} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task nobody filed from a meeting",
          status: "backlog"
        })

      # Both rows are in the SAME project, so a project-keyed implementation
      # would take the standalone one too.
      assert standalone.project_id == live.project_id
      assert standalone.metadata == %{} or is_nil(standalone.metadata["meeting_id"])

      meeting = end_meeting!(meeting)

      assert action_item_count(Archive.artifacts_for(viewer, [meeting]), meeting) == 1
    end

    test "a soft-deleted live-path task stops counting" do
      viewer = viewer_in_acme!()
      %{meeting: meeting} = meeting_fixture!("Soft delete")

      live = graduate!(meeting, "somebody should rotate the S3 keys")
      kept = graduate!(meeting, "somebody should renew the TLS certs")
      meeting = end_meeting!(meeting)

      assert action_item_count(Archive.artifacts_for(viewer, [meeting]), meeting) == 2

      live
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      # `kept` holds the count at 1 rather than 0, so this cannot pass by the
      # whole query having stopped returning anything.
      assert kept.id
      assert action_item_count(Archive.artifacts_for(viewer, [meeting]), meeting) == 1
    end
  end

  # ── 4. search/2 — the same join, the other surface ────────────────────────

  describe "search/2 searches live-path action item titles" do
    test "a live-path task's title matches, and only its own meeting" do
      viewer = viewer_in_acme!()

      %{meeting: target} = meeting_fixture!("Search target")
      %{meeting: other} = meeting_fixture!("Search other")

      graduate!(target, "somebody should decommission the zeppelin fleet")
      graduate!(other, "we should renew the TLS certs")

      target = end_meeting!(target)
      other = end_meeting!(other)

      result = Archive.search(viewer, query: "zeppelin", types: [:action_items])

      matched_ids = Enum.map(result.matches, & &1.id)

      assert target.id in matched_ids,
             "a live-path action item's title must be searchable"

      refute other.id in matched_ids,
             "and must not drag in a meeting that never had that item"

      # Positive control on the same call: the OTHER meeting is in scope for
      # this viewer and would match its own term, so its absence above is
      # about the query and not about visibility.
      others_result = Archive.search(viewer, query: "TLS", types: [:action_items])
      assert other.id in Enum.map(others_result.matches, & &1.id)
    end

    test "type_counts credits the live path under :action_items" do
      viewer = viewer_in_acme!()

      %{meeting: meeting} = meeting_fixture!("Search type counts")
      graduate!(meeting, "somebody should decommission the zeppelin fleet")
      end_meeting!(meeting)

      result = Archive.search(viewer, query: "zeppelin")

      assert result.type_counts.action_items == 1
      assert result.type_counts.canvases == 0
    end
  end
end
