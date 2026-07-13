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

  # ── ADR 0041 (T6 stages 1+2): rollup-PR webhook fan-out + stack done ───

  describe "stack rollup-branch webhook fan-out" do
    alias Platform.Tasks.Stacks

    # Build a stack with N members, each with an approved plan whose
    # running review stage carries a pending pr_merged validation. This
    # is the steady-state shape the rollup-PR webhook expects: every
    # member has just finished its review and is waiting for the rollup
    # PR's merge to flip pr_merged → passed.
    defp build_stack_with_members!(member_count, opts \\ []) when member_count > 0 do
      slug =
        Keyword.get(opts, :slug, "rollup-fanout-#{System.unique_integer([:positive])}")

      rollup_branch = "stack/#{slug}"

      {:ok, project} =
        Tasks.create_project(%{
          name: "Stack Rollup Fan-Out #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/stack-repo"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "Rollup Fan-Out",
          rollup_branch: rollup_branch
        })

      members =
        for position <- 1..member_count do
          {:ok, task} =
            Tasks.create_task(%{
              project_id: project.id,
              title: "Stack member #{position}"
            })

          # Steady-state shape per ADR 0041 §"Stack-level deploy": every
          # member is sitting at `in_review` with a pending pr_merged
          # validation on a running review stage, waiting for the rollup
          # PR to merge. The fan-out controller now requires this (an
          # unexpected status raises an `unexpected_status:*` anomaly).
          {:ok, task} =
            Tasks.update_task(task, %{
              stack_id: stack.id,
              stack_position: position,
              status: "in_review"
            })

          {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

          {:ok, stage} =
            Tasks.create_stage(%{
              plan_id: plan.id,
              position: 1,
              name: "Review",
              description: "Review stage"
            })

          {:ok, _} = Tasks.transition_stage(stage, "running")

          {:ok, pr_validation} =
            Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

          %{task: task, plan: plan, stage: stage, pr_validation: pr_validation}
        end

      %{project: project, stack: stack, rollup_branch: rollup_branch, members: members}
    end

    defp rollup_merged_payload(rollup_branch, overrides \\ %{}) do
      pr =
        Map.merge(
          %{
            "merged" => true,
            "title" => "feat: stack rollup",
            "number" => System.unique_integer([:positive]),
            "html_url" =>
              "https://github.com/test/stack-repo/pull/#{System.unique_integer([:positive])}",
            "merge_commit_sha" => "rollup#{System.unique_integer([:positive])}",
            "merged_at" => "2026-05-12T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "merge-bot"},
            "merged_by" => %{"login" => "human-merger"},
            "head" => %{"ref" => rollup_branch},
            # Stage 3 (T6 hardening): the rollup PR's base must match the
            # stack's base_branch (default "main") for the fan-out to fire.
            "base" => %{"ref" => "main"}
          },
          overrides
        )

      %{"action" => "closed", "pull_request" => pr}
    end

    test "happy path: 4 members all pass + stack transitions to done with rollup_merge metadata",
         %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stack_with_members!(4)

      merge_sha = "rollup-happy-#{System.unique_integer([:positive])}"

      payload =
        rollup_merged_payload(rollup_branch, %{
          "merge_commit_sha" => merge_sha,
          "merged_at" => "2026-05-12T13:00:00Z"
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      for %{pr_validation: pr_validation, task: task} <- members do
        updated = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)

        assert updated.status == "passed",
               "expected member #{task.id} pr_merged to be passed, got #{updated.status}"

        assert updated.evaluated_by == "github_webhook"
        assert updated.evidence["fanned_out_from_stack_rollup_pr"] == true
        assert updated.evidence["stack_id"] == stack.id
        assert updated.evidence["stack_rollup_branch"] == rollup_branch
        assert updated.evidence["member_task_id"] == task.id
      end

      # Stage 2: stack transitions to done with rollup_merge metadata.
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      rollup_merge = Map.get(reloaded_stack.metadata, "rollup_merge")
      assert is_map(rollup_merge)
      assert rollup_merge["merge_commit_sha"] == merge_sha
      assert is_binary(rollup_merge["merged_at"])
      assert rollup_merge["anomalies"] == []
      refute Map.has_key?(rollup_merge, "degraded")

      member_ids = Enum.map(members, & &1.task.id)
      assert Enum.sort(rollup_merge["members_passed"]) == Enum.sort(member_ids)
    end

    test "non-stack task branch still hits the per-task path (regression)",
         %{conn: conn} do
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      # Plain task/<uuid> branch, NOT a stack/<slug> branch.
      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: plain task PR",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/777",
            "merge_commit_sha" => "plain777",
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
      # Per-task path: evidence is NOT marked as a stack fan-out.
      refute Map.get(reloaded.evidence, "fanned_out_from_stack_rollup_pr")
    end

    test "partial anomalies: unexpected_status + no_pending_pr_merged are recorded per the T6 contract",
         %{conn: conn} do
      # Contract (T6 stage 3 / validation
      # 019e1a3d-936e-7456-b85c-b911132dd66a):
      #
      #   Stack S with 3 members.
      #     M1: in_review + pending pr_merged          → happy
      #     M2: in_progress + pending pr_merged        → unexpected_status anomaly
      #     M3: in_review + pr_merged ALREADY failed   → no_pending_pr_merged anomaly
      #
      #   Expected: M1 passed; M2 anomaly reason starts
      #   "unexpected_status:in_progress"; M3 anomaly reason
      #   "no_pending_pr_merged"; Stack → done; two anomalies; degraded unset
      #   because M1 passed.
      %{stack: stack, rollup_branch: rollup_branch, members: [m1, m2, m3]} =
        build_stack_with_members!(3)

      # Demote M2 to `in_progress`. Its pr_merged validation is LEFT
      # pending — the controller must NOT pass it, because the member
      # status is outside the accepted set (in_review/deploying).
      {:ok, _} = Tasks.update_task(m2.task, %{status: "in_progress"})

      # Pre-fail M3's pr_merged so the lookup for a *pending* one comes
      # back nil. M3's task status stays at `in_review` so the only
      # reason it lands in anomalies is no_pending_pr_merged.
      m3.pr_validation
      |> Platform.Tasks.Validation.changeset(%{status: "failed"})
      |> Platform.Repo.update!()

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # M1: passed with fan-out evidence.
      m1_reloaded = Platform.Repo.get!(Platform.Tasks.Validation, m1.pr_validation.id)
      assert m1_reloaded.status == "passed"
      assert m1_reloaded.evidence["fanned_out_from_stack_rollup_pr"] == true
      assert m1_reloaded.evidence["member_task_id"] == m1.task.id

      # M2: UNCHANGED. The fan-out saw an unexpected status and bailed
      # BEFORE touching the validation. Status stays "pending", and the
      # validation evidence carries no fan-out marker.
      m2_reloaded = Platform.Repo.get!(Platform.Tasks.Validation, m2.pr_validation.id)
      assert m2_reloaded.status == "pending"
      refute Map.get(m2_reloaded.evidence || %{}, "fanned_out_from_stack_rollup_pr")

      # M3: still failed (we set that up).
      m3_reloaded = Platform.Repo.get!(Platform.Tasks.Validation, m3.pr_validation.id)
      assert m3_reloaded.status == "failed"

      # Stack: done; members_passed has just M1; two anomalies; degraded
      # unset because at least one member (M1) actually passed.
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      rollup_merge = Map.get(reloaded_stack.metadata, "rollup_merge")
      assert is_map(rollup_merge)
      refute Map.has_key?(rollup_merge, "degraded")
      assert rollup_merge["members_passed"] == [m1.task.id]

      anomalies = rollup_merge["anomalies"]
      assert is_list(anomalies)
      assert length(anomalies) == 2

      anomalies_by_task = Map.new(anomalies, &{&1["task_id"], &1})

      m2_anomaly = Map.fetch!(anomalies_by_task, m2.task.id)
      assert m2_anomaly["reason"] == "unexpected_status:in_progress"
      assert m2_anomaly["member_status"] == "in_progress"
      assert is_binary(m2_anomaly["recorded_at"])

      m3_anomaly = Map.fetch!(anomalies_by_task, m3.task.id)
      assert m3_anomaly["reason"] == "no_pending_pr_merged"
      assert m3_anomaly["member_status"] == "in_review"
      assert is_binary(m3_anomaly["recorded_at"])
    end

    test "webhook for non-existent stack/<slug> branch is a no-op (no crash)",
         %{conn: conn} do
      # No stack with this rollup branch exists. Also no task/<uuid>
      # match. The webhook should accept the event, log nothing
      # actionable, and return 201 (the changelog entry still gets
      # created because the PR is otherwise valid).
      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: stale rollup branch",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/stack-repo/pull/999",
            "merge_commit_sha" => "stale999",
            "merged_at" => "2026-05-12T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "stack/does-not-exist-#{System.unique_integer([:positive])}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)
    end

    test "abandoned stack is skipped (no fan-out)", %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: [m1 | _]} =
        build_stack_with_members!(2,
          slug: "abandoned-stack-#{System.unique_integer([:positive])}"
        )

      # Mark the stack abandoned. The fan-out lookup excludes abandoned
      # stacks — a stale stack/<slug> branch in the repo should not
      # re-pass member validations.
      {:ok, _} = Stacks.update_stack(stack, %{status: "abandoned"})

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # Validation stays pending.
      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, m1.pr_validation.id)
      assert reloaded.status == "pending"
    end

    # ── Stage 2: degraded path + defensive rescue + idempotency ─────────────

    test "all anomalies: stack still transitions to done with degraded=true + ERROR log",
         %{conn: conn} do
      import ExUnit.CaptureLog

      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stack_with_members!(3,
          slug: "all-anomalies-#{System.unique_integer([:positive])}"
        )

      # Knock EVERY member's pr_merged validation out of "pending" so
      # every member becomes an anomaly during fan-out.
      for %{pr_validation: pr_validation} <- members do
        pr_validation
        |> Platform.Tasks.Validation.changeset(%{status: "passed"})
        |> Platform.Repo.update!()
      end

      payload = rollup_merged_payload(rollup_branch)

      log =
        capture_log(fn ->
          conn = post(conn, @github_webhook_path, payload)
          assert %{"status" => "created"} = json_response(conn, 201)
        end)

      # ERROR log fires because zero members passed.
      assert log =~ "ZERO passed members"
      assert log =~ "degraded"

      # Stack still transitions to done with degraded flag and empty
      # members_passed but populated anomalies.
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      rollup_merge = Map.get(reloaded_stack.metadata, "rollup_merge")
      assert is_map(rollup_merge)
      assert rollup_merge["degraded"] == true
      assert rollup_merge["members_passed"] == []
      assert length(rollup_merge["anomalies"]) == length(members)

      for anomaly <- rollup_merge["anomalies"] do
        assert is_binary(anomaly["task_id"])
        assert anomaly["reason"] == "no_pending_pr_merged"
      end
    end

    test "defensive: exception in stack path is caught, falls back to per-task path, returns 2xx",
         %{conn: conn} do
      import ExUnit.CaptureLog

      # Build BOTH a stack (so the fan-out branch is entered) and a
      # plain task whose branch is on the PR. The webhook should
      # rescue the induced exception and fall back to the per-task
      # path, which evaluates the per-task pr_merged validation.
      %{rollup_branch: rollup_branch} =
        build_stack_with_members!(2,
          slug: "rescue-test-#{System.unique_integer([:positive])}"
        )

      %{task: fallback_task, pr_validation: fallback_validation} =
        create_task_with_ci_validation!()

      # Use the test-only :webhook_stack_fault process-dict hook to make
      # process_stack_merged_pr/4 raise. Process-dict scope makes this
      # safe for `async: true` since Phoenix runs the controller in the
      # test's own process when invoked via `post/2`.
      Process.put(:webhook_stack_fault, :raise)

      try do
        payload =
          rollup_merged_payload(rollup_branch, %{
            "body" => "Task: #{fallback_task.id}"
          })

        log =
          capture_log(fn ->
            # Webhook STILL returns 2xx despite the rescued exception.
            conn = post(conn, @github_webhook_path, payload)
            assert %{"status" => "created"} = json_response(conn, 201)
          end)

        # ERROR logged with the exception detail.
        assert log =~ "Stack rollup fan-out raised"
        assert log =~ "synthetic webhook stack fault"

        # Fallback per-task path executed: the fallback task's
        # pr_merged validation (linked via the body's "Refs task ..."
        # extraction) is now passed.
        reloaded = Platform.Repo.get!(Platform.Tasks.Validation, fallback_validation.id)
        assert reloaded.status == "passed"
      after
        Process.delete(:webhook_stack_fault)
      end
    end

    test "idempotent: replaying the same webhook leaves stack done with original metadata intact",
         %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stack_with_members!(3,
          slug: "idempotent-#{System.unique_integer([:positive])}"
        )

      payload =
        rollup_merged_payload(rollup_branch, %{
          "merge_commit_sha" => "first-merge-sha",
          "number" => System.unique_integer([:positive])
        })

      # First delivery: full fan-out + stack→done.
      conn1 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn1, 201)

      first_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert first_stack.status == "done"
      first_rollup_merge = Map.get(first_stack.metadata, "rollup_merge")
      assert first_rollup_merge["merge_commit_sha"] == "first-merge-sha"

      # Snapshot validations after the first run.
      first_validations =
        for %{pr_validation: v} <- members do
          reloaded = Platform.Repo.get!(Platform.Tasks.Validation, v.id)
          {reloaded.id, reloaded.status, reloaded.updated_at, reloaded.evidence}
        end

      # Second delivery with a DIFFERENT commit sha (simulating a
      # replay carrying drift). Use a fresh PR number so the changelog
      # insert succeeds (the dedup guard would 422 a same-PR replay
      # before the fan-out runs at all).
      replay_payload =
        rollup_merged_payload(rollup_branch, %{
          "merge_commit_sha" => "replay-merge-sha",
          "number" => System.unique_integer([:positive])
        })

      conn2 = post(conn, @github_webhook_path, replay_payload)
      assert %{"status" => "created"} = json_response(conn2, 201)

      # Stack stays at done; rollup_merge metadata is the ORIGINAL —
      # the replay did not clobber history with the new sha.
      second_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert second_stack.status == "done"
      second_rollup_merge = Map.get(second_stack.metadata, "rollup_merge")
      assert second_rollup_merge["merge_commit_sha"] == "first-merge-sha"

      # Member validations are NOT re-evaluated on replay (no new
      # `updated_at`, evidence unchanged).
      for {first, %{pr_validation: v}} <- Enum.zip(first_validations, members) do
        {id, first_status, first_updated_at, first_evidence} = first
        reloaded = Platform.Repo.get!(Platform.Tasks.Validation, v.id)
        assert reloaded.id == id
        assert reloaded.status == first_status
        assert reloaded.updated_at == first_updated_at
        assert reloaded.evidence == first_evidence
      end
    end

    # ── Stage 3 (T6 hardening): base-branch guard ──────────────────────────

    test "base mismatch: rollup branch merged into NON-base branch does NOT complete the stack",
         %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stack_with_members!(2,
          slug: "base-mismatch-#{System.unique_integer([:positive])}"
        )

      # stack.base_branch defaults to "main"; deliver a merge whose base is
      # a DIFFERENT branch. The head matches the rollup branch but the base
      # does not — the guard must treat this as a non-rollup merge.
      payload =
        rollup_merged_payload(rollup_branch, %{
          "base" => %{"ref" => "integration-x"}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post(conn, @github_webhook_path, payload)
          assert json_response(conn, 201)
        end)

      assert log =~ "matches rollup branch of stack #{stack.id}"
      assert log =~ "NOT auto-completing stack"

      # Stack stays in its prior status (NOT done).
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      refute reloaded_stack.status == "done"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "rollup_merge")

      # No member pr_merged validation was fanned out.
      for %{pr_validation: v} <- members do
        reloaded = Platform.Repo.get!(Platform.Tasks.Validation, v.id)
        refute reloaded.status == "passed"
        refute Map.get(reloaded.evidence || %{}, "fanned_out_from_stack_rollup_pr")
      end
    end

    test "unmerged close on a rollup branch is a no-op (not merged)", %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stack_with_members!(2,
          slug: "unmerged-rollup-#{System.unique_integer([:positive])}"
        )

      payload =
        rollup_merged_payload(rollup_branch, %{"merged" => false})

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "ignored"} = json_response(conn, 200)

      # Stack untouched, no fan-out.
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      refute reloaded_stack.status == "done"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "rollup_merge")

      for %{pr_validation: v} <- members do
        reloaded = Platform.Repo.get!(Platform.Tasks.Validation, v.id)
        refute reloaded.status == "passed"
      end
    end
  end

  # ── ADR 0041 (T6 stage 4 / task 019e2be4 stage 2): member promotion ─────
  #
  # Stack members never own a per-task deploy stage — the rollup PR carries
  # the deploy. So when the rollup PR's webhook fan-out passes the per-member
  # `pr_merged` validation, the fan-out ALSO promotes the member's task
  # `in_review → done` directly (the plan-engine cascade would otherwise
  # leave the member at `in_review` indefinitely, since
  # `maybe_inject_deploy_or_complete` short-circuits for stack members).
  describe "stack rollup-branch fan-out: member task promotion to done" do
    alias Platform.Tasks.Stacks

    test "happy path: every member task transitions in_review → done", %{conn: conn} do
      %{rollup_branch: rollup_branch, members: members} = build_stack_with_members!(3)

      # Sanity: every member starts at in_review.
      for %{task: task} <- members do
        assert task.status == "in_review"
      end

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      for %{task: task} <- members do
        reloaded = Platform.Repo.get!(Platform.Tasks.Task, task.id)

        assert reloaded.status == "done",
               "expected member #{task.id} to be promoted to done, got #{reloaded.status}"
      end
    end

    test "member transition fires maybe_finalize_transition: stack recompute + sweep dependents",
         %{conn: conn} do
      # The point of using the canonical `Tasks.transition_task/2` (rather
      # than a raw `Repo.update`) is that the existing `maybe_finalize_transition`
      # chain — sweep_unblocked_dependents + maybe_recompute_stack — fires
      # for `done` (tasks.ex line 1313). We verify the stack-recompute leg
      # by observing the stack's status after fan-out: with every member
      # at `done`, `recompute_stack_status` rolls the stack to `done`
      # (the explicit `Stacks.complete_rollup_merge/2` call after fan-out
      # would do this anyway, but the recompute proves the chain ran).
      %{stack: stack, rollup_branch: rollup_branch} = build_stack_with_members!(2)

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"
    end

    test "idempotent: replaying the webhook leaves member tasks at done", %{conn: conn} do
      %{rollup_branch: rollup_branch, members: members} = build_stack_with_members!(2)

      payload = rollup_merged_payload(rollup_branch)
      conn1 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn1, 201)

      first_member_states =
        for %{task: task} <- members do
          reloaded = Platform.Repo.get!(Platform.Tasks.Task, task.id)
          assert reloaded.status == "done"
          {reloaded.id, reloaded.status, reloaded.updated_at}
        end

      # Replay the webhook with a fresh PR number (so changelog dedup
      # doesn't 422 the request before fan-out runs). The outer
      # `process_stack_merged_pr` short-circuits because the stack is
      # already done with rollup_merge metadata, so the fan-out (and
      # therefore the per-member promote) does not re-fire — member
      # statuses stay exactly as they were.
      replay_payload =
        rollup_merged_payload(rollup_branch, %{
          "number" => System.unique_integer([:positive]),
          "merge_commit_sha" => "replay-promote-sha"
        })

      conn2 = post(conn, @github_webhook_path, replay_payload)
      assert %{"status" => "created"} = json_response(conn2, 201)

      for {id, first_status, first_updated_at} <- first_member_states do
        reloaded = Platform.Repo.get!(Platform.Tasks.Task, id)
        assert reloaded.status == first_status
        assert reloaded.updated_at == first_updated_at
      end
    end

    test "deploying member is also promoted to done", %{conn: conn} do
      # ADR 0041 §"Stack-level deploy" lists `deploying` as a valid
      # member status for fan-out (a member that StackDeployer picked
      # up mid-deploy). The promote helper must accept `deploying`
      # too — the `deploying → done` edge has been valid in
      # @valid_task_transitions since well before stage 1.
      %{rollup_branch: rollup_branch, members: [m1, m2]} = build_stack_with_members!(2)

      {:ok, _} = Tasks.update_task(m2.task, %{status: "deploying"})

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      assert Platform.Repo.get!(Platform.Tasks.Task, m1.task.id).status == "done"
      assert Platform.Repo.get!(Platform.Tasks.Task, m2.task.id).status == "done"
    end

    test "anomalous member is NOT promoted (no_pending_pr_merged + unexpected_status)",
         %{conn: conn} do
      # When a member is recorded as an anomaly (either because its
      # status is outside the accepted set, or because there is no
      # pending pr_merged validation for it), the member's task status
      # MUST stay unchanged. The promote step lives inside the happy
      # branch of `fan_out_member` — the anomaly branches return
      # without touching the task.
      %{rollup_branch: rollup_branch, members: [happy, status_anomaly, no_validation_anomaly]} =
        build_stack_with_members!(3)

      # status_anomaly: in_progress (outside accepted statuses).
      {:ok, _} = Tasks.update_task(status_anomaly.task, %{status: "in_progress"})

      # no_validation_anomaly: stays in_review but its pr_merged
      # validation is pre-failed so the lookup returns nil.
      no_validation_anomaly.pr_validation
      |> Platform.Tasks.Validation.changeset(%{status: "failed"})
      |> Platform.Repo.update!()

      payload = rollup_merged_payload(rollup_branch)
      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      assert Platform.Repo.get!(Platform.Tasks.Task, happy.task.id).status == "done"

      # Anomalies stay at their pre-fan-out status.
      assert Platform.Repo.get!(Platform.Tasks.Task, status_anomaly.task.id).status ==
               "in_progress"

      assert Platform.Repo.get!(Platform.Tasks.Task, no_validation_anomaly.task.id).status ==
               "in_review"
    end

    test "solo (non-stack) task path is unchanged: no direct promote, rides per-task pr_merged",
         %{conn: conn} do
      # Regression: a plain task/<uuid> branch must continue to flow
      # through `maybe_evaluate_pr_merged_validation` and NOT through
      # the stack fan-out (which is the only path that calls the new
      # promote helper). The task's status is therefore governed by
      # whatever the per-task plan-engine cascade decides — for this
      # test fixture (deploy stage with a `pr_merged` validation), the
      # task does not get auto-promoted to done by the webhook because
      # there is no per-task deploy injection on top of an already-deploy
      # stage; the validation flips to passed and that's it. The KEY
      # assertion is that no stack-fan-out marker landed on the
      # validation evidence and the task did not jump to done from
      # in_review via our new bypass (which would only fire from the
      # stack branch).
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      # Force the task into in_review so we can prove the new bypass
      # didn't pick it up.
      {:ok, _} = Tasks.update_task(task, %{status: "in_review"})

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: solo task PR",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/ci-repo/pull/1234",
            "merge_commit_sha" => "solo1234",
            "merged_at" => "2026-05-12T12:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      reloaded_validation = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      # Per-task pr_merged is passed (existing behavior).
      assert reloaded_validation.status == "passed"

      # Crucially: NO stack fan-out marker — proving we did not go
      # through the stack-only branch that now promotes to done.
      refute Map.get(reloaded_validation.evidence || %{}, "fanned_out_from_stack_rollup_pr")

      # The task is NOT a stack member, so the new direct-promote
      # helper was never called. The task's resulting status is
      # determined by the existing solo-task plan engine cascade only.
      reloaded_task = Platform.Repo.get!(Platform.Tasks.Task, task.id)
      # Sanity: it's still a non-stack task.
      assert reloaded_task.stack_id == nil
    end

    # Stage 2 spec line: "(c) `in_review → done` is now a permitted
    # transition in `Tasks.update_task_status/2` for non-stack tasks too
    # (permissive widening, documented inline)."
    test "in_review → done is a permitted transition for any task (stage 1 widening)",
         %{conn: _conn} do
      # This is the stage 1 invariant: the @valid_task_transitions
      # widening applies uniformly, not just to stack members. Verify
      # it directly via the transition function so no webhook is involved.
      {:ok, project} =
        Tasks.create_project(%{
          name: "Widening Test #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/test/widen"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Solo task widening check"})

      {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

      {:ok, in_review_task} = Tasks.transition_task_status(task, "in_progress")
      {:ok, in_review_task} = Tasks.transition_task_status(in_review_task, "in_review")

      # The widened transition: in_review → done. Pre-stage-1, this would
      # have returned {:error, :invalid_transition}.
      assert {:ok, %{status: "done"}} = Tasks.transition_task_status(in_review_task, "done")

      # Sanity: this is a SOLO (non-stack) task — proving the widening
      # is uniform, not stack-only.
      assert is_nil(Platform.Repo.get!(Platform.Tasks.Task, task.id).stack_id)
    end
  end

  # ── Task 019f5bc4-3521 (stage 5): rollup deploy cascade end-to-end ──────
  #
  # Reproduces PR #531's production shape end-to-end: the rollup PR merges,
  # `pull_request.closed` hits this controller, and the deployer cascades
  # every stranded member from `deploying → done` in one atomic pass —
  # emitting exactly ONE `[:platform, :stacks, :deploy, :cascade_completed]`
  # event with `trigger: :webhook`.
  #
  # Complements the tighter regression in
  # `github_webhook_rollup_cascade_test.exs` by covering the three scenarios
  # the router explicitly discriminates: happy-path cascade, idempotent
  # replay of the same rollup webhook, and the negative guard that a plain
  # (non-rollup) task PR never trips the stack cascade emit.
  describe "stack rollup deploy cascade end-to-end" do
    alias Platform.Tasks.Stacks

    # Belt-and-suspenders: test config already sets async: false + the
    # `Platform.Tasks.StackDeployer.NoopRunner`, but pin it in setup so a
    # future config drift doesn't silently regress these assertions. Also
    # attach a `:cascade_completed` telemetry handler that only delivers
    # events emitted FROM the test process — this file is `async: true`, so
    # a global handler would otherwise catch events fired by parallel
    # tests. Because the deployer runs inline under `async: false`, the
    # cascade emit fires in the same process that called `post/2` (the
    # test), so a `self() == test_pid` guard cleanly isolates our events.
    setup do
      prev = Application.get_env(:platform, :stack_deployer, [])

      Application.put_env(:platform, :stack_deployer,
        git_runner: Platform.Tasks.StackDeployer.NoopRunner,
        async: false
      )

      handler_id = "e2e-cascade-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            if self() == test_pid do
              send(test_pid, {:telemetry, event, measurements, metadata})
            end
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        Application.put_env(:platform, :stack_deployer, prev)
      end)

      :ok
    end

    # PR #531 shape (see https://github.com/Startup-Suite/core/pull/531):
    # stack at `deploying` with `metadata["rollup_pr"]["opened_at"]` stamped
    # (that's what the deployer writes when it opens the rollup PR), N
    # member tasks at `deploying` with `stack_id` set. Members carry NO
    # per-task `pr_merged` validation — the rollup PR ships them
    # atomically (see `Tasks.dispatch_deploy_for_task/1` returning
    # `{:error, :stack_ships_atomically}` for stacked tasks).
    #
    # 3-phase build (per task guidance): create the stack at deploying,
    # attach members (each `update_task` skips the transition-status
    # validator so we can pin them at `deploying` directly), then leave
    # the stack row at the deploying status we wrote at creation. We do
    # NOT call `Stacks.add_task/2` — that helper fires
    # `recompute_stack_status/1` and would roll the stack away from
    # `deploying` to whatever the member-status rollup demands.
    defp e2e_build_stranded_stack!(member_count, opts) when member_count > 0 do
      slug =
        Keyword.get(opts, :slug, "e2e-cascade-#{System.unique_integer([:positive])}")

      rollup_branch = "stack/#{slug}"

      now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, project} =
        Tasks.create_project(%{
          name: "E2E Cascade #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/Startup-Suite/core"
        })

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: slug,
          name: "E2E Cascade Stack",
          base_branch: "main",
          rollup_branch: rollup_branch,
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 999,
              "url" => "https://github.com/x/y/pull/999",
              "opened_at" => now_iso
            }
          }
        })

      members =
        for position <- 1..member_count do
          {:ok, task} =
            Tasks.create_task(%{
              project_id: project.id,
              title: "Stranded member #{position}"
            })

          {:ok, _plan} =
            Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

          {:ok, task} =
            Tasks.update_task(task, %{
              stack_id: stack.id,
              stack_position: position,
              status: "deploying"
            })

          %{task: task}
        end

      %{project: project, stack: stack, rollup_branch: rollup_branch, members: members}
    end

    # Inline `pull_request.closed` payload for a rollup-branch merge.
    # Kept inline (no external JSON fixture) so the reader sees the exact
    # controller inputs alongside the assertions — the shape mirrors the
    # production PR #531 body, minus fields the controller ignores.
    defp e2e_rollup_webhook_body(rollup_branch, pr_number) do
      %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => true,
          "number" => pr_number,
          "title" => "Stack rollup: e2e cascade",
          "html_url" => "https://github.com/Startup-Suite/core/pull/#{pr_number}",
          "merge_commit_sha" => "e2e-rollup-sha-#{pr_number}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "merge-bot"},
          "merged_by" => %{"login" => "ryanm"},
          "head" => %{"ref" => rollup_branch},
          "base" => %{"ref" => "main"}
        }
      }
    end

    # Inline `pull_request.closed` payload for a plain non-rollup task PR
    # (branch `task/<uuid>`), used to prove the stack cascade code path is
    # NOT tripped by ordinary per-task merges.
    defp e2e_plain_task_webhook_body(head_ref, pr_number) do
      %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => true,
          "number" => pr_number,
          "title" => "Plain task PR",
          "html_url" => "https://github.com/test/plain-repo/pull/#{pr_number}",
          "merge_commit_sha" => "plain-sha-#{pr_number}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "agent-bot"},
          "head" => %{"ref" => head_ref}
        }
      }
    end

    test "happy path: 3 stranded members all reach done in one atomic pass", %{conn: conn} do
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        e2e_build_stranded_stack!(3, slug: "happy-#{System.unique_integer([:positive])}")

      pr_number = System.unique_integer([:positive])

      conn = post(conn, @github_webhook_path, e2e_rollup_webhook_body(rollup_branch, pr_number))
      assert %{"status" => "created"} = json_response(conn, 201)

      # Stack advanced through both transitions: fan-out flipped it to
      # `done` via `Stacks.complete_rollup_merge/2` and then
      # `StackDeployer.handle_rollup_pr_merged/2` stamped
      # `metadata["rollup_pr"]["merged_at"]` and cascaded the stranded
      # members.
      reloaded_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      rollup_pr_meta = get_in(reloaded_stack.metadata, ["rollup_pr"]) || %{}

      assert is_binary(Map.get(rollup_pr_meta, "merged_at")),
             "expected rollup_pr.merged_at to be stamped after cascade"

      # All 3 stranded members atomically advanced to done.
      member_statuses =
        for %{task: task} <- members do
          Platform.Repo.get!(Platform.Tasks.Task, task.id).status
        end

      assert Enum.uniq(member_statuses) == ["done"],
             "expected all 3 members done in one pass; got #{inspect(member_statuses)}"

      # Exactly ONE :cascade_completed telemetry event, tagged
      # `trigger: :webhook`, with the expected cascaded_count. The
      # `^stack_id` binding in both patterns keeps us safe from parallel
      # async tests' events (also filtered by the setup handler's
      # `self() == test_pid` guard, but belt-and-suspenders here).
      stack_id = stack.id

      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{
                        stack_id: ^stack_id,
                        cascaded_count: 3,
                        skipped_count: 0,
                        trigger: :webhook
                      }},
                     500

      refute_received {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _,
                       %{stack_id: ^stack_id}}
    end

    test "replay fires idempotent no-op :cascade_completed telemetry event",
         %{conn: conn} do
      # Task 019f5bc4-3521 Case B contract (strict per-webhook telemetry
      # parity): every real webhook delivery for a rollup PR fires
      # exactly one `:cascade_completed` telemetry event, INCLUDING
      # replays. On a replay `cascaded_count` is 0 (no members to
      # advance) but the event still emits so dashboards can count
      # deliveries. Stack + member rows remain untouched — the replay
      # is side-effect-free on state, its only observable effect is the
      # second telemetry event + a log line.
      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        e2e_build_stranded_stack!(3, slug: "idem-#{System.unique_integer([:positive])}")

      # First POST — full cascade path runs (fan-out anomalies for members
      # without pr_merged validation, `Stacks.complete_rollup_merge/2`
      # flips stack to done, then `handle_rollup_pr_merged/2` stamps
      # `rollup_pr.merged_at` and cascades the stranded members).
      first_pr_number = System.unique_integer([:positive])

      conn1 =
        post(conn, @github_webhook_path, e2e_rollup_webhook_body(rollup_branch, first_pr_number))

      assert %{"status" => "created"} = json_response(conn1, 201)

      first_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      assert first_stack.status == "done"
      first_rollup_pr = get_in(first_stack.metadata, ["rollup_pr"]) || %{}

      assert is_binary(Map.get(first_rollup_pr, "merged_at")),
             "expected rollup_pr.merged_at to be stamped after first POST"

      stack_id = stack.id

      # First delivery: cascaded_count = 3 (three stranded members
      # transitioned to done in the same webhook call).
      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{
                        stack_id: ^stack_id,
                        cascaded_count: 3,
                        skipped_count: 0,
                        trigger: :webhook
                      }},
                     500

      # Snapshot member `updated_at` timestamps so we can prove the
      # replay is truly a no-op on state (no writes). The ONLY visible
      # side-effect of the replay should be the second telemetry event.
      first_member_updated_ats =
        for %{task: task} <- members do
          reloaded = Platform.Repo.get!(Platform.Tasks.Task, task.id)
          {reloaded.id, reloaded.updated_at}
        end

      # Second POST — under the new Case B fix, `process_stack_merged_pr/4`
      # no longer pre-checks for done+rollup_merge. It routes replays
      # through the full chain: `fan_out_rollup_merge` (all members already
      # done → all anomalies, zero passed, zero writes) → `Stacks
      # .complete_rollup_merge/2` (idempotent no-op) → `StackDeployer
      # .handle_rollup_pr_merged/2` replay branch (cascade emit +
      # {:ok, stack}). The `:cascade_completed` event STILL fires with
      # `cascaded_count: 0` for per-webhook telemetry parity.
      replay_pr_number = System.unique_integer([:positive])

      conn2 =
        post(conn, @github_webhook_path, e2e_rollup_webhook_body(rollup_branch, replay_pr_number))

      assert %{"status" => "created"} = json_response(conn2, 201)

      # Second delivery emits a second :cascade_completed event —
      # cascaded_count: 0 (nothing to advance), same trigger. This is
      # the load-bearing Case B assertion.
      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{
                        stack_id: ^stack_id,
                        cascaded_count: 0,
                        skipped_count: 0,
                        trigger: :webhook
                      }},
                     1000

      # Members still done, untouched updated_at — the cascade helper's
      # `reject(&(&1.status == "done"))` filter drops every member from
      # the transition set, so the inner Repo.transaction is empty and
      # nothing gets written. Idempotent on state.
      for {id, first_updated_at} <- first_member_updated_ats do
        reloaded = Platform.Repo.get!(Platform.Tasks.Task, id)
        assert reloaded.status == "done"
        assert reloaded.updated_at == first_updated_at
      end

      # Stack's `rollup_pr.merged_at` is the ORIGINAL stamp — the replay
      # branch in `handle_rollup_pr_merged/2` deliberately does NOT
      # re-stamp merged_at (that would clobber the first-merge timestamp
      # + deploy-duration histogram on dashboards).
      second_stack = Platform.Repo.get!(Platform.Tasks.Stack, stack.id)
      second_rollup_pr = get_in(second_stack.metadata, ["rollup_pr"]) || %{}
      assert Map.get(second_rollup_pr, "merged_at") == Map.get(first_rollup_pr, "merged_at")

      # No THIRD :cascade_completed telemetry event — two POSTs, two
      # events, exact per-webhook parity.
      refute_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _,
                      %{stack_id: ^stack_id}},
                     200
    end

    test "non-rollup PR does not trigger the stack cascade code path", %{conn: conn} do
      # Solo (non-stack) task with a running deploy stage carrying a
      # pending pr_merged validation. Its branch (`task/<uuid>`) does not
      # match any stack's rollup_branch, so the controller takes the
      # per-task path — flipping pr_merged to passed via PlanEngine — and
      # NEVER enters `process_stack_merged_pr`.
      %{task: task, pr_validation: pr_validation} = create_task_with_ci_validation!()

      pr_number = System.unique_integer([:positive])

      conn =
        post(
          conn,
          @github_webhook_path,
          e2e_plain_task_webhook_body("task/#{task.id}", pr_number)
        )

      assert %{"status" => "created"} = json_response(conn, 201)

      # Per-task pr_merged flipped to passed, WITHOUT the fan-out marker
      # in evidence (proving we went through the per-task branch, not the
      # stack rollup branch).
      reloaded = Platform.Repo.get!(Platform.Tasks.Validation, pr_validation.id)
      assert reloaded.status == "passed"
      assert reloaded.evaluated_by == "github_webhook"
      refute Map.get(reloaded.evidence || %{}, "fanned_out_from_stack_rollup_pr")

      # No stack cascade telemetry — the whole point of the negative
      # guard. Any :cascade_completed event that lands in our mailbox
      # would have had to come from THIS test process (setup handler's
      # `self() == test_pid` filter), and Case 3 creates no stack.
      refute_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}, 200
    end
  end
end
