defmodule Platform.Social.RenderFailuresTest do
  @moduledoc """
  Every render failure ends the clip `failed` with a plain-English error,
  no Files row and nothing left in `rendering`, and the queue keeps
  serving (Social 5/7): over a platform's length limit (decided BEFORE the
  renderer is called), a renderer error, a missing ffmpeg with the real
  renderer selected, a source file gone from Files.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, RenderQueue}
  alias Platform.Social.Renderer.Fake

  setup do
    Fake.reset()
    saved = Enum.map([:renderer, :ffmpeg_path], &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:social, k)
        {k, v} -> Application.put_env(:social, k, v)
      end)
    end)

    :ok
  end

  defp render_and_wait(world, clip, opts \\ []) do
    Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(world.profile.id))
    {:ok, _} = Social.render_clip(world.scope, clip.id, opts)
    id = clip.id

    assert_receive {:social_clip, %Clip{id: ^id, status: status} = clip}
                   when status in ["rendered", "failed"],
                   5_000

    clip
  end

  defp files_in(project),
    do:
      Repo.aggregate(
        Ecto.Query.where(Platform.Files.File, [f], f.project_id == ^project.id),
        :count
      )

  test "a 150s clip for X fails on the length limit before any render runs" do
    world = render_world!(vtt: long_vtt_fixture(45))
    before = files_in(world.project)
    clip = file_clip!(world, 0.0, 150.0)

    failed = render_and_wait(world, clip)
    assert failed.status == "failed"
    assert failed.error =~ "X videos must be at most 140 seconds"
    # snapped 0.0-148.0 (the nearer sentence end), plus the 2s end card
    assert failed.error =~ "this one is 150.0 seconds"
    assert Fake.calls() == []
    assert failed.render_file_id == nil
    assert files_in(world.project) == before
  end

  test "an Instagram account of unknown type (nil) is not refused a Reel at render; personal is" do
    world = render_world!()

    {:ok, insta} =
      Social.create_account(world.org_id, world.profile, %{
        platform: "instagram",
        handle: "@show",
        platform_account_type: nil
      })

    {:ok, _youtube} =
      Social.create_account(world.org_id, world.profile, %{platform: "youtube", handle: "@show"})

    platforms = ["instagram", "youtube"]

    ok = render_and_wait(world, file_clip!(world, 4.0, 12.0), platforms: platforms)
    assert {ok.status, ok.error} == {"rendered", nil}

    insta |> Ecto.Changeset.change(platform_account_type: "personal") |> Repo.update!()

    refused = render_and_wait(world, file_clip!(world, 4.0, 12.0), platforms: platforms)
    assert refused.status == "failed"
    assert refused.error =~ "Instagram Reels need a Business or Creator account"
  end

  test "a renderer error is the clip's error; the queue serves the next one" do
    world = render_world!()
    queue = Process.whereis(RenderQueue)
    Fake.fail_next("the renderer could not read the source")

    failed = render_and_wait(world, file_clip!(world, 4.0, 12.0))
    assert {failed.status, failed.error} == {"failed", "the renderer could not read the source"}

    ok = render_and_wait(world, file_clip!(world, 4.0, 12.0))
    assert ok.status == "rendered"
    assert Process.whereis(RenderQueue) == queue
  end

  test "the real renderer with no ffmpeg fails readably, no Files row" do
    Application.put_env(:social, :renderer, Platform.Social.Renderer.Ffmpeg)
    Application.put_env(:social, :ffmpeg_path, "/nonexistent/ffmpeg")
    world = render_world!()
    before = files_in(world.project)

    failed = render_and_wait(world, file_clip!(world, 4.0, 12.0))
    assert {failed.status, failed.error} == {"failed", "ffmpeg not found on this node"}
    assert files_in(world.project) == before
  end

  test "a source video deleted from Files fails readably" do
    world = render_world!()
    clip = file_clip!(world, 4.0, 12.0)
    {:ok, _} = Platform.Files.delete_file(%{id: world.approver.id}, world.video)

    failed = render_and_wait(world, clip)
    assert failed.status == "failed"
    assert failed.error == "the source video no longer exists in Files"
  end

  test "a range that cannot snap inside the transcript fails readably" do
    world = render_world!()
    # 2s requested: under the 5s minimum
    clip = file_clip!(world, 4.0, 6.0)
    failed = render_and_wait(world, clip)
    assert failed.status == "failed"
    assert failed.error =~ "cannot be snapped to the transcript"
  end
end
