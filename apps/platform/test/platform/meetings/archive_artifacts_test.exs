defmodule Platform.Meetings.ArchiveArtifactsTest do
  @moduledoc """
  Tests for `Platform.Meetings.Archive.artifacts_for/2` (task `019fb954-c848`).

  The shape of two of these is load-bearing:

    * **Revision spans are asserted with `==`, never `=~`.** The failure mode
      this feature has is a *widened* span: drop the `written_at` window and
      meeting A's `"rev 1–3"` becomes `"rev 1–14"`, which CONTAINS `"rev 1"`.
      A substring assertion is green in both worlds and would ship a chip
      that credits one meeting with another's work.

    * **Every absence assertion carries a positive control in the same
      test.** "The soft-deleted canvas contributes no chip" is satisfied by a
      resolver that returns nothing at all, so the same run asserts a live
      canvas in the same space DOES contribute one. Likewise the summary /
      transcript pair asserts both directions rather than one refute.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Version, as: CanvasVersion
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "artifacts-#{n}@example.com",
      name: "Artifacts Reader #{n}",
      oidc_sub: "oidc-artifacts-#{n}"
    })
    |> Repo.insert!()
  end

  # A plain member, not "admin" — `root_admin?/1` reads admin as "sees every
  # org", which would make the viewer argument untested here.
  defp viewer_in_acme! do
    user = create_user!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp create_meeting!(name) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{name: "Artifacts Project #{n}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    meeting
  end

  # The actual window is the axis every span assertion turns on, so both ends
  # are supplied explicitly rather than through `end_meeting/1`, which stamps
  # `DateTime.utc_now()` for both.
  defp run_meeting!(%Meeting{} = meeting, started_at, ended_at) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: started_at}) |> Repo.update()

    {:ok, ended} =
      live |> Meeting.status_changeset("ended", %{ended_at: ended_at}) |> Repo.update()

    ended
  end

  defp participant!(%Meeting{} = meeting, display_name \\ "Author") do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    participant
  end

  # Inserted through the schema rather than `Chat.create_canvas/1`, which
  # writes a revision-1 `canvas_versions` row stamped `utc_now()`. These tests
  # own the revision numbers and the `written_at` values outright — an extra
  # revision the fixture did not ask for would land inside whichever window
  # happens to contain "now" and silently widen a span under test.
  defp canvas!(%Meeting{} = meeting, title, opts \\ []) do
    %Canvas{}
    |> Canvas.changeset(%{
      space_id: meeting.chat_space_id,
      created_by: participant!(meeting).id,
      title: title,
      deleted_at: Keyword.get(opts, :deleted_at)
    })
    |> Repo.insert!()
  end

  defp version!(%Canvas{} = canvas, revision, written_at) do
    %CanvasVersion{}
    |> CanvasVersion.changeset(%{
      canvas_id: canvas.id,
      revision: revision,
      document: %{"version" => 1, "revision" => revision, "root" => %{}},
      written_by: %{"type" => "user", "id" => Ecto.UUID.generate()},
      written_at: written_at
    })
    |> Repo.insert!()
  end

  defp transcript!(%Meeting{} = meeting, attrs) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{room_id: "room-#{Ecto.UUID.generate()}", space_id: meeting.chat_space_id},
        attrs
      )
    )
    |> Repo.insert!()
  end

  # An action item as the triage pipeline leaves it: a `tasks` row whose
  # `metadata.source_canvas_id` points at a canvas in the meeting's space.
  # Inserted directly rather than via `Tasks.create_task/2`, whose async
  # memory ingest would check a connection out of the sandbox.
  defp action_item!(%Meeting{} = meeting, %Canvas{} = canvas, title) do
    %TaskRecord{}
    |> TaskRecord.changeset(%{
      project_id: meeting.project_id,
      title: title,
      metadata: %{"source_canvas_id" => canvas.id}
    })
    |> Repo.insert!()
  end

  # Two meetings sharing one chat space is how the SAME canvas hangs off two
  # different rows in the archive — the pairing the design exists to show.
  defp share_space!(%Meeting{} = meeting, %Meeting{} = with_meeting) do
    meeting
    |> Ecto.Changeset.change(chat_space_id: with_meeting.chat_space_id)
    |> Repo.update!()
  end

  defp at(iso), do: DateTime.from_iso8601(iso) |> elem(1)

  defp chips(artifacts, %Meeting{id: id}), do: artifacts |> Map.fetch!(id) |> Map.fetch!(:chips)

  defp chips_of_type(artifacts, meeting, type) do
    artifacts |> chips(meeting) |> Enum.filter(&(&1.type == type))
  end

  # ── 1. Span correctness ────────────────────────────────────────────────────

  describe "artifacts_for/2 canvas revision spans" do
    test "each meeting's chip spans only the revisions written inside its own window" do
      viewer = viewer_in_acme!()

      # Meeting A ran 2026-06-11 09:00–09:30; meeting B ran 2026-07-29
      # 14:00–14:52. Revision 7 lands on 2026-07-01, between the two.
      meeting_a = create_meeting!("Assignment policy spike")
      meeting_b = create_meeting!("Experiment editor v2") |> share_space!(meeting_a)

      canvas = canvas!(meeting_a, "Bucket policy canvas")

      version!(canvas, 1, at("2026-06-11T09:05:00Z"))
      version!(canvas, 2, at("2026-06-11T09:12:00Z"))
      version!(canvas, 3, at("2026-06-11T09:29:00Z"))
      version!(canvas, 7, at("2026-07-01T10:00:00Z"))
      version!(canvas, 13, at("2026-07-29T14:10:00Z"))
      version!(canvas, 14, at("2026-07-29T14:41:00Z"))

      meeting_a = run_meeting!(meeting_a, at("2026-06-11T09:00:00Z"), at("2026-06-11T09:30:00Z"))
      meeting_b = run_meeting!(meeting_b, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      artifacts = Archive.artifacts_for(viewer, [meeting_a, meeting_b])

      [chip_a] = chips_of_type(artifacts, meeting_a, :canvas)
      [chip_b] = chips_of_type(artifacts, meeting_b, :canvas)

      # `==`, not `=~`. Dropping the `written_at` window widens meeting A's
      # span to "rev 1–14", which CONTAINS "rev 1" and every other substring
      # a `=~` assertion could reach for.
      assert chip_a.revision_label == "rev 1–3"
      assert chip_b.revision_label == "rev 13–14"

      assert chip_a.label == "Bucket policy canvas · rev 1–3"
      assert chip_b.label == "Bucket policy canvas · rev 13–14"

      assert {chip_a.revision_min, chip_a.revision_max} == {1, 3}
      assert {chip_b.revision_min, chip_b.revision_max} == {13, 14}

      # Revision 7 was written between the two meetings and belongs to
      # neither. Asserted on both labels, because a widened span shows up as
      # a bound moving past it in one direction or the other.
      refute chip_a.revision_label =~ "7"
      refute chip_b.revision_label =~ "7"

      # Same canvas, two rows — the pairing is the point.
      assert chip_a.canvas_id == canvas.id
      assert chip_b.canvas_id == canvas.id
    end

    test "a canvas with exactly one in-window revision renders no dash" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Ops review")
      canvas = canvas!(meeting, "Ops runbook")
      version!(canvas, 14, at("2026-07-29T14:20:00Z"))

      meeting = run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      artifacts = Archive.artifacts_for(viewer, [meeting])
      [chip] = chips_of_type(artifacts, meeting, :canvas)

      assert chip.revision_label == "rev 14"
      assert chip.label == "Ops runbook · rev 14"
      assert {chip.revision_min, chip.revision_max} == {14, 14}
    end

    test "a canvas whose only revisions fall outside the window contributes no chip, while one written during it does" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Retention review")

      touched = canvas!(meeting, "Retention plan")
      version!(touched, 4, at("2026-07-29T14:20:00Z"))

      untouched = canvas!(meeting, "Older artifact")
      version!(untouched, 9, at("2026-07-20T11:00:00Z"))

      meeting = run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      canvas_chips = chips_of_type(Archive.artifacts_for(viewer, [meeting]), meeting, :canvas)
      titles = Enum.map(canvas_chips, & &1.title)

      # Positive control first: "Older artifact" is absent from a list that
      # is demonstrably not empty.
      assert titles == ["Retention plan"]
      refute "Older artifact" in titles
      refute untouched.id in Enum.map(canvas_chips, & &1.canvas_id)
    end
  end

  # ── 2. Soft deletion ───────────────────────────────────────────────────────

  describe "artifacts_for/2 soft-deleted canvases" do
    test "a deleted canvas contributes no chip and a live one in the same space does" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Experiment editor v2")

      live = canvas!(meeting, "Popover sketch")
      version!(live, 2, at("2026-07-29T14:15:00Z"))

      deleted = canvas!(meeting, "Abandoned sketch", deleted_at: at("2026-07-30T09:00:00Z"))
      version!(deleted, 5, at("2026-07-29T14:20:00Z"))

      meeting = run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      canvas_chips = chips_of_type(Archive.artifacts_for(viewer, [meeting]), meeting, :canvas)

      # The positive control and the absence assertion in one run: without
      # the first, "the deleted canvas is absent" is satisfied by a resolver
      # that returned nothing at all.
      assert Enum.map(canvas_chips, & &1.title) == ["Popover sketch"]
      assert Enum.map(canvas_chips, & &1.canvas_id) == [live.id]
      refute deleted.id in Enum.map(canvas_chips, & &1.canvas_id)
    end
  end

  # ── 3. Summary and transcript ──────────────────────────────────────────────

  describe "artifacts_for/2 summary and transcript chips" do
    test "the two chips resolve independently from the same transcript row, in both directions" do
      viewer = viewer_in_acme!()

      summarised = create_meeting!("Budget sync")
      transcript!(summarised, %{summary: "We settled the bucket policy.", segments: []})

      summarised =
        run_meeting!(summarised, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:30:00Z"))

      recorded = create_meeting!("Latency triage")

      # A blank-but-present summary is the same state as no summary: the chip
      # would render an empty document.
      transcript!(recorded, %{summary: "   ", segments: [%{"text" => "the p99 doubled"}]})
      recorded = run_meeting!(recorded, at("2026-07-29T15:00:00Z"), at("2026-07-29T15:30:00Z"))

      artifacts = Archive.artifacts_for(viewer, [summarised, recorded])

      # Both directions, both asserted positively — a pair of refutes stays
      # green when the resolver returns nothing for either meeting.
      assert Enum.map(chips(artifacts, summarised), & &1.type) == [:summary]
      assert Enum.map(chips(artifacts, recorded), & &1.type) == [:transcript]

      assert [%{label: "Summary"}] = chips_of_type(artifacts, summarised, :summary)
      assert [] == chips_of_type(artifacts, summarised, :transcript)

      assert [%{label: "Transcript"}] = chips_of_type(artifacts, recorded, :transcript)
      assert [] == chips_of_type(artifacts, recorded, :summary)
    end
  end

  # ── 4. Action items ────────────────────────────────────────────────────────

  describe "artifacts_for/2 action items" do
    test "the chip is a count, with a shortened mobile label" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Experiment editor v2")
      canvas = canvas!(meeting, "Action items")

      action_item!(meeting, canvas, "Write the bucket policy migration")
      action_item!(meeting, canvas, "Draft the rollback runbook")
      action_item!(meeting, canvas, "Schedule the follow-up")

      meeting = run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      artifacts = Archive.artifacts_for(viewer, [meeting])

      assert [chip] = chips_of_type(artifacts, meeting, :action_items)
      assert chip.count == 3
      assert chip.label == "3 action items"
      assert chip.short_label == "3 actions"
    end
  end

  # ── 5. Row context ─────────────────────────────────────────────────────────

  describe "artifacts_for/2 row context" do
    test "carries the duration, host, attendee count and project path the subtitle renders" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Experiment editor v2")
      host = participant!(meeting, "Rowan")
      participant!(meeting, "Dalton")
      participant!(meeting, "Vega")

      meeting = meeting |> Ecto.Changeset.change(host_participant_id: host.id) |> Repo.update!()
      meeting = run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      project = Repo.get!(Project, meeting.project_id)
      org = Repo.get!(Org, project.org_id)

      context = Map.fetch!(Archive.artifacts_for(viewer, [meeting]), meeting.id)

      assert context.duration_minutes == 52
      assert context.host_name == "Rowan"
      assert context.attendee_count == 3
      assert context.project_path == "#{org.name} / #{project.name}"
    end

    test "a cancelled meeting has no duration and no artifacts" do
      viewer = viewer_in_acme!()

      meeting = create_meeting!("Budget sync")
      canvas = canvas!(meeting, "Bucket policy canvas")
      version!(canvas, 3, at("2026-07-29T14:20:00Z"))

      {:ok, meeting} =
        meeting
        |> Meeting.status_changeset("cancelled", %{cancelled_at: at("2026-07-28T09:00:00Z")})
        |> Repo.update()

      context = Map.fetch!(Archive.artifacts_for(viewer, [meeting]), meeting.id)

      assert context.duration_minutes == nil
      assert context.chips == []
    end
  end

  # ── 6. Scoping and batching ────────────────────────────────────────────────

  describe "artifacts_for/2 scoping" do
    test "a meeting in an org the viewer has no membership in is absent from the result" do
      viewer = viewer_in_acme!()

      {:ok, project} =
        Tasks.create_project(%{name: "Soylent planning", org_id: tenant_org_id("soylent")})

      {:ok, theirs} = Meetings.create_meeting(%{project_id: project.id, name: "Soylent sync"})

      canvas = canvas!(theirs, "Their canvas")
      version!(canvas, 1, at("2026-07-29T14:20:00Z"))
      theirs = run_meeting!(theirs, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      mine = create_meeting!("Acme sync")
      mine_canvas = canvas!(mine, "My canvas")
      version!(mine_canvas, 1, at("2026-07-29T14:20:00Z"))
      mine = run_meeting!(mine, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))

      artifacts = Archive.artifacts_for(viewer, [mine, theirs])

      # Positive control alongside the exclusion: an empty map satisfies the
      # refute on its own.
      assert Map.keys(artifacts) == [mine.id]
      refute Map.has_key?(artifacts, theirs.id)
    end
  end

  describe "artifacts_for/2 batching" do
    test "issues the same number of queries for a page of six meetings as for one" do
      viewer = viewer_in_acme!()

      [one | _] = many = Enum.map(1..6, &archived_meeting_with_artifacts!("Batch #{&1}"))

      one_row = count_queries(fn -> Archive.artifacts_for(viewer, [one]) end)
      six_rows = count_queries(fn -> Archive.artifacts_for(viewer, many) end)

      # The positive control: the six-row call really did resolve six rows'
      # worth of chips, so a constant query count is batching rather than a
      # short-circuit.
      assert map_size(Archive.artifacts_for(viewer, many)) == 6

      # Pinned exactly, not `> 0`: the telemetry handler silently measuring
      # nothing would make the equality below hold at 0 == 0, and the whole
      # test would pass on a resolver that never touched the database. Six is
      # `root_admin?/1`'s membership lookup, `external_user?/1`'s membership
      # lookup, one query per chip family, and the row context — see the
      # moduledoc's "Batching".
      #
      # Both viewer-class lookups are per CALL, not per row, which is why the
      # equality below still pins the batching property. If a third viewer
      # class is ever added, this number moves again — that is the point of
      # pinning it.
      assert one_row == 6

      assert six_rows == one_row,
             "artifacts_for/2 issued #{six_rows} queries for six meetings and " <>
               "#{one_row} for one — it is resolving artifacts per row"
    end
  end

  defp archived_meeting_with_artifacts!(name) do
    meeting = create_meeting!(name)
    canvas = canvas!(meeting, "#{name} canvas")
    version!(canvas, 1, at("2026-07-29T14:20:00Z"))
    action_item!(meeting, canvas, "#{name} follow-up")
    transcript!(meeting, %{summary: "#{name} summary", segments: [%{"text" => name}]})

    run_meeting!(meeting, at("2026-07-29T14:00:00Z"), at("2026-07-29T14:52:00Z"))
  end

  defp count_queries(fun) do
    handler_id = "archive-artifacts-query-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:platform, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test_pid, {handler_id, :query}) end,
      nil
    )

    try do
      fun.()
      drain_queries(handler_id, 0)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, count) do
    receive do
      {^handler_id, :query} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
