defmodule PlatformWeb.TasksMyTasksAssignTest do
  @moduledoc """
  `:my_tasks` / `:my_needs_you` on `/tasks` (task 01a1557a-b20a stage 1),
  written by `BoardHooks.refresh_board/1`.

  Nothing renders these assigns yet (the phone list is stage 2), so they are
  read from the LiveView process state. Each assertion runs after
  `:sys.get_state/1` has drained the mailbox, so a PubSub refresh has landed.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ReviewRequests, Task}

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%User{
      email: "my-tasks-#{n}@example.com",
      name: "My Tasks #{n}",
      oidc_sub: "my-tasks-#{n}"
    })
  end

  defp project! do
    {:ok, p} =
      Tasks.create_project(%{name: "My Tasks #{u()}", repo_url: "git@github.com:test/repo.git"})

    p
  end

  defp task!(project, title, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: title, status: "backlog"})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp my_ids(view), do: view |> assigns() |> Map.fetch!(:my_tasks) |> Enum.map(& &1.id)
  defp needs_you(view), do: view |> assigns() |> Map.fetch!(:my_needs_you)
  defp board_ids(view), do: view |> assigns() |> Map.fetch!(:all_tasks) |> Enum.map(& &1.id)

  defp mount(conn, user, path \\ "/tasks") do
    {:ok, view, _html} = live(init_test_session(conn, current_user_id: user.id), path)
    view
  end

  setup do
    me = user!()
    p = project!()
    sponsored = task!(p, "Sponsored by me", sponsor_user_id: me.id)
    unrelated = task!(p, "Someone else's", sponsor_user_id: user!().id)
    %{me: me, p: p, sponsored: sponsored, unrelated: unrelated}
  end

  test "holds only the viewer's task, and the board refresh keeps it current", ctx do
    view = mount(ctx.conn, ctx.me)

    # Positive control: the board itself carries both rows.
    assert MapSet.subset?(
             MapSet.new([ctx.sponsored.id, ctx.unrelated.id]),
             MapSet.new(board_ids(view))
           )

    assert my_ids(view) == [ctx.sponsored.id]

    # Through the context, which broadcasts on the board topic.
    {:ok, _} = Tasks.update_task(ctx.unrelated, %{sponsor_user_id: ctx.me.id})
    assert Enum.sort(my_ids(view)) == Enum.sort([ctx.sponsored.id, ctx.unrelated.id])

    {:ok, _} = Tasks.update_task(Repo.get!(Task, ctx.sponsored.id), %{status: "done"})
    assert my_ids(view) == [ctx.unrelated.id]
  end

  test "is independent of the board's ?sponsor= and ?q= filters", ctx do
    assigned =
      task!(ctx.p, "Assigned to me as a user",
        phase_assignees: %{"review" => %{"assignee_id" => ctx.me.id, "assignee_type" => "user"}}
      )

    view = mount(ctx.conn, ctx.me)
    expected = Enum.sort([ctx.sponsored.id, assigned.id])
    assert Enum.sort(my_ids(view)) == expected

    # ?sponsor=mine narrows the board and drops the assigned-only task from it.
    sponsor_view = mount(ctx.conn, ctx.me, "/tasks?sponsor=mine")
    refute assigned.id in board_ids(sponsor_view), "positive control: the board filter bites"
    assert Enum.sort(my_ids(sponsor_view)) == expected

    # A search that matches nothing.
    q = "zzz-no-such-task-#{u()}"
    search_view = mount(ctx.conn, ctx.me, "/tasks?q=#{q}")
    assert assigns(search_view).visible_task_count == 0, "positive control: the search bites"
    assert Enum.sort(my_ids(search_view)) == expected

    # Same view, patched: the filter change re-runs refresh_board/1.
    render_patch(view, "/tasks?sponsor=mine&q=#{q}")
    assert Enum.sort(my_ids(view)) == expected
  end

  test "a task with a pending ReviewRequest needs the viewer", ctx do
    view = mount(ctx.conn, ctx.me)
    refute MapSet.member?(needs_you(view), ctx.sponsored.id), "positive control"

    {:ok, plan} = Tasks.create_plan(%{task_id: ctx.sponsored.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
    {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, _} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: ctx.sponsored.id,
        items: [%{label: "Phone"}]
      })

    # Force one refresh through the funnel regardless of which broadcasts the
    # fixture path emitted.
    send(view.pid, {:task_updated, Repo.get!(Task, ctx.sponsored.id)})
    assert MapSet.member?(needs_you(view), ctx.sponsored.id)
    refute MapSet.member?(needs_you(view), ctx.unrelated.id)
  end

  test "a task whose plan is pending_review needs the viewer", ctx do
    {:ok, _plan} =
      %Platform.Tasks.Plan{}
      |> Platform.Tasks.Plan.changeset(%{
        task_id: ctx.sponsored.id,
        version: 1,
        status: "pending_review"
      })
      |> Repo.insert()

    view = mount(ctx.conn, ctx.me)
    assert MapSet.member?(needs_you(view), ctx.sponsored.id)
    assert MapSet.size(needs_you(view)) == 1
  end
end
