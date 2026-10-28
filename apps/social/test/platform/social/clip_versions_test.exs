defmodule Platform.Social.ClipVersionsTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Social.{AgentDrafts, Clip, ClipJobs, ClipRender, ClipVersions}

  @migration Platform.Repo.Migrations.SnapshotClipRenderInputs

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Platform.Social.Extension.migrations_path()
      |> Path.join("20261027190000_snapshot_clip_render_inputs.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    world = render_world!()
    original_bytes = "version one #{unique()}"
    file = stored_file!(world.project, original_bytes, "v1.mp4", "video/mp4")
    next_file = stored_file!(world.project, "version two #{unique()}", "v2.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        world.scope,
        world.profile.id,
        %{file_id: file.id, title: "Original headline", caption: "Original caption"},
        world.agent.id
      )

    Map.merge(world, %{
      clip: clip,
      original_file: file,
      next_file: next_file,
      original_bytes: original_bytes
    })
  end

  defp rerender!(w, result) do
    {:ok, job} =
      ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{
        trim_in_s: 10.2,
        trim_out_s: 25.8
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, Map.put(result, "file_id", w.next_file.id))

    {clip, job}
  end

  test "job snapshots preserve requested and actual bounds, all metadata and old bytes", w do
    fixes = %{"word-42" => "Kubernetes"}

    {clip, job} =
      rerender!(w, %{
        "title" => "New headline",
        "caption" => "New caption",
        "actual_in_s" => 10.0,
        "actual_out_s" => 26.0,
        "caption_fixes" => fixes,
        "candidate_id" => "pick-17",
        "alternate_id" => "cut-b",
        "duration_s" => 18.0,
        "width" => 1080,
        "height" => 1920
      })

    assert clip.rev == 2
    assert clip.review_status == "pending"
    assert {:ok, [second, first]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert {second.rev, first.rev} == {2, 1}
    assert {second.requested_start_s, second.requested_end_s} == {10.2, 25.8}
    assert {second.actual_start_s, second.actual_end_s} == {10.0, 26.0}
    assert second.headline == "New headline"
    assert second.caption == "New caption"
    assert second.caption_fixes == fixes
    assert second.candidate_id == "pick-17"
    assert second.alternate_id == "cut-b"

    assert second.provenance == %{
             "kind" => "clip_job",
             "job_id" => job.id,
             "job_kind" => "rerender"
           }

    assert {second.duration_s, second.width, second.height, second.byte_size} ==
             {18.0, 1080, 1920, w.next_file.byte_size}

    assert first.headline == "Original headline"
    assert first.caption == "Original caption"
    assert first.file_id == w.original_file.id
    assert second.file_id == w.next_file.id
    assert Platform.Files.get_file(first.file_id)
    assert {:ok, stream} = Platform.Files.Storage.get(w.original_file.storage_key)
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == w.original_bytes
    assert {:ok, ^first} = ClipVersions.get(w.scope, w.profile.id, clip.id, first.id)
  end

  test "tool bounds not reported by the runner remain unknown", w do
    {clip, _job} = rerender!(w, %{})
    {:ok, [version | _]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert version.requested_start_s == 10.2
    assert version.actual_start_s == nil
    assert version.actual_end_s == nil
    assert version.headline == nil
  end

  test "history lookup rejects another org, another profile and another clip", w do
    other = render_world!()
    {:ok, [first]} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)

    {:ok, same_org_profile} =
      Platform.Social.create_profile(
        w.org_id,
        %{name: "Another profile #{unique()}", space_id: channel!(w.org_id).id}
      )

    assert {:error, :not_found} = ClipVersions.recent(other.scope, w.profile.id, w.clip.id)
    assert {:error, :not_found} = ClipVersions.recent(w.scope, same_org_profile.id, w.clip.id)
    assert {:error, :not_found} = ClipVersions.get(other.scope, w.profile.id, w.clip.id, first.id)

    assert {:error, :not_found} =
             ClipVersions.get(w.scope, same_org_profile.id, w.clip.id, first.id)

    {:ok, other_clip} =
      AgentDrafts.submit_clip(w.scope, w.profile.id, %{file_id: w.original_file.id}, w.agent.id)

    assert {:error, :not_found} = ClipVersions.get(w.scope, w.profile.id, other_clip.id, first.id)
  end

  test "duplicate append and duplicate terminal job callback never add versions", w do
    {clip, job} = rerender!(w, %{})

    assert {:error, :job_closed} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.original_file.id})

    assert {:ok, same} =
             Repo.transaction(fn ->
               ClipVersions.append!(clip.id, w.original_file, %{title: "must not change"}, %{
                 completion_key: "clip_job:" <> job.id
               })
             end)

    assert same.rev == 2
    assert same.render_file_id == w.next_file.id
    refute same.title == "must not change"
    assert {:ok, [_, _]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
  end

  test "failed re-render keeps prior history and file current and playable", w do
    {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    assert {:ok, _} = ClipJobs.fail(w.scope, job.id, w.agent.id, "render failed")

    assert {:error, :job_closed} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.next_file.id})

    assert {:ok, [version]} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)
    assert version.file_id == w.original_file.id
    assert Repo.get!(Clip, w.clip.id).render_file_id == w.original_file.id
    assert Platform.Files.get_file(version.file_id)
    assert {:ok, _} = Platform.Files.Storage.get(w.original_file.storage_key)
  end

  test "invalid snapshot rolls back promotion and leaves the job retryable", w do
    {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, w.clip.id, w.approver.id, %{})
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    assert {:error, %Ecto.Changeset{}} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{
               "file_id" => w.next_file.id,
               "actual_in_s" => 20,
               "actual_out_s" => 10
             })

    assert Repo.get!(Clip, w.clip.id).render_file_id == w.original_file.id
    assert {:ok, [_]} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)

    assert {:ok, %{clip: %{rev: 2}}} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.next_file.id})
  end

  test "legacy backfill knows file size but never borrows today's text or bounds", w do
    legacy =
      Repo.insert!(%ClipRender{
        clip_id: w.clip.id,
        rev: 2,
        file_id: w.original_file.id,
        snapshot_status: "historical_unknown",
        look: %{},
        trim_in_s: 1.0,
        trim_out_s: 9.0
      })

    w.clip
    |> Ecto.Changeset.change(
      title: "Today's title",
      caption: "Today's caption",
      start_s: 100.0,
      end_s: 200.0
    )
    |> Repo.update!()

    Repo.query!(apply(@migration, :backfill_sql, []))
    old = Repo.get!(ClipRender, legacy.id)
    assert old.byte_size == w.original_file.byte_size
    assert old.snapshot_status == "historical_unknown"

    for field <-
          ~w(headline caption actual_start_s actual_end_s source duration_s width height provenance)a,
        do: assert(Map.fetch!(old, field) == nil, "fabricated #{field}")

    assert {old.trim_in_s, old.trim_out_s} == {1.0, 9.0}
    assert {old.requested_start_s, old.requested_end_s} == {1.0, 9.0}
  end

  test "migration recovers an untracked current output without rewriting old history", w do
    {:ok, [first]} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)

    w.clip
    |> Ecto.Changeset.change(
      render_file_id: w.next_file.id,
      title: "Edited since render",
      duration_s: 15.0,
      width: 1080,
      height: 1920
    )
    |> Repo.update!()

    sql = apply(@migration, :recover_current_sql, [])
    Repo.query!(sql)
    Repo.query!(sql)
    assert {:ok, [recovered, unchanged]} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)
    assert unchanged == first
    assert recovered.rev == 2
    assert recovered.file_id == w.next_file.id
    assert recovered.duration_s == 15.0
    assert recovered.headline == nil
    assert recovered.actual_start_s == nil
    assert recovered.snapshot_status == "historical_unknown"
    assert Repo.get!(Clip, w.clip.id).rev == 2
  end
end
