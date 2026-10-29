defmodule Platform.Social.EpisodeDiscoveryTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures

  alias Platform.Files
  alias Platform.Files.File, as: SourceFile

  alias Platform.Social.{
    Clip,
    ClipJob,
    ClipJobs,
    EpisodeDiscovery,
    EpisodePipeline,
    Post,
    Profile
  }

  setup do
    world = render_world!()
    previous = Application.get_env(:social, :episode_discovery)
    on_exit(fn -> Application.put_env(:social, :episode_discovery, previous) end)
    %{w: world}
  end

  defp upload!(w, name \\ "episode.mp4", type \\ "video/mp4", opts \\ []) do
    {:ok, file, false} =
      Files.add_bytes(
        w.project,
        "video #{unique()}",
        name,
        type,
        Keyword.merge([ingest: false, uploaded_by_user_id: w.approver.id], opts)
      )

    file
  end

  defp activate!(w) do
    {:ok, pipeline} = EpisodeDiscovery.activate(w.profile)
    pipeline
  end

  defp jobs(w), do: Repo.all(from(j in ClipJob, where: j.profile_id == ^w.profile.id))

  test "first activation excludes the historical catalog and never moves its cutoff", %{w: w} do
    old = upload!(w)
    assert EpisodeDiscovery.sweep([w.profile.id]) == []
    pipeline = Repo.get_by!(EpisodePipeline, profile_id: w.profile.id)
    assert DateTime.compare(old.inserted_at, pipeline.activated_at) == :lt
    assert EpisodeDiscovery.sweep([w.profile.id], DateTime.add(DateTime.utc_now(), 3600)) == []
    assert Repo.get!(EpisodePipeline, pipeline.id).activated_at == pipeline.activated_at
    assert jobs(w) == []
  end

  test "storage-ready inline video queues a source job without text extraction or fabricated human",
       %{w: w} do
    pipeline = activate!(w)
    file = upload!(w)
    assert file.ingest_intent == "human_only"
    refute file.ingest_status == "ingested"
    assert [{:ok, job}] = EpisodeDiscovery.sweep([w.profile.id])
    assert job.kind == "episode"
    assert job.status == "queued"
    assert job.source_file_id == file.id
    assert job.episode_pipeline_id == pipeline.id
    assert job.clip_id == nil
    assert job.requested_by_user_id == nil
    assert job.payload["episode"] == %{"source_file_id" => file.id}
    assert job.payload["pipeline_version"] == "episode-v1"
    assert job.payload["project_id"] == w.project.id
    assert Repo.aggregate(Clip, :count) == 0
  end

  test "presigned reservation queues only after finalize commits bytes", %{w: w} do
    activate!(w)

    {:ok, stat} =
      Files.Storage.put({:binary, "presigned #{unique()}"}, w.project.id, filename: "episode.mp4")

    {:ok, reservation} =
      Files.create_file(%{
        project_id: w.project.id,
        org_id: w.org_id,
        uploaded_by_user_id: w.approver.id,
        original_filename: "episode.mp4",
        content_type: "video/mp4",
        storage_key: stat.storage_key,
        byte_size: stat.byte_size,
        content_hash: nil,
        ingest_status: "pending",
        ingest_intent: "human_only"
      })

    assert EpisodeDiscovery.sweep([w.profile.id]) == []
    {:ok, %{file: ready}} = Files.finalize_presigned_upload(reservation, stat)
    assert is_binary(ready.content_hash)
    assert [{:ok, job}] = EpisodeDiscovery.sweep([w.profile.id])
    assert job.source_file_id == reservation.id

    assert {:error, :not_pending} =
             Files.finalize_presigned_upload(Repo.get!(SourceFile, reservation.id), stat)

    assert EpisodeDiscovery.sweep([w.profile.id]) == []
    assert length(jobs(w)) == 1
  end

  test "concurrent enqueue and repeated scans reuse one durable job even after failure", %{w: w} do
    pipeline = activate!(w)
    source = upload!(w)

    results =
      1..5
      |> Task.async_stream(fn _ -> ClipJobs.enqueue_episode(pipeline.id, source.id) end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.to_list()

    ids = Enum.map(results, fn {:ok, {:ok, job}} -> job.id end)
    assert length(Enum.uniq(ids)) == 1
    assert length(jobs(w)) == 1
    [job] = jobs(w)
    job |> ClipJob.finish_changeset(:failed, "TEST_FAILURE") |> Repo.update!()
    assert EpisodeDiscovery.sweep([w.profile.id]) == []
    assert length(jobs(w)) == 1
  end

  test "database uniqueness rejects a second source identity independently of discovery", %{w: w} do
    pipeline = activate!(w)
    source = upload!(w)
    {:ok, job} = ClipJobs.enqueue_episode(pipeline.id, source.id)

    duplicate =
      ClipJob.enqueue_changeset(%ClipJob{}, %{
        profile_id: w.profile.id,
        source_file_id: source.id,
        episode_pipeline_id: pipeline.id,
        kind: "episode",
        payload: job.payload
      })

    assert {:error, cs} = Repo.insert(duplicate, mode: :savepoint)
    assert errors_on(cs).profile_id == ["has already been taken"]
  end

  test "restart recovers a new upload missed while the discovery worker was stopped", %{w: w} do
    pipeline = activate!(w)

    worker =
      start_supervised!(
        {EpisodeDiscovery,
         name: :episode_restart_probe,
         profile_ids: [w.profile.id],
         interval_ms: :infinity,
         boot_sweep: false}
      )

    assert EpisodeDiscovery.sweep_now(worker) == []
    stop_supervised!(EpisodeDiscovery)
    source = upload!(w)

    start_supervised!(
      {EpisodeDiscovery,
       name: :episode_restart_probe,
       profile_ids: [w.profile.id],
       interval_ms: :infinity,
       boot_sweep: true,
       notify: self()}
    )

    assert_receive {:episode_discovery, [{:ok, %ClipJob{source_file_id: id}}]}, 2000
    assert id == source.id
    assert Repo.get!(EpisodePipeline, pipeline.id).activated_at == pipeline.activated_at
    assert length(jobs(w)) == 1
  end

  test "periodic worker discovers an upload without a manual sweep or ingest event", %{w: w} do
    activate!(w)

    start_supervised!(
      {EpisodeDiscovery,
       name: :episode_timer_probe,
       profile_ids: [w.profile.id],
       interval_ms: 10,
       boot_sweep: false,
       notify: self()}
    )

    source = upload!(w)
    assert_receive {:episode_discovery, [{:ok, %ClipJob{source_file_id: id}}]}, 2000
    assert id == source.id
    assert length(jobs(w)) == 1
  end

  test "provenance excludes runner outputs, clip renders, covers, outro assets, images and deleted files",
       %{w: w} do
    activate!(w)
    output = upload!(w, "ordinary.mp4", "video/mp4", uploaded_by_user_id: nil)
    image = upload!(w, "episode.png", "image/png")
    deleted = upload!(w)
    {:ok, _} = Files.delete_file(w.approver, deleted)
    cover = upload!(w)
    Repo.insert!(%Post{account_id: w.x.id, body: "cover fixture", cover_file_id: cover.id})
    render = upload!(w)

    {:ok, clip} =
      Platform.Social.AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => render.id,
          "title" => "render fixture"
        },
        w.agent.id
      )

    assert clip.render_file_id == render.id
    current_render = upload!(w)
    clip |> Ecto.Changeset.change(render_file_id: current_render.id) |> Repo.update!()
    # The previous rev is still an asset through ClipRender, even after
    # the clip's current render changes.
    outro = upload!(w)
    Application.put_env(:social, :episode_discovery, asset_file_ids: [outro.id])
    brand_asset = upload!(w)

    w.profile
    |> Ecto.Changeset.change(brand: %{"outro_file_id" => brand_asset.id})
    |> Repo.update!()

    assert EpisodeDiscovery.sweep([w.profile.id]) == []

    for file <- [output, image, deleted, cover, render, current_render, outro, brand_asset] do
      assert jobs(w) == []

      refute EpisodeDiscovery.eligible?(
               Repo.get!(SourceFile, file.id),
               Repo.get!(Profile, w.profile.id),
               Repo.get_by!(EpisodePipeline, profile_id: w.profile.id)
             )
    end

    source = upload!(w, "not-guessed-from-name.mp4")
    assert [{:ok, job}] = EpisodeDiscovery.sweep([w.profile.id])
    assert job.source_file_id == source.id
  end

  test "internal path rejects another project's file and a cross-tenant profile/project pairing",
       %{w: w} do
    other = render_world!()
    pipeline = activate!(w)
    foreign = upload!(other)
    assert {:error, :ineligible_episode} = ClipJobs.enqueue_episode(pipeline.id, foreign.id)
    source = upload!(w)
    w.profile |> Ecto.Changeset.change(project_id: other.project.id) |> Repo.update!()
    assert EpisodeDiscovery.sweep([w.profile.id]) == [{:error, :episode_profile_unavailable}]
    assert {:error, :ineligible_episode} = ClipJobs.enqueue_episode(pipeline.id, source.id)
    assert jobs(w) == []
    assert jobs(other) == []
  end
end
