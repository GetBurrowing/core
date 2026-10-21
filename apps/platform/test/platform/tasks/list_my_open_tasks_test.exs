defmodule Platform.Tasks.ListMyOpenTasksTest do
  @moduledoc """
  `Tasks.list_my_open_tasks/2` (task 01a1557a-b20a stage 1): the open tasks a
  user sponsors or is assigned to AS A USER in any phase.

  Rows are shaped with `Repo.update_all` so status, sponsor, flat assignee and
  phase slots can be set exactly, without the assignment API's side effects.
  Every absence is preceded on the same fixture by a positive control.

  `async: false` because the access-scope case creates tenant orgs and
  grants, as `Platform.Access.TasksScopeTest` does.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()
    Repo.insert!(%User{email: "mine-#{n}@example.com", name: "Mine #{n}", oidc_sub: "mine-#{n}"})
  end

  defp project!(attrs \\ %{}),
    do: elem(Tasks.create_project(Map.merge(%{name: "Mine Proj #{u()}"}, attrs)), 1)

  defp slot(id, type), do: %{"assignee_id" => id, "assignee_type" => type}

  defp seed(project, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "mine #{u()}"})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp ids(tasks), do: tasks |> Enum.map(& &1.id) |> MapSet.new()

  setup do
    %{me: user!(), other: user!(), p: project!()}
  end

  test "a sponsored task is returned, another user's is not", %{me: me, other: other, p: p} do
    mine = seed(p, sponsor_user_id: me.id)
    theirs = seed(p, sponsor_user_id: other.id)

    assert theirs.id in ids(Tasks.list_my_open_tasks(other.id)), "positive control"
    got = ids(Tasks.list_my_open_tasks(me.id))
    assert mine.id in got
    refute theirs.id in got
  end

  test "a user assignee only in a phase_assignees slot is returned", %{me: me, p: p} do
    other_flat = Ecto.UUID.generate()

    t =
      seed(p,
        assignee_id: other_flat,
        assignee_type: "agent",
        phase_assignees: %{"review" => slot(me.id, "user")}
      )

    assert Repo.get!(Task, t.id).assignee_id == other_flat
    assert t.id in ids(Tasks.list_my_open_tasks(me.id))
  end

  test "a user assignee in the flat column is returned", %{me: me, p: p} do
    t = seed(p, assignee_id: me.id, assignee_type: "user", phase_assignees: %{})
    assert t.id in ids(Tasks.list_my_open_tasks(me.id))
  end

  test "the same id as an AGENT assignee is not returned", %{me: me, p: p} do
    flat = seed(p, assignee_id: me.id, assignee_type: "agent", phase_assignees: %{})

    slotted =
      seed(p,
        assignee_id: nil,
        assignee_type: nil,
        phase_assignees: %{"execution" => slot(me.id, "agent")}
      )

    # Positive control: an untyped assignee filter finds both rows.
    assert MapSet.subset?(
             ids([flat, slotted]),
             ids(Tasks.list_tasks(assignee_id: me.id))
           )

    got = ids(Tasks.list_my_open_tasks(me.id))
    refute flat.id in got
    refute slotted.id in got
  end

  test "done and cancelled are excluded; every other status is included", %{me: me, p: p} do
    open = Task.statuses() -- ~w(done cancelled)
    assert open != [], "positive control: there is at least one open status"
    assert "stack_pending" in open

    by_status =
      Map.new(Task.statuses(), fn status ->
        {status, seed(p, sponsor_user_id: me.id, status: status)}
      end)

    got = ids(Tasks.list_my_open_tasks(me.id))

    for status <- open, do: assert(by_status[status].id in got, "#{status} must be open")
    refute by_status["done"].id in got
    refute by_status["cancelled"].id in got
  end

  test "a sponsored stack_pending task is returned", %{me: me, p: p} do
    t = seed(p, sponsor_user_id: me.id, status: "stack_pending")
    assert t.id in ids(Tasks.list_my_open_tasks(me.id))
  end

  test "a soft-deleted task is excluded", %{me: me, p: p} do
    t = seed(p, sponsor_user_id: me.id)
    assert t.id in ids(Tasks.list_my_open_tasks(me.id)), "positive control"

    {1, _} =
      Repo.update_all(from(x in Task, where: x.id == ^t.id),
        set: [deleted_at: DateTime.utc_now()]
      )

    refute t.id in ids(Tasks.list_my_open_tasks(me.id))
  end

  test "nil, non-binary and non-UUID user ids return []", %{me: me, p: p} do
    _ = seed(p, sponsor_user_id: me.id)
    assert Tasks.list_my_open_tasks(nil) == []
    assert Tasks.list_my_open_tasks(123) == []
    assert Tasks.list_my_open_tasks("not-a-uuid") == []
  end

  test "plans and project are preloaded", %{me: me, p: p} do
    _ = seed(p, sponsor_user_id: me.id)
    assert [task] = Tasks.list_my_open_tasks(me.id)
    assert is_list(task.plans)
    assert task.project.id == p.id
  end

  describe "access scope" do
    test "a deny on the project drops the row even though the user sponsors it" do
      _root = Platform.TenancyFixtures.acme_org_id()
      org = Platform.TenancyFixtures.tenant_org_id("globex")
      me = user!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: me.id, org_id: org, role: "member"})
      |> Repo.insert!()

      p = project!(%{org_id: org})
      q = project!(%{org_id: org})
      tp = seed(p, sponsor_user_id: me.id)
      tq = seed(q, sponsor_user_id: me.id)

      scope = fn -> Scope.for_user(Accounts.get_user(me.id)) end

      before = ids(Tasks.list_my_open_tasks(me.id, access_scope: scope.()))
      assert MapSet.subset?(ids([tp, tq]), before), "positive control"

      {:ok, _} = Grants.deny(%{principal: me, permission: "tasks.read", resource: q})

      got = ids(Tasks.list_my_open_tasks(me.id, access_scope: scope.()))
      assert tp.id in got
      refute tq.id in got
    end
  end
end
