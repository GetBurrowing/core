defmodule PlatformWeb.SocialClosingVideoTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query
  alias Platform.{Repo, Social}
  alias Platform.Social.{ClipClosingVideo, ClipJobs, ClipJob, ClosingAsset, Profile}
  @moduletag :ffmpeg

  setup_all do
    path = Path.join(System.tmp_dir!(), "closing-ui-#{System.unique_integer([:positive])}.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-v error -f lavfi -i color=c=magenta:s=64x96:r=25:d=0.4 -c:v libx264 -pix_fmt yuv420p -y) ++
          [path]
      )

    bytes = File.read!(path)
    File.rm!(path)
    %{bytes: bytes}
  end

  setup c do
    w = render_world!()

    {:ok, %{file: file}} =
      ClipClosingVideo.upload(
        w.org_id,
        w.profile.id,
        w.approver.id,
        c.bytes,
        "TEST-ONLY-A.mp4",
        "video/mp4"
      )

    %{w: w, closing_file: file}
  end

  defp open(conn, w) do
    {:ok, v, _} =
      live(
        Plug.Test.init_test_session(conn, current_user_id: w.approver.id),
        "/m/social?tab=settings"
      )

    child = find_live_child(v, "ext-page-social")
    child |> element("[data-role=social-tab-button][data-tab=settings]") |> render_click()
    child
  end

  defp card(w), do: "#social-closing-video-#{w.profile.id}"

  defp pick(v, w, file) do
    v |> element("#{card(w)} button[phx-click=pick]") |> render_click()

    v
    |> element("#{card(w)} button[phx-click=choose][phx-value-id='#{file.id}']")
    |> render_click()
  end

  defp save(v, w), do: v |> form("#{card(w)}-form") |> render_submit()

  test "pick is staged; save, audio, off, remove retain asset and durable exclusion", c do
    v = open(c.conn, c.w)
    assert has_element?(v, card(c.w), "No closing video. Clips end where the highlight ends.")
    pick(v, c.w, c.closing_file)
    refute Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id
    save(v, c.w)

    assert Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id ==
             c.closing_file.id

    v |> form("#{card(c.w)}-form", closing: %{enabled: "false", audio: "keep"}) |> render_change()
    assert has_element?(v, card(c.w), "Saved but off: new clips won't use it")
    save(v, c.w)
    s = Social.get_profile(c.w.org_id, c.w.profile.id).closing_video
    assert s.audio == :keep and not s.enabled and s.file_id == c.closing_file.id
    v |> element("#{card(c.w)} button[phx-click=remove]") |> render_click()
    assert is_nil(Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id)
    assert Platform.Files.get_file(c.closing_file.id)
    assert Repo.exists?(from(a in ClosingAsset, where: a.file_id == ^c.closing_file.id))
  end

  test "revoked membership cannot save a staged choice", c do
    v = open(c.conn, c.w)
    pick(v, c.w, c.closing_file)

    Repo.get!(Profile, c.w.profile.id)
    |> Ecto.Changeset.change(approver_user_ids: [])
    |> Repo.update!()

    save(v, c.w)
    assert has_element?(v, card(c.w), "You no longer have access to this project")
    refute Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id
  end

  test "forged foreign picker identity is rejected without replacing saved settings", c do
    foreign = stored_file!(project!(c.w.other_org_id), c.bytes, "foreign.mp4", "video/mp4")
    v = open(c.conn, c.w)
    v |> element("#{card(c.w)} button[phx-click=pick]") |> render_click()

    v
    |> element("#{card(c.w)} button[phx-click=choose][phx-value-id='#{c.closing_file.id}']")
    |> render_click(%{"id" => foreign.id})

    assert has_element?(v, card(c.w), "That video is unavailable in this project.")
    refute Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id
  end

  test "fake video selection fails safely while retaining previous saved choice", c do
    {:ok, _} =
      ClipClosingVideo.save(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        file_id: c.closing_file.id,
        enabled: true
      })

    fake = stored_file!(c.w.project, "not a real video", "fake.mp4", "video/mp4")
    v = open(c.conn, c.w)
    pick(v, c.w, fake)
    save(v, c.w)
    assert has_element?(v, card(c.w), "That file isn't a video")
    assert has_element?(v, "#{card(c.w)} video[src='/files/blob/#{c.closing_file.id}']")
    refute has_element?(v, "#{card(c.w)} video[src='/files/blob/#{fake.id}']")

    assert Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id ==
             c.closing_file.id
  end

  test "upload is finalized and registered even before save and after picker cancel", c do
    v = open(c.conn, c.w)
    v |> element("#{card(c.w)} button[phx-click=pick]") |> render_click()

    upload =
      file_input(v, "#{card(c.w)}-upload", :closing_video, [
        %{name: "TEST-ONLY-upload.mp4", content: c.bytes, type: "video/mp4"}
      ])

    render_upload(upload, "TEST-ONLY-upload.mp4")
    assert has_element?(v, "#{card(c.w)} button[type=submit]", "Save"), render(v)
    refute Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id
    assert Repo.exists?(from(a in ClosingAsset, where: a.profile_id == ^c.w.profile.id))
  end

  test "deleted saved asset has safe unavailable text and no broken player", c do
    {:ok, _} =
      ClipClosingVideo.save(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        file_id: c.closing_file.id,
        enabled: true
      })

    {:ok, _} = Platform.Files.delete_file(c.w.approver, c.closing_file)
    v = open(c.conn, c.w)

    assert has_element?(
             v,
             card(c.w),
             "The saved closing video is unavailable. Replace or remove it."
           )

    refute has_element?(v, "#{card(c.w)} video")

    assert Social.get_profile(c.w.org_id, c.w.profile.id).closing_video.file_id ==
             c.closing_file.id
  end

  test "connected platform warning counts content plus saved closing duration", c do
    {:ok, %{job: j}} =
      ClipJobs.enqueue_new_clip(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        source_url: "https://example.com/long-episode",
        in_s: 0,
        out_s: 140
      })

    {:ok, _} = ClipJobs.claim(c.w.scope, j.id, c.w.agent.id)

    output =
      stored_file!(c.w.project, "metadata-only warning fixture", "long-fixture.mp4", "video/mp4")

    {:ok, _} =
      ClipJobs.complete(c.w.scope, j.id, c.w.agent.id, %{
        file_id: output.id,
        actual_in_s: 0,
        actual_out_s: 140,
        duration_s: 140,
        candidate_id: "long-candidate"
      })

    Repo.update_all(from(a in Platform.Social.Account, where: a.id == ^c.w.x.id),
      set: [status: "connected"]
    )

    {:ok, _} =
      ClipClosingVideo.save(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        file_id: c.closing_file.id,
        enabled: true
      })

    v = open(c.conn, c.w)
    assert has_element?(v, "#{card(c.w)} .text-warning", "X videos must be at most 140 seconds")
    assert has_element?(v, "#{card(c.w)} .text-warning", "140.4")
  end

  test "preview creates a pinned pending rerender and preserves playing version", c do
    {:ok, %{job: j}} =
      ClipJobs.enqueue_new_clip(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        source_url: "https://example.com/episode",
        in_s: 0,
        out_s: 5
      })

    {:ok, _} = ClipJobs.claim(c.w.scope, j.id, c.w.agent.id)
    output = stored_file!(c.w.project, "render fixture", "before.mp4", "video/mp4")

    {:ok, %{clip: clip}} =
      ClipJobs.complete(c.w.scope, j.id, c.w.agent.id, %{
        file_id: output.id,
        candidate_id: "candidate-fixture",
        actual_in_s: 0,
        actual_out_s: 5
      })

    {:ok, _} =
      ClipClosingVideo.save(c.w.org_id, c.w.profile.id, c.w.approver.id, %{
        file_id: c.closing_file.id,
        enabled: true,
        audio: "keep"
      })

    v = open(c.conn, c.w)
    v |> element("#{card(c.w)} button[phx-click=preview]") |> render_click()
    assert has_element?(v, "[data-role=closing-preview-pending]")
    pending = Repo.one!(from(j in ClipJob, where: j.clip_id == ^clip.id and j.status == "queued"))
    assert pending.payload["closing_video"]["file_id"] == c.closing_file.id
    assert pending.payload["closing_video"]["audio"] == "keep"
    assert Social.get_clip(c.w.org_id, clip.id).render_file_id == output.id
    assert Social.get_clip(c.w.org_id, clip.id).review_status == "pending"
    # A reconnect restores the existing pending job, never queues a duplicate.
    reconnected = open(c.conn, c.w)
    assert has_element?(reconnected, "[data-role=closing-preview-pending]")
    {:ok, _} = ClipJobs.claim(c.w.scope, pending.id, c.w.agent.id)

    {:ok, _} =
      ClipJobs.fail(c.w.scope, pending.id, c.w.agent.id, "fixture failure", "unsupported_outro")

    Phoenix.LiveView.send_update(reconnected.pid, PlatformWeb.SocialClosingVideo,
      id: "social-closing-video-#{c.w.profile.id}",
      tick: true
    )

    assert render(reconnected) =~
             "The preview could not render. Your playing version is unchanged."

    assert Social.get_clip(c.w.org_id, clip.id).render_file_id == output.id
  end
end
