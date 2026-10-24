defmodule Platform.Social.FilesAccessTest do
  @moduledoc """
  Where a render lands and who can read it (Social 5/7): the MP4 is a Files
  row under the PROFILE's project; the profile's approver (a member of the
  org) gets it from `GET /files/blob/:id`, a user in another org does not;
  and a profile whose project is nil, or not in the profile's org, is
  refused BEFORE anything is queued (Files lets every logged-in user read an
  org-less project's blobs, and another org's members read its project's).

  `Platform.Access` is not on main at this stage's execution, so the read
  goes through `PlatformWeb.FileBlobController` as it is.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.SocialFixtures
  require Ecto.Query

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, Profile}
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

  test "the render is stored under the profile's project; approver 200, outsider refused",
       %{conn: conn} = world do
    clip = rendered!(world)
    file = Platform.Files.get_file(clip.render_file_id)
    assert file.project_id == world.profile.project_id
    assert file.content_type == "video/mp4"
    assert file.ingest_intent == "human_only"
    assert file.byte_size == clip.byte_size

    ok =
      conn
      |> init_test_session(current_user_id: world.approver.id)
      |> get("/files/blob/#{file.id}")

    assert ok.status == 200
    assert ok.resp_body =~ "fake mp4"

    denied =
      build_conn()
      |> init_test_session(current_user_id: world.outsider.id)
      |> get("/files/blob/#{file.id}")

    assert denied.status in [403, 404]
    refute denied.resp_body =~ "fake mp4"
  end

  test "a profile with no project is refused before enqueue", world do
    clip = file_clip!(world, 4.0, 12.0)

    Repo.update_all(Ecto.Query.where(Profile, [p], p.id == ^world.profile.id),
      set: [project_id: nil]
    )

    assert {:error, :profile_needs_project} = Social.render_clip(world.scope, clip.id)
    assert Repo.get!(Clip, clip.id).status == "candidate"
    assert Fake.calls() == []
  end

  # projects.org_id is NOT NULL on this branch, so FileBlobController's
  # org-less branch cannot be reached with a real row; the live hazard is a
  # profile pointed (behind the context's back) at ANOTHER org's project.
  test "a profile whose project is in another org is refused before enqueue", world do
    clip = file_clip!(world, 4.0, 12.0)
    foreign = project!(world.other_org_id)

    Repo.update_all(Ecto.Query.where(Profile, [p], p.id == ^world.profile.id),
      set: [project_id: foreign.id]
    )

    assert {:error, :profile_needs_project} = Social.render_clip(world.scope, clip.id)

    assert {:error, %{code: :profile_needs_project, error: msg}} =
             Platform.Federation.ToolArguments.dispatch(
               "social_clip_render",
               %{"clip_id" => clip.id},
               %{agent_id: world.agent.id}
             )

    assert msg == Social.profile_needs_project()
    assert Repo.get!(Clip, clip.id).status == "candidate"
  end
end
