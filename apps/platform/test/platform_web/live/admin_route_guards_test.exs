defmodule PlatformWeb.AdminRouteGuardsTest do
  @moduledoc """
  Route-level integration tests for the `:admin` `live_session` block
  installed in `PlatformWeb.Router` (task 019e3c4a stage 5). Verifies
  the `LiveAuth.on_mount(:ensure_admin, ...)` hook:

    * lets admin users reach `/admin/prompts` and `/admin/federation`
    * redirects member / no-membership users to `/` with a flash error
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "admin-guards-#{n}@example.com",
          name: "Admin Guards #{n}",
          oidc_sub: "oidc-admin-guards-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  describe "/admin (landing page)" do
    test "admin user reaches the page and sees all 4 section cards", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/admin")

      assert html =~ "Admin · Fabrikam Operations"
      assert html =~ "Agent Resources"
      assert html =~ "Agent Federation"
      assert html =~ "Usage / Cost Metering"
      assert html =~ "Prompts"
      assert html =~ ~s(href="/control")
      assert html =~ ~s(href="/admin/federation")
      assert html =~ ~s(href="/control/usage")
      assert html =~ ~s(href="/admin/prompts")
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end

    test "user with no memberships is redirected to /", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin")
    end
  end

  describe "/admin/prompts" do
    test "admin user reaches the page", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      {:ok, _view, _html} = conn |> authenticated_conn(user) |> live(~p"/admin/prompts")
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/prompts")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end

    test "user with no memberships is redirected to /", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/prompts")
    end
  end

  describe "/admin/federation" do
    test "admin user reaches the page", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      {:ok, _view, _html} = conn |> authenticated_conn(user) |> live(~p"/admin/federation")
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/federation")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end
  end

  describe "admin nav gating in shell" do
    # The dedicated **Admin** cluster tile in the icon-rail / bottom-rail /
    # more-sheet is the single piece of admin-only nav chrome — gated on
    # `is_fabrikam_user`, which (after stack 2) is driven by
    # `Tenancy.fabrikam_admin_preloaded?/1`. The shared **Prompts** tile
    # (`/admin/prompts`, working cluster, `fabrikam_only?: false` by design —
    # see `icon_rail.ex`) is visible to everyone today. The Admin tile
    # points at the landing page (`/admin`) which surfaces section cards
    # for the Fabrikam-only sub-surfaces (Agent Resources, Agent Federation,
    # Usage/Cost Metering, Prompts). `/admin/federation` is reachable via
    # the landing page card or direct URL.
    test "admin user sees the Admin cluster tile in shell", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/tasks")

      assert html =~ ~s(data-destination="admin")
      assert html =~ ~s(href="/admin")
    end

    test "member user does NOT see the Admin cluster tile in shell", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/tasks")

      refute html =~ ~s(data-destination="admin")
      # The shared "Prompts" working-cluster tile points at /admin/prompts
      # too and is intentionally NOT fabrikam_only? — so the path itself
      # still surfaces for members. The route-level guard (live_session
      # :admin) is what actually keeps members out of the page.
    end
  end
end
