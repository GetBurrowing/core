defmodule PlatformWeb.GithubWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Changelog
  alias Platform.Tasks

  @github_webhook_path "/api/webhooks/github"

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Webhook Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/repo"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Fix something"
      })

    task
  end

  defp create_task_with_ci_validation! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CI Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/ci-repo"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Task with CI"
      })

    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        status: "approved"
      })

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: PR merge",
        description: "Deploy via PR merge"
      })

    {:ok, _} = Tasks.transition_stage(stage, "running")
    stage = Platform.Repo.get!(Platform.Tasks.Stage, stage.id)

    {:ok, ci_validation} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "ci_passed"
      })

    {:ok, pr_validation} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "pr_merged"
      })

    %{
      project: project,
      task: task,
      plan: plan,
      stage: stage,
      ci_validation: ci_validation,
      pr_validation: pr_validation
    }
  end

  defp merged_pr_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => true,
          "title" => "feat: add changelog module",
          "number" => System.unique_integer([:positive]),
          "html_url" => "https://github.com/test/repo/pull/1",
          "merge_commit_sha" => "abc123def456",
          "merged_at" => "2026-03-25T01:00:00Z",
          "body" => "Added the changelog module for tracking changes.",
          "user" => %{"login" => "dev-user"},
          "head" => %{"ref" => "feat/changelog"}
        }
      },
      overrides
    )
  end

  defp check_suite_payload(branch, conclusion) do
    %{
      "action" => "completed",
      "check_suite" => %{
        "head_branch" => branch,
        "conclusion" => conclusion,
        "head_sha" => "abc123",
        "url" => "https://api.github.com/repos/test/ci-repo/check-suites/12345"
      },
      "repository" => %{
        "html_url" => "https://github.com/test/ci-repo"
      }
    }
  end

  defp workflow_run_payload(branch, conclusion) do
    %{
      "action" => "completed",
      "workflow_run" => %{
        "head_branch" => branch,
        "conclusion" => conclusion,
        "head_sha" => "def456",
        "html_url" => "https://github.com/test/ci-repo/actions/runs/67890"
      },
      "repository" => %{
        "html_url" => "https://github.com/test/ci-repo"
      }
    }
  end

  # ── Merged PR tests (existing functionality) ────────────────────────────

  describe "POST #{@github_webhook_path} — merged PRs" do
    test "creates a changelog entry for a merged PR", %{conn: conn} do
      payload = merged_pr_payload()

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "created", "id" => id} = json_response(conn, 201)
      assert is_binary(id)

      entry = Changelog.get_entry(id)
      assert entry.title == "add changelog module"
      assert entry.tags == ["feature"]
      assert entry.author == "dev-user"
    end

    test "ignores non-merged closed PRs", %{conn: conn} do
      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => false,
            "title" => "not merged",
            "number" => 999
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end

    test "ignores non-pull_request events", %{conn: conn} do
      conn = post(conn, @github_webhook_path, %{"action" => "opened", "issue" => %{}})
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end

    test "links to task when branch contains task ID", %{conn: conn} do
      task = create_task!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "fix: resolve the thing",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/repo/pull/2",
            "merge_commit_sha" => "def456",
            "merged_at" => "2026-03-25T02:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "created", "id" => id} = json_response(conn, 201)
      entry = Changelog.get_entry(id)
      assert entry.task_id == task.id
      assert entry.tags == ["fix"]
    end

    test "deduplicates by PR number", %{conn: conn} do
      pr_number = System.unique_integer([:positive])

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: first",
            "number" => pr_number,
            "html_url" => "https://github.com/test/repo/pull/#{pr_number}",
            "merge_commit_sha" => "aaa",
            "merged_at" => "2026-03-25T01:00:00Z",
            "body" => "",
            "user" => %{"login" => "dev"},
            "head" => %{"ref" => "feat/thing"}
          }
        })

      conn1 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn1, 201)

      conn2 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "error"} = json_response(conn2, 422)
    end
  end

  # ── CI webhook tests ────────────────────────────────────────────────────

  describe "POST #{@github_webhook_path} — check_suite.completed" do
    test "evaluates ci_passed validation as passed on success", %{conn: conn} do
      %{task: task, ci_validation: ci_validation} = create_task_with_ci_validation!()

      branch = "task/#{task.id}"
      payload = check_suite_payload(branch, "success")

      conn = post(conn, @github_webhook_path, payload)

      assert %{
               "status" => "evaluated",
               "validation_id" => _id,
               "result" => "passed"
             } = json_response(conn, 201)

      # Verify the validation was actually updated
      updated = Platform.Repo.get!(Platform.Tasks.Validation, ci_validation.id)
      assert updated.status == "passed"
      assert updated.evaluated_by == "github_webhook"
      assert updated.evidence["event_type"] == "check_suite"
      assert updated.evidence["conclusion"] == "success"
      assert updated.evidence["sha"] == "abc123"
    end

    test "evaluates ci_passed validation as failed on failure", %{conn: conn} do
      %{task: task, ci_validation: ci_validation} = create_task_with_ci_validation!()

      branch = "task/#{task.id}"
      payload = check_suite_payload(branch, "failure")

      conn = post(conn, @github_webhook_path, payload)

      assert %{
               "status" => "evaluated",
               "result" => "failed"
             } = json_response(conn, 201)

      updated = Platform.Repo.get!(Platform.Tasks.Validation, ci_validation.id)
      assert updated.status == "failed"
      assert updated.evidence["conclusion"] == "failure"
    end

    test "ignores branches that don't match task pattern", %{conn: conn} do
      payload = check_suite_payload("main", "success")

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "branch does not match task pattern"} =
               json_response(conn, 200)
    end

    test "ignores when no pending ci_passed validation exists", %{conn: conn} do
      task = create_task!()
      branch = "task/#{task.id}"
      payload = check_suite_payload(branch, "success")

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "ignored", "reason" => "no pending ci_passed validation"} =
               json_response(conn, 200)
    end
  end

  describe "POST #{@github_webhook_path} — workflow_run.completed" do
    test "evaluates ci_passed validation as passed on success", %{conn: conn} do
      %{task: task, ci_validation: ci_validation} = create_task_with_ci_validation!()

      branch = "task/#{task.id}"
      payload = workflow_run_payload(branch, "success")

      conn = post(conn, @github_webhook_path, payload)

      assert %{
               "status" => "evaluated",
               "validation_id" => _id,
               "result" => "passed"
             } = json_response(conn, 201)

      updated = Platform.Repo.get!(Platform.Tasks.Validation, ci_validation.id)
      assert updated.status == "passed"
      assert updated.evaluated_by == "github_webhook"
      assert updated.evidence["event_type"] == "workflow_run"
      assert updated.evidence["sha"] == "def456"
    end

    test "evaluates ci_passed validation as failed on failure", %{conn: conn} do
      %{task: task, ci_validation: ci_validation} = create_task_with_ci_validation!()

      branch = "task/#{task.id}"
      payload = workflow_run_payload(branch, "failure")

      conn = post(conn, @github_webhook_path, payload)

      assert %{
               "status" => "evaluated",
               "result" => "failed"
             } = json_response(conn, 201)

      updated = Platform.Repo.get!(Platform.Tasks.Validation, ci_validation.id)
      assert updated.status == "failed"
    end
  end

  # ── pull_request.closed (merged) → pr_merged validation auto-eval ───────

  describe "POST #{@github_webhook_path} — merged PR auto-evaluates pr_merged" do
    test "marks pending pr_merged validation as passed with evidence", %{conn: conn} do
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: ship the thing",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/42",
            "merge_commit_sha" => "deadbeef0011",
            "merged_at" => "2026-05-05T12:34:56Z",
            "body" => "ships",
            "user" => %{"login" => "agent-bot"},
            "merged_by" => %{"login" => "human-merger"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      updated = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert updated.status == "passed"
      assert updated.evaluated_by == "github_webhook"
      assert updated.evidence["pr_url"] == "https://github.com/test/ci-repo/pull/42"
      assert updated.evidence["merge_commit_sha"] == "deadbeef0011"
      assert updated.evidence["merged_by"] == "human-merger"
      assert is_binary(updated.evidence["merged_at"])
    end

    test "falls back to PR author when merged_by is absent", %{conn: conn} do
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: no merger field",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/43",
            "merge_commit_sha" => "abc123",
            "merged_at" => "2026-05-05T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "fallback-author"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      updated = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert updated.status == "passed"
      assert updated.evidence["merged_by"] == "fallback-author"
    end

    test "is a no-op for tasks without a pending pr_merged validation", %{conn: conn} do
      task = create_task!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: no validation",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/repo/pull/100",
            "merge_commit_sha" => "feedface",
            "merged_at" => "2026-05-05T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "noone"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      # Webhook still succeeds (changelog entry is created); no validation exists to update.
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)
    end

    test "does not touch validations on stages owned by other tasks", %{conn: conn} do
      %{task: task_a, pr_validation: pr_validation_a} = create_task_with_ci_validation!()
      %{pr_validation: pr_validation_b} = create_task_with_ci_validation!()

      # Merge PR for task_a only
      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: merge A only",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/77",
            "merge_commit_sha" => "aaaaaaa",
            "merged_at" => "2026-05-05T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "rowan"},
            "head" => %{"ref" => "task/#{task_a.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      a_after = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation_a.id)
      b_after = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation_b.id)

      assert a_after.status == "passed"
      assert b_after.status == "pending"
    end
  end

  # ── HMAC signature verification tests ───────────────────────────────────

  describe "HMAC signature verification" do
    test "verify_hmac/3 returns true for valid signature" do
      body = ~s({"action": "completed"})
      secret = "test-secret-key"

      hex_digest =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :lower)

      signature = "sha256=#{hex_digest}"

      assert PlatformWeb.GithubWebhookController.verify_hmac(body, signature, secret)
    end

    test "verify_hmac/3 returns false for invalid signature" do
      body = ~s({"action": "completed"})
      secret = "test-secret-key"
      signature = "sha256=0000000000000000000000000000000000000000000000000000000000000000"

      refute PlatformWeb.GithubWebhookController.verify_hmac(body, signature, secret)
    end

    test "verify_hmac/3 returns false for malformed signature" do
      refute PlatformWeb.GithubWebhookController.verify_hmac("body", "not-sha256", "secret")
    end

    test "requests without signature header are allowed through (backward compat)", %{conn: conn} do
      # No x-hub-signature-256 header — should be allowed
      conn = post(conn, @github_webhook_path, %{"action" => "opened", "issue" => %{}})
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end
  end

  # ── Auto-merge query tests ─────────────────────────────────────────────

  # ── ADR 0041 (T5 stage 3): stack-member guards ──────────────────────────

  describe "stack-member pr_merged webhook guard" do
    alias Platform.Tasks.Stacks

    test "does NOT auto-pass a stack member's per-task pr_merged validation",
         %{conn: conn} do
      # Build a task with a pending pr_merged validation, then enroll it
      # into a stack. The per-task webhook MUST defer to T6's rollup-PR
      # fan-out and leave the validation pending.
      %{task: task, pr_validation: pr_validation, project: project} =
        create_task_with_ci_validation!()

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "guard-test-#{System.unique_integer([:positive])}",
          name: "Guard Test",
          rollup_branch: "stack/guard-test"
        })

      {:ok, _enrolled} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: stack member should defer",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/88",
            "merge_commit_sha" => "deadbabe",
            "merged_at" => "2026-05-12T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # Validation must remain pending — T6 owns this fan-out.
      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert reloaded.status == "pending"
    end

    test "non-stack tasks still auto-pass their pr_merged (regression guard)",
         %{conn: conn} do
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: lone task still passes",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/89",
            "merge_commit_sha" => "abc987",
            "merged_at" => "2026-05-12T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert reloaded.status == "passed"
    end
  end

  describe "find_pending_pr_merged_validation/1" do
    test "finds pending pr_merged validation on running deploy stage" do
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      found =
        PlatformWeb.GithubWebhookController.find_pending_pr_merged_validation(task.id)

      assert found != nil
      assert found.id == pr_validation.id
    end

    test "returns nil when no pending pr_merged validation exists" do
      task = create_task!()
      assert PlatformWeb.GithubWebhookController.find_pending_pr_merged_validation(task.id) == nil
    end

    test "finds ci_check kind validation (used when auto_merge is true)" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Auto Merge Query #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/auto-merge-query"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Auto merge query"})

      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Deploy: PR merge"
        })

      {:ok, _} = Tasks.transition_stage(stage, "running")

      {:ok, ci_check_val} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "ci_check"})

      found =
        PlatformWeb.GithubWebhookController.find_pending_pr_merged_validation(task.id)

      assert found != nil
      assert found.id == ci_check_val.id
    end
  end
end
