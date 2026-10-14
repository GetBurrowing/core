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
    test "admin user reaches the page and sees the 4 section cards", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/admin")

      assert html =~ "Admin · Operations"
      refute html =~ "Fabrikam Operations"
      assert html =~ "Agent Resources"
      assert html =~ "Agent Federation"
      assert html =~ "Usage / Cost Metering"
      assert html =~ "User Access"
      assert html =~ ~s(href="/control")
      assert html =~ ~s(href="/admin/federation")
      assert html =~ ~s(href="/control/usage")
      assert html =~ ~s(href="/admin/users")
      # Prompts is intentionally NOT a card on the landing page — it's
      # reached via the working-cluster rail tile (admin-only, root_only?:
      # true). Per 2026-05-20 dedup decision: single source of truth.
      # Can't `refute html =~ ~s(href="/admin/prompts")` page-wide because
      # the surrounding shell rail (visible to admins) renders the Prompts
      # tile with that same href. Instead, assert the landing-card
      # description for Prompts is gone (the description was unique to the
      # old card; removing it confirms the card is gone).
      refute html =~ "Manage system prompt templates"
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

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

  describe "/admin/users (User Access)" do
    test "admin user reaches the page and sees the user-list surface", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/admin/users")

      assert html =~ "Admin · User Access"
      # Toggle button rendered — this is the primary affordance of the
      # (no-longer-stubbed) surface. Task 019f671f Stage 6.
      assert html =~ ~s(data-role="toggle-show-archived")
      # Own admin row present with the self-archive guard rendered
      # (`disabled` on the current-user row, self-explanatory title).
      # `'` is HTML-escaped to `&#39;` inside the title attribute.
      assert html =~ "You can&#39;t archive yourself"
      # The old "Coming Soon" copy is gone.
      refute html =~ "Coming Soon"
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/users")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end

    test "user with no memberships is redirected to /", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/users")
    end
  end

  describe "/admin/prompts" do
    test "admin user reaches the page", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")

      {:ok, _view, _html} = conn |> authenticated_conn(user) |> live(~p"/admin/prompts")
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

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
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")

      {:ok, _view, _html} = conn |> authenticated_conn(user) |> live(~p"/admin/federation")
    end

    test "member user is redirected to /", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/federation")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end
  end

  describe "admin nav gating in shell" do
    # Admin-only nav chrome is gated on `root_user`, which is driven by
    # `Tenancy.root_admin_preloaded?/1`. Admin-only tiles in the rail today:
    # the dedicated **Admin** cluster tile (lands at `/admin` landing page
    # with section cards for Agent Resources / Agent Federation / Usage /
    # User Access) AND the **Prompts** working-cluster tile (root_only?:
    # true as of 2026-05-20 — was false until then, which rendered the tile
    # for members but redirected on click; that bug is fixed).
    test "admin user sees the Admin cluster tile in shell", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/tasks")

      assert html =~ ~s(data-destination="admin")
      assert html =~ ~s(href="/admin")
    end

    test "member user does NOT see the Admin cluster tile in shell", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

      {:ok, _view, html} = conn |> authenticated_conn(user) |> live(~p"/tasks")

      refute html =~ ~s(data-destination="admin")
      # Members must also NOT see the Prompts tile (root_only?: true as
      # of 2026-05-20). The data-destination attribute is the precise
      # check — the path string "/admin/prompts" alone could surface in
      # other contexts (e.g. tests that don't render the rail).
      refute html =~ ~s(data-destination="prompts")
    end
  end
end
