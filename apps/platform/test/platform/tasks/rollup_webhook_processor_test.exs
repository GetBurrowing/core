defmodule Platform.Tasks.RollupWebhookProcessorTest do
  @moduledoc """
  Fan-out behaviour of `Platform.Tasks.RollupWebhookProcessor` for members
  that never entered execution (task 01a05393 stage 5, ADR 0045).

  A member still at `stack_pending` / `backlog` / `planning` when the
  rollup PR merges did not land. Before this stage it fell into the
  generic `unexpected_status:*` bucket and stayed put while the stack
  flipped to `done` — the "done stack with a stack_pending member" shape
  the two recovery Mix tasks exist for. Now it is cancelled with a
  `cancellation_note`, and the fact is recorded in the stack's
  `rollup_merge` anomaly report.

  Anti-vacuity: every member's status is seeded DELIBERATELY (`create_task/1`
  defaults to `backlog`), asserted BEFORE the fan-out, then asserted after.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Tasks
  alias Platform.Tasks.{RollupWebhookProcessor, Stacks, Task}

  # `StackDeployer.handle_rollup_pr_merged/2` kicks a rollup-branch delete
  # after the cascade; stub the git runner so nothing shells out.
  defmodule NoopRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, %{status: :created, base_sha: "beefbeef"}}

    @impl true
    def merge_member_into_rollup(_args), do: {:ok, %{status: :merged, merge_sha: "cafecafe"}}

    @impl true
    def open_stack_pr(_args), do: {:ok, %{number: 1, url: "https://github.com/test/repo/pull/1"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args), do: {:ok, %{status: :reverted, revert_sha: "revert00"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  @cancellation_note "rollup merged without this member"

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    Application.put_env(:platform, :stack_deployer, git_runner: NoopRunner, async: false)
    on_exit(fn -> Application.put_env(:platform, :stack_deployer, prev) end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "RollupWebhookProcessor #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/rollup-webhook-processor"
      })

    %{project: project}
  end

  describe "process_stack_merged_pr/4 — members that never entered execution" do
    test "cancels a stack_pending member with a note while the in_review sibling still lands",
         %{project: project} do
      pr_number = System.unique_integer([:positive])
      stack = build_deploying_stack!(project, pr_number)

      landed = add_member!(stack, project, 1, "in_review", pending_pr_merged: true)
      unlanded = add_member!(stack, project, 2, "stack_pending")

      # Beat 1: the excluded state is really seeded.
      assert Tasks.get_task_record(landed.id).status == "in_review"
      assert Tasks.get_task_record(unlanded.id).status == "stack_pending"
      refute Map.has_key?(Tasks.get_task_record(unlanded.id).metadata || %{}, "cancellation_note")

      # Beat 2: run the fan-out; the guard explains itself when it fires.
      log =
        capture_log(fn ->
          assert :ok =
                   RollupWebhookProcessor.process_stack_merged_pr(
                     stack,
                     pr_payload(pr_number),
                     DateTime.utc_now(),
                     nil
                   )
        end)

      assert log =~ "member task #{unlanded.id} was still \"stack_pending\""
      assert log =~ "rollup PR ##{pr_number} merged"
      assert log =~ "Stack #{stack.id} rollup fan-out"
      assert log =~ "cancelling it with cancellation_note="

      # Beat 3: the unlanded member is cancelled AND carries the note; the
      # member that landed is done (the rule LOSES for in_review) and
      # carries no note.
      reloaded_unlanded = Tasks.get_task_record(unlanded.id)
      assert reloaded_unlanded.status == "cancelled"
      assert reloaded_unlanded.metadata["cancellation_note"] == @cancellation_note
      assert reloaded_unlanded.metadata["cancelled_by_rollup_pr"] == pr_number

      reloaded_landed = Tasks.get_task_record(landed.id)
      assert reloaded_landed.status == "done"
      refute Map.has_key?(reloaded_landed.metadata || %{}, "cancellation_note")

      # The fact is in the processor's report, not only the log.
      stack_after = Stacks.get_stack(stack.id)
      assert stack_after.status == "done"
      report = stack_after.metadata["rollup_merge"]
      assert landed.id in report["members_passed"]
      refute unlanded.id in report["members_passed"]

      assert [anomaly] = report["anomalies"]
      assert anomaly["task_id"] == unlanded.id
      assert anomaly["member_status"] == "stack_pending"
      assert anomaly["reason"] == "cancelled_unlanded:stack_pending"
      assert anomaly["cancellation_note"] == @cancellation_note
      assert anomaly["rollup_pr_number"] == pr_number
    end

    for status <- ~w(backlog planning) do
      @tag seeded_status: status
      test "cancels a #{status} member with a note and reports it", %{
        project: project,
        seeded_status: status
      } do
        pr_number = System.unique_integer([:positive])
        stack = build_deploying_stack!(project, pr_number)

        landed = add_member!(stack, project, 1, "in_review", pending_pr_merged: true)
        unlanded = add_member!(stack, project, 2, status)

        assert Tasks.get_task_record(unlanded.id).status == status

        capture_log(fn ->
          assert :ok =
                   RollupWebhookProcessor.process_stack_merged_pr(
                     stack,
                     pr_payload(pr_number),
                     DateTime.utc_now(),
                     nil
                   )
        end)

        reloaded = Tasks.get_task_record(unlanded.id)
        assert reloaded.status == "cancelled"
        assert reloaded.metadata["cancellation_note"] == @cancellation_note
        assert Tasks.get_task_record(landed.id).status == "done"

        report = Stacks.get_stack(stack.id).metadata["rollup_merge"]
        assert [%{"task_id" => task_id, "reason" => reason}] = report["anomalies"]
        assert task_id == unlanded.id
        assert reason == "cancelled_unlanded:" <> status
      end
    end

    test "an already-done member is skipped idempotently, never cancelled", %{
      project: project
    } do
      pr_number = System.unique_integer([:positive])
      stack = build_deploying_stack!(project, pr_number)

      landed = add_member!(stack, project, 1, "in_review", pending_pr_merged: true)
      already_done = add_member!(stack, project, 2, "done")

      assert Tasks.get_task_record(already_done.id).status == "done"

      capture_log(fn ->
        assert :ok =
                 RollupWebhookProcessor.process_stack_merged_pr(
                   stack,
                   pr_payload(pr_number),
                   DateTime.utc_now(),
                   nil
                 )
      end)

      reloaded = Tasks.get_task_record(already_done.id)
      assert reloaded.status == "done"
      refute Map.has_key?(reloaded.metadata || %{}, "cancellation_note")
      assert Tasks.get_task_record(landed.id).status == "done"

      report = Stacks.get_stack(stack.id).metadata["rollup_merge"]
      assert [%{"task_id" => task_id, "reason" => "unexpected_status:done"}] = report["anomalies"]
      assert task_id == already_done.id
    end

    test "an in_review member alone is promoted to done with no note and no anomaly", %{
      project: project
    } do
      pr_number = System.unique_integer([:positive])
      stack = build_deploying_stack!(project, pr_number)
      landed = add_member!(stack, project, 1, "in_review", pending_pr_merged: true)

      assert Tasks.get_task_record(landed.id).status == "in_review"

      capture_log(fn ->
        assert :ok =
                 RollupWebhookProcessor.process_stack_merged_pr(
                   stack,
                   pr_payload(pr_number),
                   DateTime.utc_now(),
                   nil
                 )
      end)

      reloaded = Tasks.get_task_record(landed.id)
      assert reloaded.status == "done"
      refute Map.has_key?(reloaded.metadata || %{}, "cancellation_note")

      report = Stacks.get_stack(stack.id).metadata["rollup_merge"]
      assert report["anomalies"] == []
      assert report["members_passed"] == [landed.id]
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  # Stack in the "rollup PR merged, webhook arriving" shape: `deploying`,
  # `rollup_pr.number` stamped, rollup_branch set.
  defp build_deploying_stack!(project, pr_number) do
    slug = "rwp-#{pr_number}-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "RollupWebhookProcessor fixture #{slug}",
        base_branch: "main",
        rollup_branch: "stack/#{slug}",
        metadata: %{
          "rollup_pr" => %{
            "number" => pr_number,
            "url" => "https://github.com/test/repo/pull/#{pr_number}",
            "opened_at" => "2026-08-30T00:00:00Z"
          }
        }
      })

    # Bypass changeset validation to reach the pre-webhook steady state,
    # as the reprocess-rollup-pr and backfill tests do.
    stack
    |> Ecto.Changeset.change(status: "deploying")
    |> Repo.update!()
  end

  # Attach a member at an EXPLICIT status. `create_task/1` defaults to
  # `backlog`, so the status is written deliberately via `update_task/2`
  # (which does not consult the transition table). With
  # `pending_pr_merged: true` the member also gets an approved plan whose
  # running stage carries a pending `pr_merged` validation — the shape a
  # landed member has when the rollup PR merges.
  defp add_member!(stack, project, position, status, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "#{stack.slug} member #{position} (#{status})"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: position, status: status})

    if Keyword.get(opts, :pending_pr_merged, false) do
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Review",
          description: "Review stage"
        })

      {:ok, _} = Tasks.transition_stage(stage, "running")
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})
    end

    %Task{} = Tasks.get_task_record(task.id)
  end

  defp pr_payload(pr_number) do
    %{
      "number" => pr_number,
      "merged" => true,
      "merge_commit_sha" => "sha-#{pr_number}",
      "html_url" => "https://github.com/test/repo/pull/#{pr_number}",
      "merged_by" => %{"login" => "human-merger"},
      "user" => %{"login" => "opener"},
      "head" => %{"ref" => "stack/x"},
      "base" => %{"ref" => "main"}
    }
  end
end
