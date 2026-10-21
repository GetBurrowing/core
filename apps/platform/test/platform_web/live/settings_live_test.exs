defmodule PlatformWeb.SettingsLiveTest do
  @moduledoc """
  `/settings` (task 01a1557a-807f stage 1): Profile, Theme, the gated Account
  rows (Usage, Admin, Prompts) and Sign out.

  The gated rows are checked against REAL mounts, not against a restatement of
  the rules: for each actor, a row is present exactly when `live/2` of its
  path succeeds for that actor.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ModuleGate

  @gated_rows [
    {"settings-usage", "/control/usage"},
    {"settings-admin", "/admin"},
    {"settings-prompts", "/admin/prompts"}
  ]

  defp user!(role, org_id, external? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "settings-#{n}@example.com",
        name: "Settings User #{n}",
        oidc_sub: "settings-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external?
    })
    |> Repo.insert!()

    user
  end

  defp member!, do: user!("member", acme_org_id())
  defp root!, do: user!("admin", acme_org_id())

  # A child-org member holding a project-scoped prompts.manage grant: the
  # nearest thing to a "prompts module admin" short of root.
  defp prompts_grantee! do
    child = tenant_org_id("settings-prompts-#{System.unique_integer([:positive])}")
    user = user!("member", child)
    {:ok, project} = Tasks.create_project(%{name: "Settings prompts scope", org_id: child})
    {:ok, _} = Grants.grant(%{principal: user, permission: "prompts.manage", resource: project})
    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp scope(user), do: Scope.for_user(Platform.Accounts.get_user(user.id))

  defp roles(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role^=settings-]")
    |> LazyHTML.attribute("data-role")
  end

  defp mounts?(user, path) do
    case live(authed(user), path) do
      {:ok, _view, _html} -> true
      {:error, {_kind, %{to: _}}} -> false
    end
  end

  describe "rows" do
    test "a member sees Profile, Theme and Sign out, and no Admin or Prompts row" do
      member = member!()
      {:ok, _view, html} = live(authed(member), "/settings")
      roles = roles(html)

      for role <- ~w(settings-profile settings-theme settings-sign-out),
          do: assert(role in roles, role)

      refute "settings-admin" in roles
      refute "settings-prompts" in roles
      # Positive control: the member really is refused both pages.
      refute mounts?(member, "/admin")
      refute mounts?(member, "/admin/prompts")
    end

    test "a root admin sees every row, in order" do
      {:ok, _view, html} = live(authed(root!()), "/settings")

      assert roles(html) == ~w(settings-profile settings-theme settings-usage
               settings-admin settings-prompts settings-sign-out)
    end

    test "the profile head shows the name and the email in text-subtle" do
      member = member!()
      {:ok, view, _html} = live(authed(member), "/settings")

      assert view |> element("[data-role=settings-profile]") |> render() =~ member.name

      assert has_element?(
               view,
               "[data-role=settings-profile] p.text-subtle",
               member.email
             )
    end

    test "each gated row is present exactly when its page mounts for that actor" do
      actors = %{
        member: member!(),
        prompts_grantee: prompts_grantee!(),
        root_admin: root!()
      }

      results =
        for {name, user} <- actors, {role, path} <- @gated_rows do
          {:ok, _view, html} = live(authed(user), "/settings")
          shown? = role in roles(html)
          {name, role, shown?, mounts?(user, path)}
        end

      disagreements = for {n, r, shown?, mounts?} <- results, shown? != mounts?, do: {n, r}

      # ONE known disagreement, pinned so it cannot grow or vanish unnoticed.
      # A pre-existing gate split, not this page's: ModuleGate admits a
      # project-scoped prompts.manage grantee to AdminPromptsLive
      # (`module_access?/3` is `holds_anywhere?`), and the page's own
      # `PromptTemplates.list_templates/1` re-check, which wants the
      # permission install-wide, then sends them to /access-denied. The row
      # follows ModuleGate by design (one rule). When the split is closed,
      # this list becomes [] and this assertion must be updated.
      assert disagreements == [{:prompts_grantee, "settings-prompts"}], inspect(results)

      # The comparison above means something only if it saw both outcomes.
      assert Enum.any?(results, fn {_, _, _, m} -> m end)
      refute Enum.all?(results, fn {_, _, _, m} -> m end)
    end
  end

  describe "sign out" do
    test "the sign-out row links to a real GET logout route" do
      {:ok, _view, html} = live(authed(member!()), "/settings")

      [href] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-role=settings-sign-out]")
        |> LazyHTML.attribute("href")

      # A plain link is a GET. The More sheet's row once pointed at
      # /oidc/logout, which the router never defined. The route check comes
      # first: it is the property, the literal is the spelling.
      assert %{plug: PlatformWeb.AuthController, plug_opts: :logout} =
               Phoenix.Router.route_info(PlatformWeb.Router, "GET", href, "localhost")

      assert href == "/auth/logout"
    end
  end

  describe "theme" do
    test "clicking Theme opens the existing theme picker sheet" do
      {:ok, view, _html} = live(authed(member!()), "/settings")

      refute has_element?(view, "#theme-picker-sheet[data-open=true]")
      view |> element("[data-role=settings-theme]") |> render_click()

      assert has_element?(view, "#theme-picker-sheet[data-open=true]")
      assert :sys.get_state(view.pid).socket.assigns.theme_picker_open == true
    end
  end

  describe "guest" do
    setup do
      guest = user!("member", tenant_org_id("settings-guest"), true)
      %{guest: guest}
    end

    test "a guest Scope passes the page gate and is shown no gated row", %{guest: guest} do
      guest_scope = scope(guest)
      assert Scope.guest?(guest_scope)

      assert ModuleGate.mounts?(guest_scope, PlatformWeb.SettingsLive)
      assert PlatformWeb.SettingsLive.visible_rows(guest_scope) == []
    end

    test "a guest navigating in-app from /chat mounts /settings with no gated row", %{
      guest: guest
    } do
      {:ok, chat, _} = live(authed(guest), "/chat")
      {:ok, _view, html} = live_redirect(chat, to: "/settings")

      roles = roles(html)
      assert "settings-sign-out" in roles
      for {role, _} <- @gated_rows, do: refute(role in roles, role)
    end
  end

  test "the shell names the module Settings" do
    {:ok, view, _html} = live(authed(member!()), "/settings")
    assert :sys.get_state(view.pid).socket.assigns.active_module == "Settings"
    assert page_title(view) =~ "Settings"
  end
end
