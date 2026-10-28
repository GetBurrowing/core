defmodule Platform.Social.EpisodePipelineE2ETest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Files

  alias Platform.Social.{
    Clip,
    ClipJob,
    ClipRender,
    EpisodeDiscovery,
    EpisodeFakeRunner,
    EpisodePipeline,
    Post
  }

  alias Platform.Social.Publisher.Fake

  setup do
    w = render_world!()
    {:ok, activation} = EpisodeDiscovery.activate(w.profile)
    Fake.reset()
    start_discovery!(w)
    %{w: w, activation: activation}
  end

  defp start_discovery!(w) do
    start_supervised!(
      {EpisodeDiscovery,
       name: :episode_e2e_discovery,
       profile_ids: [w.profile.id],
       interval_ms: 10,
       boot_sweep: true,
       notify: self()}
    )
  end

  defp stop_discovery! do
    # Finish the current DB call before terminating a sandbox-sharing worker.
    :sys.suspend(Process.whereis(:episode_e2e_discovery))
    stop_supervised!(EpisodeDiscovery)
    drain_notifications()
  end

  defp drain_notifications do
    receive do
      {:episode_discovery, _} -> drain_notifications()
    after
      0 -> :ok
    end
  end

  defp upload!(w) do
    # Real committed upload; never direct enqueue or preinserted final clips.
    bytes = File.read!(Path.expand("../../support/fixtures/episode_pipeline/source.mp4", __DIR__))

    {:ok, file, false} =
      Files.add_bytes(w.project, bytes, "episode-#{unique()}.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: w.approver.id
      )

    file
  end

  defp discovered!(source_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2000
    remaining = max(0, deadline - System.monotonic_time(:millisecond))
    assert_receive {:episode_discovery, results}, remaining

    case Enum.find(results, &match?({:ok, %ClipJob{source_file_id: ^source_id}}, &1)) do
      {:ok, job} -> job
      nil -> discovered!(source_id, deadline)
    end
  end

  defp no_publishing! do
    assert Repo.aggregate(Post, :count) == 0
    assert Fake.calls(:publish) == []
    assert Repo.aggregate(from(c in Clip, where: c.review_status == "approved"), :count) == 0
  end

  test "one real upload automatically yields exactly three headlined pending MP4s", %{w: w} do
    # Both peers run before the upload. No manual pipeline action follows it.
    start_supervised!({EpisodeFakeRunner, world: w, notify: self(), observer: self()})
    source = upload!(w)
    job = discovered!(source.id)
    assert job.kind == "episode"
    assert job.requested_by_user_id == nil
    assert_receive {:episode_runner, job_id, trace}, 5000
    assert job_id == job.id
    assert_receive {:episode_candidates, candidates, snapshot}
    assert snapshot == [{"candidate", nil}, {"candidate", nil}, {"candidate", nil}]
    assert length(candidates) == 3
    assert Enum.all?(candidates, &is_nil(Repo.get!(ClipJob, &1.id).requested_by_user_id))
    # Independently authored expectations, not obtained from the fixture runner.
    expected = [
      {"demo", 1.0, 8.0, "The demo finally worked",
       "94ba4fbd1e93c123e8df968033278245604f9cbf140994cc5b9e9a4f2f869da1"},
      {"button", 10.0, 19.0, "We fixed the wrong button",
       "8c2f46947b68ed3a365d9d47cd039618ab718dbc68a5b9ee314d11602dfe7991"},
      {"bug", 22.0, 31.0, "The tiny bug won again",
       "f0fa473719ebe114c3ef11d0248463fdb614a07cb43941704972ae2ccf3426d2"}
    ]

    assert Repo.aggregate(Clip, :count) == 3
    assert Repo.aggregate(ClipRender, :count) == 3
    assert Repo.get!(ClipJob, job.id).result == %{"outcome" => "rendered", "pick_count" => 3}

    for {id, start, stop, headline, sha} <- expected do
      child = Enum.find(candidates, &(&1.payload["candidate_id"] == id))
      clip = Repo.get!(Clip, child.clip_id)
      assert clip.status == "rendered"
      assert clip.review_status == "pending"
      assert clip.requested_start_s == start
      assert clip.requested_end_s == stop
      assert is_binary(clip.render_file_id)
      assert clip.reviewed_at == nil
      assert Repo.get!(ClipJob, child.id).result["headline_applied"] == true
      render = Repo.get_by!(ClipRender, clip_id: clip.id)
      assert render.source["source_file_id"] == source.id
      assert render.file_id == clip.render_file_id
      file = Repo.get!(Files.File, clip.render_file_id)
      assert file.project_id == w.project.id
      assert file.content_type == "video/mp4"
      assert file.uploaded_by_user_id == nil
      {:ok, stream} = Files.Storage.get(file.storage_key)
      bytes = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert bytes =~ "ftyp"
      assert bytes =~ headline
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha
      assert Enum.find(trace.artifacts, &(&1.candidate_id == id)).headline == headline
      refute Jason.encode!(Enum.map(trace.calls, &Tuple.to_list/1)) =~ headline
    end

    assert Enum.all?(trace.calls, fn {tool, _} ->
             tool in ~w(social_clip_job_claim social_clip_job_source social_clip_job_progress social_clip_job_complete)
           end)

    assert Enum.count(trace.calls, fn {tool, _} -> tool == "social_clip_job_complete" end) == 4
    no_publishing!()
  end

  test "presigned reservation waits for finalization then restart cannot duplicate", %{
    w: w,
    activation: activation
  } do
    bytes = File.read!(Path.expand("../../support/fixtures/episode_pipeline/source.mp4", __DIR__))
    {:ok, stat} = Files.Storage.put({:binary, bytes}, w.project.id, filename: "episode.mp4")

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

    drain_notifications()
    assert_receive {:episode_discovery, []}, 2000
    assert Repo.aggregate(ClipJob, :count) == 0
    {:ok, _} = Files.finalize_presigned_upload(reservation, stat)
    parent = discovered!(reservation.id)
    EpisodeFakeRunner.run(w, parent)
    stop_discovery!()
    start_discovery!(w)
    assert_receive {:episode_discovery, []}, 2000
    assert Repo.aggregate(ClipJob, :count) == 4
    assert Repo.aggregate(Clip, :count) == 3
    assert Repo.get!(EpisodePipeline, activation.id).activated_at == activation.activated_at
    no_publishing!()
  end

  test "restart recovers missed upload and generated outputs/foreign project cannot recurse", %{
    w: w
  } do
    stop_discovery!()
    other = render_world!()
    _foreign = upload!(other)
    source = upload!(w)
    assert Repo.aggregate(ClipJob, :count) == 0
    start_discovery!(w)
    parent = discovered!(source.id)
    EpisodeFakeRunner.run(w, parent)
    stop_discovery!()
    start_discovery!(w)
    assert_receive {:episode_discovery, []}, 2000
    assert Repo.aggregate(ClipJob, :count) == 4

    assert Repo.aggregate(from(j in ClipJob, where: j.profile_id == ^other.profile.id), :count) ==
             0

    no_publishing!()
  end

  test "zero picks completes explicitly without candidate or render", %{w: w} do
    parent = upload!(w) |> Map.fetch!(:id) |> discovered!()
    trace = EpisodeFakeRunner.run(w, parent, zero_picks: true)
    assert Repo.get!(ClipJob, parent.id).result == %{"outcome" => "no_picks", "pick_count" => 0}
    assert trace.artifacts == []
    assert Repo.aggregate(Clip, :count) == 0
    assert Repo.aggregate(ClipRender, :count) == 0
    no_publishing!()
  end

  test "pre-candidate failure persists and restart does not silently retry", %{w: w} do
    parent = upload!(w) |> Map.fetch!(:id) |> discovered!()
    EpisodeFakeRunner.run(w, parent, failure: :before_picks)
    assert %{status: "failed", error: error} = Repo.get!(ClipJob, parent.id)
    assert error =~ "HEADLINE_CLI_UNSUPPORTED"
    assert Repo.aggregate(Clip, :count) == 0
    stop_discovery!()
    start_discovery!(w)
    assert_receive {:episode_discovery, []}, 2000
    assert Repo.aggregate(ClipJob, :count) == 1
    no_publishing!()
  end

  test "partial failure preserves successful pending children and fails parent", %{w: w} do
    parent = upload!(w) |> Map.fetch!(:id) |> discovered!()
    trace = EpisodeFakeRunner.run(w, parent, failure: :second_render)
    assert %{status: "failed", error: "EPISODE_INCOMPLETE"} = Repo.get!(ClipJob, parent.id)

    assert Repo.aggregate(
             from(c in Clip, where: c.status == "rendered" and c.review_status == "pending"),
             :count
           ) == 2

    assert Repo.aggregate(ClipRender, :count) == 2
    assert Enum.count(trace.calls, fn {tool, _} -> tool == "social_clip_job_complete" end) == 2
    assert Repo.aggregate(from(j in ClipJob, where: j.status == "failed"), :count) == 2
    no_publishing!()
  end
end
