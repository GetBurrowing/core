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
  # a `@acme.test` address would derive admin and blanket-bypass the scope
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
    acme_org_id = Platform.TenancyFixtures.acme_org_id()
    tenant_org_id = Platform.TenancyFixtures.tenant_org_id("globex")

    own = project!(acme_org_id, "Own Acme Project #{System.unique_integer([:positive])}")
    foreign = project!(tenant_org_id, "Foreign Project #{System.unique_integer([:positive])}")

    %{acme_org_id: acme_org_id, own: own, foreign: foreign, skill: skill!()}
  end

  # The plain member is seeded into a TENANT org, not the root org. Per Alex's
  # 2026-08-05 sub-orgs ruling, sub-orgs are filtering mechanisms rather than
  # walls, so `Tenancy.visibility/1` returns `:root_all` for a root member at
  # ANY role — a root-org viewer would see every tenant's project and make this
  # absence assertion unsatisfiable by design. Only a non-root viewer exercises
  # the org filter.
  test "a plain member is not offered a foreign org's project", %{conn: conn} do
    %{skill: skill} = seed()
    own_org_id = Platform.TenancyFixtures.tenant_org_id("initech")
    own = project!(own_org_id, "Own Tenant Project #{System.unique_integer([:positive])}")

    foreign =
      project!(
        Platform.TenancyFixtures.tenant_org_id("globex"),
        "Foreign Project #{System.unique_integer([:positive])}"
      )

    user = user!("member", own_org_id)

    # Preconditions: an admin viewer bypasses the scope by design, and a
    # root-org viewer sees everything by design. Either would make a broken
    # filter look correct.
    refute Tenancy.root_admin?(user)
    refute Tenancy.root_member?(user)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")

    options = option_texts(html)

    # Positive control — without it, `@all_projects == []` passes the refute.
    assert own.name in options
    refute foreign.name in options
  end

  test "an Acme root admin is offered both orgs' projects", %{conn: conn} do
    %{acme_org_id: acme_org_id, own: own, foreign: foreign, skill: skill} = seed()
    admin = user!("admin", acme_org_id)

    assert Tenancy.root_admin?(admin) == true

    conn = init_test_session(conn, current_user_id: admin.id)
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")

    options = option_texts(html)

    assert own.name in options
    assert foreign.name in options
  end

  # Drawer width. Not a project-scope concern, but this is the only test that
  # mounts the skill-detail surface, so extending it is cheaper than a second
  # LiveView mount. The panel carries no `id` and no `data-role`, so it is
  # selected by the class recipe that is unique to it on this page.
  test "the skill detail panel carries the shared desktop width cap", %{conn: conn} do
    %{acme_org_id: acme_org_id, skill: skill} = seed()
    user = user!("member", acme_org_id)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, _view, html} = live(conn, "/skills/#{skill.slug}")

    panel_tag = Regex.run(~r/<div[^>]*class="fixed top-0[^"]*max-w-2xl[^"]*"[^>]*>/, html)
    refute is_nil(panel_tag), "expected the skill detail panel container to render"
    [panel_tag] = panel_tag

    # Full-bleed on a phone; the base `max-w-2xl` still governs below `lg`.
    assert panel_tag =~ "w-full"
    assert panel_tag =~ "max-w-2xl"

    # The shared cap above 1024px. `min(60vw,60rem)` is 234px on a 390px
    # phone, so the `lg:` prefix is what keeps mobile full-bleed — asserted
    # here as a literal so dropping the prefix fails this test.
    assert panel_tag =~ "lg:max-w-[min(60vw,60rem)]"
  end

  test "an already-attached project drops out of the picker", %{conn: conn} do
    %{acme_org_id: acme_org_id, own: own, skill: skill} = seed()
    user = user!("member", acme_org_id)
    refute Tenancy.root_admin?(user)

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
