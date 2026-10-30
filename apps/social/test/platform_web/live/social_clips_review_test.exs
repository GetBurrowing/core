defmodule PlatformWeb.SocialClipsReviewTest do
  @moduledoc """
  Clip Studio 3/9 (task 01a16662-8c00) stage 2: the desktop Review bay in
  `PlatformWeb.SocialClipsReview` (queue rail with the render queue, the
  9:16 player, the details rail, the empty state), mounted through Social's
  nested LiveView at `/m/social?tab=clips`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, ClipJobs}

  @titles [
    "Who makes Total War? Sorry, Creative Assembly",
    "Harder than the summit",
    "We moved the doomsday clock to 89 seconds"
  ]

  setup do
    w = render_world!()

    {:ok, ig} =
      Social.create_account(w.org_id, w.profile, %{platform: "instagram", handle: "@show.ig"})

    {:ok, yt} =
      Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@show.yt"})

    octavius =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "octavius-#{unique()}",
        name: "Octavius",
        metadata: %{"org_id" => w.org_id}
      })

    %{w: Map.merge(w, %{ig: ig, yt: yt, octavius: octavius})}
  end

  defp clip!(w, title, attrs \\ %{}) do
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        Map.merge(
          %{
            "file_id" => file.id,
            "title" => title,
            "episode_code" => "S2E14",
            "source_label" => "htc-clip-tool",
            "duration_s" => 42,
            "platforms" => ["instagram", "youtube"]
          },
          attrs
        ),
        w.octavius.id
      )

    clip
  end

  defp three!(w), do: Enum.map(@titles, &clip!(w, &1))

  defp render_job!(w, progress, eta_s) do
    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        "source_file_id" => w.video.id,
        "in_s" => 2011.3,
        "out_s" => 2058.3,
        "title" => "GPU tax: who actually pays?"
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.octavius.id)

    if progress do
      {:ok, _} = ClipJobs.progress(w.scope, job.id, w.octavius.id, progress, eta_s)
    end

    job
  end

  defp open(conn, user, query \\ "?tab=clips&view=review") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social" <> query)
    find_live_child(view, "ext-page-social")
  end

  defp bay(child), do: with_target(child, "#social-clips-review")

  test "the decision footer is outside the keyboard-accessible details scroll region", %{
    conn: conn,
    w: w
  } do
    clip!(w, "Keep decisions on screen")
    child = open(conn, w.approver)

    assert has_element?(
             child,
             "[data-role='clips-details-body'][role='region'][tabindex='0'][aria-label='Clip details'] [data-role='clip-caption']"
           )

    assert has_element?(child, "[data-role='clips-details-body'] [data-role='clip-note']")

    assert has_element?(
             child,
             "[data-role='clips-details'] > [data-role='clips-decide'] [data-role='clip-approve']"
           )

    refute has_element?(child, "[data-role='clips-details-body'] [data-role='clips-decide']")
    assert has_element?(child, "[data-role='clips-player-stack'] [data-role='clip-frame']")
    assert has_element?(child, "[data-role='clips-pbar'] [data-role='clips-pbar-approve']")
  end

  test "each bay element is present with its copy", %{conn: conn, w: w} do
    [first, second, _] = three!(w)
    render_job!(w, 0.5, 30)
    child = open(conn, w.approver)

    # Subhead.
    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")
    assert has_element?(child, "[data-role='clips-count']", "· one approval publishes")
    assert has_element?(child, "[data-role='clips-rendering-pill']", "1 rendering")
    assert has_element?(child, "[data-role='clips-rendering-pill']", "on clip tool")

    assert has_element?(
             child,
             "[data-role='clips-view-button'][role='tab'][aria-selected='true']",
             "Review"
           )

    # Queue rail and render queue.
    assert has_element?(child, "[data-role='clips-queue']", "Review")
    assert has_element?(child, "[data-role='clips-queue-item']", "S2E14 · 0:42")

    assert has_element?(
             child,
             "[data-role='clips-queue-item'][aria-current='true'][data-clip-id='#{first.id}']"
           )

    assert has_element?(child, "#rq[data-role='clips-render-queue']", "Rendering on clip tool")

    assert has_element?(
             child,
             "[data-role='clips-render-queue']",
             "Finished renders land in Review."
           )

    # Stage.
    assert has_element?(child, "[data-role='clips-position']", "1 of 3")
    assert has_element?(child, "[aria-label='Previous clip (K)'][disabled]")
    assert has_element?(child, "[aria-label='Next clip (J)']:not([disabled])")

    assert has_element?(
             child,
             "#clip-player-#{first.id}-r1[phx-hook='ChatClip'][phx-update='ignore'][data-role='clip-player']"
           )

    assert has_element?(
             child,
             "[data-role='clip-frame'] video[src='/files/blob/#{first.render_file_id}']"
           )

    assert has_element?(child, "[data-role='clip-fallback']", "Can't play this video")
    assert has_element?(child, "[data-role='clip-play'][aria-label='Play or pause']")
    assert has_element?(child, "[data-role='clip-scrub']", "0:00")
    assert has_element?(child, "[data-role='clip-scrub']", "0:42")

    for {key, label} <- [{"J", "next"}, {"K", "previous"}, {"Space", "play / pause"}] do
      assert has_element?(child, "[data-role='clips-kbd-hint'] kbd.kbd", key)
      assert has_element?(child, "[data-role='clips-kbd-hint']", label)
    end

    # Details rail.
    assert has_element?(child, "[data-role='clip-title']", hd(@titles))
    assert has_element?(child, "[data-role='clip-meta']", "S2E14 · 0:42 · htc-clip-tool · v1")
    assert has_element?(child, "[data-role='clips-details']", "Caption")
    assert has_element?(child, "[data-role='clip-caption-count']", "0/2200")
    assert has_element?(child, "[data-role='clip-caption'][maxlength='2200']")
    assert has_element?(child, "[data-role='clips-details']", "Post to")
    assert has_element?(child, "[data-role='clips-details']", "publishes on approve")

    for label <- ~w(TikTok X Instagram YouTube) do
      assert has_element?(child, "[data-role='clip-platform-row']", label)
    end

    assert has_element?(
             child,
             "[data-role='clip-platform-row'][data-platform='instagram'] input.toggle[role='switch'][aria-label='Instagram'][checked]"
           )

    refute has_element?(
             child,
             "[data-role='clip-platform-row'][data-platform='tiktok'] input[checked]"
           )

    assert has_element?(child, "[data-role='clip-note-hint']", "needed to reject")

    assert has_element?(
             child,
             "[data-role='clip-note'][placeholder='Why not? Octavius reads this for the next cut…']"
           )

    assert has_element?(
             child,
             "[data-role='clip-approve']:not([disabled])",
             "Approve and publish"
           )

    assert has_element?(
             child,
             "[data-role='clip-why']",
             "Publishes to Instagram and YouTube now · no second approval"
           )

    # Navigation moves the selection and asks the hook to sync the URL.
    bay(child) |> render_click("next", %{})
    assert has_element?(child, "[data-role='clips-position']", "2 of 3")
    assert_push_event(child, "clips:url", %{tab: "clips", view: "review", clip: id})
    assert id == second.id
  end

  test "Approve is disabled and reads Pick a platform with no platforms ticked",
       %{conn: conn, w: w} do
    clip!(w, "No platforms", %{"platforms" => []})
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='clip-approve'][disabled]", "Pick a platform")
    refute has_element?(child, "[data-role='clip-approve']", "Approve and publish")
    assert has_element?(child, "[data-role='clip-why']", "Tick at least one platform to approve")

    # Toggling a platform on saves it and enables Approve.
    child
    |> element("[data-role='clip-platform-row'][data-platform='youtube'] input")
    |> render_click()

    assert has_element?(
             child,
             "[data-role='clip-approve']:not([disabled])",
             "Approve and publish"
           )

    assert has_element?(
             child,
             "[data-role='clip-why']",
             "Publishes to YouTube now · no second approval"
           )
  end

  test "Reject is disabled with no note", %{conn: conn, w: w} do
    clip!(w, "Needs a note")
    child = open(conn, w.approver)

    assert has_element?(
             child,
             "[data-role='clip-reject'][disabled][title='Add a note to reject']"
           )

    child
    |> form("[data-role='clips-details'] form[phx-change='note']")
    |> render_change(%{"note" => "   "})

    assert has_element?(child, "[data-role='clip-reject'][disabled]")

    child
    |> form("[data-role='clips-details'] form[phx-change='note']")
    |> render_change(%{"note" => "payoff is cut off"})

    assert has_element?(
             child,
             "[data-role='clip-reject']:not([disabled])[title='Reject with your note']"
           )
  end

  test "the empty state", %{conn: conn, w: w} do
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='clips-empty']", "All caught up")
    assert has_element?(child, "[data-role='clips-empty'] .hero-check-badge")
    assert has_element?(child, "[data-role='clips-empty']", "Approved clips are publishing.")
    refute has_element?(child, "[data-role='clips-empty']", "More are rendering")
    assert has_element?(child, "[data-role='clips-queue']", "Nothing left to review.")
    assert has_element?(child, "[data-role='clips-count'] b", "0 to review")
    refute has_element?(child, "[data-role='clips-rendering-pill']")

    render_job!(w, nil, nil)
    child = open(conn, w.approver)

    assert has_element?(
             child,
             "[data-role='clips-empty']",
             "Approved clips are publishing. More are rendering on the clip tool."
           )

    child |> element("[data-role='clips-open-library']", "Open Library") |> render_click()
    assert has_element?(child, "[data-role='clips-review'][data-view='library']")
    assert has_element?(child, "[data-role='clips-library']")
  end

  test "an external clip's byline", %{conn: conn, w: w} do
    clip!(w, "Byline")
    child = open(conn, w.approver)

    assert has_element?(
             child,
             "[data-role='clip-byline']",
             "htc-clip-tool · rendered by Octavius"
           )

    assert has_element?(child, "[data-role='clip-byline'] .font-mono", "htc-clip-tool")
    assert has_element?(child, "[data-role='clip-byline'] b", "Octavius")
  end

  test "a non-approver sees no decision buttons", %{conn: conn, w: w} do
    clip!(w, "Read only")
    member = member!(user!(), w.org_id)
    child = open(conn, member)

    assert has_element?(child, "[data-role='clips-details']")
    refute has_element?(child, "[data-role='clips-decide']")
    refute has_element?(child, "[data-role='clip-approve']")
    refute has_element?(child, "[data-role='clip-reject']")
    assert has_element?(child, "[data-role='clip-caption'][disabled]")
    assert has_element?(child, "[data-role='clip-note'][disabled]")
    assert has_element?(child, "[data-role='clip-title'][disabled]")
    refute has_element?(child, "[data-role='clip-platform-toggle']:not([disabled])")
  end

  test "a non-approver's forged write changes nothing", %{conn: conn, w: w} do
    clip = clip!(w, "Original")
    member = member!(user!(), w.org_id)
    child = open(conn, member)

    bay(child) |> render_submit("save_title", %{"title" => "Forged"})
    bay(child) |> render_change("save_caption", %{"caption" => "Forged"})
    bay(child) |> render_click("toggle_platform", %{"platform" => "tiktok"})

    reloaded = Repo.reload!(clip)
    assert reloaded.title == "Original"
    assert reloaded.caption == nil
    assert reloaded.platforms == ["instagram", "youtube"]
  end

  test "an approver edits the title and caption", %{conn: conn, w: w} do
    clip = clip!(w, "Before")
    child = open(conn, w.approver)

    child |> element("[data-role='clip-title']") |> render_click()
    assert has_element?(child, "[data-role='clip-title-input'][maxlength='200']")

    child |> form("[data-role='clip-title-form']") |> render_submit(%{"title" => "After"})
    assert has_element?(child, "[data-role='clip-title']", "After")

    child
    |> form("[data-role='clips-details'] form[phx-change='save_caption']")
    |> render_change(%{"caption" => "hello"})

    assert has_element?(child, "[data-role='clip-caption-count']", "5/2200")
    assert %{title: "After", caption: "hello"} = Repo.reload!(clip)
  end

  test "picking another org's clip id is refused", %{conn: conn, w: w} do
    [first, _, third] = three!(w)
    other = render_world!()

    {:ok, foreign} =
      AgentDrafts.submit_clip(
        other.scope,
        other.profile.id,
        %{
          "file_id" =>
            stored_file!(other.project, "foreign #{unique()}", "f.mp4", "video/mp4").id,
          "title" => "FOREIGN-CLIP-TITLE"
        },
        other.agent.id
      )

    child = open(conn, w.approver)
    bay(child) |> render_click("pick", %{"id" => foreign.id})

    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{first.id}']")
    assert has_element?(child, "[data-role='clips-position']", "1 of 3")
    refute render(child) =~ "FOREIGN-CLIP-TITLE"

    # An own clip is picked.
    child
    |> element("[data-role='clips-queue-item'][data-clip-id='#{third.id}']")
    |> render_click()

    assert has_element?(child, "[data-role='clips-position']", "3 of 3")
    assert has_element?(child, "[aria-label='Next clip (J)'][disabled]")
  end

  test "the render queue shows progress and time left", %{conn: conn, w: w} do
    clip!(w, "Pending")
    render_job!(w, 0.5, 30)
    render_job!(w, nil, nil)
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='clips-rendering-pill']", "2 rendering")
    assert has_element?(child, "[data-role='clips-render-row']", "GPU tax: who actually pays?")
    assert has_element?(child, "[data-role='clips-render-row']", "0:30 left")

    assert has_element?(
             child,
             "[data-role='clips-render-row'] progress.progress-info[value='50']"
           )

    # Unknown progress: an indeterminate bar, and no "left".
    assert has_element?(
             child,
             "[data-role='clips-render-row'] progress.progress-info:not([value])"
           )

    html = child |> element("#rq") |> render()
    assert length(Regex.scan(~r/ left/, html)) == 1
  end

  test "placeholders are not rendered", %{conn: conn, w: w} do
    three!(w)
    child = open(conn, w.approver)

    for role <-
          ~w(clip-edit-look clip-trim clip-cover-row clip-new-button clip-rerender clip-frame-title),
        do: refute(has_element?(child, "[data-role='#{role}']"))

    refute render(child) =~ "New clip from episode"
    refute render(child) =~ "Edit look"
  end

  test "the bay carries no hex colour and no emoji", %{conn: conn, w: w} do
    three!(w)
    render_job!(w, 0.5, 30)
    child = open(conn, w.approver)
    html = child |> element("#social-clips-review") |> render()

    attrs = Regex.scan(~r/\s(?:class|style)="([^"]*)"/, html, capture: :all_but_first)
    assert attrs != []

    for [value] <- attrs do
      refute value =~ ~r/#[0-9a-fA-F]{3,8}\b/, "hex colour in #{value}"
      refute value =~ ~r/rgba?\(/, "rgb colour in #{value}"
    end

    text = html |> LazyHTML.from_fragment() |> LazyHTML.text()
    refute text =~ ~r/\p{Extended_Pictographic}/u

    # The empty state too.
    w2 = render_world!()
    render_job!(Map.merge(w2, %{octavius: w2.agent}), nil, nil)
    empty = conn |> open(w2.approver) |> element("#social-clips-review") |> render()
    assert empty =~ "All caught up"

    for [value] <- Regex.scan(~r/\s(?:class|style)="([^"]*)"/, empty, capture: :all_but_first),
        do: refute(value =~ ~r/#[0-9a-fA-F]{3,8}\b/)

    refute empty |> LazyHTML.from_fragment() |> LazyHTML.text() =~ ~r/\p{Extended_Pictographic}/u
  end

  defp ending_fixture!(w, name, color) do
    path = Path.join(System.tmp_dir!(), "review-ending-#{unique()}.mp4")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=#{color}:s=64x96:r=25:d=0.4",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-y",
        path
      ])

    bytes = File.read!(path)
    File.rm!(path)

    {:ok, %{file: file}} =
      Social.ClipClosingVideo.upload(
        w.org_id,
        w.profile.id,
        w.approver.id,
        bytes,
        name,
        "video/mp4"
      )

    file
  end

  defp ending_default!(w, file, audio \\ "keep", enabled \\ true) do
    {:ok, _} =
      Social.ClipClosingVideo.save(w.org_id, w.profile.id, w.approver.id, %{
        file_id: file.id,
        audio: audio,
        enabled: enabled
      })
  end

  defp ending_clip!(w, output) do
    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/TEST-ONLY-source",
        in_s: 0,
        out_s: 1
      })

    ending_complete!(w, job, output)
  end

  defp ending_complete!(w, job, output) do
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: output.id,
        candidate_id: "original-only",
        actual_in_s: 0,
        actual_out_s: 1,
        title: "TEST ONLY source"
      })

    {:ok, [render | _]} = Social.ClipVersions.recent(w.org_id, w.profile.id, clip.id)
    {clip, render}
  end

  @tag :ffmpeg
  test "selected immutable endings survive replacement and old playback disables decisions", %{
    conn: conn,
    w: w
  } do
    a =
      ending_fixture!(
        w,
        "TEST-ONLY-A-with-a-very-long-filename-that-truncates-on-a-phone.mp4",
        "magenta"
      )

    b = ending_fixture!(w, "TEST-ONLY-B.mp4", "lime")
    ending_default!(w, a)
    {clip, old} = ending_clip!(w, a)
    ending_default!(w, b, "mute")
    child = open(conn, w.approver)
    bay(child) |> render_click("pick_version", %{})
    bay(child) |> render_click("pick_version", %{"render_id" => "not-a-uuid"})
    assert has_element?(child, "[data-role=selected-ending]", "Ends with: #{a.name}")
    assert has_element?(child, "[data-role=use-closing-video] input[value='#{old.id}']")
    child |> form("[data-role=use-closing-video]") |> render_submit()
    assert has_element?(child, "[data-role=closing-render-pending]")
    assert has_element?(child, "#clip-player-#{clip.id}-r#{old.rev}")
    assert has_element?(child, "[data-role=use-closing-video] button[disabled]")
    {:ok, jobs} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    job = Enum.find(jobs, &(&1.payload["base_render_id"] == old.id))
    assert job.payload["closing_video"]["file_id"] == b.id
    {updated, current} = ending_complete!(w, job, b)
    render(child)
    assert has_element?(child, "[data-role=selected-ending]", "Ends with: #{b.name}")
    refute has_element?(child, "[data-role=use-closing-video]")

    # Hiding a form must not authorize a forged matching submission.
    {:ok, before_forged} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    bay(child) |> render_click("use_closing_video", %{"base_render_id" => current.id})
    assert has_element?(child, "[data-role=closing-render-error]")
    refute has_element?(child, "[data-role=closing-render-pending]")
    {:ok, after_forged} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    assert length(after_forged) == length(before_forged)
    assert has_element?(child, "#clip-player-#{clip.id}-r#{updated.rev}")

    child
    |> element("[data-role=pick-render-version][data-render-id='#{old.id}']")
    |> render_click()

    assert has_element?(child, "[data-role=selected-ending]", "Ends with: #{a.name}")
    assert has_element?(child, "#clip-player-#{clip.id}-r#{old.rev}")
    refute has_element?(child, "[data-role=clips-pbar]")
    refute has_element?(child, "[data-role=use-closing-video]")
    refute has_element?(child, "[data-role=clip-approve]")
    bay(child) |> render_click("use_closing_video", %{"base_render_id" => old.id})
    assert has_element?(child, "[data-role=closing-render-error]")
    {:ok, after_jobs} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    assert length(after_jobs) == length(jobs)

    child
    |> element("[data-role=pick-render-version][data-render-id='#{current.id}']")
    |> render_click()

    assert has_element?(child, "#clip-player-#{clip.id}-r#{updated.rev}")
    assert has_element?(child, "[data-role=clip-approve]")
  end

  @tag :ffmpeg
  test "impact filter shares Settings counts and removes a clip once its new ending completes", %{
    conn: conn,
    w: w
  } do
    a = ending_fixture!(w, "TEST-ONLY-A.mp4", "magenta")
    b = ending_fixture!(w, "TEST-ONLY-B.mp4", "lime")
    ending_default!(w, a)
    {old_clip, old} = ending_clip!(w, a)
    ending_default!(w, b, "mute")
    {matching_clip, _} = ending_clip!(w, b)

    child =
      open(conn, w.approver, "?tab=clips&view=review&profile=#{w.profile.id}&closing=previous")

    assert has_element?(child, "[data-role=closing-impact-filter]")
    assert has_element?(child, "[data-role=clips-queue-item][phx-value-id='#{old_clip.id}']")
    refute has_element?(child, "[data-role=clips-queue-item][phx-value-id='#{matching_clip.id}']")
    bay(child) |> render_click("pick", %{"id" => matching_clip.id})
    assert has_element?(child, "[data-role=clips-bay][data-clip-id='#{old_clip.id}']")
    child |> form("[data-role=use-closing-video]") |> render_submit()
    {:ok, jobs} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    job = Enum.find(jobs, &(&1.payload["base_render_id"] == old.id))
    ending_complete!(w, job, b)
    render(child)
    refute has_element?(child, "[data-role=clips-queue-item]")
    assert has_element?(child, "[data-role=clips-empty]")
    profile = Social.get_profile(w.org_id, w.profile.id)

    assert Social.ClipClosingVideo.review_renders(profile)
           |> Enum.all?(fn {_, r} ->
             Social.ClipClosingVideo.same_ending?(r.closing_video, profile.closing_video)
           end)
  end

  @tag :ffmpeg
  test "failed closing renders and forged duplicate revoked or approved requests keep playing bytes",
       %{conn: conn, w: w} do
    a = ending_fixture!(w, "TEST-ONLY-A.mp4", "magenta")
    ending_default!(w, a)
    {clip, old} = ending_clip!(w, a)
    ending_default!(w, a, "mute")
    child = open(conn, w.approver)
    child |> form("[data-role=use-closing-video]") |> render_submit()
    bay(child) |> render_click("use_closing_video", %{"base_render_id" => old.id})
    {:ok, jobs} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    assert Enum.count(jobs, &(&1.status == "queued")) == 1
    job = Enum.find(jobs, &(&1.status == "queued"))
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    {:ok, _} = ClipJobs.fail(w.scope, job.id, w.agent.id, "CLOSING_DOWNLOAD_FAILED", "safe")
    render(child)
    assert has_element?(child, "[data-role=closing-render-failure]")
    assert has_element?(child, "#clip-player-#{clip.id}-r#{old.rev}")
    w.profile |> Ecto.Changeset.change(approver_user_ids: []) |> Repo.update!()
    bay(child) |> render_click("use_closing_video", %{"base_render_id" => old.id})
    {:ok, revoked_jobs} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    assert length(revoked_jobs) == length(jobs)

    Repo.reload!(w.profile)
    |> Ecto.Changeset.change(approver_user_ids: [w.approver.id])
    |> Repo.update!()

    {:ok, _} =
      Social.approve_clip(
        w.org_id,
        clip.id,
        w.approver.id,
        %{"render_id" => old.id, "account_ids" => [w.ig.id]},
        now: DateTime.add(DateTime.utc_now(), 3600),
        publish_server: :closing_review_no_publisher
      )

    bay(child) |> render_click("use_closing_video", %{"base_render_id" => old.id})
    {:ok, final} = ClipJobs.list_jobs(w.org_id, w.profile.id)
    assert length(final) == length(jobs)
    assert Social.get_clip(w.org_id, clip.id).render_file_id == old.file_id
  end
end
