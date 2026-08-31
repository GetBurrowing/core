defmodule Platform.Orchestration.HeartbeatSchedulerRollupBackstopTest do
  @moduledoc """
  Task 01a05392 stage 4 — the missing-`rollup_branch_ready` backstop in
  `HeartbeatScheduler.stack_member_git_workflow_section/2`.

  Stage 1 stamps `rollup_branch_ready` synchronously before any root is
  promoted, so an execution dispatch for a member of an `in_progress` stack
  WITHOUT the stamp is an anomaly. The old else-arm quietly branched the member
  from `origin/<default_branch>` — manufacturing the very divergence stage 2
  escalates. It is now a LOUD backstop: it renders a stop-and-report section
  (no `git worktree add` at all) and files the same needs_human
  `execution.blocked` event stage 2 files, ONCE per task + rollup branch.

  `heartbeat_scheduler_test.exs` is `use ExUnit.Case` with plain-map fixtures
  and no DB ownership; it covers the rendered text. This file is DataCase
  because the event is a row, and the dedupe is a query.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  @stop_sentence "STOP — do not create a worktree or branch for this task"
  @retry_tool "stack_retry_member_merge"

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Rollup backstop #{uniq()}",
        repo_url: "https://github.com/test/rollup-backstop-#{uniq()}"
      })

    slug = "backstop-#{uniq()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: "main",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member #{uniq()}"})
    {:ok, _} = Stacks.add_task(stack, task)

    {:ok, project: project, stack: stack, task: task}
  end

  describe "member of an in_progress stack WITH the stamp (control)" do
    test "renders the rollup parent and the retry paragraph, and files NO blocker", %{
      stack: stack,
      task: task
    } do
      {:ok, _} = Stacks.update_stack(stack, %{status: "in_progress", metadata: ready_stamp()})

      prompt = render(task)

      assert prompt =~ "-b task/#{task.id} origin/#{stack.rollup_branch}"
      assert prompt =~ "git rebase origin/#{stack.rollup_branch} && git push --force-with-lease"
      assert prompt =~ "call `#{@retry_tool}` with `task_id` = `#{task.id}`"
      refute prompt =~ @stop_sentence

      # The control that separates "fires when the stamp is missing" from
      # "fires on every stack member": a ready member files nothing.
      assert blocked_events(task.id) == []
    end
  end

  describe "member of an in_progress stack WITHOUT the stamp" do
    test "renders the stop section and files one needs_human execution.blocked event", %{
      stack: stack,
      task: task
    } do
      {:ok, _} = Stacks.update_stack(stack, %{status: "in_progress"})

      log =
        capture_log(fn ->
          prompt = render(task)

          refute prompt =~ "git worktree add"
          refute prompt =~ "-b task/#{task.id} origin/main"
          assert prompt =~ @stop_sentence
          assert prompt =~ "rollup branch `origin/#{stack.rollup_branch}` has not been confirmed"
        end)

      assert log =~ "rollup not yet ready"

      assert [%RuntimeEvent{} = event] = blocked_events(task.id)
      assert event.event_type == "execution.blocked"
      assert event.phase == "execution"
      # Same seam as stage 2 — `StackDeployer.record_merge_blocker/3` owns the
      # canonical keys; the caller cannot downgrade `needs_human`.
      assert event.payload["needs_human"] == true
      assert event.payload["kind"] == "rollup_branch_missing"
      assert event.payload["member_task_id"] == task.id
      assert event.payload["stack_id"] == stack.id
      assert event.payload["rollup_branch"] == stack.rollup_branch
      assert event.payload["default_branch"] == "main"
      assert event.payload["description"] =~ "carries no `rollup_branch_ready` stamp"
      assert event.payload["description"] =~ "STOP rather than branch from origin/main"
    end

    test "a second render does not file a second blocker (dedupe on task + rollup_branch)", %{
      stack: stack,
      task: task
    } do
      {:ok, _} = Stacks.update_stack(stack, %{status: "in_progress"})

      # The dedupe logs at :info, which the test logger (pinned to :warning)
      # never emits — the row count is the assertion, not the log line.
      capture_log(fn ->
        _ = render(task)
        _ = render(task)
        _ = render(task)
      end)

      assert [%RuntimeEvent{}] = blocked_events(task.id)
    end

    test "the execution-phase assignee is addressed, falling back to the task assignee", %{
      stack: stack,
      task: task
    } do
      {:ok, _} = Stacks.update_stack(stack, %{status: "in_progress"})

      task_with_phase =
        task
        |> load()
        |> Map.put(:phase_assignees, %{"execution" => %{"assignee_id" => "agent-exec"}})
        |> Map.put(:assignee_id, "agent-current")

      capture_log(fn ->
        _ = HeartbeatScheduler.dispatch_prompt(task_with_phase, plan(), stage())
      end)

      assert [%RuntimeEvent{payload: %{"assignee_id" => "agent-exec"}}] = blocked_events(task.id)
    end
  end

  describe "member of a stack that is NOT in_progress, without the stamp" do
    test "renders the stop section but files nothing — only an in_progress stack is anomalous",
         %{stack: stack, task: task} do
      # `create_stack/1` defaults status to `forming`; assert rather than assume.
      assert Stacks.get_stack!(stack.id).status == "forming"

      capture_log(fn ->
        prompt = render(task)
        assert prompt =~ @stop_sentence
        refute prompt =~ "git worktree add"
      end)

      assert blocked_events(task.id) == []
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Reload with `:stack` preloaded (the shape `Tasks.get_task_detail/1` hands
  # the router) and put the task in the execution status the in_progress
  # dispatch template keys on. `create_task/1` defaults to `backlog`, and the
  # status machine would demand an approved plan to move it; the prompt
  # renderer only reads the field.
  defp load(task), do: task.id |> Tasks.get_task_detail() |> Map.put(:status, "in_progress")

  defp render(task), do: HeartbeatScheduler.dispatch_prompt(load(task), plan(), stage())

  defp plan, do: %{version: 1, stages: [%{}]}

  defp stage do
    %{
      id: "01a05392-backstop-stage",
      position: 1,
      name: "coding",
      description: "Backstop probe stage",
      validations: [%{id: "val-test-1", kind: "test_pass"}]
    }
  end

  defp ready_stamp do
    %{"rollup_branch_ready" => %{"at" => "2026-08-30T00:00:00Z", "base_sha" => "abc1234"}}
  end

  defp blocked_events(task_id) do
    RuntimeEvent
    |> where([e], e.task_id == ^task_id and e.event_type == "execution.blocked")
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()
end
