defmodule PlatformWeb.GithubWebhookRollupCascadeTest do
  @moduledoc """
  Regression test for the PR #531 hang (2026-07-13).

  Reproduces the exact production shape observed when a rollup PR
  merges: the stack advances to `done`, its 3 members should all
  cascade to `done`, and a `[:platform, :stacks, :deploy,
  :cascade_completed]` telemetry event should fire exactly once.

  Stage 2 wired `Stacks.cascade_members_to_done/2` to emit the
  event, so the happy-path assertion now passes. The negative-shape
  test (non-rollup PR guard) locks in that the cascade code path is
  NOT tripped by ordinary task PRs — it must not overfire.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, Task, Validation}

  @github_webhook_path "/api/webhooks/github"

  # ── Runner stub ────────────────────────────────────────────────────────
  #
  # `StackDeployer.handle_rollup_pr_merged/2` triggers a rollup-branch
  # delete after the cascade. In async: false mode that shell-runs
  # synchronously — we stub it out so nothing actually shells out.

  defmodule NoopRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args),
      do: {:ok, %{status: :created, base_sha: "beefbeef"}}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "cafecafe"}}

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 1, url: "https://github.com/test/repo/pull/1"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def revert_member_merge(_args),
      do: {:ok, %{status: :reverted, revert_sha: "revert00"}}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    # Bug #2 (task 019f708f): default to reachable so this cascade test
    # keeps exercising the pre-bug-#2 code paths.
    @impl true
    def sha_reachable?(_args), do: {:ok, true}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: NoopRunner,
      async: false
    )

    # Task 019f7b7f stage 3 — the multi-strategy tests below assert on
    # the info-level "Stack ... matched via ..." log line from the
    # controller. Test env defaults Logger to :warning, which would
    # drop the message before `capture_log` could see it. Bump to
    # :info for the whole describe (info is quiet enough not to
    # matter for the older tests, which don't grep this level).
    prev_logger_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)
      Logger.configure(level: prev_logger_level)
    end)

    :ok
  end

  # ── Regression: rollup-PR merge cascades stack + members to done ──────

  describe "rollup PR merge deploy cascade (task 019f5bc4-3521 / PR #531)" do
    test "3 deploying members + deploying stack all reach done with :cascade_completed telemetry fired once",
         %{conn: conn} do
      handler_id = "cascade-happy-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stranded_stack!(3, slug: "regression-cascade-#{System.unique_integer([:positive])}")

      payload =
        rollup_pr_closed_payload(rollup_branch, %{
          "number" => 999,
          "html_url" => "https://github.com/x/y/pull/999",
          "merge_commit_sha" => "rollup-happy-sha"
        })

      conn = signed_github_post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # 1. Stack advanced to done.
      reloaded_stack = Repo.get!(Platform.Tasks.Stack, stack.id)
      assert reloaded_stack.status == "done"

      # 2. All members advanced to done.
      member_statuses =
        for %{task: task} <- members do
          Repo.get!(Task, task.id).status
        end

      assert member_statuses == ["done", "done", "done"],
             "expected all members to cascade to done; got #{inspect(member_statuses)}"

      # 3. :cascade_completed telemetry fired exactly once with the
      #    expected shape. This is the assertion that fails today.
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

      refute_received {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}
    end

    # Task 019f7b7f stage 3 — end-to-end idempotency guard. Distinct
    # from the unit-level idempotency case in `github_webhook_controller_test.exs`
    # (which asserts snapshot equality on member validations); this
    # one exercises the full cascade + StackDeployer chain and pins
    # the telemetry parity contract from the plan:
    #
    #   * cascade telemetry fires ONCE per delivery (dashboards can
    #     count deliveries)
    #   * first event carries `cascaded_count: N`, replay carries `0`
    #   * `metadata.rollup_pr.merged_at` is NOT clobbered by the replay
    #   * each member transitions to `done` EXACTLY ONCE (audit log
    #     stand-in for the "no duplicate task-timeline done entries"
    #     invariant from the plan)
    test "idempotency: replaying the webhook fires :cascade_completed twice, second with cascaded_count=0, no clobbered merged_at",
         %{conn: conn} do
      handler_id = "cascade-idempotency-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stranded_stack!(3,
          slug: "idempotency-cascade-#{System.unique_integer([:positive])}"
        )

      first_pr_number = System.unique_integer([:positive])

      first_payload =
        rollup_pr_closed_payload(rollup_branch, %{
          "number" => first_pr_number,
          "html_url" => "https://github.com/x/y/pull/#{first_pr_number}",
          "merge_commit_sha" => "idempotency-first-sha"
        })

      # 1st delivery — full fan-out.
      conn1 = signed_github_post(conn, @github_webhook_path, first_payload)
      assert %{"status" => "created"} = json_response(conn1, 201)

      # Snapshot post-first-delivery: stack done, merged_at stamped,
      # rollup_pr.merged_at stamped, members done.
      stack_after_first = Repo.get!(Platform.Tasks.Stack, stack.id)
      assert stack_after_first.status == "done"

      first_rollup_pr = get_in(stack_after_first.metadata, ["rollup_pr"])
      first_rollup_merge = get_in(stack_after_first.metadata, ["rollup_merge"])
      assert is_binary(first_rollup_pr["merged_at"])
      assert first_rollup_merge["merge_commit_sha"] == "idempotency-first-sha"

      first_merged_at = first_rollup_pr["merged_at"]

      member_ids = for %{task: task} <- members, do: task.id

      first_member_updated_at =
        for id <- member_ids do
          {id, Repo.get!(Platform.Tasks.Task, id).updated_at}
        end
        |> Map.new()

      # Consume the first :cascade_completed event.
      stack_id = stack.id

      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{stack_id: ^stack_id, cascaded_count: 3, trigger: :webhook}},
                     500

      # 2nd delivery — same rollup branch, DIFFERENT commit sha to
      # prove the replay path doesn't clobber history. Different PR
      # number so the changelog dedup doesn't 422 us before we hit
      # the fan-out.
      replay_pr_number = System.unique_integer([:positive])

      replay_payload =
        rollup_pr_closed_payload(rollup_branch, %{
          "number" => replay_pr_number,
          "html_url" => "https://github.com/x/y/pull/#{replay_pr_number}",
          "merge_commit_sha" => "idempotency-replay-sha",
          "merged_at" => "2027-01-01T00:00:00Z"
        })

      conn2 = signed_github_post(conn, @github_webhook_path, replay_payload)
      assert %{"status" => "created"} = json_response(conn2, 201)

      # Stack still at done, rollup_pr.merged_at UNCHANGED — replay
      # did not clobber the original timestamp.
      stack_after_replay = Repo.get!(Platform.Tasks.Stack, stack.id)
      assert stack_after_replay.status == "done"
      replay_rollup_pr = get_in(stack_after_replay.metadata, ["rollup_pr"])
      replay_rollup_merge = get_in(stack_after_replay.metadata, ["rollup_merge"])

      assert replay_rollup_pr["merged_at"] == first_merged_at,
             "expected merged_at to be preserved across replay; got #{inspect(replay_rollup_pr["merged_at"])}"

      # rollup_merge summary also preserved (still points at first sha).
      assert replay_rollup_merge["merge_commit_sha"] == "idempotency-first-sha"

      # Members' updated_at is unchanged — the replay did NOT trigger
      # another `done` transition write. This is the DB-level stand-in
      # for the plan's "no duplicate task-timeline done entries" clause.
      for {id, first_at} <- first_member_updated_at do
        reloaded = Repo.get!(Platform.Tasks.Task, id)

        assert reloaded.status == "done"

        assert reloaded.updated_at == first_at,
               "member #{id} was re-updated on replay (updated_at drifted from " <>
                 "#{inspect(first_at)} to #{inspect(reloaded.updated_at)})"
      end

      # 2nd :cascade_completed event fired — same shape but with
      # cascaded_count=0 (nothing to cascade the second time).
      assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                      %{count: 1, member_count: 3},
                      %{stack_id: ^stack_id, cascaded_count: 0, trigger: :webhook}},
                     500

      # No 3rd event.
      refute_received {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}
    end

    test "multi-strategy: rollup_branch match cascades end-to-end", %{conn: conn} do
      # This IS the happy-path shape covered by the top test, but
      # asserted explicitly at the strategy level so a regression in
      # the rollup_branch strategy shows here as well as at the
      # controller unit level.
      handler_id = "cascade-strategy-rollup-#{System.unique_integer([:positive])}"
      test_pid = self()
      :ok = attach_telemetry(handler_id, test_pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{stack: stack, rollup_branch: rollup_branch, members: members} =
        build_stranded_stack!(2,
          slug: "strategy-rollup-branch-#{System.unique_integer([:positive])}"
        )

      pr_number = System.unique_integer([:positive])

      payload =
        rollup_pr_closed_payload(rollup_branch, %{
          "number" => pr_number,
          "html_url" => "https://github.com/x/y/pull/#{pr_number}",
          "merge_commit_sha" => "strategy-rollup-branch-sha"
        })

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          conn = signed_github_post(conn, @github_webhook_path, payload)
          assert %{"status" => "created"} = json_response(conn, 201)
        end)

      # Strategy log tag from the controller.
      assert log =~ "Stack #{stack.id} matched via rollup_branch"

      assert_cascade_completed(stack.id, 2)
      assert_all_members_done(members)
    end

    test "multi-strategy: pr_number fallback cascades end-to-end when rollup_branch is stale",
         %{conn: conn} do
      handler_id = "cascade-strategy-pr-number-#{System.unique_integer([:positive])}"
      test_pid = self()
      :ok = attach_telemetry(handler_id, test_pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      pr_number = System.unique_integer([:positive])

      # Stack's rollup_branch column is set to a STALE value that
      # WILL NOT match the webhook's head ref — only metadata.rollup_pr.number
      # is a lever the pr_number strategy can grab.
      %{stack: stack, members: members} =
        build_stack_with_stale_rollup_branch!(pr_number, 2)

      # Head ref intentionally different from stack.rollup_branch to
      # force the rollup_branch strategy to miss.
      payload =
        rollup_pr_closed_payload("stack/wildly-different-branch-name", %{
          "number" => pr_number,
          "html_url" => "https://github.com/x/y/pull/#{pr_number}",
          "merge_commit_sha" => "strategy-pr-number-sha"
        })

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          conn = signed_github_post(conn, @github_webhook_path, payload)
          assert %{"status" => "created"} = json_response(conn, 201)
        end)

      assert log =~ "Stack #{stack.id} matched via pr_number for PR ##{pr_number}"

      assert_cascade_completed(stack.id, 2)
      assert_all_members_done(members)
    end

    test "multi-strategy: slug fallback cascades end-to-end when rollup_branch is stale + pr_number is unstamped",
         %{conn: conn} do
      handler_id = "cascade-strategy-slug-#{System.unique_integer([:positive])}"
      test_pid = self()
      :ok = attach_telemetry(handler_id, test_pid)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Slug matches the branch convention `stack/<slug>` per
      # `rollup_branch_name/1`, but the stored rollup_branch column
      # is a STALE value AND metadata.rollup_pr.number is absent.
      # Only the slug regex can match.
      slug = "slug-strategy-#{System.unique_integer([:positive])}"

      %{stack: stack, members: members} =
        build_stack_with_slug_only!(slug, 2)

      payload =
        rollup_pr_closed_payload("stack/#{slug}", %{
          "number" => System.unique_integer([:positive]),
          "html_url" => "https://github.com/x/y/pull/#{System.unique_integer([:positive])}",
          "merge_commit_sha" => "strategy-slug-sha"
        })

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          conn = signed_github_post(conn, @github_webhook_path, payload)
          assert %{"status" => "created"} = json_response(conn, 201)
        end)

      assert log =~ "Stack #{stack.id} matched via slug"

      assert_cascade_completed(stack.id, 2)
      assert_all_members_done(members)
    end

    test "non-rollup PR: per-task path fires, no :cascade_completed telemetry",
         %{conn: conn} do
      # Negative guard — a plain task/<uuid> merge must go through the
      # per-task pr_merged path and MUST NOT trip the stack cascade
      # emission. Passes today; locks in that the fix (stage 2) does
      # not overfire.
      handler_id = "cascade-negative-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :cascade_completed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{task: task, pr_validation: pr_validation} = build_solo_task_with_pr_merged!()

      payload =
        plain_pr_closed_payload("task/#{task.id}", %{
          "number" => 4242,
          "html_url" => "https://github.com/test/solo-repo/pull/4242",
          "merge_commit_sha" => "solo-sha"
        })

      conn = signed_github_post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn, 201)

      # Per-task path fired: pr_merged validation flipped to passed.
      reloaded = Repo.get!(Validation, pr_validation.id)
      assert reloaded.status == "passed"
      assert reloaded.evaluated_by == "github_webhook"
      # Not tagged as a stack fan-out — proves it went through the
      # per-task code path, not the stack rollup path.
      refute Map.get(reloaded.evidence || %{}, "fanned_out_from_stack_rollup_pr")

      # No stack cascade telemetry — the point of the guard.
      refute_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed], _, _}, 200
    end
  end

  # ── Fixture helpers ────────────────────────────────────────────────────

  # Build a stack in the exact "PR #531" shape: stack at `deploying`
  # with `rollup_pr.opened_at` stamped, N member tasks all at
  # `deploying` with `stack_id` set, an approved plan carrying ONE
  # completed execution stage and NO per-task pr_merged validation
  # (stack members ship via the rollup PR — see
  # `Tasks.dispatch_deploy_for_task/1` returning
  # `{:error, :stack_ships_atomically}` for stacked tasks).
  defp build_stranded_stack!(member_count, opts) when member_count > 0 do
    slug =
      Keyword.get(opts, :slug, "rollup-cascade-#{System.unique_integer([:positive])}")

    rollup_branch = "stack/#{slug}"

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Cascade Regression #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/cascade-repo"
      })

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Cascade Regression Stack",
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
            title: "Cascade member #{position}"
          })

        # A completed execution stage on an approved plan — enough to
        # satisfy the `require_approved_plan_for/2` guard. NO deploy
        # stage, NO pr_merged validation: stack members never carry
        # one.
        {:ok, plan} =
          Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, _stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Execute",
            description: "Execute stage",
            status: "passed"
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            status: "deploying"
          })

        %{task: task, plan: plan}
      end

    %{
      project: project,
      stack: stack,
      rollup_branch: rollup_branch,
      members: members
    }
  end

  # Variant of `build_stranded_stack!/2` for the pr_number-strategy
  # end-to-end test: `rollup_branch` column is set to a stale value
  # that will NOT match the webhook's head ref, but `metadata.rollup_pr.number`
  # IS stamped so the pr_number fallback strategy fires.
  defp build_stack_with_stale_rollup_branch!(pr_number, member_count)
       when member_count > 0 do
    slug = "stale-branch-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stale Branch Cascade #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/stale-branch-repo"
      })

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stale Branch Cascade",
        base_branch: "main",
        # Deliberately stale — the webhook's head ref will NOT match.
        rollup_branch: "stack/old-#{slug}-abandoned",
        status: "deploying",
        metadata: %{
          "rollup_pr" => %{
            "number" => pr_number,
            "url" => "https://github.com/x/y/pull/#{pr_number}",
            "opened_at" => now_iso
          }
        }
      })

    members = attach_deploying_members!(project, stack, member_count)
    %{project: project, stack: stack, members: members}
  end

  # Variant for the slug-strategy end-to-end test: `rollup_branch` is
  # stale AND `metadata.rollup_pr.number` is unstamped. Only the
  # `slug` fallback (regex on `stack/<slug>`) can match.
  #
  # NB: `metadata.rollup_pr.opened_at` IS set (but NOT `number`) so
  # `StackDeployer.handle_rollup_pr_merged/2` follows its first-time
  # happy-path branch (the `else` case in the status="done" cond tree
  # at `stack_deployer.ex:1132`). Without any `rollup_pr` map at all,
  # the handler treats the stack as "manually flipped to done" and
  # short-circuits — no cascade, no telemetry — which is a legitimate
  # test-seam path but not the shape we want to exercise here.
  defp build_stack_with_slug_only!(slug, member_count) when member_count > 0 do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Slug Cascade #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/slug-repo"
      })

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Slug Cascade",
        base_branch: "main",
        # Stale rollup_branch (will not match webhook's `stack/<slug>`).
        rollup_branch: "stack/legacy-#{slug}-#{System.unique_integer([:positive])}",
        status: "deploying",
        # Minimal rollup_pr — `number` deliberately absent so the
        # pr_number fallback strategy MISSES and only the slug regex
        # can match at the controller. `opened_at` is enough for
        # `handle_rollup_pr_merged` to take the first-time path.
        metadata: %{
          "rollup_pr" => %{
            "url" => "https://github.com/x/y/pull/manual",
            "opened_at" => now_iso
          }
        }
      })

    members = attach_deploying_members!(project, stack, member_count)
    %{project: project, stack: stack, members: members}
  end

  # Common member-attach helper for the strategy variants: builds N
  # tasks each with an approved plan + a completed execution stage,
  # then attaches them to the stack at `deploying` status. Mirrors
  # `build_stranded_stack!`'s member shape.
  defp attach_deploying_members!(project, stack, member_count) do
    for position <- 1..member_count do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Strategy member #{position}"
        })

      {:ok, plan} =
        Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

      {:ok, _stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Execute",
          description: "Execute stage",
          status: "passed"
        })

      {:ok, task} =
        Tasks.update_task(task, %{
          stack_id: stack.id,
          stack_position: position,
          status: "deploying"
        })

      %{task: task, plan: plan}
    end
  end

  # Telemetry attach + one-off assertion shared across the three
  # strategy tests to keep them lean.
  defp attach_telemetry(handler_id, test_pid) do
    :telemetry.attach(
      handler_id,
      [:platform, :stacks, :deploy, :cascade_completed],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )
  end

  defp assert_cascade_completed(stack_id, expected_member_count) do
    assert_receive {:telemetry, [:platform, :stacks, :deploy, :cascade_completed],
                    %{count: 1, member_count: ^expected_member_count},
                    %{stack_id: ^stack_id, trigger: :webhook}},
                   500
  end

  defp assert_all_members_done(members) do
    for %{task: task} <- members do
      reloaded = Repo.get!(Task, task.id)

      assert reloaded.status == "done",
             "expected member #{task.id} at done; got #{reloaded.status}"
    end
  end

  # A solo (non-stack) task at `in_review` with a running deploy
  # stage carrying a pending pr_merged validation. Mirrors the shape
  # `create_task_with_ci_validation!` in `github_webhook_controller_test.exs`
  # produces, minus the ci_validation — we only need the pr_merged one.
  defp build_solo_task_with_pr_merged! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Solo Task #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/solo-repo"
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Solo task"})

    {:ok, plan} =
      Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: PR merge",
        description: "Deploy via PR merge"
      })

    {:ok, _} = Tasks.transition_stage(stage, "running")
    stage = Repo.get!(Platform.Tasks.Stage, stage.id)

    {:ok, pr_validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

    %{project: project, task: task, plan: plan, stage: stage, pr_validation: pr_validation}
  end

  defp rollup_pr_closed_payload(rollup_branch, overrides) do
    pr =
      Map.merge(
        %{
          "merged" => true,
          "title" => "chore: rollup cascade regression",
          "number" => System.unique_integer([:positive]),
          "html_url" =>
            "https://github.com/test/cascade-repo/pull/#{System.unique_integer([:positive])}",
          "merge_commit_sha" => "rollup#{System.unique_integer([:positive])}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "merge-bot"},
          "merged_by" => %{"login" => "ryanm"},
          "head" => %{"ref" => rollup_branch},
          "base" => %{"ref" => "main"}
        },
        overrides
      )

    %{"action" => "closed", "pull_request" => pr}
  end

  defp plain_pr_closed_payload(head_ref, overrides) do
    pr =
      Map.merge(
        %{
          "merged" => true,
          "title" => "feat: solo task",
          "number" => System.unique_integer([:positive]),
          "html_url" =>
            "https://github.com/test/solo-repo/pull/#{System.unique_integer([:positive])}",
          "merge_commit_sha" => "solo#{System.unique_integer([:positive])}",
          "merged_at" => "2026-07-13T06:18:00Z",
          "body" => "",
          "user" => %{"login" => "agent-bot"},
          "head" => %{"ref" => head_ref}
        },
        overrides
      )

    %{"action" => "closed", "pull_request" => pr}
  end
end
