defmodule PlatformWeb.AdminOrgsLiveTest do
  @moduledoc """
  `/admin/orgs` — the human-reachable caller for `Tenancy.create_org/2`
  (task 019ffe9d stage 4).

  Covers the two halves of the authorization story (the `:admin`
  live_session's `:ensure_admin` hook, and the fact that a created org is
  really parented to the root org by the context function rather than by
  the form), plus the three form outcomes: valid, duplicate slug, and
  malformed slug. The duplicate-slug case is the one that matters most —
  it must render as an inline error on `:slug`, never an
  `Ecto.ConstraintError` reaching the browser.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "admin-orgs-#{n}@example.com",
          name: "Admin Orgs #{n}",
          oidc_sub: "oidc-admin-orgs-#{n}"
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

  defp admin_user! do
    user = create_user!()
    create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "admin")
    user
  end

  defp count_orgs_with_slug(slug) do
    Repo.aggregate(from(o in Org, where: o.slug == ^slug), :count)
  end

  describe "authorization" do
    test "a member (non-admin) mount is redirected by :ensure_admin", %{conn: conn} do
      user = create_user!()
      create_membership!(user, Tenancy.get_org_by_slug!("fabrikam"), "member")

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/orgs")

      assert Phoenix.Flash.get(flash, :error) =~ "don't have access"
    end

    test "a user with no memberships is redirected", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/orgs")
    end
  end

  describe "rendering" do
    test "an admin renders the route and can open the create sheet", %{conn: conn} do
      admin = admin_user!()

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")

      assert html =~ "Admin · Orgs"
      # Seeded root org is listed.
      assert html =~ ~s(data-org-slug="fabrikam")
      # The sheet is not in the DOM until it is opened.
      refute html =~ ~s(id="create-org-sheet")

      opened =
        view
        |> element(~s([data-role="open-create-org"]))
        |> render_click()

      assert opened =~ ~s(id="create-org-sheet")
      assert opened =~ ~s(data-role="create-org-form")
      # Slug format rule is shown up front, not discovered by rejection.
      assert opened =~ "^[a-z][a-z0-9_-]*$"
      # And the surface says out loud that it does not finish the job.
      assert opened =~ "require a follow-up code change"
    end

    test "the admin hub links to the new surface", %{conn: conn} do
      admin = admin_user!()

      {:ok, _view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin")

      assert html =~ ~s(data-role="admin-orgs-link")
      assert html =~ ~s(href="/admin/orgs")
    end
  end

  describe "create" do
    test "a valid name and slug creates a tenant org parented to Fabrikam, and it lists", %{
      conn: conn
    } do
      admin = admin_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      html =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: "aurora_labs"})
        |> render_submit()

      created = Repo.get_by!(Org, slug: "aurora_labs")
      assert created.name == "Aurora Labs"
      # Parentage is derived by `create_org/2`, not posted by the form.
      assert created.parent_org_id == fabrikam.id

      assert html =~ ~s(data-org-slug="aurora_labs")
      assert html =~ "Aurora Labs"
    end

    test "a duplicate slug renders an inline :slug error, no crash, no second row", %{conn: conn} do
      admin = admin_user!()

      assert {:ok, _first} =
               Tenancy.create_org(admin, %{name: "Aurora Labs", slug: "aurora_labs"})

      assert count_orgs_with_slug("aurora_labs") == 1

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      html =
        view
        |> form(~s(#create-org-form), org: %{name: "Aurora Labs Two", slug: "aurora_labs"})
        |> render_submit()

      # The LiveView is still alive — an Ecto.ConstraintError reaching the
      # browser would have killed it before this line.
      assert render(view) =~ ~s(id="create-org-sheet")

      slug_error = view |> element(~s([data-role="org-slug-error"])) |> render()
      assert slug_error =~ "has already been taken"

      # The error is on :slug specifically, not smeared across the form.
      refute html =~ ~s(data-role="org-name-error")

      assert count_orgs_with_slug("aurora_labs") == 1
    end

    test "an invalid slug format renders the format error", %{conn: conn} do
      admin = admin_user!()

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/orgs")
      view |> element(~s([data-role="open-create-org"])) |> render_click()

      view
      |> form(~s(#create-org-form), org: %{name: "Aurora Labs", slug: "Not A Slug"})
      |> render_submit()

      slug_error = view |> element(~s([data-role="org-slug-error"])) |> render()
      assert slug_error =~ "must start with a lowercase letter"

      assert count_orgs_with_slug("Not A Slug") == 0
    end
  end
end
