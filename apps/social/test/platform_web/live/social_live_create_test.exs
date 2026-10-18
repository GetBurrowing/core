defmodule PlatformWeb.SocialLiveCreateTest do
  @moduledoc """
  Creating a social profile from the Social tab (task 01a14668): the
  empty-state form, "+ New profile" beside the switcher, the duplicate and
  blank-name errors, the per-org scope, and the refusal of a viewer who
  cannot create (an agent) or a forged org id. Every write under test goes
  through the LiveView's `create_profile` event, which calls
  `Platform.Social.create_profile/2`. `async: false`: needs_approval posts
  fan out approval cards through core's chat.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Social

  defp login(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp open(conn, user) do
    {:ok, view, _html} = live(login(conn, user), "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp submit_create(child, name, home_url \\ "") do
    child
    |> form("#social-create-form", profile: %{name: name, home_url: home_url})
    |> render_submit()
  end

  defp open_new_profile(child) do
    child |> element("[data-role='social-new-profile']") |> render_click()
    assert has_element?(child, "[data-role='social-create-panel'] form#social-create-form")
  end

  defp profiles_in(org_id), do: Social.list_profiles(org_id)

  defp option_names(child) do
    child
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#social-profile-select [data-role='social-profile-option']")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+\d+$/, "")))
  end

  defp selected_option(profile_id),
    do: "#social-profile-select option[selected][value='#{profile_id}']"

  describe "A1: a human member of an org with no profiles" do
    test "sees the form, creates HTC, and becomes its approver with editable Settings",
         %{conn: conn} do
      org = org_id!()
      human = member!(user!(), org)
      child = open(conn, human)

      # I1-I5 copy, and no switcher or tabs yet.
      assert has_element?(
               child,
               "[data-role='social-create-heading']",
               "Set up your first social profile"
             )

      assert has_element?(
               child,
               "[data-role='social-create-explanation']",
               "A profile is a brand or person you post for. You'll be its first approver."
             )

      assert has_element?(child, "label[for='social-create-name']", "Name")
      assert has_element?(child, "input[data-role='social-create-name'][required]")
      assert has_element?(child, "label[for='social-create-home-url']", "Home page (optional)")

      assert has_element?(
               child,
               "[data-role='social-create-home-url'][placeholder='https://youtube.com/@htc']"
             )

      assert has_element?(
               child,
               "#social-create-home-hint",
               "Where clips link back to. Add it later in Settings if you like."
             )

      assert has_element?(
               child,
               "button[type='submit'].btn-primary[phx-disable-with][data-role='social-create-submit']",
               "Create profile"
             )

      refute has_element?(child, "#social-profile-select")
      refute has_element?(child, "[data-role='social-tabs']")
      refute has_element?(child, "[data-role='social-no-profiles']")

      submit_create(child, "HTC", "https://youtube.com/@htc")

      assert [htc] = profiles_in(org)
      assert htc.name == "HTC"
      assert htc.org_id == org
      assert htc.home_url == "https://youtube.com/@htc"
      assert htc.approver_user_ids == [human.id]

      assert has_element?(child, selected_option(htc.id))
      assert has_element?(child, ".tab-active[data-tab='queue']")

      assert has_element?(
               child,
               "[data-pane='queue'] [data-role='social-empty']",
               "Nothing waiting for approval on HTC. Connect an account to start."
             )

      assert has_element?(
               child,
               "[data-role='social-go-connections'][phx-click='select_tab'][phx-value-tab='connections']",
               "Go to Connections"
             )

      refute has_element?(child, "form#social-create-form")

      # Settings is the editable form for the creator (can_edit? true).
      child |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()
      assert has_element?(child, "[data-pane='settings'] [data-role='social-settings-form']")
      refute has_element?(child, "[data-role='social-settings-readonly']")
    end
  end

  describe "A2: + New profile after HTC has rows" do
    test "creating Legacy selects it and leaves no HTC queue or account row in the DOM",
         %{conn: conn} do
      org = org_id!()
      human = member!(user!(), org)
      child = open(conn, human)
      submit_create(child, "HTC")
      assert [htc] = profiles_in(org)

      # Fixture setup: a channel so a needs_approval post can get its card.
      {:ok, htc} = Social.update_profile(org, htc, %{space_id: channel!(org).id})

      {:ok, account} =
        Social.create_account(org, htc, %{platform: "linkedin", handle: "@htc_official"})

      {:ok, post} =
        Social.create_post(org, account, %{body: "Episode 12", status: "needs_approval"})

      # Switch to HTC so its rows render.
      child |> form("#social-profile-switcher", %{profile_id: htc.id}) |> render_change()
      assert has_element?(child, "#social-queue #queue-#{post.id}[data-role='social-queue-row']")
      assert has_element?(child, "#social-accounts [data-role='social-account-row']")

      open_new_profile(child)
      submit_create(child, "Legacy")

      assert [_, _] = profiles = profiles_in(org)
      legacy = Enum.find(profiles, &(&1.name == "Legacy"))
      assert legacy.approver_user_ids == [human.id]

      assert Enum.sort(option_names(child)) == ["HTC", "Legacy"]
      assert has_element?(child, selected_option(legacy.id))
      refute has_element?(child, selected_option(htc.id))

      refute has_element?(child, "#queue-#{post.id}")
      refute has_element?(child, "#social-queue [data-role='social-queue-row']")
      refute has_element?(child, "#accounts-#{account.id}")
      refute has_element?(child, "#social-accounts [data-role='social-account-row']")

      assert has_element?(
               child,
               "[data-pane='queue'] [data-role='social-empty']",
               "Nothing waiting for approval on Legacy. Connect an account to start."
             )
    end
  end

  describe "A3: cross-org" do
    test "neither org's human sees the other's profiles; each row is in its own org",
         %{conn: conn} do
      org_a = org_id!()
      org_b = org_id!()
      ha = member!(user!(), org_a)
      hb = member!(user!(), org_b)

      child_a = open(conn, ha)
      submit_create(child_a, "Alpha")
      child_b = open(build_conn(), hb)
      submit_create(child_b, "Bravo")

      assert [alpha] = profiles_in(org_a)
      assert [bravo] = profiles_in(org_b)
      assert alpha.org_id == org_a
      assert bravo.org_id == org_b
      assert alpha.approver_user_ids == [ha.id]

      child_a = open(build_conn(), ha)
      child_b = open(build_conn(), hb)

      assert option_names(child_a) == ["Alpha"]
      assert option_names(child_b) == ["Bravo"]
      refute has_element?(child_a, "[data-role='social-profile-option'][value='#{bravo.id}']")
      refute has_element?(child_b, "[data-role='social-profile-option'][value='#{alpha.id}']")
      refute render(child_a) =~ "Bravo"
      refute render(child_b) =~ "Alpha"
    end
  end

  describe "A4: duplicate and blank names" do
    test "a duplicate shows the inline error under Name, keeps the input, inserts nothing",
         %{conn: conn} do
      org = org_id!()
      human = member!(user!(), org)
      child = open(conn, human)
      submit_create(child, "HTC")
      assert [_] = profiles_in(org)

      open_new_profile(child)
      submit_create(child, "HTC", "https://youtube.com/@htc")

      assert Process.alive?(child.pid)
      assert [_] = profiles_in(org)

      assert has_element?(
               child,
               "[data-role='social-create-panel'] [data-role='social-create-error']",
               "A profile called HTC already exists."
             )

      assert has_element?(
               child,
               "#social-create-name[aria-describedby='social-create-error'] ~ [data-role='social-create-error']"
             )

      assert has_element?(child, "[data-role='social-create-name'][value='HTC']")

      assert has_element?(
               child,
               "[data-role='social-create-home-url'][value='https://youtube.com/@htc']"
             )

      assert has_element?(child, "[data-role='social-create-submit']", "Create profile")
    end

    test "the same name in another org succeeds (uniqueness is per org)", %{conn: conn} do
      org_a = org_id!()
      org_c = org_id!()
      ha = member!(user!(), org_a)
      hc = member!(user!(), org_c)

      submit_create(open(conn, ha), "HTC")
      child_c = open(build_conn(), hc)
      submit_create(child_c, "HTC")

      assert [%{name: "HTC"}] = profiles_in(org_a)
      assert [%{name: "HTC"} = htc_c] = profiles_in(org_c)
      assert has_element?(child_c, selected_option(htc_c.id))
      refute has_element?(child_c, "[data-role='social-create-error']")
    end

    test "a blank name shows an inline error and inserts nothing", %{conn: conn} do
      org = org_id!()
      human = member!(user!(), org)
      child = open(conn, human)

      submit_create(child, "", "https://youtube.com/@htc")

      assert Process.alive?(child.pid)
      assert profiles_in(org) == []
      assert has_element?(child, "form#social-create-form [data-role='social-create-error']")
      refute has_element?(child, "#social-profile-select")
    end
  end

  describe "A5: an agent viewer" do
    test "gets no create control, and a forged create inserts nothing (positive control: a human's identical payload inserts one)",
         %{conn: conn} do
      org = org_id!()
      agent = agent!()
      human = member!(user!(), org)

      {:ok, g_view, _html} =
        live_isolated(conn, PlatformWeb.SocialLive, session: %{"user_id" => agent.id})

      assert has_element?(
               g_view,
               "[data-role='social-no-profiles']",
               "No social profiles yet. Ask an org member to set one up."
             )

      refute has_element?(g_view, "#social-create-form")
      refute has_element?(g_view, "[data-role='social-create-form']")
      refute has_element?(g_view, "[data-role='social-new-profile']")
      refute has_element?(g_view, "[data-role='social-create-submit']")

      payload = %{"profile" => %{"name" => "Forged", "home_url" => ""}}
      render_hook(g_view, "create_profile", payload)
      render_hook(g_view, "create_profile", put_in(payload, ["profile", "org_id"], org))

      assert Process.alive?(g_view.pid)
      assert profiles_in(org) == []
      refute has_element?(g_view, "#social-create-form")
      assert has_element?(g_view, "[data-role='social-no-profiles']")

      # Positive control: the identical event from a human member writes.
      h_child = open(build_conn(), human)
      render_hook(h_child, "create_profile", payload)

      assert [%{name: "Forged", org_id: ^org} = forged] = profiles_in(org)
      assert forged.approver_user_ids == [human.id]
    end
  end

  describe "A6: a forged org id" do
    test "for an org the human is not a member of is refused with no insert", %{conn: conn} do
      org_a = org_id!()
      org_x = org_id!()
      human = member!(user!(), org_a)
      child = open(conn, human)

      render_hook(child, "create_profile", %{
        "profile" => %{"name" => "Smuggled", "home_url" => "", "org_id" => org_x}
      })

      assert Process.alive?(child.pid)
      assert profiles_in(org_x) == []
      assert profiles_in(org_a) == []

      # Positive control: the same human, no forged org, creates in org A.
      submit_create(child, "Smuggled")
      assert [%{name: "Smuggled"}] = profiles_in(org_a)
      assert profiles_in(org_x) == []
    end
  end
end
