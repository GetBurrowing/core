defmodule PlatformWeb.SocialEpisodeJobsTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query

  alias Platform.Repo

  alias Platform.Social.{
    Clip,
    ClipJob,
    ClipJobs,
    ClipReviewFeed,
    EpisodeDiscovery,
    EpisodePipeline,
    Post
  }

  setup do
    w = render_world!()
    {:ok, pipeline} = EpisodeDiscovery.activate(w.profile)
    %{w: w, pipeline: pipeline}
  end

  defp episode!(w, pipeline) do
    {:ok, source, false} =
      Platform.Files.add_bytes(w.project, "episode #{unique()}", "episode.mp4", "video/mp4",
        ingest: false,
        uploaded_by_user_id: w.approver.id
      )

    {:ok, job} = ClipJobs.enqueue_episode(pipeline.id, source.id)
    job
  end

  defp open(conn, w) do
    {:ok, view, _} =
      conn
      |> Plug.Test.init_test_session(current_user_id: w.approver.id)
      |> live("/m/social?tab=clips&view=review")

    find_live_child(view, "ext-page-social")
  end

  defp job_selector(job), do: "[data-role='episode-job'][data-job-id='#{job.id}']"

  defp age!(job, seconds) do
    past = DateTime.add(DateTime.utc_now(), -seconds, :second)
    from(j in ClipJob, where: j.id == ^job.id) |> Repo.update_all(set: [updated_at: past])
  end

  test "an initially empty bay receives queued, claimed, running and done outcomes without actions",
       c do
    child = open(c.conn, c.w)
    refute has_element?(child, "[data-role='episode-jobs']")
    job = episode!(c.w, c.pipeline)

    render(child)

    assert has_element?(
             child,
             job_selector(job) <> "[data-status='queued']",
             "Waiting for runner"
           )

    {:ok, _} = ClipJobs.claim(c.w.scope, job.id, c.w.agent.id)
    render(child)
    assert has_element?(child, job_selector(job) <> "[data-status='claimed']", "Runner connected")
    {:ok, _} = ClipJobs.progress(c.w.scope, job.id, c.w.agent.id, 0.2)

    render(child)

    assert has_element?(
             child,
             job_selector(job) <> "[data-status='running']",
             "Processing episode"
           )

    render(child)
    assert has_element?(child, "progress[aria-label='Episode progress'][value='0.2']")
    {:ok, []} = ClipJobs.plan_episode(c.w.scope, job.id, c.w.agent.id, [])
    {:ok, _} = ClipJobs.complete(c.w.scope, job.id, c.w.agent.id, %{})
    render(child)
    assert has_element?(child, job_selector(job) <> "[data-status='done']", "No picks found")
    reloaded = open(c.conn, c.w)
    assert has_element?(reloaded, job_selector(job), "No picks found")
    refute has_element?(child, "[data-role='episode-jobs'] button")
    assert Repo.aggregate(Post, :count) == 0
  end

  test "pre-candidate failures persist and expose only closed safe codes, never runner prose",
       c do
    job = episode!(c.w, c.pipeline)
    child = open(c.conn, c.w)
    {:ok, _} = ClipJobs.claim(c.w.scope, job.id, c.w.agent.id)

    {:ok, _} =
      ClipJobs.fail(
        c.w.scope,
        job.id,
        c.w.agent.id,
        "SECRET transcript https://secret.test/?token=private",
        "HEADLINE_CLI_UNSUPPORTED"
      )

    render(child)

    assert has_element?(
             child,
             job_selector(job) <> "[data-status='failed'] [role='alert']",
             "HEADLINE_CLI_UNSUPPORTED"
           )

    refute render(child) =~ "SECRET"
    refute render(child) =~ "secret.test"
    assert Repo.aggregate(Clip, :count) == 0
    reloaded = open(c.conn, c.w)
    assert has_element?(reloaded, job_selector(job), "HEADLINE_CLI_UNSUPPORTED")
    other = episode!(c.w, c.pipeline)
    {:ok, _} = ClipJobs.claim(c.w.scope, other.id, c.w.agent.id)
    {:ok, _} = ClipJobs.fail(c.w.scope, other.id, c.w.agent.id, "PRIVATE-CODE: credentials")
    render(child)
    assert has_element?(child, job_selector(other), "RENDER_FAILED")
    refute render(child) =~ "PRIVATE-CODE"
  end

  test "one failed child makes parent incomplete while completed headline clips remain pending across reload",
       c do
    job = episode!(c.w, c.pipeline)
    {:ok, _} = ClipJobs.claim(c.w.scope, job.id, c.w.agent.id)

    {:ok, [first, second]} =
      ClipJobs.plan_episode(c.w.scope, job.id, c.w.agent.id, [
        %{candidate_id: "one", in_s: 0, out_s: 10},
        %{candidate_id: "two", in_s: 20, out_s: 30}
      ])

    child = open(c.conn, c.w)
    render(child)
    assert has_element?(child, job_selector(job), "Rendering picks")

    render(child)

    assert has_element?(
             child,
             "[data-role='episode-child-job'][data-job-id='#{first.id}'][data-status='queued']"
           )

    {:ok, _} = ClipJobs.claim(c.w.scope, first.id, c.w.agent.id)
    {:ok, _} = ClipJobs.progress(c.w.scope, first.id, c.w.agent.id, 0.5)

    render(child)

    assert has_element?(
             child,
             "[data-role='episode-child-job'][data-status='running']",
             "Generating headline and rendering"
           )

    file = stored_file!(c.w.project, "render #{unique()}", "clip.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(c.w.scope, first.id, c.w.agent.id, %{
        file_id: file.id,
        title: "The team celebrated",
        headline_applied: true
      })

    {:ok, _} = ClipJobs.claim(c.w.scope, second.id, c.w.agent.id)
    {:ok, _} = ClipJobs.fail(c.w.scope, second.id, c.w.agent.id, "private", "HEADLINE_UNBACKED")

    render(child)

    assert has_element?(
             child,
             job_selector(job) <> "[data-status='failed']",
             "EPISODE_INCOMPLETE"
           )

    render(child)

    assert has_element?(
             child,
             "[data-role='episode-child-job'][data-job-id='#{first.id}'][data-status='done']",
             "Ready for review"
           )

    render(child)

    assert has_element?(
             child,
             "[data-role='episode-child-job'][data-status='failed']",
             "HEADLINE_UNBACKED"
           )

    render(child)
    assert has_element?(child, "[data-role='clips-queue-item']", "The team celebrated")
    render(child)
    assert has_element?(child, "video[src='/files/blob/#{file.id}']")
    assert Repo.reload!(clip).review_status == "pending"
    assert Repo.reload!(clip).render_file_id == file.id
    assert {:error, :job_closed} = ClipJobs.complete(c.w.scope, job.id, c.w.agent.id, %{})
    reloaded = open(c.conn, c.w)
    assert has_element?(reloaded, job_selector(job), "EPISODE_INCOMPLETE")
    assert has_element?(reloaded, "video[src='/files/blob/#{file.id}']")
    assert Repo.aggregate(Post, :count) == 0
  end

  test "background reconciliation visibly times out stale queued and running jobs, never fresh or terminal work",
       c do
    queued = episode!(c.w, c.pipeline)
    running = episode!(c.w, c.pipeline)
    fresh = episode!(c.w, c.pipeline)

    manual =
      elem(
        ClipJobs.enqueue_new_clip(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
          source_file_id: c.w.video.id,
          in_s: 0,
          out_s: 10
        }),
        1
      ).job

    {:ok, _} = ClipJobs.claim(c.w.scope, running.id, c.w.agent.id)
    {:ok, _} = ClipJobs.progress(c.w.scope, running.id, c.w.agent.id, 0.1)
    age!(queued, 4000)
    age!(running, 2000)
    age!(manual, 4000)
    child = open(c.conn, c.w)

    {:ok, pid} =
      EpisodeDiscovery.start_link(
        name: nil,
        profile_ids: [],
        boot_sweep: false,
        interval_ms: :infinity
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    EpisodeDiscovery.sweep_now(pid)
    GenServer.stop(pid)
    render(child)
    assert has_element?(child, job_selector(queued), "RUNNER_UNAVAILABLE")
    render(child)
    assert has_element?(child, job_selector(running), "RUNNER_TIMEOUT")
    assert Repo.reload!(fresh).status == "queued"
    assert Repo.reload!(manual).status == "queued"
    assert EpisodePipeline.reconcile_jobs() == []
    assert has_element?(open(c.conn, c.w), job_selector(running), "RUNNER_TIMEOUT")
  end

  test "reconciliation is bounded, fresh heartbeats survive and child timeout preserves successful sibling",
       c do
    jobs = for _ <- 1..3, do: episode!(c.w, c.pipeline)
    Enum.each(jobs, &age!(&1, 4000))
    assert length(EpisodePipeline.reconcile_jobs(DateTime.utc_now(), limit: 1)) == 1
    assert Enum.count(jobs, &(Repo.reload!(&1).status == "queued")) == 2
    assert length(EpisodePipeline.reconcile_jobs()) == 2
    parent = episode!(c.w, c.pipeline)
    {:ok, _} = ClipJobs.claim(c.w.scope, parent.id, c.w.agent.id)

    {:ok, [one, two]} =
      ClipJobs.plan_episode(c.w.scope, parent.id, c.w.agent.id, [
        %{candidate_id: "one", in_s: 0, out_s: 2},
        %{candidate_id: "two", in_s: 3, out_s: 5}
      ])

    {:ok, _} = ClipJobs.claim(c.w.scope, one.id, c.w.agent.id)
    file = stored_file!(c.w.project, "render #{unique()}", "clip.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(c.w.scope, one.id, c.w.agent.id, %{
        file_id: file.id,
        headline_applied: true
      })

    {:ok, _} = ClipJobs.claim(c.w.scope, two.id, c.w.agent.id)
    age!(parent, 2000)
    {:ok, _} = ClipJobs.progress(c.w.scope, parent.id, c.w.agent.id, 0.8)
    age!(two, 2000)
    assert [%{id: id}] = EpisodePipeline.reconcile_jobs()
    assert id == two.id
    assert Repo.reload!(parent).error == "EPISODE_INCOMPLETE"
    assert Repo.reload!(clip).review_status == "pending"
    assert Repo.reload!(one).status == "done"
  end

  test "other tenant jobs, events and outcomes never appear in the viewer's bay", c do
    local = episode!(c.w, c.pipeline)
    other = render_world!()
    {:ok, pipeline} = EpisodeDiscovery.activate(other.profile)
    foreign = episode!(other, pipeline)
    assert ClipReviewFeed.episode_jobs(c.w.org_id, other.profile.id) == []
    child = open(c.conn, c.w)
    send(child.pid, {:social_clip_job, %{id: foreign.id, profile_id: foreign.profile_id}})
    render(child)
    assert has_element?(child, job_selector(local))
    refute has_element?(child, job_selector(foreign))
    refute render(child) =~ foreign.id
  end
end
