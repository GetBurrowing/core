defmodule PlatformWeb.SkillsLiveProjectScopeTest do
  @moduledoc """
  The skill-detail surface renders an "Attach to project…" `<select>` whose
  options came from the unscoped project list, so every authenticated user
  could read the NAME of every project in every org from `/skills/:slug`.

  These assertions are about the RENDERED `<option>` set, not about the return
  value of `Tasks.list_projects_for_user/2` — that context-level coverage lives
  with the function itself. The positive control is mandatory: assigning `[]`
  for everybody would satisfy the absence assertion while breaking the feature.

  The already-attached case is a second, independent signal: it proves the
  scope change did not disturb the `Enum.reject` on `attached_project_ids`.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Skills.Skill
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # `@example.com` keeps `Tenancy.derive_role_from_email/1` at `:member`;
  # a `@example.com` address would derive admin and blanket-bypass the scope
  # these tests pin.
  defp user!(role, org_id) do
    user =
      Repo.insert!(%User{
        email: "skills_scope_#{System.unique_integer([:positive])}@example.com",
        name: "Skills Scope User",
        oidc_sub: "oidc-skills-scope-#{System.unique_integer([:positive])}"
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
        slug: "skills-scope-#{System.unique_integer([:positive])}",
        org_id: org_id
      })
      |> Repo.insert()

    project
  end

  defp skill! do
    {:ok, skill} =
      %Skill{}
      |> Skill.changeset(%{
        name: "Skills Scope Skill #{System.unique_integer([:positive])}",
        content: "body"
      })
      |> Repo.insert()

    skill
  end

  # Read the attach picker's own options rather than the whole document, so a
  # project name appearing elsewhere on the page can never make an assertion
  # pass or fail for the wrong reason. `Floki` is not a dependency here;
  # LiveView 1.1 ships `lazy_html`.
  defp option_texts(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select[name=project_id] option")
    |> Enum.map(fn node -> node |> LazyHTML.text() |> String.trim() end)
  end

  defp seed do
    fabrikam_org_id = Platform.TenancyFixtures.fabrikam_org_id()
    tenant_org_id = Platform.TenancyFixtures.tenant_org_id("sxi")

    own = project!(fabrikam_org_id, "Own Fabrikam Project #{System.unique_integer([:positive])}")
    foreign = project!(tenant_org_id, "Foreign Project #{System.unique_integer([:positive])}")

    %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign, skill: skill!()}
  end

  # The plain member is seeded into a TENANT org, not the root org. Per Rowan's
  # 2026-08-05 sub-orgs ruling, sub-orgs are filtering mechanisms rather than
  # walls, so `Tenancy.visibility/1` returns `:root_all` for a root member at
  # ANY role — a root-org viewer would see every tenant's project and make this
  # absence assertion unsatisfiable by design. Only a non-root viewer exercises
  # the org filter.
  test "a plain member is not offered a foreign org's project", %{conn: conn} do
    %{skill: skill} = seed()
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
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")

    options = option_texts(html)

    # Positive control — without it, `@all_projects == []` passes the refute.
    assert own.name in options
    refute foreign.name in options
  end

  test "a Fabrikam root admin is offered both orgs' projects", %{conn: conn} do
    %{fabrikam_org_id: fabrikam_org_id, own: own, foreign: foreign, skill: skill} = seed()
    admin = user!("admin", fabrikam_org_id)

    assert Tenancy.fabrikam_admin?(admin) == true

    conn = init_test_session(conn, current_user_id: admin.id)
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")

    options = option_texts(html)

    assert own.name in options
    assert foreign.name in options
  end

  test "an already-attached project drops out of the picker", %{conn: conn} do
    %{fabrikam_org_id: fabrikam_org_id, own: own, skill: skill} = seed()
    user = user!("member", fabrikam_org_id)
    refute Tenancy.fabrikam_admin?(user)

    conn = init_test_session(conn, current_user_id: user.id)

    # Before: offered.
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")
    assert own.name in option_texts(html)

    {:ok, _attachment} = Skills.attach_skill(skill.id, "project", own.id)

    # After: rejected by `attached_project_ids`, not by the org scope.
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")
    refute own.name in option_texts(html)
  end
end
