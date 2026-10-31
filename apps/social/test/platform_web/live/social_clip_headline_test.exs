defmodule PlatformWeb.SocialClipHeadlineTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Clip, ClipJob, ClipJobs, ClipVersions, Post}

  setup do
    w = render_world!()

    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/episode.mp4",
        in_s: 10,
        out_s: 30
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    file = stored_file!(w.project, "fixture #{unique()}", "v1.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: file.id,
        candidate_id: "candidate-fixture",
        actual_in_s: 10.0,
        actual_out_s: 30.0
      })

    {:ok, [base]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    {:ok, w: Map.merge(w, %{clip: clip, base: base, file: file})}
  end

  defp open(conn, w, user \\ nil) do
    conn = Plug.Test.init_test_session(conn, current_user_id: (user || w.approver).id)
    {:ok, view, _} = live(conn, "/m/social?tab=clips&view=review")
    find_live_child(view, "ext-page-social")
  end

  defp submit(child, w, text) do
    child
    |> element("[data-role='clip-headline-form']")
    |> render_submit(%{"base_render_id" => w.base.id, "headline" => text})
  end

  defp attempt(w),
    do: Repo.one!(from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"))

  test "one field binds exact human text and base; completion selects n+1 without deleting history",
       %{conn: conn, w: w} do
    child = open(conn, w)
    assert has_element?(child, "label[for='clip-headline']", "Headline")
    assert has_element?(child, "input[name='base_render_id'][value='#{w.base.id}']")
    assert has_element?(child, "#clip-headline[value='']")
    submit(child, w, "The team celebrated")
    job = attempt(w)

    assert job.payload["headline"] == %{
             "consumer" => "edit",
             "requested_headline" => "The team celebrated"
           }

    refute Map.has_key?(job.payload, "fix")
    assert job.payload["base_render_id"] == w.base.id
    assert job.payload["candidate_id"] == "candidate-fixture"
    assert job.payload["expected_rev"] == 2
    assert has_element?(child, "[data-role='clip-headline-pending']")
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
    assert Repo.reload!(w.clip).rev == 1
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    file = stored_file!(w.project, "render #{unique()}", "v2.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{file_id: file.id, title: nil})

    render(child)
    assert clip.rev == 2
    assert has_element?(child, "video[src='/files/blob/#{file.id}']")
    assert has_element?(child, "#clip-headline[value='The team celebrated']")
    {:ok, [new, old]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert old.file_id == w.file.id
    assert new.headline == "The team celebrated"
    assert Platform.Files.get_file(old.file_id)
    assert Repo.aggregate(Post, :count) == 0
    assert Repo.reload!(w.clip).review_status == "pending"

    assert {:error, :job_closed} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{file_id: file.id})

    assert {:ok, versions} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert length(versions) == 2
  end

  test "failed headline persists safely after reload, keeps playback and permits retry", %{
    conn: conn,
    w: w
  } do
    child = open(conn, w)
    submit(child, w, "First attempt")
    job = attempt(w)
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, _} =
      ClipJobs.fail(
        w.scope,
        job.id,
        w.agent.id,
        "SECRET transcript generated words",
        "HEADLINE_UNBACKED"
      )

    child = open(conn, w)

    assert has_element?(
             child,
             "[data-role='clip-headline-failure']",
             "Render failed. Try Render preview again. If it fails again, ask the render operator to check the job. Your previous video is unchanged."
           )

    refute render(child) =~ "SECRET transcript"
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
    submit(child, w, "Second attempt")

    assert Repo.aggregate(
             from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"),
             :count
           ) == 2

    assert Repo.reload!(w.clip).rev == 1
    assert Repo.aggregate(Post, :count) == 0
  end

  test "headline model preflight shares safe guidance without exposing raw diagnostics", %{
    conn: conn,
    w: w
  } do
    child = open(conn, w)
    submit(child, w, "First attempt")
    job = attempt(w)
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, _} =
      ClipJobs.fail(
        w.scope,
        job.id,
        w.agent.id,
        "doctor failed (model:base.en)",
        "CLIP_DOCTOR_FIX"
      )

    child = open(conn, w)

    assert has_element?(
             child,
             "[data-role='clip-headline-failure']",
             "Render could not start because the runner's transcription model is not ready. Ask the render operator to finish setup, then try Render preview again. Your previous video is unchanged."
           )

    refute render(child) =~ "CLIP_DOCTOR_FIX"
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
  end

  test "blank, stale, foreign bases and removed approver cannot enqueue", %{conn: conn, w: w} do
    child = open(conn, w)
    submit(child, w, "   ")
    assert has_element?(child, "[data-role='clip-headline-error']", "1–200")

    assert {:error, :not_found} =
             ClipJobs.enqueue_fix(Ecto.UUID.generate(), w.clip.id, w.approver.id, %{
               operation: "edit_headline",
               base_render_id: w.base.id,
               headline: "Foreign"
             })

    assert {:error, :not_found} =
             ClipJobs.enqueue_fix(w.org_id, w.clip.id, w.approver.id, %{
               operation: "edit_headline",
               base_render_id: Ecto.UUID.generate(),
               headline: "Forged"
             })

    Repo.update_all(from(c in Clip, where: c.id == ^w.clip.id), inc: [rev: 1])
    submit(child, w, "Stale")
    assert has_element?(child, "[data-role='clip-headline-error']", "newer version")
    assert Repo.aggregate(from(j in ClipJob, where: j.kind == "rerender"), :count) == 0
    # Fresh server authorization is checked even for a forged event after removal.
    Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id),
      set: [approver_user_ids: []]
    )

    child
    |> with_target("#social-clips-review")
    |> render_click("rerender_headline", %{"base_render_id" => w.base.id, "headline" => "Denied"})

    assert Repo.aggregate(from(j in ClipJob, where: j.kind == "rerender"), :count) == 0
  end
end
