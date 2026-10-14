defmodule Platform.Access.BoardPremiseTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 1, planner premise P5, MEASURED rather than read:
  the Tasks board is not viewer-scoped, so a sub-org member with no root-org
  row sees another org's tasks on `/tasks`, while project listing IS fenced to
  their orgs.

  This is why the built-in `member` role carries `tasks.read` at `"all"`
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Built-in roles`): any
  narrower rule would change what this user sees today. If this test ever
  fails because the board became viewer-scoped, the `member` mapping must be
  revisited with it; narrowing belongs to resource scoping (stack position 3),
  not to this member.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tenancy.OrgMembership

  test "a sub-org member sees a foreign org's tasks on the board, but not its projects", %{
    conn: conn
  } do
    own_org = tenant_org_id("rbac_p5_own")
    foreign_org = tenant_org_id("rbac_p5_foreign")
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "rbac-p5-#{n}@example.com",
        name: "P5 Sub-org Member #{n}",
        oidc_sub: "rbac-p5-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: own_org, role: "member"})
    |> Repo.insert!()

    # No root-org row: visibility/1 is {:orgs, [own_org]}, not :root_all.
    refute Platform.Tenancy.root_member?(user)
    assert Platform.Tenancy.visibility(user) == {:orgs, [own_org]}

    {:ok, foreign_project} =
      Tasks.create_project(%{
        name: "P5 Foreign #{n}",
        repo_url: "git@github.com:test/p5.git",
        org_id: foreign_org
      })

    foreign_tasks =
      for status <- ~w(backlog in_progress) do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: foreign_project.id,
            title: "P5 foreign #{status} #{n}",
            status: status,
            priority: "medium"
          })

        task
      end

    # The project listing is fenced to the viewer's orgs...
    refute foreign_project.id in Enum.map(Tasks.list_projects_for_user(user), & &1.id)

    # ...but the board is not.
    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/tasks")
    html = render(view)

    visible = for t <- foreign_tasks, html =~ ~s(data-task-id="#{t.id}"), do: t.id

    assert visible != [],
           "P5 is false on this base: the board hid every foreign-org task from a sub-org member"
  end
end
