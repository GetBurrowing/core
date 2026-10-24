defmodule PlatformWeb.SocialTabsTest do
  @moduledoc """
  Social authoring 1/11: the tab registry, the All brands scope, the top
  bar's waiting count and health dot, and the cross-profile reads behind
  them. `async: false`: needs_approval writes post approval cards through
  core's chat.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Social

  alias PlatformWeb.{
    SocialIdeasTab,
    SocialQueueTab,
    SocialResultsTab,
    SocialTabs
  }

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp open(conn, user, query \\ "") do
    {:ok, view, _html} = live(login(conn, user), "/m/social" <> query)
    find_live_child(view, "ext-page-social")
  end

  defp profile!(org_id, name, account_attrs) do
    {:ok, profile} = Social.create_profile(org_id, %{name: name, space_id: channel!(org_id).id})

    {:ok, account} =
      Social.create_account(
        org_id,
        profile,
        Map.merge(%{platform: "linkedin", handle: "@#{name}"}, account_attrs)
      )

    {profile, account}
  end

  defp connected, do: %{status: "connected", provider_account_ref: "acc_#{unique()}"}

  defp needs_approval!(org_id, account, body) do
    {:ok, post} = Social.create_post(org_id, account, %{body: body, status: "needs_approval"})
    post
  end

  defp all_brands(child),
    do: child |> form("#social-profile-switcher", %{profile_id: "all"}) |> render_change()

  setup do
    org_a = org_id!()
    org_b = org_id!()
    j = member!(user!(), org_a)
    {alpha, alpha_account} = profile!(org_a, "Alpha", connected())
    {beta, beta_account} = profile!(org_a, "Beta", connected())
    {gamma, gamma_account} = profile!(org_b, "Gamma", connected())

    %{
      org_a: org_a,
      org_b: org_b,
      j: j,
      alpha: alpha,
      beta: beta,
      gamma: gamma,
      alpha_post: needs_approval!(org_a, alpha_account, "alpha body"),
      beta_post: needs_approval!(org_a, beta_account, "beta body"),
      gamma_post: needs_approval!(org_b, gamma_account, "gamma body")
    }
  end

  describe "the registry" do
    test "lists the tabs in order and keeps out every module whose enabled?/0 is false" do
      assert Enum.map(SocialTabs.registry(), & &1.key) ==
               ~w(queue ideas calendar clips results connections settings)

      refute SocialIdeasTab.enabled?()
      refute SocialResultsTab.enabled?()
      refute PlatformWeb.SocialComposer.enabled?()

      assert Enum.map(SocialTabs.tabs(), & &1.key) ==
               ~w(queue calendar clips connections settings)

      queue = %{key: "queue", label: "Queue", module: SocialQueueTab}
      ideas = %{key: "ideas", label: "Ideas", module: SocialIdeasTab}
      assert SocialTabs.tabs([ideas, queue]) == [queue]
    end

    test "a disabled tab adds no button, no data-tab, no pane and no New idea button",
         %{conn: conn, j: j} do
      child = open(conn, j)

      for key <- ~w(queue calendar clips connections settings) do
        assert has_element?(child, "[data-role='social-tab-button'][data-tab='#{key}']")
        assert has_element?(child, "[data-pane='#{key}']")
      end

      for key <- ~w(ideas results) do
        refute has_element?(child, "[data-tab='#{key}']")
        refute has_element?(child, "[data-pane='#{key}']")
      end

      refute has_element?(child, "[data-role='social-new-idea']")
    end

    test "a disabled tab's key is ignored by select_tab and by ?tab=", %{conn: conn, j: j} do
      child = open(conn, j, "?tab=ideas")
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='queue']")

      render_click(child, "select_tab", %{"tab" => "results"})
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='queue']")
    end
  end

  describe "All brands" do
    test "is offered above the profiles in the switcher", %{conn: conn, j: j} do
      child = open(conn, j)

      assert has_element?(
               child,
               "#social-profile-select option[data-role='social-profile-option-all'][value='all']",
               "All brands"
             )
    end

    test "on Queue lists the posts of every visible profile, and nothing of another org",
         %{conn: conn, j: j} = ctx do
      child = open(conn, j)
      assert has_element?(child, "#queue-#{ctx.alpha_post.id}")
      refute has_element?(child, "#queue-#{ctx.beta_post.id}")

      all_brands(child)

      assert has_element?(child, "#social-profile-select option[selected][value='all']")
      assert has_element?(child, "[data-pane='queue']:not(.hidden) #queue-#{ctx.alpha_post.id}")
      assert has_element?(child, "[data-pane='queue']:not(.hidden) #queue-#{ctx.beta_post.id}")
      refute has_element?(child, "#queue-#{ctx.gamma_post.id}")
      assert has_element?(child, "[data-role='social-needs-approval']", "2 need approval")
      assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (2)")
    end

    test "on Settings shows the pick-a-brand prompt instead of the pane",
         %{conn: conn, j: j} = ctx do
      child = open(conn, j)
      child |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()
      all_brands(child)

      assert has_element?(
               child,
               "[data-role='social-pick-brand']",
               "Pick a brand to see Settings"
             )

      assert has_element?(child, "[data-pane='settings'].hidden")

      assert has_element?(
               child,
               "[data-role='social-pick-brand-option'][data-profile-id='#{ctx.beta.id}']"
             )

      refute has_element?(
               child,
               "[data-role='social-pick-brand-option'][data-profile-id='#{ctx.gamma.id}']"
             )

      # Picking a brand from the prompt lands on that brand's Settings.
      child
      |> element("[data-role='social-pick-brand-option'][data-profile-id='#{ctx.beta.id}']")
      |> render_click()

      refute has_element?(child, "[data-role='social-pick-brand']")

      assert has_element?(
               child,
               "#social-profile-select option[selected][value='#{ctx.beta.id}']"
             )

      assert has_element?(child, "[data-pane='settings']:not(.hidden)")
    end

    test "on Connections and Clips shows the prompt too", %{conn: conn, j: j} do
      child = open(conn, j)
      all_brands(child)

      for {key, label} <- [{"connections", "Connections"}, {"clips", "Clips"}] do
        child |> element("[data-role='social-tab-button'][data-tab='#{key}']") |> render_click()

        assert has_element?(
                 child,
                 "[data-role='social-pick-brand']",
                 "Pick a brand to see #{label}"
               )

        assert has_element?(child, "[data-pane='#{key}'].hidden")
      end
    end

    test "the waiting count totals every visible profile and opens All brands",
         %{conn: conn, j: j} = ctx do
      child = open(conn, j)

      assert has_element?(
               child,
               "[data-role='social-waiting-count'][data-count='2']",
               "2 waiting in all brands"
             )

      child |> element("[data-role='social-waiting-count']") |> render_click()
      assert has_element?(child, "#social-profile-select option[selected][value='all']")
      assert has_element?(child, "#queue-#{ctx.beta_post.id}")
    end
  end

  describe "the health dot" do
    test "is absent while every account is connected and nothing failed", %{conn: conn, j: j} do
      child = open(conn, j)
      refute has_element?(child, "[data-role='social-health-dot']")
    end

    test "with one disconnected account, appears and opens that profile's Connections",
         %{conn: conn, j: j, org_a: org_a} do
      {delta, _account} = profile!(org_a, "Delta", %{platform: "x"})
      child = open(conn, j)

      assert has_element?(
               child,
               "[data-role='social-health-dot'][data-profile-id='#{delta.id}'][aria-label*='X on Delta']"
             )

      child |> element("[data-role='social-health-dot']") |> render_click()

      assert has_element?(child, "#social-profile-select option[selected][value='#{delta.id}']")
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='connections']")
      assert has_element?(child, "[data-pane='connections']:not(.hidden)", "@Delta")
    end

    test "appears for a post that failed in the last 7 days", %{conn: conn, j: j} = ctx do
      {:ok, _} =
        ctx.alpha_post
        |> Ecto.Changeset.change(status: "failed", error: "rejected")
        |> Platform.Repo.update()

      child = open(conn, j)

      assert has_element?(
               child,
               "[data-role='social-health-dot'][data-profile-id='#{ctx.alpha.id}'][aria-label*='1 post on Alpha failed']"
             )
    end
  end

  describe "zero data" do
    test "a user with no profiles still gets the create form and no top bar", %{conn: conn} do
      org = org_id!()
      lone = member!(user!(), org)
      child = open(conn, lone)

      assert has_element?(child, "form#social-create-form[phx-submit='create_profile']")
      refute has_element?(child, "[data-role='social-top-bar']")
      refute has_element?(child, "[data-role='social-health-dot']")
    end
  end

  describe "Social.list_posts_for_profiles/3" do
    test "reads only the user's visible profiles; a foreign id narrows to nothing", ctx do
      ids = ctx.j |> Social.list_posts_for_profiles(:all, status: "needs_approval") |> ids()
      assert ctx.alpha_post.id in ids
      assert ctx.beta_post.id in ids
      refute ctx.gamma_post.id in ids

      assert Social.list_posts_for_profiles(ctx.j, [ctx.gamma.id], []) == []

      assert ctx.j |> Social.list_posts_for_profiles([ctx.beta.id, ctx.gamma.id], []) |> ids() ==
               [ctx.beta_post.id]

      assert Social.list_posts_for_profiles(nil, :all, []) == []
    end
  end

  defp ids(posts), do: Enum.map(posts, & &1.id)
end
