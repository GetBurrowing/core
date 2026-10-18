defmodule PlatformWeb.SocialLiveTest do
  @moduledoc """
  The Social tab shell (Social 7/7 stage 1): the rail item, `/m/social`
  through core's generic extension page, the profile switcher with
  per-profile needs-approval counts, and the tab strip. `async: false`:
  needs_approval writes post approval cards through core's chat.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Social
  alias PlatformWeb.Components.IconRail

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp open(conn, user) do
    {:ok, view, html} = live(login(conn, user), "/m/social")
    {view, find_live_child(view, "ext-page-social"), html}
  end

  defp profile!(org_id, name) do
    {:ok, profile} =
      Social.create_profile(org_id, %{name: name, space_id: channel!(org_id).id})

    {:ok, account} =
      Social.create_account(org_id, profile, %{platform: "linkedin", handle: "@#{name}"})

    {profile, account}
  end

  defp needs_approval!(org_id, account, n) do
    for i <- 1..n//1 do
      {:ok, post} =
        Social.create_post(org_id, account, %{body: "post #{i}", status: "needs_approval"})

      post
    end
  end

  setup do
    org_a = org_id!()
    org_b = org_id!()
    j = member!(user!(), org_a)
    {htc, htc_account} = profile!(org_a, "HTC")
    {legacy, legacy_account} = profile!(org_a, "Legacy")
    {bravo, bravo_account} = profile!(org_b, "Bravo")
    needs_approval!(org_a, htc_account, 2)
    needs_approval!(org_a, legacy_account, 1)
    needs_approval!(org_b, bravo_account, 4)
    # A post in another status counts for nothing.
    {:ok, _} = Social.create_post(org_a, htc_account, %{body: "draft"})

    %{org_a: org_a, org_b: org_b, j: j, htc: htc, legacy: legacy, bravo: bravo}
  end

  describe "the rail item" do
    test "is in IconRail.destinations, under More on mobile (not a bottom-bar tile)" do
      assert %{path: "/m/social", label: "Social", cluster: :working} =
               Enum.find(IconRail.destinations(), &(&1.key == :social))

      bar = render_component(&IconRail.bottom_rail/1, current_path: "/m/social")
      refute bar =~ "/m/social"
    end

    test "is on the page's desktop rail", %{conn: conn, j: j} do
      {_view, _child, html} = open(conn, j)
      assert html =~ ~s(href="/m/social")
    end
  end

  describe "/m/social" do
    test "renders the Social tab for a member", %{conn: conn, j: j, htc: htc} do
      {_view, child, _html} = open(conn, j)
      assert has_element?(child, "[data-role='social-tab']")
      assert has_element?(child, "#social-profile-select option[selected][value='#{htc.id}']")
    end

    test "is a 404 (or the external gate's 403) for an external user", %{conn: conn, org_a: org_a} do
      ext = user!()

      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: ext.id,
        org_id: org_a,
        role: "member",
        external: true
      })
      |> Platform.Repo.insert!()

      conn = get(login(conn, ext), "/m/social")
      assert conn.status in [403, 404]
      refute conn.resp_body =~ "social-tab"
    end

    # Task 01a14668: a human member with no visible profile now gets the
    # create form AS the empty state (not the "ask someone" line), and still
    # no switcher or tabs.
    test "with no visible profile says so, and shows no switcher or tabs", %{conn: conn} do
      lonely = member!(user!(), org_id!())
      {_view, child, _html} = open(conn, lonely)

      assert has_element?(
               child,
               "[data-role='social-create-heading']",
               "Set up your first social profile"
             )

      assert has_element?(child, "form#social-create-form[phx-submit='create_profile']")
      assert has_element?(child, "[data-role='social-create-name']")
      assert has_element?(child, "[data-role='social-create-submit']", "Create profile")
      refute has_element?(child, "[data-role='social-no-profiles']")
      refute has_element?(child, "#social-profile-select")
      refute has_element?(child, "[data-role='social-tabs']")
    end
  end

  describe "the profile switcher" do
    test "lists both profiles by name, each with its needs-approval count",
         %{conn: conn, j: j, htc: htc, legacy: legacy} do
      {_view, child, _html} = open(conn, j)

      assert has_element?(
               child,
               "[data-role='social-profile-option'][value='#{htc.id}'][data-count='2']",
               "HTC 2"
             )

      assert has_element?(
               child,
               "[data-role='social-profile-option'][value='#{legacy.id}'][data-count='1']",
               "Legacy 1"
             )

      assert has_element?(child, "[data-role='social-needs-approval']", "2 need approval")
      assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (2)")

      for {tab, label} <- [
            {"calendar", "Calendar"},
            {"connections", "Connections"},
            {"settings", "Settings"}
          ] do
        assert has_element?(child, "[data-role='social-tab-button'][data-tab='#{tab}']", label)
      end
    end

    test "switching changes the header and the copy, and keeps the current tab",
         %{conn: conn, j: j, legacy: legacy} do
      {_view, child, _html} = open(conn, j)

      child |> element("[data-role='social-tab-button'][data-tab='calendar']") |> render_click()
      assert has_element?(child, "[data-role='social-tab-body']", "Nothing scheduled for HTC")

      child |> form("#social-profile-switcher", %{profile_id: legacy.id}) |> render_change()

      assert has_element?(child, "#social-profile-select option[selected][value='#{legacy.id}']")
      assert has_element?(child, "[data-role='social-needs-approval']", "1 need approval")
      assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (1)")
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='calendar']")
      assert has_element?(child, "[data-role='social-tab-body']", "Nothing scheduled for Legacy")
      refute has_element?(child, "[data-role='social-tab-body']", "HTC")
      assert has_element?(child, ".tab-active[data-tab='calendar']")
    end

    test "a user who sees only org A never sees org B's profile, even by a forged switch",
         %{conn: conn, j: j, bravo: bravo, htc: htc} do
      {_view, child, _html} = open(conn, j)

      refute has_element?(child, "[data-role='social-profile-option'][value='#{bravo.id}']")
      refute render(child) =~ "Bravo"

      render_hook(child, "switch_profile", %{"profile_id" => bravo.id})

      assert has_element?(child, "#social-profile-select option[selected][value='#{htc.id}']")
      refute render(child) =~ "Bravo"
    end

    test "list_profiles_for_user/1 and needs_approval_counts/1 (the switcher's reads)",
         %{j: j, htc: htc, legacy: legacy, bravo: bravo} do
      assert Enum.map(Social.list_profiles_for_user(j), & &1.id) == [htc.id, legacy.id]
      assert Social.list_profiles_for_user(nil) == []
      assert Social.list_profiles_for_user(user!()) == []

      assert Social.needs_approval_counts([htc.id, legacy.id, bravo.id]) ==
               %{htc.id => 2, legacy.id => 1, bravo.id => 4}

      assert Social.needs_approval_counts([]) == %{}
    end
  end
end
