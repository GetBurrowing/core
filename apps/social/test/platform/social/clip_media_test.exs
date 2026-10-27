defmodule Platform.Social.ClipMediaTest do
  @moduledoc """
  A rendered clip attached to a draft (Social 5/7): the draft's
  `media_meta` gets the clip's duration and dimensions, so member 2's
  MediaRules can judge it at publish: TikTok passes, a 150s clip is refused
  for X.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, ClipMedia, MediaRules, Post}
  alias Platform.Social.Renderer.Fake

  setup do
    Fake.reset()
    world = render_world!()
    Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(world.profile.id))
    world
  end

  defp rendered!(world) do
    clip = file_clip!(world, 4.0, 12.0)
    {:ok, _} = Social.render_clip(world.scope, clip.id)
    id = clip.id
    assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"} = clip}, 5_000
    clip
  end

  defp item(file, meta),
    do: %{
      content_type: file.content_type,
      byte_size: file.byte_size,
      duration_s: meta["duration_s"],
      width: meta["width"],
      height: meta["height"]
    }

  test "social_draft_create with the render fills media_meta; TikTok's rules then pass", world do
    clip = rendered!(world)

    assert {:ok, %{posts: [post]}} =
             ToolArguments.dispatch(
               "social_draft_create",
               %{
                 "profile_id" => world.profile.id,
                 "account_ids" => [world.tiktok.id],
                 "body" => "watch this",
                 "media_file_ids" => [clip.render_file_id]
               },
               %{agent_id: world.agent.id}
             )

    row = Repo.get!(Post, post.id)
    assert row.status == "needs_approval"

    assert row.media_meta == %{
             clip.render_file_id => %{
               "duration_s" => clip.duration_s,
               "width" => 1080,
               "height" => 1920
             }
           }

    file = Platform.Files.get_file(clip.render_file_id)
    meta = row.media_meta[clip.render_file_id]
    assert :ok = MediaRules.check("tiktok", world.tiktok, [item(file, meta)])
  end

  test "historical file metadata stays bound to its snapshot after a newer render", world do
    old = rendered!(world)
    file = stored_file!(world.project, "new bytes", "new.mp4", "video/mp4")

    {:ok, current} =
      Repo.transaction(fn ->
        Platform.Social.ClipVersions.append!(
          old.id,
          file,
          %{duration_s: 17.0, width: 720, height: 1280},
          %{headline: "Alternate", caption: "New caption", completion_key: "media-v2"}
        )
      end)

    Repo.update!(Ecto.Changeset.change(current, duration_s: 99.0))

    assert ClipMedia.meta_for(world.profile.id, [old.render_file_id, file.id]) == %{
             old.render_file_id => %{"duration_s" => 10.0, "width" => 1080, "height" => 1920},
             file.id => %{"duration_s" => 17.0, "width" => 720, "height" => 1280}
           }

    other = render_world!()
    assert ClipMedia.meta_for(other.profile.id, [old.render_file_id]) == %{}
  end

  test "a 150s clip is refused for X by MediaRules from media_meta", world do
    clip = rendered!(world)

    Repo.update_all(Ecto.Query.where(Platform.Social.ClipRender, [r], r.clip_id == ^clip.id),
      set: [duration_s: 150.0]
    )

    {:ok, post} =
      Social.create_post(world.org_id, world.x, %{
        body: "long one",
        media_file_ids: [clip.render_file_id],
        status: "needs_approval"
      })

    meta = post.media_meta[clip.render_file_id]
    assert meta["duration_s"] == 150.0
    file = Platform.Files.get_file(clip.render_file_id)

    assert {:error, ["X videos must be at most 140 seconds; this one is 150.0 seconds"]} =
             MediaRules.check("x", world.x, [item(file, meta)])
  end

  test "update paths merge too, and keep facts already there", world do
    clip = rendered!(world)

    {:ok, post} =
      Social.create_post(world.org_id, world.tiktok, %{
        body: "x",
        status: "draft",
        media_meta: %{"other" => %{"duration_s" => 1.0}}
      })

    {:ok, post} = Social.update_post(world.org_id, post, %{media_file_ids: [clip.render_file_id]})
    assert Map.keys(post.media_meta) |> Enum.sort() == Enum.sort(["other", clip.render_file_id])

    {:ok, draft} =
      Platform.Social.AgentDrafts.update_agent_draft(world.scope, post.id, %{
        "media_file_ids" => [clip.render_file_id]
      })

    assert draft.media_meta[clip.render_file_id]["width"] == 1080
  end

  test "meta_for/2 answers only for rendered clips of that profile", world do
    clip = rendered!(world)
    other = render_world!()

    assert Map.keys(ClipMedia.meta_for(world.profile.id, [clip.render_file_id, "junk"])) == [
             clip.render_file_id
           ]

    assert ClipMedia.meta_for(other.profile.id, [clip.render_file_id]) == %{}
    assert ClipMedia.meta_for(world.profile.id, [world.video.id]) == %{}
  end
end
