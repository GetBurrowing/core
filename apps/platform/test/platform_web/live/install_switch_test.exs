defmodule PlatformWeb.InstallSwitchTest do
  @moduledoc """
  Task 01a1ccd4 stage 3: the install switcher at the Burrow mark on desktop
  and web, and `/switcher/connected`.

  One component renders both switchers (`PlatformWeb.Components.InstallSwitch`):
  the phone top bar's `#native-install-switch` (hidden until its hook
  reveals it, as task 01a1261e shipped it) and the desktop sidebar's
  `#sidebar-install-switch` in `#sidebar-brand`. Each has a sibling
  `#<id>-menu` that is `phx-update="ignore"`, so the hook-drawn dropdown
  survives LiveView patches.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp signed_in(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "install-switch-#{n}@example.com",
        name: "Install Switch #{n}",
        oidc_sub: "oidc-install-switch-#{n}"
      })

    Repo.insert!(%OrgMembership{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })

    init_test_session(conn, current_user_id: user.id)
  end

  describe "the shell" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn), ~p"/tasks")
      %{view: view}
    end

    test "renders the phone switcher in the top bar and the desktop one in the sidebar brand row",
         %{view: view} do
      assert has_element?(
               view,
               "#phone-top-bar #native-install-switch[phx-hook=NativeInstallSwitch]"
             )

      assert has_element?(
               view,
               "#sidebar-brand #sidebar-install-switch[phx-hook=NativeInstallSwitch]"
             )

      assert has_element?(view, "#native-install-switch[data-variant=phone]")
      assert has_element?(view, "#sidebar-install-switch[data-variant=sidebar]")
    end

    test "both carry the install name, its own unread, the label and a hidden bg-primary dot",
         %{view: view} do
      name = Platform.Branding.app_name()

      for id <- ["native-install-switch", "sidebar-install-switch"] do
        assert has_element?(view, ~s(##{id}[data-install-name="#{name}"]))
        assert has_element?(view, ~s(##{id}[data-current-unread="0"]))
        assert has_element?(view, ~s(##{id}[aria-label="Switch install, current: #{name}"]))
        assert has_element?(view, "##{id} [data-role=install-unread-dot].hidden.bg-primary")
      end
    end

    test "each switcher has its own hook-managed dropdown container", %{view: view} do
      assert has_element?(view, "#phone-top-bar #native-install-switch-menu[phx-update=ignore]")
      assert has_element?(view, "#sidebar-brand #sidebar-install-switch-menu[phx-update=ignore]")
      refute has_element?(view, "#native-install-switch-menu *")
      refute has_element?(view, "#sidebar-install-switch-menu *")
    end

    test "the phone switcher still renders hidden (only the hook reveals it), the desktop one visible",
         %{view: view} do
      assert has_element?(view, "#native-install-switch.hidden")
      refute has_element?(view, "#native-install-switch.flex")
      refute has_element?(view, "#sidebar-install-switch.hidden")
    end

    test "the sidebar brand row keeps one Burrow mark and the command palette button last",
         %{view: view} do
      assert has_element?(view, "#sidebar-brand #sidebar-install-switch img[src*=burrow-mark]")
      assert has_element?(view, "#sidebar-brand > button#cmdk-btn:last-child")
    end
  end

  describe "/switcher/connected" do
    test "renders the working card with the SwitcherConnected hook, the invalid card hidden",
         %{conn: conn} do
      {:ok, view, _html} = live(signed_in(conn), ~p"/switcher/connected")

      assert has_element?(
               view,
               "#switcher-connected[phx-hook=SwitcherConnected][phx-update=ignore]"
             )

      assert has_element?(view, "#switcher-connected [data-role=connected-working]")
      assert has_element?(view, "#switcher-connected [data-role=connected-invalid].hidden")
      assert has_element?(view, "[data-role=connected-invalid] h1", "This link doesn't work")
    end

    test "signed out, it sends the browser to sign in first", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/switcher/connected")
    end
  end
end
