defmodule PlatformWeb.MeetingLiveProjectScopeTest do
  @moduledoc """
  The `/meetings` index start-meeting sheet renders a project `<select>`.
  Before this test's companion change it was populated from an unscoped
  `Tasks.list_projects_unscoped/1`, so every authenticated user saw the NAME of
  every project in every org.

  These assertions are deliberately about the RENDERED `<option>` SET, not
  about the return value of `Tasks.list_projects_for_user/2` — that
  context-level coverage lives with the function itself. The point here is
  that the LiveView actually passes a viewer through.

  The positive controls are mandatory: an implementation that assigns `[]`
  to `@projects` for everybody would satisfy the absence assertion alone
  while breaking the feature.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # `@example.com` keeps `Tenancy.derive_role_from_email/1` at `:member`;
  # a `@example.com` address would derive admin and blanket-bypass the very
  # scope these tests pin.
  defp user!(role, org_id) do
    user =
      Repo.insert!(%User{
        email: "meeting_scope_#{System.unique_integer([:positive])}@example.com",
        name: "Meeting Scope User",
        oidc_sub: "oidc-meeting-scope-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id, name) do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: name,
        slug: "meeting-scope-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  defp project_option_texts(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select[data-role=start-meeting-project] option")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp seed do
    fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
    tenant_org_id = Platform.TenancyFixtures.tenant_org_id("sxi")

    own = project!(fabrikam_org_id, "Own Fabrikam Project #{System.unique_integer([:positive])}")
    foreign = project!(tenant_org_id, "Foreign Project #{System.unique_integer([:positive])}")

    %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign}
  end

  describe "start-meeting project picker scoping" do
    # The plain member is seeded into a TENANT org, not the root org. Per
    # Rowan's 2026-08-05 sub-orgs ruling, sub-orgs are filtering mechanisms
    # rather than walls, so `Tenancy.visibility/1` returns `:root_all` for a
    # root member at ANY role — a root-org viewer would see every tenant's
    # project and make this absence assertion unsatisfiable by design. Only a
    # non-root viewer exercises the org filter.
    test "a plain member does not see a foreign org's project name", %{conn: conn} do
      own_org_id = Platform.TenancyFixtures.tenant_org_id("soylent")
      own = project!(own_org_id, "Own Tenant Project #{System.unique_integer([:positive])}")

      foreign =
        project!(
          Platform.TenancyFixtures.tenant_org_id("sxi"),
          "Foreign Project #{System.unique_integer([:positive])}"
        )

      user = user!("member", own_org_id)

      # Preconditions: an admin viewer bypasses the scope by design, and a
      # root-org viewer sees everything by design. Either would make a broken
      # filter look correct.
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, "/meetings")

      # The picker only renders inside the start-meeting sheet, which the
      # FAB opens; the dead render never contains it.
      options =
        view
        |> element("[data-role=start-meeting-fab]")
        |> render_click()
        |> project_option_texts()

      # Positive control — without it, `@projects == []` passes the refute.
      assert own.name in options
      refute foreign.name in options
    end

    test "a Fabrikam root admin sees both orgs' projects", %{conn: conn} do
      %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign} = seed()
      admin = user!("admin", fabrikam_org_id)

      assert Tenancy.fabrikam_admin?(admin) == true

      conn = init_test_session(conn, current_user_id: admin.id)
      {:ok, view, _html} = live(conn, "/meetings")

      options =
        view
        |> element("[data-role=start-meeting-fab]")
        |> render_click()
        |> project_option_texts()

      assert own.name in options
      assert foreign.name in options
    end
  end
end
