defmodule PlatformWeb.SocialProfileDeepLinkTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.Ideas
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()

    {:ok, second} =
      Social.create_profile(ctx.org_id, %{
        name: "ZZZ Second profile",
        space_id: ctx.space.id,
        approver_user_ids: [ctx.h1.id],
        provider_profile_ref: "vendor_profile_second"
      })

    {:ok, second_account} = Social.create_account(ctx.org_id, second, %{platform: "youtube"})

    {:ok, first_idea} =
      Ideas.create(ctx.org_id, ctx.profile.id, %{title: "First profile idea"}, {:user, ctx.h1.id})

    {:ok, second_idea} =
      Ideas.create(ctx.org_id, second.id, %{title: "Second profile idea"}, {:user, ctx.h1.id})

    {first_post, _} = pending_post!(ctx, ctx.a, %{body: "First profile post"})
    {second_post, _} = pending_post!(ctx, second_account, %{body: "Second profile post"})

    Map.merge(ctx, %{
      second: second,
      first_idea: first_idea,
      second_idea: second_idea,
      first_post: first_post,
      second_post: second_post
    })
  end

  defp open(conn, user, path) do
    {:ok, parent, _} = conn |> Plug.Test.init_test_session(current_user_id: user.id) |> live(path)
    find_live_child(parent, "ext-page-social")
  end

  test "Ideas deep link to second visible profile excludes the first profile",
       %{conn: conn} = c do
    view = open(conn, c.h1, "/m/social?tab=ideas&profile=#{c.second.id}")
    assert has_element?(view, "#idea-card-#{c.second_idea.id}")
    refute has_element?(view, "#idea-card-#{c.first_idea.id}")
  end

  test "Queue deep link to second visible profile excludes the first profile",
       %{conn: conn} = c do
    view = open(conn, c.h1, "/m/social?tab=queue&profile=#{c.second.id}")
    assert has_element?(view, "#queue-card-idea-#{c.second_post.id}")
    refute has_element?(view, "#queue-card-idea-#{c.first_post.id}")
  end

  test "Connections deep link only shows the selected profile's accounts", %{conn: conn} = c do
    view = open(conn, c.h1, "/m/social?tab=connections&profile=#{c.second.id}")
    assert has_element?(view, "#accounts-#{c.second_post.account_id}")
    refute has_element?(view, "#accounts-#{c.a.id}")
  end

  test "Calendar deep link only shows the selected profile's scheduled posts",
       %{conn: conn} = c do
    now = DateTime.utc_now()

    for post <- [c.first_post, c.second_post] do
      post
      |> Ecto.Changeset.change(
        status: "scheduled",
        scheduled_at: now,
        approved_by_user_id: c.h1.id,
        approved_at: now
      )
      |> Platform.Repo.update!()
    end

    view = open(conn, c.h1, "/m/social?tab=calendar&profile=#{c.second.id}")

    assert has_element?(
             view,
             "[data-role='social-calendar-item'][data-post-id='#{c.second_post.id}']"
           )

    refute has_element?(
             view,
             "[data-role='social-calendar-item'][data-post-id='#{c.first_post.id}']"
           )
  end

  test "first profile, picker changes, and invalid profile links keep their scope",
       %{conn: conn} = c do
    view = open(conn, c.h1, "/m/social?tab=ideas&profile=#{c.profile.id}")
    assert has_element?(view, "#idea-card-#{c.first_idea.id}")
    refute has_element?(view, "#idea-card-#{c.second_idea.id}")
    view |> form("#social-profile-switcher", %{profile_id: c.second.id}) |> render_change()
    assert has_element?(view, "#idea-card-#{c.second_idea.id}")
    refute has_element?(view, "#idea-card-#{c.first_idea.id}")

    invalid = open(conn, c.h1, "/m/social?tab=ideas&profile=not-a-profile")
    assert has_element?(invalid, "#idea-card-#{c.first_idea.id}")
    refute has_element?(invalid, "#idea-card-#{c.second_idea.id}")
  end

  test "a hidden profile id in the query does not select it", %{conn: conn} = c do
    {:ok, hidden} = Social.create_profile(org_id!(), %{name: "Hidden profile"})

    {:ok, secret} =
      Ideas.create(hidden.org_id, hidden.id, %{title: "Hidden idea"}, {:user, c.h1.id})

    view = open(conn, c.h1, "/m/social?tab=ideas&profile=#{hidden.id}")
    assert has_element?(view, "#idea-card-#{c.first_idea.id}")
    refute has_element?(view, "#idea-card-#{secret.id}")
    refute has_element?(view, "#idea-card-#{c.second_idea.id}")
  end

  test "an OAuth error return for the second profile does not mix Ideas", %{conn: conn} = c do
    view = open(conn, c.h1, "/m/social?error=denied&profileId=vendor_profile_second&tab=ideas")
    assert has_element?(view, "#idea-card-#{c.second_idea.id}")
    refute has_element?(view, "#idea-card-#{c.first_idea.id}")
  end

  test "an explicit profile wins after a return for another visible profile", %{conn: conn} = c do
    view =
      open(
        conn,
        c.h1,
        "/m/social?error=denied&profileId=vendor_profile_second&profile=#{c.profile.id}&tab=ideas"
      )

    assert has_element?(view, "#idea-card-#{c.first_idea.id}")
    refute has_element?(view, "#idea-card-#{c.second_idea.id}")
  end
end
