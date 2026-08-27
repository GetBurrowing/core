defmodule PlatformWeb.PlanApproveErrorLoggingTest do
  @moduledoc """
  Task 01a04516 — the diagnosis gap.

  `TaskDetailComponent.handle_event("plan_approve", …)` used to match
  `{:error, _}` and DISCARD the reason, flashing a constant string. That
  is why the 2026-08-11 approval outage produced a clean console and no
  server-side trace at all: the operator saw "Failed to approve plan."
  and the log said nothing, so the failing gate could not be identified
  from production output.

  The hotfix (`e3c00787`) added a `Logger.error` carrying the reason.
  Nothing pinned it, so a future refactor could drop it back to `_` and
  restore the blind spot silently. This is that pin.

  The failure is manufactured through the ADR-0046 architecture gate,
  which is the one deterministic `{:error, reason}` the handler can
  actually receive: an OPEN gate refuses any approval whose `approved_by`
  does not resolve to an `Accounts.User`. A live session whose user row
  has since been removed is exactly that shape.

  Not `async: true`: `approve_plan/3` broadcasts on `tasks:board`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  defp u, do: System.unique_integer([:positive])

  setup %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "plan_approve_log_#{u()}@example.com",
        name: "Approval Log User",
        oidc_sub: "oidc-plan-approve-log-#{u()}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    {:ok, project} = Tasks.create_project(%{name: "Approve Log Project #{u()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Approval logging fixture #{u()}",
        status: "planning"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1})
    {:ok, _stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      task: task,
      plan: plan
    }
  end

  # Park the plan in `pending_review` with the architecture gate OPEN,
  # without going through `submit_plan_for_review/1` — this test is about
  # the handler's error branch, not about how the gate came to be open.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, nil)
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    gated
  end

  defp click_approve(view, plan_id) do
    view
    |> element(~s{button[phx-click="plan_approve"][phx-value-plan-id="#{plan_id}"]})
    |> render_click()
  end

  describe "the plan_approve error branch" do
    test "logs the reason it used to discard", %{conn: conn, user: user, task: task, plan: plan} do
      gated = open_gate!(task, plan)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      # The session outlives the user row. `human_approver/1` now resolves
      # to nil, so the open gate refuses and `approve_plan/3` returns
      # `{:error, :architecture_gate_open}` — a real reason, reaching the
      # handler exactly as the freeze failure did in production.
      Repo.delete!(user)

      log = capture_log(fn -> click_approve(view, gated.id) end)

      # The REASON, not just the fact of a failure. A handler that logged
      # "approval failed" with no reason would pass a weaker assertion and
      # would still leave the outage undiagnosable.
      assert log =~ "architecture_gate_open"
      assert log =~ "plan_approve failed"

      # Identifying detail: which plan, on which task. Without these the
      # line cannot be tied to a report on a busy server.
      assert log =~ gated.id
      assert log =~ task.id

      # And it is an ERROR, not a debug line that production filters out.
      assert log =~ "[error]"
    end

    test "still shows the operator a flash and leaves the plan unapproved", %{
      conn: conn,
      user: user,
      task: task,
      plan: plan
    } do
      gated = open_gate!(task, plan)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      Repo.delete!(user)

      capture_log(fn -> click_approve(view, gated.id) end)

      # The detail panel is a LiveComponent; the flash arrives on the next
      # render pass (the component notifies the shell via send/2).
      assert render(view) =~ "Failed to approve plan."

      # Read the ROW: a logged error must not have been accompanied by a
      # partial write.
      reloaded = Repo.get!(Plan, gated.id)
      assert reloaded.status == "pending_review"
      assert reloaded.approved_by == nil
      assert reloaded.approved_at == nil
    end

    test "a SUCCESSFUL approval logs no error — the pin is not just 'something logs'", %{
      conn: conn,
      task: task,
      plan: plan
    } do
      # Same fixture, gate never opened, user still present. If this also
      # emitted an error line the assertions above would be satisfied by
      # noise rather than by the handler's error branch.
      {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      log = capture_log(fn -> click_approve(view, submitted.id) end)

      refute log =~ "plan_approve failed"
      assert Repo.get!(Plan, submitted.id).status == "approved"
    end
  end
end
