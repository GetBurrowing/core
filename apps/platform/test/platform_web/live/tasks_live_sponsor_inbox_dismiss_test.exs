defmodule PlatformWeb.TasksLiveSponsorInboxDismissTest do
  @moduledoc """
  Task 01a116ff: opening a task as its sponsor dismisses that task's
  `task_sponsor_assigned` inbox row.

  Both open paths run `PlatformWeb.TasksLive.handle_params/3`: the task pane
  (`select_task` -> `push_patch`) and the inbox deep link (`InboxLive` "open"
  -> `push_navigate` -> mount). The dismissal is scoped to the CURRENT user and
  to the one kind, so a `task_plan_review` row for the same task survives and a
  non-sponsor's visit clears nothing of the sponsor's.

  The rows are seeded with `Inbox.emit/1` rather than through a real sponsor
  assignment, so each case starts with exactly the rows it names. Every
  expected value is a literal (`nil` / not `nil`), never a value the code under
  test computed.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Inbox, Repo, Tasks}
  alias Platform.Inbox.Item

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "sponsor_dismiss_#{n}@example.com",
      name: "Sponsor Dismiss User #{n}",
      oidc_sub: "oidc-sponsor-dismiss-#{n}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Sponsor Dismiss Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Sponsored task"})
    task
  end

  defp emit!(user, task, kind) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: kind,
        source_type: "task",
        source_id: task.id,
        title: "Row #{kind}",
        url: "/tasks/#{task.id}"
      })

    item
  end

  test "the sponsor opening /tasks/:id dismisses the sponsor row and leaves the plan-review row",
       %{conn: conn} do
    sponsor = insert_user()
    task = create_task!()
    # A REAL pending_review plan: the shell's `Inbox.reconcile_for_user/1` runs
    # on mount and correctly dismisses a `task_plan_review` row whose task has
    # no pending plan, which would fail the survival assertion below for a
    # reason that has nothing to do with this change.
    {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "pending_review", version: 1})
    sponsor_row = emit!(sponsor, task, "task_sponsor_assigned")
    plan_row = emit!(sponsor, task, "task_plan_review")

    {:ok, _view, _html} = live(auth(conn, sponsor), ~p"/tasks/#{task.id}")

    assert Repo.get!(Item, sponsor_row.id).dismissed_at != nil
    assert Repo.get!(Item, plan_row.id).dismissed_at == nil

    # Idempotent: nothing left of this kind for the sponsor on this task.
    assert {:ok, 0} =
             Inbox.dismiss_by_source(sponsor.id, "task", task.id, kind: "task_sponsor_assigned")
  end

  test "opening the task from the board pane (select_task -> push_patch) dismisses the sponsor row",
       %{conn: conn} do
    sponsor = insert_user()
    task = create_task!()
    sponsor_row = emit!(sponsor, task, "task_sponsor_assigned")

    {:ok, view, _html} = live(auth(conn, sponsor), ~p"/tasks")

    # Mounting the board alone must not clear it.
    assert Repo.get!(Item, sponsor_row.id).dismissed_at == nil

    render_click(view, "select_task", %{"id" => task.id})

    assert Repo.get!(Item, sponsor_row.id).dismissed_at != nil
  end

  test "a non-sponsor opening the task clears nothing of the sponsor's", %{conn: conn} do
    sponsor = insert_user()
    other = insert_user()
    task = create_task!()
    sponsor_row = emit!(sponsor, task, "task_sponsor_assigned")

    {:ok, _view, _html} = live(auth(conn, other), ~p"/tasks/#{task.id}")

    assert Repo.get!(Item, sponsor_row.id).dismissed_at == nil
  end

  test "the inbox deep link (open -> push_navigate) dismisses the sponsor row, and the task page keeps it dismissed",
       %{conn: conn} do
    sponsor = insert_user()
    task = create_task!()
    sponsor_row = emit!(sponsor, task, "task_sponsor_assigned")
    conn = auth(conn, sponsor)

    {:ok, inbox, _html} = live(conn, ~p"/inbox")

    assert {:error, {:live_redirect, %{to: to}}} =
             render_click(inbox, "open", %{
               "id" => sponsor_row.id,
               "url" => "/tasks/#{task.id}"
             })

    assert to == "/tasks/#{task.id}"

    # Task 01a11703: the inbox's own "open" acknowledges every kind outside
    # `Inbox.action_kinds/0`, so the sponsor row is already dismissed, with
    # `dismissed_at == read_at`, before the task page mounts. (This asserted
    # `dismissed_at == nil` here while opening only marked read.)
    opened = Repo.get!(Item, sponsor_row.id)
    assert %DateTime{} = opened.dismissed_at
    assert opened.dismissed_at == opened.read_at

    {:ok, _view, _html} = live(conn, to)

    # The task page's dismiss is a no-op on an already-dismissed row: the
    # acknowledgement timestamp survives.
    assert Repo.get!(Item, sponsor_row.id).dismissed_at == opened.dismissed_at
  end
end
