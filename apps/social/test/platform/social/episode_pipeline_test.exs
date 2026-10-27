defmodule Platform.Social.EpisodePipelineTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures

  alias Platform.Files
  alias Platform.Files.SignedUrl
  alias Platform.Social.{ClipJob, ClipJobs, EpisodeDiscovery, Tools}

  setup do
    w = render_world!()
    {:ok, pipeline} = EpisodeDiscovery.activate(w.profile)

    {:ok, source, false} =
      Files.add_bytes(w.project, "episode #{unique()}", "episode.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: w.approver.id
      )

    {:ok, job} = ClipJobs.enqueue_episode(pipeline.id, source.id)
    %{w: w, source: source, job: job, ctx: %{agent_id: w.agent.id}}
  end

  defp download(job, ctx, extras \\ %{}) do
    Tools.execute("social_clip_job_source", Map.put(extras, "job_id", job.id), ctx)
  end

  test "claimer downloads its durable source with a short-lived Files token and no persisted URL",
       c do
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)
    before = DateTime.utc_now()
    assert {:ok, reply} = download(c.job, c.ctx)
    assert reply.file_id == c.source.id
    assert reply.project_id == c.w.project.id
    assert reply.content_type == "video/mp4"
    assert reply.byte_size == c.source.byte_size
    assert DateTime.diff(reply.expires_at, before) in 899..900
    token = URI.parse(reply.url).path |> String.split("/") |> List.last()
    assert SignedUrl.verify(token) == {:ok, c.source.id}
    assert {:ok, stream} = Files.Storage.get(c.source.storage_key)
    assert IO.iodata_to_binary(Enum.to_list(stream)) =~ "episode "
    assert Repo.get!(ClipJob, c.job.id).payload == c.job.payload
    assert Repo.get!(ClipJob, c.job.id).result == nil

    {:ok, _} = ClipJobs.progress(c.w.scope, c.job.id, c.w.agent.id, 0.2)
    assert {:ok, refreshed} = download(c.job, c.ctx)
    assert refreshed.file_id == c.source.id
  end

  test "caller cannot choose another source or spoof the claiming agent", c do
    other = render_world!()
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)

    assert {:ok, reply} = download(c.job, c.ctx, %{"source_file_id" => Ecto.UUID.generate()})
    assert reply.file_id == c.source.id
    second = pinned_agent!(c.w.org_id)

    assert {:error, %{code: :not_claimer}} =
             download(c.job, %{agent_id: second.id}, %{"agent_id" => c.w.agent.id})

    assert {:error, %{code: :not_found}} = download(c.job, %{agent_id: other.agent.id})
    assert {:error, %{code: :no_agent}} = download(c.job, %{})
  end

  test "a foreign job is indistinguishable from a missing job", c do
    other = render_world!()
    ctx = %{agent_id: other.agent.id}
    assert download(c.job, ctx) == download(%{id: Ecto.UUID.generate()}, ctx)
    assert {:error, %{code: :not_found}} = download(c.job, ctx)
  end

  test "deleted source is refused after claim", c do
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)
    {:ok, _} = Files.delete_file(c.w.approver, c.source)
    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)
  end

  test "source readiness and project ownership are rechecked after claim", c do
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)
    c.source |> Ecto.Changeset.change(content_hash: nil) |> Repo.update!()
    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)

    c.source
    |> Ecto.Changeset.change(content_hash: c.source.content_hash, content_type: "image/png")
    |> Ecto.Changeset.force_change(:content_hash, c.source.content_hash)
    |> Repo.update!()

    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)

    Repo.get!(Files.File, c.source.id)
    |> Ecto.Changeset.change(content_type: "video/mp4")
    |> Repo.update!()

    other = render_world!()

    c.w.profile |> Ecto.Changeset.change(project_id: other.project.id) |> Repo.update!()
    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)
  end

  test "an archived project and post-upload assets are refused", c do
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)

    c.w.profile
    |> Ecto.Changeset.change(brand: %{"outro_file_id" => c.source.id})
    |> Repo.update!()

    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)

    Repo.get!(Platform.Social.Profile, c.w.profile.id)
    |> Ecto.Changeset.change(brand: %{})
    |> Repo.update!()

    c.w.project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    assert {:error, %{code: :source_unavailable}} = download(c.job, c.ctx)
  end

  test "completed/failed jobs cannot mint fresh URLs and manual jobs cannot select arbitrary sources",
       c do
    assert {:error, %{code: :not_claimer}} = download(c.job, c.ctx)
    {:ok, _} = ClipJobs.claim(c.w.scope, c.job.id, c.w.agent.id)
    {:ok, _} = ClipJobs.fail(c.w.scope, c.job.id, c.w.agent.id, "missing headline hook")
    assert {:error, %{code: :job_closed}} = download(c.job, c.ctx)

    {:ok, %{job: manual}} =
      ClipJobs.enqueue_new_clip(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        source_file_id: c.source.id,
        in_s: 0,
        out_s: 20
      })

    {:ok, _} = ClipJobs.claim(c.w.scope, manual.id, c.w.agent.id)
    assert {:error, %{code: :source_unavailable}} = download(manual, c.ctx)
  end
end
