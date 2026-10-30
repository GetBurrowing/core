defmodule Platform.Social.ClipClosingJobsTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  import Platform.SocialFixtures
  alias Platform.Files

  alias Platform.Social.{
    Clip,
    ClipJobs,
    ClipJob,
    ClipRender,
    ClipVersions,
    ClipClosingVideo,
    EpisodeDiscovery,
    ClipMedia,
    Tools,
    Profile
  }

  @moduletag :ffmpeg
  setup_all do
    fixtures =
      for {name, color, duration} <- [
            {:a, "magenta", "0.4"},
            {:b, "lime", "0.6"},
            {:output, "blue", "1.4"}
          ],
          into: %{} do
        path =
          Path.join(
            System.tmp_dir!(),
            "closing-job-#{name}-#{System.unique_integer([:positive])}.mp4"
          )

        {_, 0} =
          System.cmd("ffmpeg", [
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=#{color}:s=64x96:r=25:d=#{duration}",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-y",
            path
          ])

        bytes = File.read!(path)
        File.rm!(path)
        {name, bytes}
      end

    %{media: fixtures}
  end

  setup %{media: media} do
    w = render_world!()

    {:ok, %{file: a}} =
      ClipClosingVideo.upload(
        w.org_id,
        w.profile.id,
        w.approver.id,
        media.a,
        "TEST-ONLY-A.mp4",
        "video/mp4"
      )

    {:ok, %{file: b}} =
      ClipClosingVideo.upload(
        w.org_id,
        w.profile.id,
        w.approver.id,
        media.b,
        "TEST-ONLY-B.mp4",
        "video/mp4"
      )

    output = stored_file!(w.project, media.output, "TEST-ONLY-output.mp4", "video/mp4")
    %{w: w, a: a, b: b, output: output}
  end

  defp save!(w, file, audio \\ "keep", enabled \\ true) do
    {:ok, _} =
      ClipClosingVideo.save(w.org_id, w.profile.id, w.approver.id, %{
        file_id: file.id,
        enabled: enabled,
        audio: audio
      })
  end

  defp enqueue!(w) do
    {:ok, result} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/episode",
        in_s: 5,
        out_s: 6
      })

    result
  end

  defp complete!(w, job, output, extras \\ %{}) do
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, %{clip: clip}} =
      ClipJobs.complete(
        w.scope,
        job.id,
        w.agent.id,
        Map.merge(
          %{
            file_id: output.id,
            actual_in_s: 5.0,
            actual_out_s: 6.0,
            candidate_id: "exact-source-pick"
          },
          extras
        )
      )

    clip
  end

  defp current(w, clip) do
    {:ok, [render | _]} = ClipVersions.recent(w.org_id, w.profile.id, clip.id)
    render
  end

  test "two queued clips pin A; replacement B never rewrites either job or approved render", c do
    save!(c.w, c.a)
    one = enqueue!(c.w)
    two = enqueue!(c.w)
    assert one.job.payload["closing_video"] == two.job.payload["closing_video"]
    contract = one.job.payload["closing_video"]
    assert contract["file_id"] == c.a.id and contract["audio"] == "keep"
    assert contract["content_hash"] == c.a.content_hash
    assert contract["duration_s"] == 0.4
    save!(c.w, c.b, "mute")
    completed = complete!(c.w, one.job, c.output)
    base = current(c.w, completed)
    assert base.closing_video.file_id == c.a.id
    assert base.closing_video.audio == :keep
    assert Platform.Social.ClosingVideoSnapshot.dump(base.closing_video) == contract

    assert {:ok, %{posts: [approved_post]}} =
             Platform.Social.approve_clip(
               c.w.org_id,
               completed.id,
               c.w.approver.id,
               %{"render_id" => base.id, "account_ids" => [c.w.x.id]},
               now: DateTime.add(DateTime.utc_now(), 3600),
               publish_server: :closing_jobs_no_publisher
             )

    assert approved_post.clip_render_id == base.id
    assert approved_post.media_file_ids == [c.output.id]
    assert Repo.get!(ClipJob, two.job.id).payload == two.job.payload
    assert current(c.w, completed) == base

    assert {:error, :version_approved} =
             ClipJobs.enqueue_closing_video(c.w.org_id, completed.id, c.w.approver.id, %{
               base_render_id: base.id
             })

    assert {:ok, download_job} = ClipJobs.claim(c.w.scope, two.job.id, c.w.agent.id)

    assert {:ok, source} =
             ClipJobs.source_download(c.w.scope, download_job.id, c.w.agent.id, "closing_video")

    assert source.file_id == c.a.id and source.content_hash == c.a.content_hash
    assert source.max_bytes == 209_715_200
    assert DateTime.diff(source.expires_at, DateTime.utc_now()) in 898..900

    assert Files.SignedUrl.verify(URI.parse(source.url).path |> String.split("/") |> List.last()) ==
             {:ok, c.a.id}

    refute inspect(Repo.get!(ClipJob, one.job.id).payload["closing_video"]) =~ "http"

    assert {:ok, rerender} =
             ClipJobs.enqueue_rerender(c.w.org_id, completed.id, c.w.approver.id, %{})

    replacement_output =
      stored_file!(
        c.w.project,
        c.media.output <> "replacement output",
        "TEST-ONLY-v2.mp4",
        "video/mp4"
      )

    pending = complete!(c.w, rerender, replacement_output)
    assert pending.review_status == "pending"
    assert current(c.w, pending).closing_video.file_id == c.b.id
    assert Repo.get!(ClipRender, base.id).closing_video.file_id == c.a.id
    assert Repo.get!(Platform.Social.Post, approved_post.id) == approved_post
    assert Files.get_file(c.output.id).content_hash == c.output.content_hash
    # An old approved post does not prevent updating today's unapproved version.
    assert {:ok, _} =
             ClipJobs.enqueue_closing_video(c.w.org_id, pending.id, c.w.approver.id, %{
               base_render_id: current(c.w, pending).id
             })
  end

  test "episode children inherit parent A even after B replaces it or is subsequently deleted",
       c do
    save!(c.w, c.a)
    {:ok, pipeline} = EpisodeDiscovery.activate(c.w.profile)

    {:ok, source, _} =
      Files.add_bytes(c.w.project, "episode #{unique()}", "episode.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: c.w.approver.id
      )

    {:ok, parent} = ClipJobs.enqueue_episode(pipeline.id, source.id)
    save!(c.w, c.b, "mute")
    {:ok, _} = Files.delete_file(c.w.approver, c.b)
    {:ok, _} = ClipJobs.claim(c.w.scope, parent.id, c.w.agent.id)

    picks = [
      %{candidate_id: "one", in_s: 5, out_s: 6},
      %{candidate_id: "two", in_s: 10, out_s: 11}
    ]

    assert {:ok, children} = ClipJobs.plan_episode(c.w.scope, parent.id, c.w.agent.id, picks)
    assert length(children) == 2

    for child <- children do
      assert child.payload["closing_video"] == parent.payload["closing_video"]
      assert child.payload["closing_video"]["file_id"] == c.a.id
    end

    assert {:ok, replay} = ClipJobs.plan_episode(c.w.scope, parent.id, c.w.agent.id, picks)
    assert Enum.map(children, & &1.id) == Enum.map(replay, & &1.id)
  end

  test "closing rerender pins B with exact base candidate/source, stays pending and refuses stale/inflight and agents",
       c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    clip = complete!(c.w, original.job, c.output)
    base = current(c.w, clip)
    save!(c.w, c.b, "mute")

    assert {:error, :not_a_human} =
             ClipJobs.enqueue_closing_video(c.w.org_id, clip.id, c.w.agent.id, %{
               base_render_id: base.id
             })

    assert {:ok, job} =
             ClipJobs.enqueue_closing_video(c.w.org_id, clip.id, c.w.approver.id, %{
               base_render_id: base.id,
               look: %{outro: true}
             })

    assert job.payload["closing_video"]["file_id"] == c.b.id
    assert job.payload["closing_video"]["audio"] == "mute"
    assert job.payload["base_render_id"] == base.id
    assert job.payload["candidate_id"] == "exact-source-pick"
    assert job.payload["episode"] == base.source
    refute job.payload["episode"]["source_file_id"] == c.output.id
    assert {job.payload["in_s"], job.payload["out_s"]} == {5.0, 6.0}
    assert Repo.get!(Clip, clip.id).render_file_id == c.output.id
    assert current(c.w, clip) == base

    assert {:error, :job_in_flight} =
             ClipJobs.enqueue_closing_video(c.w.org_id, clip.id, c.w.approver.id, %{
               base_render_id: base.id
             })

    new = complete!(c.w, job, c.output)
    assert new.review_status == "pending" and new.rev == 2

    assert {:error, :stale_version} =
             ClipJobs.enqueue_closing_video(c.w.org_id, clip.id, c.w.approver.id, %{
               base_render_id: base.id
             })

    assert {:error, :job_closed} =
             ClipJobs.complete(c.w.scope, job.id, c.w.agent.id, %{file_id: c.output.id})

    assert Repo.aggregate(from(r in ClipRender, where: r.clip_id == ^clip.id), :count) == 2
    assert Repo.get!(ClipRender, base.id).closing_video.file_id == c.a.id
  end

  test "generic, title/caption and appearance/music rerenders use today's default and preserve source bounds",
       c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    clip = complete!(c.w, original.job, c.output)
    save!(c.w, c.b, "mute")
    base = current(c.w, clip)
    assert {:ok, generic} = ClipJobs.enqueue_rerender(c.w.org_id, clip.id, c.w.approver.id, %{})
    assert generic.payload["closing_video"]["file_id"] == c.b.id
    assert generic.payload["base_render_id"] == base.id
    assert generic.payload["candidate_id"] == base.candidate_id
    assert generic.payload["episode"] == base.source
    clip = complete!(c.w, generic, c.output)
    save!(c.w, c.a)
    base = current(c.w, clip)

    assert {:ok, fix} =
             ClipJobs.enqueue_fix(c.w.org_id, clip.id, c.w.approver.id, %{
               base_render_id: base.id,
               operation: "caption_word",
               position: 1,
               original: "a",
               replacement: "b"
             })

    assert fix.payload["closing_video"]["file_id"] == c.a.id
    clip = complete!(c.w, fix, c.output)
    save!(c.w, c.b, "mute")
    base = current(c.w, clip)

    assert {:ok, appearance} =
             ClipJobs.enqueue_appearance(c.w.org_id, clip.id, c.w.approver.id, %{
               base_render_id: base.id,
               look: %{music_track: %{muted: true}}
             })

    assert appearance.payload["closing_video"]["file_id"] == c.b.id
    assert appearance.payload["episode"] == base.source
    assert {appearance.payload["in_s"], appearance.payload["out_s"]} == {5.0, 6.0}
  end

  test "disabled preserves saved choice but cannot download; legacy missing contracts remain honestly absent",
       c do
    save!(c.w, c.a, "keep", false)
    original = enqueue!(c.w)
    assert original.job.payload["closing_video"]["file_id"] == c.a.id
    refute original.job.payload["closing_video"]["enabled"]
    {:ok, _} = ClipJobs.claim(c.w.scope, original.job.id, c.w.agent.id)

    assert {:error, :closing_video_unavailable} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")

    legacy =
      original.job
      |> Ecto.Changeset.change(payload: Map.delete(original.job.payload, "closing_video"))
      |> Repo.update!()

    save!(c.w, c.b, "mute")

    assert {:ok, %{clip: clip}} =
             ClipJobs.complete(c.w.scope, legacy.id, c.w.agent.id, %{file_id: c.output.id})

    assert current(c.w, clip).closing_video == nil
    assert Repo.get!(Profile, c.w.profile.id).closing_video.file_id == c.b.id
  end

  test "only the claimer of an open same-org job gets its own pinned closing file", c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    foreign = render_world!()

    assert {:error, :not_claimer} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")

    {:ok, _} = ClipJobs.claim(c.w.scope, original.job.id, c.w.agent.id)

    assert {:error, :not_found} =
             ClipJobs.source_download(
               foreign.scope,
               original.job.id,
               foreign.agent.id,
               "closing_video"
             )

    assert {:error, :not_claimer} =
             ClipJobs.source_download(
               c.w.scope,
               original.job.id,
               pinned_agent!(c.w.org_id).id,
               "closing_video"
             )

    assert {:error, :invalid_asset} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "arbitrary")

    for key <- ~w(file_id path url source_file_id) do
      assert {:error, %{code: :invalid_asset}} =
               Tools.execute(
                 "social_clip_job_source",
                 %{"job_id" => original.job.id, "asset" => "closing_video", key => c.b.id},
                 %{agent_id: c.w.agent.id}
               )
    end

    assert {:ok, %{file_id: id}} =
             Tools.execute(
               "social_clip_job_source",
               %{"job_id" => original.job.id, "asset" => "closing_video"},
               %{agent_id: c.w.agent.id}
             )

    assert id == c.a.id
    assert {:ok, _} = ClipJobs.fail(c.w.scope, original.job.id, c.w.agent.id, "safe failure")

    assert {:error, :job_closed} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")
  end

  test "deleted, altered, foreign, incomplete or archived assets fail closed and never fall back to current default",
       c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    {:ok, _} = ClipJobs.claim(c.w.scope, original.job.id, c.w.agent.id)
    save!(c.w, c.b, "mute")
    foreign = render_world!()

    for attrs <- [
          %{org_id: foreign.org_id},
          %{project_id: foreign.project.id},
          %{content_hash: nil},
          %{byte_size: c.a.byte_size + 1},
          %{content_type: "text/plain"}
        ] do
      c.a |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :closing_video_unavailable} =
               ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")

      Repo.update_all(from(f in Files.File, where: f.id == ^c.a.id),
        set: [
          org_id: c.a.org_id,
          project_id: c.a.project_id,
          content_hash: c.a.content_hash,
          byte_size: c.a.byte_size,
          content_type: c.a.content_type
        ]
      )
    end

    c.w.project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :closing_video_unavailable} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")

    Repo.update_all(from(p in Platform.Tasks.Project, where: p.id == ^c.w.project.id),
      set: [archived_at: nil]
    )

    {:ok, _} = Files.delete_file(c.w.approver, c.a)

    assert {:error, :closing_video_unavailable} =
             ClipJobs.source_download(c.w.scope, original.job.id, c.w.agent.id, "closing_video")

    assert Repo.get!(ClipJob, original.job.id).payload["closing_video"]["file_id"] == c.a.id
  end

  test "source download fails safely when decoding is unavailable and keeps the pinned job unchanged",
       c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    {:ok, _} = ClipJobs.claim(c.w.scope, original.job.id, c.w.agent.id)
    prior = Application.get_env(:social, :ffprobe_path)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:social, :ffprobe_path, prior),
        else: Application.delete_env(:social, :ffprobe_path)
    end)

    Application.put_env(:social, :ffprobe_path, "/missing/ffprobe")

    assert {:error, %{code: :closing_video_unavailable, recoverable: false}} =
             Tools.execute(
               "social_clip_job_source",
               %{"job_id" => original.job.id, "asset" => "closing_video"},
               %{agent_id: c.w.agent.id}
             )

    assert Repo.get!(ClipJob, original.job.id).payload == original.job.payload
    assert Repo.get!(Clip, original.clip.id).render_file_id == nil
  end

  test "completion rejects injected closing contract; measured TOTAL output wins over reported content duration",
       c do
    save!(c.w, c.a)
    original = enqueue!(c.w)
    {:ok, _} = ClipJobs.claim(c.w.scope, original.job.id, c.w.agent.id)

    assert {:error, :closing_video_override} =
             ClipJobs.complete(c.w.scope, original.job.id, c.w.agent.id, %{
               file_id: c.output.id,
               closing_video: %{file_id: c.b.id}
             })

    assert {:error, %{code: :closing_video_override}} =
             Tools.execute(
               "social_clip_job_complete",
               %{"job_id" => original.job.id, "file_id" => c.output.id, "closing_video" => nil},
               %{agent_id: c.w.agent.id}
             )

    fake = stored_file!(c.w.project, "not decoded", "fake.mp4", "video/mp4")

    assert {:error, :output_measurements_unavailable} =
             ClipJobs.complete(c.w.scope, original.job.id, c.w.agent.id, %{
               file_id: fake.id,
               duration_s: 1.4,
               width: 64,
               height: 96
             })

    assert {:ok, %{clip: clip}} =
             ClipJobs.complete(c.w.scope, original.job.id, c.w.agent.id, %{
               file_id: c.output.id,
               duration_s: 1.0,
               actual_in_s: 5.0,
               actual_out_s: 6.0
             })

    render = current(c.w, clip)
    assert_in_delta render.duration_s, 1.4, 0.01
    assert render.byte_size == c.output.byte_size
    assert {render.requested_start_s, render.requested_end_s} == {5.0, 6.0}
    assert {render.actual_start_s, render.actual_end_s} == {5.0, 6.0}

    assert ClipMedia.meta_for(c.w.profile.id, [c.output.id])[c.output.id]["duration_s"] ==
             render.duration_s

    assert render.closing_video.file_id == c.a.id
  end
end
