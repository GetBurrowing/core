defmodule Platform.Access.TaskTargetTest do
  @moduledoc """
  `Platform.Access.TaskTarget.resolve/1` and `Platform.Access.task_target/3`
  (task 01a1472d stage 1): every target form resolves to the typed resource
  that owns it, an invalid UUID and a missing row are both `:not_found`, and
  the decision is the org-fenced `can?/3` (orgs: `org_fence/1`).
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{Grants, Scope, TaskTarget}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.{Epic, Plan, ReviewItem, ReviewRequest, Stack, Stage, Task, Validation}
  alias Platform.Tenancy.OrgMembership

  defp n, do: System.unique_integer([:positive])

  defp user!(tag, org, role \\ "member") do
    i = n()

    u =
      Repo.insert!(%User{
        email: "tt-#{tag}-#{i}@example.com",
        name: "TT #{tag} #{i}",
        oidc_sub: "tt-#{tag}-#{i}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: role})
    |> Repo.insert!()

    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp world!(org) do
    i = n()
    {:ok, project} = Platform.Tasks.create_project(%{name: "tt-#{i}", org_id: org})
    epic = Repo.insert!(%Epic{project_id: project.id, name: "tt epic #{i}"})

    stack =
      Repo.insert!(%Stack{
        project_id: project.id,
        slug: "tt-#{i}",
        name: "tt stack #{i}",
        rollup_branch: "stack/tt-#{i}"
      })

    task = Repo.insert!(%Task{project_id: project.id, title: "tt task #{i}", status: "backlog"})
    plan = Repo.insert!(%Plan{task_id: task.id, status: "pending_review", version: 1})
    stage = Repo.insert!(%Stage{plan_id: plan.id, position: 1, name: "s"})
    validation = Repo.insert!(%Validation{stage_id: stage.id, kind: "manual_approval"})

    request =
      Repo.insert!(%ReviewRequest{
        validation_id: validation.id,
        task_id: task.id,
        status: "pending",
        submitted_by: "tt"
      })

    item = Repo.insert!(%ReviewItem{review_request_id: request.id, label: "i"})

    space =
      %Space{}
      |> Space.changeset(%{kind: "channel", name: "tt-#{i}", slug: "tt-#{i}", org_id: org})
      |> Repo.insert!()

    %{
      org: org,
      project: project,
      epic: epic,
      stack: stack,
      task: task,
      plan: plan,
      stage: stage,
      validation: validation,
      request: request,
      item: item,
      space: space
    }
  end

  setup do
    root = acme_org_id()
    s = tenant_org_id("tt_s_#{n()}")
    %{root: root, s: s, r: world!(root), w: world!(s)}
  end

  describe "resolve/1" do
    test "every form resolves to the typed resource that owns it", %{w: w} do
      task = {:task, w.task.id}

      assert TaskTarget.resolve({:task, w.task.id}) == {:ok, task}
      assert TaskTarget.resolve({:project, w.project.id}) == {:ok, {:project, w.project.id}}
      assert TaskTarget.resolve({:stack, w.stack.id}) == {:ok, {:stack, w.stack.id}}
      assert TaskTarget.resolve({:space, w.space.id}) == {:ok, {:space, w.space.id}}
      assert TaskTarget.resolve({:org, w.org}) == {:ok, {:org, w.org}}
      assert TaskTarget.resolve({:plan, w.plan.id}) == {:ok, task}
      assert TaskTarget.resolve({:stage, w.stage.id}) == {:ok, task}
      assert TaskTarget.resolve({:validation, w.validation.id}) == {:ok, task}
      assert TaskTarget.resolve({:review_request, w.request.id}) == {:ok, task}
      assert TaskTarget.resolve({:review_item, w.item.id}) == {:ok, task}
      assert TaskTarget.resolve({:epic, w.epic.id}) == {:ok, {:project, w.project.id}}
    end

    test "an uppercase id resolves to the canonical lowercase one", %{w: w} do
      assert TaskTarget.resolve({:task, String.upcase(w.task.id)}) == {:ok, {:task, w.task.id}}
    end

    test "an invalid UUID, a 16-byte slug, a missing row and an unknown form are :not_found" do
      for form <- TaskTarget.forms() do
        assert TaskTarget.resolve({form, "higgins"}) == :not_found
        assert TaskTarget.resolve({form, "higginshigginsxx"}) == :not_found
        assert TaskTarget.resolve({form, Ecto.UUID.generate()}) == :not_found
        assert TaskTarget.resolve({form, nil}) == :not_found
      end

      assert TaskTarget.resolve({:canvas_thing, Ecto.UUID.generate()}) == :not_found
      assert TaskTarget.resolve(nil) == :not_found
    end
  end

  describe "task_target/3" do
    test "a fenced member gets its own targets and :not_found for every R one", ctx do
      m = scope(user!("m", ctx.s))

      for {form, own, foreign} <- forms(ctx.w, ctx.r) do
        assert {:ok, _} = Access.task_target(m, {form, own}, "tasks.write"), "#{form} own"
        assert Access.task_target(m, {form, foreign}, "tasks.write") == :not_found, "#{form}"
        assert Access.task_target(m, {form, foreign}, "tasks.read") == :not_found, "#{form}"
      end

      assert Access.task_target(m, {:task, Ecto.UUID.generate()}, "tasks.write") == :not_found
    end

    test "a root member and a root admin get both sides", ctx do
      for actor <- [user!("rm", ctx.root), user!("ra", ctx.root, "admin")],
          {form, own, foreign} <- forms(ctx.w, ctx.r) do
        s = scope(actor)
        assert {:ok, _} = Access.task_target(s, {form, own}, "tasks.write")
        assert {:ok, _} = Access.task_target(s, {form, foreign}, "tasks.write")
      end
    end

    test "a list is all-or-nothing and returns every typed resource in order", ctx do
      m = scope(user!("m", ctx.s))

      assert Access.task_target(
               m,
               [{:project, ctx.w.project.id}, {:plan, ctx.w.plan.id}],
               "tasks.write"
             ) ==
               {:ok, [{:project, ctx.w.project.id}, {:task, ctx.w.task.id}]}

      assert Access.task_target(
               m,
               [{:project, ctx.w.project.id}, {:epic, ctx.r.epic.id}],
               "tasks.write"
             ) ==
               :not_found

      assert Access.task_target(m, [], "tasks.write") == {:ok, []}
    end

    test "a tasks.write deny refuses its holder on writes only", ctx do
      rm = user!("rm", ctx.root)
      {:ok, _} = Grants.deny(%{principal: rm, permission: "tasks.write", resource: ctx.r.project})
      s = scope(rm)

      assert Access.task_target(s, {:task, ctx.r.task.id}, "tasks.write") == :not_found
      assert {:ok, _} = Access.task_target(s, {:task, ctx.r.task.id}, "tasks.read")
      assert {:ok, _} = Access.task_target(s, {:task, ctx.w.task.id}, "tasks.write")
    end

    test "an org outside the fence is :not_found; a missing scope or bad permission refuses",
         ctx do
      m = scope(user!("m", ctx.s))
      assert Access.task_target(m, {:org, ctx.root}, "tasks.write") == :not_found
      assert {:ok, {:org, _}} = Access.task_target(m, {:org, ctx.s}, "tasks.write")
      assert Access.task_target(nil, {:task, ctx.w.task.id}, "tasks.write") == :not_found

      assert Access.task_target(m, {:task, ctx.w.task.id}, "tasks.manage") == :not_found
    end
  end

  defp forms(own, foreign) do
    for key <- [
          :task,
          :project,
          :stack,
          :plan,
          :stage,
          :validation,
          :review_request,
          :review_item,
          :epic,
          :space
        ] do
      field = %{review_request: :request, review_item: :item}[key] || key
      {key, Map.fetch!(own, field).id, Map.fetch!(foreign, field).id}
    end
  end
end
