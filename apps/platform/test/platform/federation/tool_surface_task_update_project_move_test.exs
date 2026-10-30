defmodule Platform.Federation.ToolSurfaceTaskUpdateProjectMoveTest do
  @moduledoc """
  Task 01a18d37 stage 1: `task_update` re-files a task into another project.

  The cast (`Task.changeset/2`) and the two-sided write fence
  (`@task_write_targets`) already existed; this stage declares `project_id`
  in the tool schema, keeps the task's stack and epic consistent with the
  new project (`Tasks.apply_task_update/3`), and records ONE
  `platform.tasks.project_moved` audit row per successful move.

  The caller is a runtime owned by an internal member of a sub-org S, so
  the fence is real: S projects are writable, a root-org project is not.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Audit.Event
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Epic, Stack, Task}
  alias Platform.Tenancy.OrgMembership

  @event "platform.tasks.project_moved"
  @profile AgentRuntime.default_tool_profile() ++ ~w(task plan review)

  defp n, do: System.unique_integer([:positive])

  defp project!(org) do
    {:ok, project} = Tasks.create_project(%{name: "pmove-#{n()}", org_id: org})
    project
  end

  defp epic!(project), do: Repo.insert!(%Epic{project_id: project.id, name: "pmove epic #{n()}"})

  defp task!(project, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Task{project_id: project.id, title: "pmove task #{n()}", status: "backlog"},
        attrs
      )
    )
  end

  # A runtime owned by an internal member of `org`, carrying the bundles
  # that map to tasks.write, so only the owner's fence can refuse it.
  defp runtime_context!(org) do
    i = n()

    user =
      Repo.insert!(%User{
        email: "pmove-#{i}@example.com",
        name: "Project move member #{i}",
        oidc_sub: "pmove-#{i}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org, role: "member"})
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "pmove-agent-#{i}", name: "Project move #{i}", status: "active"})
      |> Repo.insert()

    raw = AgentRuntime.generate_token()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "pmove-rt-#{i}",
        owner_user_id: user.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        rt,
        @profile,
        Platform.Access.RuntimeProfiles.translated_permissions(@profile)
      )

    %{runtime_id: rt.runtime_id, agent_id: agent.id}
  end

  defp move_audits(task_id) do
    Repo.all(
      from(e in Event,
        where: e.event_type == @event and e.resource_id == ^task_id,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp update(ctx, args), do: ToolSurface.execute("task_update", args, ctx)

  setup do
    s = tenant_org_id("pmove_s_#{n()}")
    %{s: s, root: acme_org_id(), ctx: runtime_context!(s)}
  end

  describe "a permitted move" do
    test "changes project_id and records exactly one audit row", %{s: s, ctx: ctx} do
      a = project!(s)
      b = project!(s)
      task = task!(a)

      assert {:ok, result} = update(ctx, %{"task_id" => task.id, "project_id" => b.id})
      assert result.project_id == b.id
      assert Repo.get!(Task, task.id).project_id == b.id

      assert [audit] = move_audits(task.id)
      assert audit.action == "move"
      assert audit.resource_type == "task"
      assert audit.actor_type == "agent"
      assert audit.actor_id == ctx.agent_id

      assert audit.metadata == %{
               "from_project_id" => a.id,
               "to_project_id" => b.id,
               "cleared_epic_id" => nil,
               "via" => "mcp_task_update"
             }
    end

    test "clears an epic left in the old project and records it", %{s: s, ctx: ctx} do
      a = project!(s)
      b = project!(s)
      old_epic = epic!(a)
      task = task!(a, %{epic_id: old_epic.id})

      assert {:ok, _} = update(ctx, %{"task_id" => task.id, "project_id" => b.id})

      moved = Repo.get!(Task, task.id)
      assert moved.project_id == b.id
      assert moved.epic_id == nil

      assert [audit] = move_audits(task.id)
      assert audit.metadata["cleared_epic_id"] == old_epic.id
    end

    test "keeps an epic_id supplied from the new project", %{s: s, ctx: ctx} do
      a = project!(s)
      b = project!(s)
      task = task!(a, %{epic_id: epic!(a).id})
      new_epic = epic!(b)

      assert {:ok, _} =
               update(ctx, %{
                 "task_id" => task.id,
                 "project_id" => b.id,
                 "epic_id" => new_epic.id
               })

      moved = Repo.get!(Task, task.id)
      assert {moved.project_id, moved.epic_id} == {b.id, new_epic.id}
      assert [%{metadata: %{"cleared_epic_id" => nil}}] = move_audits(task.id)
    end
  end

  describe "refused moves write nothing" do
    test "an epic_id from a third project is refused", %{s: s, ctx: ctx} do
      a = project!(s)
      b = project!(s)
      c = project!(s)
      task = task!(a)
      before = Repo.get!(Task, task.id)

      assert {:error, error} =
               update(ctx, %{
                 "task_id" => task.id,
                 "project_id" => b.id,
                 "epic_id" => epic!(c).id
               })

      assert error.recoverable == true
      assert error.error =~ "epic_project_mismatch"
      assert error.error =~ "Nothing was written"

      after_row = Repo.get!(Task, task.id)
      assert after_row.project_id == a.id
      assert after_row.epic_id == nil
      assert after_row.updated_at == before.updated_at
      assert move_audits(task.id) == []
    end

    test "a stacked task is refused", %{s: s, ctx: ctx} do
      a = project!(s)
      b = project!(s)

      stack =
        Repo.insert!(%Stack{
          project_id: a.id,
          slug: "pmove-stack-#{n()}",
          name: "pmove stack",
          rollup_branch: "stack/pmove-#{n()}"
        })

      task = task!(a, %{stack_id: stack.id, stack_position: 1})
      before = Repo.get!(Task, task.id)

      assert {:error, error} = update(ctx, %{"task_id" => task.id, "project_id" => b.id})
      assert error.recoverable == true
      assert error.suggestion =~ "stack_eject"

      after_row = Repo.get!(Task, task.id)
      assert {after_row.project_id, after_row.stack_id} == {a.id, stack.id}
      assert after_row.updated_at == before.updated_at
      assert move_audits(task.id) == []
    end

    test "a target project outside the caller's write scope is the not-found answer",
         %{s: s, root: root, ctx: ctx} do
      a = project!(s)
      r = project!(root)
      task = task!(a)
      before = Repo.get!(Task, task.id)

      refused = update(ctx, %{"task_id" => task.id, "project_id" => r.id})
      random = Ecto.UUID.generate()

      expected =
        ctx
        |> update(%{"task_id" => task.id, "project_id" => random})
        |> inspect()
        |> String.replace(random, r.id)

      # Regression pin of the existing fence: indistinguishable from a
      # project that does not exist.
      assert inspect(refused) == expected
      assert {:error, _} = refused

      after_row = Repo.get!(Task, task.id)
      assert after_row.project_id == a.id
      assert after_row.updated_at == before.updated_at
      assert move_audits(task.id) == []
    end
  end

  describe "no move, no audit row" do
    test "an update that does not touch project_id", %{s: s, ctx: ctx} do
      a = project!(s)
      task = task!(a)

      assert {:ok, _} = update(ctx, %{"task_id" => task.id, "title" => "Renamed"})
      assert {:ok, _} = update(ctx, %{"task_id" => task.id, "project_id" => a.id})

      assert Repo.get!(Task, task.id).project_id == a.id
      assert move_audits(task.id) == []
    end
  end

  test "the task_update definition declares project_id" do
    tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "task_update"))

    assert %{type: "string", required: false, description: description} =
             tool.parameters.project_id

    assert description =~ "Move the task to another project"
    assert tool.description =~ "re-file the task into another project"
  end
end
