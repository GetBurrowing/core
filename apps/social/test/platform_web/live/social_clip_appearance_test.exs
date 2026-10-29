defmodule PlatformWeb.SocialClipAppearanceTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{ClipJob, ClipJobs, ClipVersions, Post}

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

  defp choose(child, style) do
    child |> element("[data-role='caption-style'][data-style='#{style}']") |> render_click()
  end

  defp preview(child, base) do
    child
    |> element("[data-role='caption-render-form']")
    |> render_submit(%{"base_render_id" => base})
  end

  defp job(w),
    do: Repo.one!(from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"))

  test "real styles bind immutable base, block stale approval, complete without losing history",
       %{conn: conn, w: w} do
    child = open(conn, w)

    refute has_element?(child, "[data-role='caption-dirty']")
    assert has_element?(child, "[data-role='caption-render'][disabled]")

    for style <- ~w(plain phrase-pop karaoke),
        do: assert(has_element?(child, "[data-style='#{style}']"))

    choose(child, "karaoke")
    assert has_element?(child, "[data-role='caption-dirty']")
    assert has_element?(child, "[data-role='clip-approve'][disabled]")
    preview(child, w.base.id)
    j = job(w)
    assert j.payload["appearance"] == true
    assert j.payload["base_render_id"] == w.base.id
    assert j.payload["candidate_id"] == "candidate-fixture"
    assert j.payload["expected_rev"] == 2
    assert j.payload["clip_overrides"]["mapped"]["captions.style"] == "karaoke"
    refute Map.has_key?(j.payload["clip_overrides"]["mapped"], "captions.preset")
    assert has_element?(child, "[data-role='caption-pending']")
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
    assert Repo.reload!(w.clip).rev == 1
    {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)
    file = stored_file!(w.project, "new #{unique()}", "new.mp4", "video/mp4")
    {:ok, %{clip: clip}} = ClipJobs.complete(w.scope, j.id, w.agent.id, %{file_id: file.id})
    render(child)
    assert has_element?(child, "video[src='/files/blob/#{file.id}']")
    assert has_element?(child, "[data-role='caption-applied']", "karaoke")
    refute has_element?(child, "[data-role='caption-dirty']")
    {:ok, [new, old]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert new.look["cap"]["style"] == "karaoke"
    assert old.id == w.base.id
    assert Platform.Files.get_file(old.file_id)
    assert Repo.aggregate(Post, :count) == 0
  end

  test "stale form, unsupported style and revoked human cannot enqueue", %{conn: conn, w: w} do
    child = open(conn, w)
    choose(child, "plain")
    preview(child, Ecto.UUID.generate())
    assert has_element?(child, "[data-role='caption-error']")

    assert Repo.aggregate(
             from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"),
             :count
           ) == 0

    assert {:error, {:invalid_look, _}} =
             ClipJobs.enqueue_appearance(w.org_id, w.clip.id, w.approver.id, %{
               base_render_id: w.base.id,
               look: %{cap: %{style: "imaginary"}}
             })

    assert {:error, :not_a_human} =
             ClipJobs.enqueue_appearance(w.org_id, w.clip.id, w.agent.id, %{
               base_render_id: w.base.id,
               look: %{cap: %{style: "plain"}}
             })

    {:ok, _} = Platform.Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})
    preview(child, w.base.id)

    assert Repo.aggregate(
             from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"),
             :count
           ) == 0

    assert Repo.reload!(w.clip).rev == 1
  end

  test "failed render keeps playback and exposes safe retry after reload", %{conn: conn, w: w} do
    child = open(conn, w)
    choose(child, "plain")
    preview(child, w.base.id)
    j = job(w)
    {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)

    {:ok, _} =
      ClipJobs.fail(
        w.scope,
        j.id,
        w.agent.id,
        "APPEARANCE_PROJECT_MISSING",
        "private transcript secret"
      )

    render(child)
    assert has_element?(child, "[data-role='caption-failure']", "original project or source")
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
    refute render(child) =~ "private transcript secret"
    choose(child, "plain")
    preview(child, w.base.id)

    assert Repo.aggregate(
             from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"),
             :count
           ) == 2
  end

  test "music picker, mute/gain draft, preview and completion keep exact immutable settings", %{
    conn: conn,
    w: w
  } do
    song =
      stored_file!(w.project, "RIFF0000WAVEunique #{unique()}", "Project song.wav", "audio/wav")

    child = open(conn, w)
    assert has_element?(child, "#clip-music-song option[value='#{song.id}']", "Project song.wav")
    refute has_element?(child, "[data-role='music-preview']")

    child
    |> element("[data-role='music-settings']")
    |> render_change(%{"file_id" => song.id, "gain_db" => "-27", "muted" => "false"})

    assert has_element?(child, "audio[data-role='music-preview'][src='/files/blob/#{song.id}']")
    assert has_element?(child, "[data-role='music-gain']", "-27")
    assert has_element?(child, "[data-role='clip-approve'][disabled]")

    child
    |> element("[data-role='music-settings']")
    |> render_change(%{"file_id" => song.id, "gain_db" => "-27", "muted" => "true"})

    assert has_element?(child, "#clip-music-gain[value='-27.0']")

    child
    |> element("[data-role='music-settings']")
    |> render_change(%{"file_id" => song.id, "gain_db" => "-27", "muted" => "false"})

    preview(child, w.base.id)
    j = job(w)
    assert j.payload["music"] == %{"file_id" => song.id, "enabled" => true, "level_db" => -27.0}
    assert j.payload["base_render_id"] == w.base.id
    assert has_element?(child, "video[src='/files/blob/#{w.file.id}']")
    {:ok, _} = ClipJobs.claim(w.scope, j.id, w.agent.id)
    file = stored_file!(w.project, "new music video #{unique()}", "music.mp4", "video/mp4")
    {:ok, _} = ClipJobs.complete(w.scope, j.id, w.agent.id, %{file_id: file.id})
    render(child)
    assert has_element?(child, "[data-role='music-applied']", "-27")
    refute has_element?(child, "[data-role='caption-dirty']")
    assert has_element?(child, "video[src='/files/blob/#{file.id}']")
  end

  test "empty audio, None and foreign selection never fabricate a song", %{conn: conn, w: w} do
    child = open(conn, w)
    assert has_element?(child, "[data-role='music-empty']")
    assert has_element?(child, "#clip-music-song option[value='']", "None")
    other = render_world!()

    foreign =
      stored_file!(
        other.project,
        "RIFF0000WAVEprivate #{unique()}",
        "Private song.wav",
        "audio/wav"
      )

    refute render(child) =~ foreign.id

    child
    |> element("[data-role='music-settings']")
    |> render_change(%{"file_id" => foreign.id, "gain_db" => "-18", "muted" => "false"})

    assert has_element?(child, "[data-role='caption-error']", "unavailable")
    refute render(child) =~ "Private song.wav"

    assert Repo.aggregate(
             from(j in ClipJob, where: j.clip_id == ^w.clip.id and j.kind == "rerender"),
             :count
           ) == 0
  end
end
