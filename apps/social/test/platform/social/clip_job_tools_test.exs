defmodule Platform.Social.ClipJobToolsTest do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234) stage 4: the five clip job tools,
  all through `Platform.Social.Tools.execute/3` with an agent context. The
  acting agent always comes from the context; job_complete reads only the
  submit arguments; another org's job or profile is not_found, exactly as a
  random id.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social.{Clip, ClipJob, ClipJobs, ClipLook, ClipRender, Tools}

  @url "https://www.youtube.com/watch?v=abc"

  setup do
    world = render_world!()
    other = render_world!()
    f1 = stored_file!(world.project, "render one #{unique()}", "f1.mp4", "video/mp4")
    agent2 = pinned_agent!(world.org_id)

    Map.merge(world, %{
      other: other,
      f1: f1,
      agent2: agent2,
      ctx: %{agent_id: world.agent.id},
      ctx2: %{agent_id: agent2.id}
    })
  end

  defp tool(name, args, ctx), do: Tools.execute(name, args, ctx)

  test "fix transport preserves typed base identity and safe applied facts", w do
    {clip, job} = enqueue!(w)
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, _} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: w.f1.id,
        actual_in_s: 120.0,
        actual_out_s: 162.0,
        candidate_id: "base-candidate"
      })

    base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: 1)

    {:ok, fix} =
      ClipJobs.enqueue_fix(w.org_id, clip.id, w.approver.id, %{
        base_render_id: base.id,
        operation: "nudge",
        edge: "end",
        delta_s: -1
      })

    assert {:ok, %{jobs: [listed]}} =
             tool(
               "social_clip_job_list",
               %{"profile_id" => w.profile.id, "status" => "queued"},
               w.ctx
             )

    assert listed.payload["base_render_id"] == base.id
    assert listed.payload["fix"]["operation"] == "nudge"
    {:ok, _} = tool("social_clip_job_claim", %{"job_id" => fix.id}, w.ctx)

    assert {:ok, %{job: done}} =
             tool(
               "social_clip_job_complete",
               %{
                 "job_id" => fix.id,
                 "file_id" => w.f1.id,
                 "actual_in_s" => 120.0,
                 "actual_out_s" => 160.9,
                 "candidate_id" => "base-candidate",
                 "transcript" => "must drop"
               },
               w.ctx
             )

    assert done.result["actual_out_s"] == 160.9
    refute Map.has_key?(done.result, "transcript")
    rendered = Repo.get_by!(ClipRender, clip_id: clip.id, rev: 2)
    assert rendered.requested_end_s == 161.0
    assert rendered.actual_end_s == 160.9
    assert rendered.candidate_id == "base-candidate"
  end

  defp enqueue!(w, org_id \\ nil, profile \\ nil, approver \\ nil) do
    {:ok, %{clip: clip, job: job}} =
      ClipJobs.enqueue_new_clip(
        org_id || w.org_id,
        (profile || w.profile).id,
        (approver || w.approver).id,
        %{source_url: @url, in_s: 120.0, out_s: 162.0}
      )

    {clip, job}
  end

  test "the full round trip through the tools", w do
    {clip, job} = enqueue!(w)

    assert {:ok, %{jobs: [listed], total: 1, has_more: false}} =
             tool("social_clip_job_list", %{"profile_id" => w.profile.id}, w.ctx)

    assert listed.id == job.id
    assert {listed.kind, listed.status} == {"new_clip", "queued"}
    assert listed.payload["clip_user_profile"] == "burrow-" <> w.profile.id
    assert listed.payload["base_profile"] == "how-to-computer"
    assert {listed.payload["in_s"], listed.payload["out_s"]} == {120.0, 162.0}
    assert listed.payload["look_delta"] == %{}

    assert {:ok, %{jobs: [_]}} =
             tool(
               "social_clip_job_list",
               %{"profile_id" => w.profile.id, "status" => "queued", "kind" => "new_clip"},
               w.ctx
             )

    assert {:ok, %{jobs: []}} =
             tool(
               "social_clip_job_list",
               %{"profile_id" => w.profile.id, "status" => "done"},
               w.ctx
             )

    assert {:ok, %{job: claimed}} = tool("social_clip_job_claim", %{"job_id" => job.id}, w.ctx)
    assert {claimed.status, claimed.claimed_by_agent_id} == {"claimed", w.agent.id}

    assert {:ok, %{job: running}} =
             tool(
               "social_clip_job_progress",
               %{"job_id" => job.id, "progress" => 0.5, "eta_s" => 30},
               w.ctx
             )

    assert {running.status, running.progress, running.eta_s} == {"running", 0.5, 30}

    assert {:ok, %{job: done, clip: clip_json}} =
             tool(
               "social_clip_job_complete",
               %{
                 "job_id" => job.id,
                 "file_id" => w.f1.id,
                 "title" => "Who makes Total War?",
                 "episode_code" => "S2E14",
                 "source_label" => "htc-clip-tool"
               },
               w.ctx
             )

    assert {done.status, done.progress} == {"done", 1.0}
    assert clip_json.id == clip.id
    assert clip_json.review_status == "pending"

    assert %Clip{
             rev: 1,
             status: "rendered",
             review_status: "pending",
             origin: "burrow",
             title: "Who makes Total War?"
           } = reloaded = Repo.get!(Clip, clip.id)

    assert reloaded.render_file_id == w.f1.id
    assert reloaded.look == ClipLook.effective(w.profile.show_look)
    assert [%ClipRender{rev: 1}] = Repo.all(from(r in ClipRender, where: r.clip_id == ^clip.id))

    assert {:ok, %{clips: [%{id: id}]}} =
             tool(
               "social_clip_list",
               %{"profile_id" => w.profile.id, "review_status" => "pending"},
               w.ctx
             )

    assert id == clip.id
  end

  test "claimed_by is the calling agent even when args name another", w do
    {_clip, job} = enqueue!(w)

    assert {:ok, %{job: claimed}} =
             tool(
               "social_clip_job_claim",
               %{
                 "job_id" => job.id,
                 "agent_id" => w.agent2.id,
                 "claimed_by_agent_id" => w.agent2.id
               },
               w.ctx
             )

    assert claimed.claimed_by_agent_id == w.agent.id
    assert Repo.get!(ClipJob, job.id).claimed_by_agent_id == w.agent.id

    # and the named agent is not the claimer
    assert {:error, %{code: :not_claimer}} =
             tool("social_clip_job_progress", %{"job_id" => job.id, "progress" => 0.2}, w.ctx2)
  end

  test "a non-claimer cannot complete via the tool", w do
    {clip, job} = enqueue!(w)
    {:ok, _} = tool("social_clip_job_claim", %{"job_id" => job.id}, w.ctx)

    assert {:error, %{code: :already_claimed}} =
             tool("social_clip_job_claim", %{"job_id" => job.id}, w.ctx2)

    assert {:error, %{code: :not_claimer}} =
             tool(
               "social_clip_job_complete",
               %{"job_id" => job.id, "file_id" => w.f1.id, "agent_id" => w.agent.id},
               w.ctx2
             )

    assert {:error, %{code: :not_claimer}} =
             tool("social_clip_job_fail", %{"job_id" => job.id, "error" => "x"}, w.ctx2)

    assert %ClipJob{status: "claimed", progress: nil} = Repo.get!(ClipJob, job.id)
    assert %Clip{status: "candidate", render_file_id: nil} = Repo.get!(Clip, clip.id)
  end

  test "review_status in job_complete args is not written", w do
    {clip, job} = enqueue!(w)
    {:ok, _} = tool("social_clip_job_claim", %{"job_id" => job.id}, w.ctx)

    assert {:ok, %{job: done}} =
             tool(
               "social_clip_job_complete",
               %{
                 "job_id" => job.id,
                 "file_id" => w.f1.id,
                 "review_status" => "approved",
                 "review_note" => "ok",
                 "reviewed_by_user_id" => w.approver.id,
                 "reviewed_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "rev" => 9
               },
               w.ctx
             )

    assert %Clip{review_status: "pending", review_note: nil, reviewed_by_user_id: nil, rev: 1} =
             Repo.get!(Clip, clip.id)

    for key <- ~w(review_status review_note reviewed_by_user_id reviewed_at rev),
        do: refute(Map.has_key?(done.result, key))
  end

  test "job errors: closed job, bad progress, non-video, blank error", w do
    {_clip, job} = enqueue!(w)
    {:ok, _} = tool("social_clip_job_claim", %{"job_id" => job.id}, w.ctx)

    assert {:error, %{code: :invalid_progress}} =
             tool("social_clip_job_progress", %{"job_id" => job.id, "progress" => 2}, w.ctx)

    assert {:error, %{code: :not_a_video}} =
             tool(
               "social_clip_job_complete",
               %{"job_id" => job.id, "file_id" => w.transcript.id},
               w.ctx
             )

    assert {:error, %{code: :file_not_in_project}} =
             tool(
               "social_clip_job_complete",
               %{"job_id" => job.id, "file_id" => w.other.video.id},
               w.ctx
             )

    assert {:error, %{code: :invalid_error}} =
             tool("social_clip_job_fail", %{"job_id" => job.id, "error" => " "}, w.ctx)

    assert {:ok, %{job: failed}} =
             tool(
               "social_clip_job_fail",
               %{"job_id" => job.id, "error" => "no speech", "code" => "E_NO_SPEECH"},
               w.ctx
             )

    assert {failed.status, failed.error} == {"failed", "E_NO_SPEECH: no speech"}

    assert {:error, %{code: :job_closed}} =
             tool("social_clip_job_complete", %{"job_id" => job.id, "file_id" => w.f1.id}, w.ctx)
  end

  test "cross-org job and profile ids are not_found for all five tools, like a random id", w do
    {their_clip, theirs} =
      enqueue!(w, w.other.org_id, w.other.profile, w.other.approver)

    calls = fn job_id, profile_id ->
      [
        tool("social_clip_job_list", %{"profile_id" => profile_id}, w.ctx),
        tool("social_clip_job_claim", %{"job_id" => job_id}, w.ctx),
        tool("social_clip_job_progress", %{"job_id" => job_id, "progress" => 0.5}, w.ctx),
        tool("social_clip_job_complete", %{"job_id" => job_id, "file_id" => w.f1.id}, w.ctx),
        tool("social_clip_job_fail", %{"job_id" => job_id, "error" => "x"}, w.ctx),
        tool("social_clip_list", %{"profile_id" => profile_id}, w.ctx)
      ]
    end

    cross = calls.(theirs.id, w.other.profile.id)
    random = calls.(Ecto.UUID.generate(), Ecto.UUID.generate())

    for result <- cross, do: assert({:error, %{code: :not_found}} = result)
    assert cross == random

    assert %ClipJob{status: "queued", claimed_by_agent_id: nil} = Repo.get!(ClipJob, theirs.id)
    assert %Clip{status: "candidate"} = Repo.get!(Clip, their_clip.id)
  end

  test "a job_json with nil result and error serializes", w do
    {_clip, _job} = enqueue!(w)

    assert {:ok, %{jobs: [row]} = reply} =
             tool("social_clip_job_list", %{"profile_id" => w.profile.id}, w.ctx)

    assert {row.result, row.error, row.progress, row.eta_s, row.claimed_by_agent_id} ==
             {nil, nil, nil, nil, nil}

    assert Map.keys(row) |> Enum.sort() ==
             Enum.sort(
               ~w(id profile_id clip_id kind status progress eta_s payload result error claimed_by_agent_id claimed_at finished_at inserted_at)a
             )

    assert {:ok, json} = Jason.encode(reply)
    assert json =~ ~s("result":null)
  end

  test "a call with no agent is refused", w do
    {_clip, job} = enqueue!(w)

    assert {:error, %{code: :no_agent}} =
             tool("social_clip_job_claim", %{"job_id" => job.id}, %{})

    assert Repo.get!(ClipJob, job.id).status == "queued"
  end
end
