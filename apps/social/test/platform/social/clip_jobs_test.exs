defmodule Platform.Social.ClipJobsTest do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234) stage 3: the clip job list.
  Humans enqueue (approver-checked, org-scoped); a runner agent claims
  atomically, reports progress, and completes (rev bump, back to review
  pending, one render row per rev) or fails. Another org's job is
  not_found everywhere. No agent writes a review field.

  `async: false`: the concurrent-claim test shares the sandbox.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social.{Clip, ClipJob, ClipJobs, ClipLook, ClipRender, Profile}

  @url "https://www.youtube.com/watch?v=abc"

  setup do
    world = render_world!()
    other = render_world!()

    f1 = stored_file!(world.project, "render one #{unique()}", "f1.mp4", "video/mp4")
    f2 = stored_file!(world.project, "render two #{unique()}", "f2.mp4", "video/mp4")
    agent2 = pinned_agent!(world.org_id)

    Map.merge(world, %{other: other, f1: f1, f2: f2, agent2: agent2})
  end

  defp new_clip!(w, attrs \\ %{}) do
    {:ok, %{clip: clip, job: job}} =
      ClipJobs.enqueue_new_clip(
        w.org_id,
        w.profile.id,
        w.approver.id,
        Map.merge(%{source_url: @url, in_s: 120.0, out_s: 162.0}, attrs)
      )

    {clip, job}
  end

  defp claimed!(w, job, agent \\ nil) do
    {:ok, job} = ClipJobs.claim(w.scope, job.id, (agent || w.agent).id)
    job
  end

  # A clip at rev 1, rendered with f1, review pending.
  defp rendered_clip!(w) do
    {clip, job} = new_clip!(w)
    claimed!(w, job)
    {:ok, _} = ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.f1.id})
    Repo.get!(Clip, clip.id)
  end

  defp renders(clip_id),
    do: Repo.all(from(r in ClipRender, where: r.clip_id == ^clip_id, order_by: r.rev))

  test "caption fix snapshots accumulate user corrections without rewriting earlier versions",
       w do
    clip = rendered_clip!(w)
    [base] = renders(clip.id)
    first = %{"position" => 2, "original" => "there", "replacement" => "their"}
    second = %{"position" => 4, "original" => "form", "replacement" => "from"}

    {:ok, job} =
      ClipJobs.enqueue_fix(
        w.org_id,
        clip.id,
        w.approver.id,
        Map.merge(first, %{"base_render_id" => base.id, "operation" => "caption_word"})
      )

    claimed!(w, job)
    {:ok, _} = ClipJobs.complete(w.scope, job.id, w.agent.id, %{file_id: w.f2.id})
    [original, corrected] = renders(clip.id)
    assert original.caption_fixes == nil
    assert corrected.caption_fixes == %{"edits" => [first]}

    {:ok, next} =
      ClipJobs.enqueue_fix(
        w.org_id,
        clip.id,
        w.approver.id,
        Map.merge(second, %{"base_render_id" => corrected.id, "operation" => "caption_word"})
      )

    assert next.payload["caption_fixes"] == %{"edits" => [first, second]}
    assert renders(clip.id) == [original, corrected]
    assert Repo.get!(Clip, clip.id).render_file_id == w.f2.id
  end

  describe "enqueue_new_clip" do
    test "a new_clip job's clip is never in rendering", w do
      {clip, job} = new_clip!(w, %{title: "Who makes Total War?"})

      assert %Clip{status: "candidate", rev: 1, origin: "burrow", review_status: nil} =
               Repo.get!(Clip, clip.id)

      assert %ClipJob{kind: "new_clip", status: "queued", clip_id: clip_id} = job
      assert clip_id == clip.id
      assert clip.look == ClipLook.effective(w.profile.show_look)
      assert {clip.trim_in_s, clip.trim_out_s} == {120.0, 162.0}
      assert {clip.requested_start_s, clip.requested_end_s} == {120.0, 162.0}
      assert clip.title == "Who makes Total War?"

      # still candidate after a claim and progress
      claimed!(w, job)
      {:ok, _} = ClipJobs.progress(w.scope, job.id, w.agent.id, 0.5, 30)
      assert Repo.get!(Clip, clip.id).status == "candidate"
    end

    test "a file source must be in the profile's project", w do
      assert {:ok, %{clip: clip}} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
                 source_file_id: w.video.id,
                 transcript_file_id: w.transcript.id,
                 in_s: 1.0,
                 out_s: 9.0
               })

      assert clip.source_file_id == w.video.id

      assert {:error, :source_not_in_project} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
                 source_file_id: w.other.video.id,
                 in_s: 1.0,
                 out_s: 9.0
               })

      assert {:error, :invalid_range} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
                 source_url: @url,
                 in_s: 9.0,
                 out_s: 1.0
               })

      assert {:error, :invalid_source} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
                 in_s: 1.0,
                 out_s: 9.0
               })
    end

    test "enqueue with an agent id is refused; another org's profile is not_found", w do
      before = Repo.aggregate(ClipJob, :count)
      attrs = %{source_url: @url, in_s: 1.0, out_s: 9.0}

      assert {:error, :not_a_human} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.agent.id, attrs)

      assert {:error, :not_found} =
               ClipJobs.enqueue_new_clip(w.org_id, w.other.profile.id, w.approver.id, attrs)

      assert {:error, :not_found} =
               ClipJobs.enqueue_new_clip(w.org_id, Ecto.UUID.generate(), w.approver.id, attrs)

      # not an approver of this profile
      assert {:error, :not_an_approver} =
               ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.outsider.id, attrs)

      clip = rendered_clip!(w)

      assert {:error, :not_a_human} =
               ClipJobs.enqueue_rerender(w.org_id, clip.id, w.agent.id, %{})

      assert {:error, :not_found} =
               ClipJobs.enqueue_rerender(w.other.org_id, clip.id, w.other.approver.id, %{})

      assert {:error, :not_a_human} =
               ClipJobs.save_show_default(w.org_id, w.profile.id, w.agent.id, %{})

      assert {:error, :not_found} =
               ClipJobs.save_show_default(w.org_id, w.other.profile.id, w.approver.id, %{})

      assert Repo.aggregate(ClipJob, :count) == before + 1
    end
  end

  describe "enqueue_rerender" do
    test "a second rerender while one is open returns job_in_flight", w do
      clip = rendered_clip!(w)
      assert {:ok, _} = ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{})

      assert {:error, :job_in_flight} =
               ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{})

      # a queued new_clip job blocks a rerender too
      {fresh, _job} = new_clip!(w)

      assert {:error, :job_in_flight} =
               ClipJobs.enqueue_rerender(w.org_id, fresh.id, w.approver.id, %{})
    end

    test "a bad look is refused and nothing is queued", w do
      clip = rendered_clip!(w)

      assert {:error, {:invalid_look, _}} =
               ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{
                 look: %{"cap" => %{"size" => 99}}
               })

      assert {:error, :invalid_range} =
               ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{
                 trim_in_s: 10.0,
                 trim_out_s: 5.0
               })

      assert {:ok, []} = ClipJobs.list_jobs(w.scope, w.profile.id, status: "queued")
    end

    test "the payload carries the full clip_user_profile, the look delta, the overrides and the rejection note",
         w do
      clip = rendered_clip!(w)

      {:ok, _} =
        clip
        |> Clip.review_changeset({:reject, w.approver.id, "payoff is cut off"})
        |> Repo.update()

      look = put_in(clip.look, ["cap", "size"], 7.0)

      {:ok, job} =
        ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{
          look: look,
          trim_in_s: 118.0,
          trim_out_s: 165.0
        })

      p = job.payload
      assert p["clip_user_profile"] == "burrow-" <> w.profile.id
      assert String.length(p["clip_user_profile"]) == String.length("burrow-") + 36
      assert p["base_profile"] == "how-to-computer"
      assert p["kind"] == "rerender"
      assert p["clip_id"] == clip.id
      assert p["profile_name"] == w.profile.name
      assert p["look"] == look
      assert p["look_delta"] == %{"cap" => %{"size" => 7.0}}
      assert p["clip_overrides"]["mapped"] == %{"captions.size_frac" => 0.07}
      refute Enum.any?(p["clip_overrides"]["unmapped"], &String.starts_with?(&1, "cap"))
      assert p["review_note"] == "payoff is cut off"
      assert {p["in_s"], p["out_s"]} == {118.0, 165.0}
      assert p["expected_rev"] == 2

      assert p["episode"] == %{
               "source_url" => @url,
               "source_file_id" => nil,
               "transcript_file_id" => nil
             }

      # the clip row still describes rev 1 until complete
      assert %Clip{rev: 1, trim_in_s: 120.0, look: old_look} = Repo.get!(Clip, clip.id)
      assert old_look["cap"]["size"] == 5.8
    end

    test "a new clip's payload: full profile id, base profile, empty delta, episode source", w do
      {clip, job} = new_clip!(w)
      p = job.payload

      assert p["clip_user_profile"] == "burrow-" <> w.profile.id
      assert p["base_profile"] == "how-to-computer"
      assert {p["in_s"], p["out_s"]} == {120.0, 162.0}
      assert p["look_delta"] == %{}
      assert p["clip_overrides"] == %{"mapped" => %{}, "unmapped" => []}
      assert p["episode"]["source_url"] == @url
      assert p["review_note"] == nil
      assert p["expected_rev"] == 1
      assert p["clip_id"] == clip.id
    end
  end

  describe "claim" do
    test "exactly one of 8 concurrent claims wins", w do
      {_clip, job} = new_clip!(w)
      agents = for _ <- 1..8, do: pinned_agent!(w.org_id)
      scope = w.scope

      results =
        agents
        |> Task.async_stream(fn agent -> {agent.id, ClipJobs.claim(scope, job.id, agent.id)} end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)

      winners = for {agent_id, {:ok, _}} <- results, do: agent_id
      losers = for {_agent_id, {:error, :already_claimed}} <- results, do: :lost

      assert length(winners) == 1
      assert length(losers) == 7

      [winner] = winners

      assert %ClipJob{status: "claimed", claimed_by_agent_id: ^winner} =
               Repo.get!(ClipJob, job.id)
    end

    test "a second claim on a claimed job returns already_claimed", w do
      {_clip, job} = new_clip!(w)

      assert {:ok, %ClipJob{status: "claimed"} = claimed} =
               ClipJobs.claim(w.scope, job.id, w.agent.id)

      assert claimed.claimed_by_agent_id == w.agent.id
      assert %DateTime{} = claimed.claimed_at

      assert {:error, :already_claimed} = ClipJobs.claim(w.scope, job.id, w.agent2.id)
      assert {:error, :already_claimed} = ClipJobs.claim(w.scope, job.id, w.agent.id)
      assert Repo.get!(ClipJob, job.id).claimed_by_agent_id == w.agent.id
    end
  end

  describe "progress, complete and fail" do
    test "a non-claimer cannot progress, complete or fail", w do
      {clip, job} = new_clip!(w)
      claimed!(w, job)
      before = Repo.get!(ClipJob, job.id)

      assert {:error, :not_claimer} = ClipJobs.progress(w.scope, job.id, w.agent2.id, 0.3)

      assert {:error, :not_claimer} =
               ClipJobs.complete(w.scope, job.id, w.agent2.id, %{"file_id" => w.f1.id})

      assert {:error, :not_claimer} = ClipJobs.fail(w.scope, job.id, w.agent2.id, "x")

      assert Repo.get!(ClipJob, job.id) == before
      assert %Clip{status: "candidate", render_file_id: nil} = Repo.get!(Clip, clip.id)
      assert renders(clip.id) == []

      # nor can anyone on an unclaimed job
      {_c2, queued} = new_clip!(w)
      assert {:error, :not_claimer} = ClipJobs.progress(w.scope, queued.id, w.agent.id, 0.3)
    end

    test "progress: running, 0..1, eta >= 0", w do
      {_clip, job} = new_clip!(w)
      claimed!(w, job)

      assert {:ok, %ClipJob{status: "running", progress: 0.5, eta_s: 30}} =
               ClipJobs.progress(w.scope, job.id, w.agent.id, 0.5, 30)

      for {p, eta} <- [{1.5, nil}, {-0.1, nil}, {"half", nil}, {0.5, -1}, {0.5, "soon"}] do
        assert {:error, :invalid_progress} =
                 ClipJobs.progress(w.scope, job.id, w.agent.id, p, eta)
      end
    end

    test "complete new_clip gives rev 1, pending and one render row", w do
      {clip, job} = new_clip!(w)
      claimed!(w, job)

      assert {:ok, %{job: done, clip: completed}} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{
                 "file_id" => w.f1.id,
                 "title" => "Who makes Total War?",
                 "episode_code" => "S2E14",
                 "source_label" => "htc-clip-tool",
                 "actual_in_s" => 119.9,
                 "actual_out_s" => 162.2,
                 "duration_s" => 42.0,
                 "width" => 1080,
                 "height" => 1920
               })

      assert %ClipJob{status: "done", progress: 1.0, finished_at: %DateTime{}} = done
      assert done.result["file_id"] == w.f1.id

      clip = Repo.get!(Clip, clip.id)
      assert completed.id == clip.id

      assert %Clip{
               rev: 1,
               status: "rendered",
               review_status: "pending",
               origin: "burrow",
               title: "Who makes Total War?",
               episode_code: "S2E14",
               source_label: "htc-clip-tool",
               duration_s: 42.0
             } = clip

      assert clip.render_file_id == w.f1.id
      assert clip.submitted_by_agent_id == w.agent.id
      assert clip.look == ClipLook.effective(w.profile.show_look)

      assert [%ClipRender{rev: 1, file_id: f1}] = renders(clip.id)
      assert f1 == w.f1.id
      [snapshot] = renders(clip.id)
      assert {snapshot.requested_start_s, snapshot.requested_end_s} == {120.0, 162.0}
      assert {snapshot.actual_start_s, snapshot.actual_end_s} == {119.9, 162.2}
      assert snapshot.headline == "Who makes Total War?"
      assert snapshot.source["source_url"] == @url
    end

    test "rerender complete bumps rev to 2 and keeps the rev 1 render row with the old file_id",
         w do
      clip = rendered_clip!(w)
      look = put_in(clip.look, ["cap", "size"], 7.0)

      {:ok, job} =
        ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{
          look: look,
          trim_in_s: 118.0,
          trim_out_s: 165.0
        })

      claimed!(w, job)
      count = Repo.aggregate(Clip, :count)

      assert {:ok, %{clip: %Clip{id: same_id}}} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.f2.id})

      assert same_id == clip.id
      assert Repo.aggregate(Clip, :count) == count

      assert %Clip{rev: 2, review_status: "pending", trim_in_s: 118.0, trim_out_s: 165.0} =
               reloaded = Repo.get!(Clip, clip.id)

      assert reloaded.render_file_id == w.f2.id
      assert reloaded.look == look

      assert [r1, r2] = renders(clip.id)
      assert {r1.rev, r1.file_id, r1.look["cap"]["size"]} == {1, w.f1.id, 5.8}
      assert {r2.rev, r2.file_id, r2.look["cap"]["size"]} == {2, w.f2.id, 7.0}
      assert {r2.trim_in_s, r2.trim_out_s} == {118.0, 165.0}
      assert r1.look != r2.look
    end

    test "a rejected clip re-rendered returns to pending with note cleared", w do
      clip = rendered_clip!(w)

      {:ok, _} =
        clip
        |> Clip.review_changeset({:reject, w.approver.id, "payoff is cut off"})
        |> Repo.update()

      {:ok, job} = ClipJobs.enqueue_rerender(w.org_id, clip.id, w.approver.id, %{})
      claimed!(w, job)
      {:ok, _} = ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.f2.id})

      assert %Clip{
               review_status: "pending",
               review_note: nil,
               reviewed_by_user_id: nil,
               reviewed_at: nil,
               rev: 2
             } = Repo.get!(Clip, clip.id)
    end

    test "complete on a done job returns job_closed; fail sets failed plus error", w do
      {clip, job} = new_clip!(w)
      claimed!(w, job)
      {:ok, _} = ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.f1.id})

      assert {:error, :job_closed} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.f2.id})

      assert {:error, :job_closed} = ClipJobs.fail(w.scope, job.id, w.agent.id, "late")
      assert Repo.get!(Clip, clip.id).render_file_id == w.f1.id

      {clip2, job2} = new_clip!(w)
      claimed!(w, job2)

      assert {:ok, %ClipJob{status: "failed", error: error, finished_at: %DateTime{}}} =
               ClipJobs.fail(w.scope, job2.id, w.agent.id, "no speech found", "E_NO_SPEECH")

      assert error == "E_NO_SPEECH: no speech found"
      assert %Clip{status: "candidate", render_file_id: nil} = Repo.get!(Clip, clip2.id)

      {_clip3, job3} = new_clip!(w)
      claimed!(w, job3)
      assert {:error, :invalid_error} = ClipJobs.fail(w.scope, job3.id, w.agent.id, "  ")

      {:ok, %ClipJob{error: long}} =
        ClipJobs.fail(w.scope, job3.id, w.agent.id, String.duplicate("e", 3000))

      assert String.length(long) == 2000
    end

    test "complete checks the file like social_clip_submit", w do
      {_clip, job} = new_clip!(w)
      claimed!(w, job)

      assert {:error, :file_not_in_project} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.other.video.id})

      assert {:error, :file_not_in_project} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{})

      assert {:error, :not_a_video} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{"file_id" => w.transcript.id})

      assert %ClipJob{status: "claimed"} = Repo.get!(ClipJob, job.id)
    end

    test "review_status in result is not written", w do
      {clip, job} = new_clip!(w)
      claimed!(w, job)

      {:ok, %{job: done}} =
        ClipJobs.complete(w.scope, job.id, w.agent.id, %{
          "file_id" => w.f1.id,
          "review_status" => "approved",
          "review_note" => "ok",
          "reviewed_by_user_id" => w.approver.id,
          "reviewed_at" => DateTime.utc_now(),
          "rev" => 9
        })

      assert %Clip{review_status: "pending", review_note: nil, reviewed_by_user_id: nil, rev: 1} =
               Repo.get!(Clip, clip.id)

      refute Map.has_key?(done.result, "review_status")
      refute Map.has_key?(done.result, "rev")
    end

    test "result with title nil and caption nil succeeds", w do
      {clip, job} = new_clip!(w)
      claimed!(w, job)

      assert {:ok, _} =
               ClipJobs.complete(w.scope, job.id, w.agent.id, %{
                 "file_id" => w.f1.id,
                 "title" => nil,
                 "caption" => nil,
                 "speaker" => nil,
                 "episode_code" => nil
               })

      assert %Clip{title: nil, caption: nil, review_status: "pending", rev: 1} =
               Repo.get!(Clip, clip.id)
    end
  end

  test "another org's job id is not_found for list, claim, progress, complete and fail", w do
    {_clip, theirs} =
      (fn ->
         {:ok, %{clip: c, job: j}} =
           ClipJobs.enqueue_new_clip(w.other.org_id, w.other.profile.id, w.other.approver.id, %{
             source_url: @url,
             in_s: 1.0,
             out_s: 9.0
           })

         {c, j}
       end).()

    random = Ecto.UUID.generate()

    for id <- [theirs.id, random, "not-a-uuid"] do
      assert {:error, :not_found} = ClipJobs.claim(w.scope, id, w.agent.id)
      assert {:error, :not_found} = ClipJobs.progress(w.scope, id, w.agent.id, 0.5)

      assert {:error, :not_found} =
               ClipJobs.complete(w.scope, id, w.agent.id, %{"file_id" => w.f1.id})

      assert {:error, :not_found} = ClipJobs.fail(w.scope, id, w.agent.id, "x")
    end

    assert {:error, :not_found} = ClipJobs.list_jobs(w.scope, w.other.profile.id)
    assert {:error, :not_found} = ClipJobs.list_jobs(w.scope, random)
    assert %ClipJob{status: "queued", claimed_by_agent_id: nil} = Repo.get!(ClipJob, theirs.id)

    # their own agent sees it
    assert {:ok, [listed]} = ClipJobs.list_jobs(w.other.scope, w.other.profile.id)
    assert listed.id == theirs.id
  end

  test "list_jobs filters by status and kind, oldest first", w do
    {_c1, j1} = new_clip!(w)
    {_c2, j2} = new_clip!(w)
    claimed!(w, j2)
    {:ok, %{job: j3}} = ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{})

    assert {:ok, jobs} = ClipJobs.list_jobs(w.scope, w.profile.id)
    assert Enum.map(jobs, & &1.id) == [j1.id, j2.id, j3.id]
    assert {:ok, [%{id: id}]} = ClipJobs.list_jobs(w.scope, w.profile.id, status: "claimed")
    assert id == j2.id

    assert {:ok, [%{id: ^id}]} =
             ClipJobs.list_jobs(w.scope, w.profile.id, %{
               "status" => "claimed",
               "kind" => "new_clip"
             })

    assert {:ok, [%{kind: "save_default"}]} =
             ClipJobs.list_jobs(w.scope, w.profile.id, kind: "save_default")
  end

  test "save_show_default writes show_look and a clip enqueued afterwards copies it", w do
    look = %{"cap" => %{"size" => 7.0, "font" => "Inter Black"}, "music" => false}

    assert {:ok, %{profile: profile, job: job}} =
             ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, look)

    assert Repo.get!(Profile, w.profile.id).show_look == look
    assert profile.show_look == look
    assert %ClipJob{kind: "save_default", clip_id: nil, status: "queued"} = job
    assert job.payload["look"] == ClipLook.effective(look)
    assert job.payload["look_delta"] == look
    assert job.payload["clip_overrides"]["mapped"] == %{"captions.size_frac" => 0.07}
    assert job.payload["clip_overrides"]["unmapped"] == ["cap.font", "music"]
    assert job.payload["clip_user_profile"] == "burrow-" <> w.profile.id

    {clip, new_job} = new_clip!(w)
    assert clip.look == ClipLook.effective(look)
    assert clip.look["cap"]["size"] == 7.0
    # the new clip matches the show default, so no per-clip delta
    assert new_job.payload["look_delta"] == %{}

    assert {:error, {:invalid_look, _}} =
             ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
               "cap" => %{"size" => 0}
             })

    # a save_default job completes with no clip write
    claimed!(w, job)

    assert {:ok, %{clip: nil, job: %ClipJob{status: "done"}}} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{})
  end
end
