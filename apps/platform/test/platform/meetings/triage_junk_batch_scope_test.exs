defmodule Platform.Meetings.TriageJunkBatchScopeTest do
  @moduledoc """
  `Triage.junk_batch/2` must reach BOTH filing paths for a meeting, and
  neither one belonging to a different meeting (task 01a04d9f).

  ## The two paths, and the two different keys they write

  `Triage.file_tasks_from_canvas/2` stamps `metadata["source_canvas_id"]`
  and `metadata["source"] = "meetings.triage"`. It does NOT stamp a
  `meeting_id` — `:meeting_id` is an opt it forwards into telemetry and
  reconciliation, never into `build_task_attrs/6`.

  `Candidates.graduate/2` stamps `metadata["meeting_id"]`,
  `metadata["candidate_id"]` and `metadata["source"] =
  "meetings.candidate"` (task 01a03fda / #867). It has no canvas in
  scope and stamps NO `source_canvas_id`.

  So the two paths share no metadata key. A selector on either one alone
  reaches exactly half the meeting's tasks — which is why the fix is a
  UNION of two selectors and not a widening of one.

  ## Anti-vacuity

  The refutation here is that a task from a DIFFERENT meeting, and a
  task from no meeting at all, survive. A `refute` over a set nothing
  could have added passes under every implementation, so:

    * every keeper is asserted to EXIST and be non-deleted immediately
      before the junk, in the same test, so the set is provably
      non-empty at the moment the claim is made;
    * `the keeper set is reachable by an over-broad selector` files the
      exact same fixtures and junks the OTHER meeting's canvas, showing
      each keeper is deletable by a `junk_batch/2` call and is therefore
      a real candidate for the sweep rather than an unreachable row.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Triage
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "JunkScope #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/junk-scope"
      })

    target = meeting_fixture!(project)
    other = meeting_fixture!(project)

    %{project: project, target: target, other: other}
  end

  # A meeting owns its own chat space (`Platform.Meetings.create_meeting/1`
  # mints `meeting-<id>`), and its canvases are the ones sitting in that
  # space. That `chat_canvases.space_id == meetings.chat_space_id` join is
  # the same one `Platform.Meetings.Archive` documents as the only link
  # between a meeting and a task.
  defp meeting_fixture!(project) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "JunkScope Space #{n}", slug: "junk-scope-#{n}", kind: "meeting"})

    meeting =
      %Meeting{}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "junk-scope-#{n}",
        name: "JunkScope Meeting #{n}",
        livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
      })
      |> Repo.insert!()

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "TriageAgent",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Scribe canvas #{n}"
      })

    %{meeting: meeting, space: space, canvas: canvas, participant: participant}
  end

  # The live card path, as `CandidateSweeper.fire/1` reaches it.
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

  # The post-meeting reconciliation path.
  defp file!(canvas, project, title) do
    {:ok, %{filed: [%Task{} = task]}} =
      Triage.file_tasks_from_canvas(canvas,
        project_id: project.id,
        action_items: [%{title: title}]
      )

    task
  end

  defp deleted?(%Task{id: id}), do: not is_nil(Repo.get!(Task, id).deleted_at)

  defp alive!(%Task{id: id} = task, label) do
    row = Repo.get!(Task, id)

    refute row.deleted_at,
           "#{label} must exist and be non-deleted before the junk — " <>
             "otherwise the refutation below is vacuous"

    task
  end

  # ── What each path actually stamps ──────────────────────────────────────

  describe "the metadata the two paths write" do
    test "the live path stamps meeting_id and no source_canvas_id",
         %{target: target} do
      task = graduate!(target.meeting, "somebody should chase the SOC2 renewal")

      assert task.metadata["meeting_id"] == target.meeting.id
      assert task.metadata["source"] == "meetings.candidate"
      assert is_binary(task.metadata["candidate_id"])

      refute Map.has_key?(task.metadata, "source_canvas_id"),
             "graduate/2 has no canvas in scope; if it gains one this test " <>
               "is the place that says so"
    end

    test "the triage path stamps source_canvas_id and no meeting_id",
         %{project: project, target: target} do
      task = file!(target.canvas, project, "Chase the SOC2 renewal")

      assert task.metadata["source_canvas_id"] == target.canvas.id
      assert task.metadata["source"] == "meetings.triage"

      refute Map.has_key?(task.metadata, "meeting_id"),
             "file_tasks_from_canvas/2 forwards :meeting_id into telemetry " <>
               "and reconciliation only, never into the task's metadata — " <>
               "which is why junk_batch/2 cannot key on meeting_id alone"
    end
  end

  # ── The sweep ───────────────────────────────────────────────────────────

  describe "junk_batch/2 reaches both paths for one meeting" do
    test "removes the live-path task, the triage-path task, and nothing else",
         %{project: project, target: target, other: other} do
      live = graduate!(target.meeting, "somebody should rotate the S3 keys")
      triaged = file!(target.canvas, project, "Rotate the S3 access keys")

      # The keepers. Each is asserted alive immediately below, so the
      # refutes at the bottom are claims about a provably non-empty set.
      other_live = graduate!(other.meeting, "we should renew the TLS certs")
      other_triaged = file!(other.canvas, project, "Renew the TLS certificates")

      {:ok, standalone} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Task nobody filed from a meeting",
          status: "backlog"
        })

      alive!(live, "the live-path task")
      alive!(triaged, "the triage-path task")
      alive!(other_live, "the other meeting's live-path task")
      alive!(other_triaged, "the other meeting's triage-path task")
      alive!(standalone, "the non-meeting task")

      assert {:ok, 2} = Triage.junk_batch(target.canvas)

      assert deleted?(live),
             "the task graduate/2 filed for this meeting must be swept"

      assert deleted?(triaged),
             "POSITIVE CONTROL: the triage path's existing behaviour must " <>
               "not regress"

      refute deleted?(other_live), "another meeting's live-path task"
      refute deleted?(other_triaged), "another meeting's triage-path task"
      refute deleted?(standalone), "a task with no meeting provenance at all"
    end

    test "the keeper set is reachable — junking the OTHER canvas takes them",
         %{project: project, target: target, other: other} do
      # Same fixtures as the test above, junked from the other side. If
      # the keepers there were unreachable rows, they would survive here
      # too and this test would fail — which is what makes that test's
      # refutes non-vacuous.
      _live = graduate!(target.meeting, "somebody should rotate the S3 keys")
      _triaged = file!(target.canvas, project, "Rotate the S3 access keys")

      other_live = graduate!(other.meeting, "we should renew the TLS certs")
      other_triaged = file!(other.canvas, project, "Renew the TLS certificates")

      assert {:ok, 2} = Triage.junk_batch(other.canvas)

      assert deleted?(other_live)
      assert deleted?(other_triaged)
    end

    test "a second call is still a no-op", %{project: project, target: target} do
      live = graduate!(target.meeting, "somebody should page the on-call")
      _triaged = file!(target.canvas, project, "Page the on-call rota")

      assert {:ok, 2} = Triage.junk_batch(target.canvas)
      assert {:ok, 0} = Triage.junk_batch(target.canvas)
      assert deleted?(live)
    end
  end

  describe "preview_batch/1 counts what junk_batch/2 would take" do
    test "the preview count equals the junked count",
         %{project: project, target: target, other: other} do
      graduate!(target.meeting, "somebody should rotate the S3 keys")
      file!(target.canvas, project, "Rotate the S3 access keys")
      graduate!(other.meeting, "we should renew the TLS certs")

      assert {:ok, %{surviving_task_count: 2}} = Triage.preview_batch(target.canvas)
      assert {:ok, 2} = Triage.junk_batch(target.canvas)
      assert {:ok, %{surviving_task_count: 0}} = Triage.preview_batch(target.canvas)
    end
  end

  # The widening most likely to surprise an operator, characterised
  # rather than asserted-away: two triage canvases in one meeting's
  # space. Each still sweeps only its OWN triage filings, but either one
  # sweeps the whole meeting's live-path tasks. If this is ever narrowed
  # to a canonical meeting canvas, this test is what says so.
  describe "two triage canvases in one meeting's space" do
    test "either canvas takes the meeting's live tasks; each takes only its own filings",
         %{project: project, target: target} do
      {:ok, second_canvas} =
        Chat.create_canvas(%{
          "space_id" => target.space.id,
          "created_by" => target.participant.id,
          "title" => "Re-parsed scribe canvas"
        })

      live = graduate!(target.meeting, "somebody should rotate the S3 keys")
      first_filing = file!(target.canvas, project, "Rotate the S3 access keys")
      second_filing = file!(second_canvas, project, "Audit the S3 bucket policy")

      alive!(live, "the live-path task")
      alive!(first_filing, "the first canvas's triage filing")
      alive!(second_filing, "the second canvas's triage filing")

      # Junk the SECOND canvas: its own filing plus the meeting's live task.
      assert {:ok, 2} = Triage.junk_batch(second_canvas)

      assert deleted?(second_filing)
      assert deleted?(live), "the live task is reachable from either canvas"

      refute deleted?(first_filing),
             "a canvas still sweeps only its OWN triage filings"
    end
  end

  describe "a canvas that belongs to no meeting" do
    test "still sweeps its own triage filings and nothing by meeting",
         %{project: project, target: target} do
      n = System.unique_integer([:positive])

      {:ok, loose_space} =
        Chat.create_space(%{name: "Loose #{n}", slug: "loose-#{n}", kind: "channel"})

      {:ok, loose_participant} =
        Chat.add_participant(loose_space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Loose",
          joined_at: DateTime.utc_now()
        })

      {:ok, loose_canvas} =
        Chat.create_canvas(%{
          "space_id" => loose_space.id,
          "created_by" => loose_participant.id,
          "title" => "Not a meeting canvas"
        })

      loose = file!(loose_canvas, project, "Filed from a plain channel canvas")
      live = graduate!(target.meeting, "somebody should rotate the S3 keys")

      alive!(loose, "the plain-canvas triage task")
      alive!(live, "the meeting's live-path task")

      assert {:ok, 1} = Triage.junk_batch(loose_canvas)

      assert deleted?(loose)
      refute deleted?(live), "a canvas in no meeting's space sweeps no meeting"
    end
  end
end
