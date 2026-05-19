defmodule PlatformWeb.LiveAuthIntegrationTest do
  @moduledoc """
  End-to-end LV mount coverage for the `LiveAuth` hook chain installed
  by the router. Mounts `ChatLive` (a representative authenticated
  surface) as an admin / member / no-membership user and asserts the
  expected assigns surfaced.
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
          email: "live-auth-int-#{n}@example.com",
          name: "LV Auth Int #{n}",
          oidc_sub: "oidc-live-auth-int-#{n}"
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

  describe "live_session :authenticated → LiveAuth :default" do
    test "admin user has :fabrikam_admin? = true on LV mount", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "admin")

      {:ok, view, _html} = conn |> authenticated_conn(user) |> live(~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.fabrikam_admin? == true
      assert %{role: :admin, org: %{slug: "fabrikam"}} = assigns.current_user_org_membership
    end

    test "member user has :fabrikam_admin? = false on LV mount", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      {:ok, view, _html} = conn |> authenticated_conn(user) |> live(~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.fabrikam_admin? == false
      assert %{role: :member, org: %{slug: "fabrikam"}} = assigns.current_user_org_membership
    end

    test "user with no memberships has :fabrikam_admin? = false + nil membership", %{conn: conn} do
      user = create_user!()

      {:ok, view, _html} = conn |> authenticated_conn(user) |> live(~p"/tasks")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.fabrikam_admin? == false
      assert is_nil(assigns.current_user_org_membership)
    end
  end
end
