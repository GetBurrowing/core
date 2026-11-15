defmodule Platform.Social.StudioDeleteClipsTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, ClipRender, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  test "a profile holding only a Studio clip is refused; the clip and its render survive", %{w: w} do
    clip = w |> pending_clip!() |> make_studio_clip!()
    render_id = render_id!(clip)

    assert {:error, :has_studio_clips} = Social.delete_profile(w.org_id, w.profile)

    assert Social.get_profile(w.org_id, w.profile.id)
    assert Repo.get(Clip, clip.id)
    assert Repo.get(ClipRender, render_id)
  end

  test "a profile with a Studio post and a Studio clip reports the post first", %{w: w} do
    {:ok, _post} =
      Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "p", status: "draft"})

    clip = w |> pending_clip!() |> make_studio_clip!()

    assert {:error, :has_studio_posts} = Social.delete_profile(w.org_id, w.profile)
    assert Repo.get(Clip, clip.id)
  end

  test "a profile with only legacy clips still deletes", %{w: w} do
    clip = pending_clip!(w)
    render_id = render_id!(clip)

    assert {:ok, _} = Social.delete_profile(w.org_id, w.profile)
    refute Repo.get(Clip, clip.id)
    refute Repo.get(ClipRender, render_id)
  end
end
