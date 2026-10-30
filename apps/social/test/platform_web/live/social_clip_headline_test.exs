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
    assert has_element?(child, "[data-role='clip-headline-failure']", "HEADLINE_UNBACKED")
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
    |> with_target("#headline-#{w.clip.id}")
    |> render_click("submit", %{"base_render_id" => w.base.id, "headline" => "Denied"})

    assert Repo.aggregate(from(j in ClipJob, where: j.kind == "rerender"), :count) == 0
  end

  test "each treatment submits exact source-bound text, independent emphasis and unchanged captions",
       %{conn: conn, w: w} do
    for template <- ~w(chrome-hook neon-broadcast arcade-punch) do
      child = open(conn, w)

      child
      |> element("[data-role=clip-headline-form]")
      |> render_submit(%{
        "headline" => "The team celebrated",
        "template" => template,
        "seconds" => "3.5",
        "emphasis" => "2, 3"
      })

      job = Repo.one!(from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.status == "queued"))
      assert job.payload["headline_template"]["template"] == template
      assert job.payload["headline_template"]["emphasis"] == [1, 2]
      assert job.payload["headline_template"]["emphasis_text"] == "The team celebrated"

      assert job.payload["headline_template"]["timing"] == %{
               "entrance_s" => 0.2,
               "hold_s" => 3.05,
               "exit_s" => 0.25,
               "total_s" => 3.5
             }

      assert job.payload["headline"]["requested_headline"] == "The team celebrated"
      assert job.payload["base_render_id"] == w.base.id
      assert job.payload["candidate_id"] == "candidate-fixture"
      assert job.payload["episode"] == w.base.source
      assert job.payload["look"]["cap"] == w.base.look["cap"]
      assert Repo.reload!(w.clip).rev == 1
      assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
      {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

      {:ok, _} =
        ClipJobs.fail(w.scope, job.id, w.agent.id, "fixture", "HEADLINE_TEMPLATE_CLI_UNSUPPORTED")
    end

    assert Repo.aggregate(Post, :count) == 0
  end

  test "word edits clear emphasis visibly and forged out-of-range duplicates or timing cannot enqueue",
       %{conn: conn, w: w} do
    child = open(conn, w)
    form = element(child, "[data-role=clip-headline-form]")

    render_change(form, %{
      "headline" => "The team celebrated",
      "template" => "chrome-hook",
      "seconds" => "3.0",
      "emphasis" => ""
    })

    render_change(form, %{
      "headline" => "The team celebrated",
      "template" => "chrome-hook",
      "seconds" => "3.0",
      "emphasis" => "2"
    })

    render_change(form, %{
      "headline" => "The app shipped",
      "template" => "chrome-hook",
      "seconds" => "3.0",
      "emphasis" => "2"
    })

    assert has_element?(child, "[data-role=headline-emphasis][value='']")
    assert has_element?(child, "[data-role=headline-notice]", "Emphasis cleared")

    for {seconds, emphasis} <- [
          {"0.5", ""},
          {"7", ""},
          {"3.0", "8"},
          {"3.0", "2,2"},
          {"3.0", "0"}
        ] do
      render_submit(form, %{
        "headline" => "The app shipped",
        "template" => "chrome-hook",
        "seconds" => seconds,
        "emphasis" => emphasis
      })

      assert has_element?(child, "[data-role=clip-headline-error]", "unique word numbers")
    end

    assert Repo.aggregate(from(j in ClipJob, where: j.kind == "rerender"), :count) == 0
  end

  test "show defaults save and reset only headline settings; old snapshots and caption selections remain",
       %{conn: conn, w: w} do
    {:ok, _} =
      ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
        "cap" => %{"style" => "karaoke"},
        "title" => %{"font" => "Anton"}
      })

    child = open(conn, w)

    child
    |> element("[data-role=clip-headline-form]")
    |> render_change(%{
      "headline" => "The team celebrated",
      "template" => "chrome-hook",
      "seconds" => "4.0",
      "emphasis" => "2"
    })

    child |> element("[data-role=headline-default-save]") |> render_click()
    saved = Platform.Social.get_profile(w.org_id, w.profile.id).show_look

    assert saved["title"] == %{
             "template" => "chrome-hook",
             "secs" => 4.0,
             "enabled" => true,
             "font" => "Anton"
           }

    assert saved["cap"] == %{"style" => "karaoke"}
    assert has_element?(child, "[data-role=headline-notice]", "Existing videos are unchanged")
    child |> element("[data-role=headline-default-use]") |> render_click()
    assert has_element?(child, "option[value=chrome-hook][selected]")
    assert has_element?(child, "[data-role=headline-emphasis][value='']")
    child |> element("[data-role=headline-default-reset]") |> render_click()
    reset = Platform.Social.get_profile(w.org_id, w.profile.id).show_look
    assert reset == %{"cap" => %{"style" => "karaoke"}, "title" => %{"font" => "Anton"}}
    assert Repo.reload!(w.base).look == w.base.look
    assert Repo.reload!(w.clip).rev == 1
    assert Repo.aggregate(from(j in ClipJob, where: j.kind == "rerender"), :count) == 0
  end

  test "no opening headline is a real appearance job and cannot disable automatic show generation",
       %{conn: conn, w: w} do
    child = open(conn, w)

    child
    |> element("[data-role=clip-headline-form]")
    |> render_change(%{
      "headline" => "",
      "template" => "disabled",
      "seconds" => "3.0",
      "emphasis" => ""
    })

    child |> element("[data-role=headline-default-save]") |> render_click()
    assert has_element?(child, "[data-role=clip-headline-error]", "this clip only")

    child
    |> element("[data-role=clip-headline-form]")
    |> render_submit(%{"headline" => "", "template" => "disabled", "seconds" => "3.0"})

    job = attempt(w)
    assert job.payload["appearance"]
    assert job.payload["look"]["title"]["enabled"] == false
    assert job.payload["clip_overrides"]["mapped"]["captions.hook_title"] == false
    assert is_nil(job.payload["headline_template"])
    refute job.payload["headline"]
    assert has_element?(child, "[data-role=clip-headline-render][disabled]")
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
  end

  test "renderer capability and fit failures show actionable safe codes while keeping player and captions",
       %{conn: conn, w: w} do
    for {code, copy} <- [
          {"HEADLINE_TEMPLATE_CLI_UNSUPPORTED", "qualified renderer"},
          {"HEADLINE_LAYOUT_SHORTEN_TEXT", "Shorten it"},
          {"APPEARANCE_PROJECT_MISSING", "original project"},
          {"HEADLINE_TIMING_EXCEEDS_CLIP", "opening duration"}
        ] do
      child = open(conn, w)

      child
      |> element("[data-role=clip-headline-form]")
      |> render_submit(%{
        "headline" => "The team celebrated",
        "template" => "chrome-hook",
        "seconds" => "3.0"
      })

      job = Repo.one!(from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.status == "queued"))
      {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

      {:ok, _} =
        ClipJobs.fail(
          w.scope,
          job.id,
          w.agent.id,
          "SECRET private transcript https://signed.invalid/?token=secret",
          code
        )

      child = open(conn, w)
      assert has_element?(child, "[data-role=clip-headline-failure]", copy)
      refute render(child) =~ "SECRET"
      refute render(child) =~ "signed.invalid"
      assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
      assert has_element?(child, "[data-role=caption-style]")
    end
  end

  test "render details report applied snapshot timing rather than the current selection", %{
    conn: conn,
    w: w
  } do
    child = open(conn, w)

    child
    |> element("[data-role=clip-headline-form]")
    |> render_submit(%{
      "headline" => "The team celebrated",
      "template" => "chrome-hook",
      "seconds" => "3.5"
    })

    job = attempt(w)
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    file = stored_file!(w.project, "applied branded render #{unique()}", "v2.mp4", "video/mp4")
    hash = String.duplicate("b", 64)

    receipt =
      job.payload["headline_template"]
      |> Map.drop(["emphasis_text"])
      |> Map.merge(%{
        "content" => %{"artifact" => "sha256:" <> hash, "sha256" => hash},
        "output_sha256" => file.content_hash
      })

    {:ok, _} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: file.id,
        headline_applied: true,
        headline_render: receipt
      })

    child = open(conn, w)
    assert has_element?(child, "[data-role=headline-render-details]", "Template: chrome-hook")
    assert has_element?(child, "[data-role=headline-render-details]", "entrance_s: 0.2 s")
    assert has_element?(child, "[data-role=headline-render-details]", "hold_s: 3.05 s")
    assert has_element?(child, "[data-role=headline-render-details]", "exit_s: 0.25 s")

    child
    |> element("[data-role=clip-headline-form]")
    |> render_change(%{
      "headline" => "The team celebrated",
      "template" => "neon-broadcast",
      "seconds" => "4.0",
      "emphasis" => ""
    })

    assert has_element?(child, "[data-role=headline-render-details]", "Template: chrome-hook")
    refute has_element?(child, "[data-role=headline-render-details]", "Template: neon-broadcast")
    assert has_element?(child, "video[src='/files/blob/#{file.id}']")
  end

  test "revoked approver cannot save defaults and orphan source cannot reprocess delivered video",
       %{conn: conn, w: w} do
    Repo.update_all(from(r in Platform.Social.ClipRender, where: r.id == ^w.base.id),
      set: [source: %{}]
    )

    child = open(conn, w)
    submit(child, w, "The team celebrated")
    assert has_element?(child, "[data-role=clip-headline-error]", "original source mapping")

    Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id),
      set: [approver_user_ids: []]
    )

    child |> element("[data-role=headline-default-save]") |> render_click()
    assert Platform.Social.get_profile(w.org_id, w.profile.id).show_look == %{}

    assert Repo.aggregate(
             from(j in ClipJob, where: j.kind in ["rerender", "save_default"]),
             :count
           ) == 0
  end
end
