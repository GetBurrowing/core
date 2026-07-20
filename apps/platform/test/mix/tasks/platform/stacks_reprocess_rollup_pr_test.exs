defmodule Mix.Tasks.Platform.Stacks.ReprocessRollupPrTest do
  @moduledoc """
  Tests for the operator recovery Mix task
  (task `019f7b7f-51bd-7a67-af26-2f317993abb3` stage 3).

  The task is exercised via its public `do_run/2` entry point rather
  than `run/1` — `run/1` calls `Mix.Task.run("app.start")` which
  `Platform.DataCase` has already run. Driving `do_run/2` directly
  keeps the test loop fast and side-effect-free, and lets us inject
  a fake `gh` runner (`FakeGhRunner`) so nothing shells out.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.Stacks.ReprocessRollupPr
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks, Validation}

  # ── Fake gh runner ──────────────────────────────────────────────────────
  #
  # Mirrors the `NoopRunner` pattern from
  # `github_webhook_rollup_cascade_test.exs`. Each test seeds a
  # canned response via `put_response/2`; `pr_view/2` returns it.

  defmodule FakeGhRunner do
    @moduledoc false
    @behaviour Mix.Tasks.Platform.Stacks.ReprocessRollupPr.GhRunner

    def put_response(key, response), do: Process.put({__MODULE__, key}, response)

    @impl true
    def pr_view(pr_number, repo) do
      case Process.get({__MODULE__, {pr_number, repo}}) do
        nil ->
          case Process.get({__MODULE__, :any}) do
            nil -> {:error, {:fake_no_response_registered, pr_number, repo}}
            response -> response
          end

        response ->
          response
      end
    end
  end

  # ── Fake processor ──────────────────────────────────────────────────────
  #
  # Some tests want to assert the Mix task's call SHAPE without
  # actually running the fan-out (which would exercise the whole
  # StackDeployer chain). This fake records the call to the test
  # process for later assertion.

  defmodule RecordingProcessor do
    @moduledoc false

    def process_stack_merged_pr(stack, pr, merged_at, task_id) do
      pid = Process.get(:recording_pid) || self()
      send(pid, {:processed, stack.id, pr, merged_at, task_id})
      :ok
    end
  end

  setup do
    # Isolate FakeGhRunner state between tests — Process dict is
    # per-test-process anyway, but be explicit.
    on_exit(fn -> Process.delete({FakeGhRunner, :any}) end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Reprocess RollupPR #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/reprocess-rollup-pr"
      })

    %{project: project}
  end

  # ── Validation of option surface ────────────────────────────────────────

  describe "do_run/2 — required options" do
    test "missing --pr-number returns {:error, ...} and does not shell out" do
      output =
        capture_io(fn ->
          assert {:error, "--pr-number is required"} =
                   ReprocessRollupPr.do_run([repo: "x/y"], gh_runner: FakeGhRunner)
        end)

      assert output =~ "ABORT"
    end

    test "missing --repo returns {:error, ...} and does not shell out" do
      output =
        capture_io(fn ->
          assert {:error, msg} =
                   ReprocessRollupPr.do_run([pr_number: "1"], gh_runner: FakeGhRunner)

          assert msg =~ "--repo is required"
        end)

      assert output =~ "ABORT"
    end
  end

  # ── gh hydration failure paths ─────────────────────────────────────────

  describe "do_run/2 — gh runner failures" do
    test "gh shell error surfaces to the operator" do
      FakeGhRunner.put_response(
        {"569", "StartupSuite/core"},
        {:error, {:gh_exit, 1, "auth failed"}}
      )

      output =
        capture_io(fn ->
          assert {:error, {:gh_failed, {:gh_exit, 1, "auth failed"}}} =
                   ReprocessRollupPr.do_run(
                     [pr_number: "569", repo: "StartupSuite/core"],
                     gh_runner: FakeGhRunner
                   )
        end)

      assert output =~ "ABORT"
      assert output =~ "auth failed"
    end

    test "unmerged PR is refused (loudly)" do
      FakeGhRunner.put_response(
        {"569", "StartupSuite/core"},
        {:ok,
         %{
           "number" => 569,
           "merged" => false,
           "mergeCommit" => nil,
           "headRefName" => "stack/foo",
           "baseRefName" => "main",
           "mergedAt" => nil,
           "mergedBy" => nil,
           "htmlUrl" => "https://github.com/StartupSuite/core/pull/569",
           "user" => %{"login" => "op"}
         }}
      )

      output =
        capture_io(fn ->
          assert {:error, {:not_merged, msg}} =
                   ReprocessRollupPr.do_run(
                     [pr_number: "569", repo: "StartupSuite/core"],
                     gh_runner: FakeGhRunner
                   )

          assert msg =~ "PR #569"
        end)

      assert output =~ "ABORT"
    end
  end

  # ── Stack resolution ────────────────────────────────────────────────────

  describe "do_run/2 — stack resolution" do
    test "--stack-id bypasses the multi-strategy lookup and finds an explicit stack",
         %{project: project} do
      pr_number = System.unique_integer([:positive])

      {stack, _members} = build_stack_with_pending_members!(project, 3, pr_number)

      FakeGhRunner.put_response({to_string(pr_number), "test/repo"}, gh_ok_response(pr_number))

      output =
        capture_io(fn ->
          assert :ok =
                   ReprocessRollupPr.do_run(
                     [
                       pr_number: to_string(pr_number),
                       repo: "test/repo",
                       stack_id: stack.id
                     ],
                     gh_runner: FakeGhRunner,
                     processor: RecordingProcessor
                   )
        end)

      # No `--confirm` → dry-run, RecordingProcessor should NOT have
      # been invoked.
      refute_received {:processed, _, _, _, _}

      # Preview lists the members with their pending pr_merged
      # validation ids.
      assert output =~ "Stack has 3 member(s)"
      assert output =~ "pending pr_merged"
      assert output =~ "DRY-RUN"
    end

    test "no --stack-id + stack matches via rollup_branch: multi-strategy lookup fires",
         %{project: project} do
      pr_number = System.unique_integer([:positive])
      slug = "reprocess-happy-#{System.unique_integer([:positive])}"
      rollup_branch = "stack/#{slug}"

      {stack, _members} =
        build_stack_with_pending_members!(project, 2, pr_number,
          slug: slug,
          rollup_branch: rollup_branch
        )

      FakeGhRunner.put_response(
        {to_string(pr_number), "test/repo"},
        gh_ok_response(pr_number, head_ref: rollup_branch)
      )

      output =
        capture_io(fn ->
          assert :ok =
                   ReprocessRollupPr.do_run(
                     [pr_number: to_string(pr_number), repo: "test/repo"],
                     gh_runner: FakeGhRunner,
                     processor: RecordingProcessor
                   )
        end)

      assert output =~ "Resolved stack #{stack.id}"
      assert output =~ "DRY-RUN"
    end

    test "explicit --stack-id that does not exist returns {:error, :stack_not_found}" do
      pr_number = System.unique_integer([:positive])

      FakeGhRunner.put_response({to_string(pr_number), "test/repo"}, gh_ok_response(pr_number))

      bogus_id = Ecto.UUID.generate()

      output =
        capture_io(fn ->
          assert {:error, {:stack_not_found, ^bogus_id}} =
                   ReprocessRollupPr.do_run(
                     [
                       pr_number: to_string(pr_number),
                       repo: "test/repo",
                       stack_id: bogus_id
                     ],
                     gh_runner: FakeGhRunner
                   )
        end)

      assert output =~ "ABORT"
    end

    test "no --stack-id + no strategy matches → {:error, :stack_lookup_failed}" do
      pr_number = System.unique_integer([:positive])

      FakeGhRunner.put_response(
        {to_string(pr_number), "test/repo"},
        gh_ok_response(pr_number, head_ref: "task/019xyz-not-a-stack")
      )

      output =
        capture_io(fn ->
          assert {:error, {:stack_lookup_failed, msg}} =
                   ReprocessRollupPr.do_run(
                     [pr_number: to_string(pr_number), repo: "test/repo"],
                     gh_runner: FakeGhRunner
                   )

          assert msg =~ "no stack matched PR ##{pr_number}"
        end)

      assert output =~ "ABORT"
    end
  end

  # ── Dry-run vs --confirm ────────────────────────────────────────────────

  describe "do_run/2 — mutation gating" do
    test "dry-run leaves stack + members untouched", %{project: project} do
      pr_number = System.unique_integer([:positive])
      {stack, members} = build_stack_with_pending_members!(project, 2, pr_number)

      FakeGhRunner.put_response(
        {to_string(pr_number), "test/repo"},
        gh_ok_response(pr_number, head_ref: stack.rollup_branch)
      )

      capture_io(fn ->
        assert :ok =
                 ReprocessRollupPr.do_run(
                   [
                     pr_number: to_string(pr_number),
                     repo: "test/repo",
                     stack_id: stack.id
                   ],
                   gh_runner: FakeGhRunner
                 )
      end)

      # Stack still at seeded status, members still `in_review`, no
      # validations flipped.
      reloaded_stack = Repo.get!(Stack, stack.id)
      assert reloaded_stack.status == "deploying"

      for %{pr_validation: v} <- members do
        reloaded_v = Repo.get!(Validation, v.id)
        assert reloaded_v.status == "pending"
      end
    end

    test "--confirm invokes the processor exactly once with the translated payload",
         %{project: project} do
      pr_number = System.unique_integer([:positive])
      {stack, _members} = build_stack_with_pending_members!(project, 2, pr_number)

      FakeGhRunner.put_response(
        {to_string(pr_number), "test/repo"},
        gh_ok_response(pr_number, head_ref: stack.rollup_branch)
      )

      Process.put(:recording_pid, self())

      capture_io(fn ->
        assert :ok =
                 ReprocessRollupPr.do_run(
                   [
                     pr_number: to_string(pr_number),
                     repo: "test/repo",
                     stack_id: stack.id,
                     confirm: true
                   ],
                   gh_runner: FakeGhRunner,
                   processor: RecordingProcessor
                 )
      end)

      stack_id = stack.id

      assert_received {:processed, ^stack_id, pr, %DateTime{} = _merged_at, nil}

      # Payload was translated from gh --json shape into the webhook
      # shape the processor expects (nested head/base, snake_case sha).
      assert pr["number"] == pr_number
      assert pr["merged"] == true
      assert pr["head"]["ref"] == stack.rollup_branch
      assert pr["base"]["ref"] == "main"
      assert is_binary(pr["merge_commit_sha"])
      assert pr["html_url"] =~ "/pull/#{pr_number}"

      refute_received {:processed, _, _, _, _}
    end
  end

  # ── Payload shape translation (regression guard) ────────────────────────

  describe "to_webhook_shape/1" do
    test "translates gh --json shape to the pull_request webhook shape" do
      gh_pr = %{
        "number" => 42,
        "merged" => true,
        "mergeCommit" => %{"oid" => "deadbeef"},
        "headRefName" => "stack/example",
        "baseRefName" => "main",
        "mergedAt" => "2026-07-20T12:00:00Z",
        "mergedBy" => %{"login" => "human-merger"},
        "user" => %{"login" => "opener"},
        "htmlUrl" => "https://github.com/x/y/pull/42"
      }

      assert %{
               "number" => 42,
               "merged" => true,
               "merge_commit_sha" => "deadbeef",
               "head" => %{"ref" => "stack/example"},
               "base" => %{"ref" => "main"},
               "merged_at" => "2026-07-20T12:00:00Z",
               "merged_by" => %{"login" => "human-merger"},
               "user" => %{"login" => "opener"},
               "html_url" => "https://github.com/x/y/pull/42"
             } = ReprocessRollupPr.to_webhook_shape(gh_pr)
    end

    test "tolerates nil mergeCommit (unmerged edge cases)" do
      gh_pr = %{
        "number" => 43,
        "merged" => false,
        "mergeCommit" => nil,
        "headRefName" => "stack/example",
        "baseRefName" => "main",
        "mergedAt" => nil,
        "mergedBy" => nil,
        "user" => %{"login" => "opener"},
        "htmlUrl" => "https://github.com/x/y/pull/43"
      }

      assert %{"merge_commit_sha" => nil, "merged_at" => nil} =
               ReprocessRollupPr.to_webhook_shape(gh_pr)
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp gh_ok_response(pr_number, opts \\ []) do
    head_ref = Keyword.get(opts, :head_ref, "stack/reprocess-#{pr_number}")
    base_ref = Keyword.get(opts, :base_ref, "main")

    {:ok,
     %{
       "number" => pr_number,
       "merged" => true,
       "mergeCommit" => %{"oid" => "sha-#{pr_number}"},
       "headRefName" => head_ref,
       "baseRefName" => base_ref,
       "mergedAt" => "2026-07-20T12:00:00Z",
       "mergedBy" => %{"login" => "human-merger"},
       "htmlUrl" => "https://github.com/test/repo/pull/#{pr_number}",
       "user" => %{"login" => "opener"}
     }}
  end

  # Build a stack in the "webhook never fired" shape: stack at
  # `deploying` with `rollup_pr.number` stamped + rollup_branch set,
  # N members at `in_review` each carrying a pending pr_merged
  # validation on a running review stage.
  defp build_stack_with_pending_members!(project, member_count, pr_number, opts \\ [])
       when member_count > 0 do
    slug =
      Keyword.get(opts, :slug, "reprocess-#{pr_number}-#{System.unique_integer([:positive])}")

    rollup_branch = Keyword.get(opts, :rollup_branch, "stack/#{slug}")

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Reprocess Fixture #{slug}",
        base_branch: "main",
        rollup_branch: rollup_branch,
        metadata: %{
          "rollup_pr" => %{
            "number" => pr_number,
            "url" => "https://github.com/test/repo/pull/#{pr_number}",
            "opened_at" => "2026-07-19T00:00:00Z"
          }
        }
      })

    # Force stack to `deploying` — the pre-webhook steady state we're
    # simulating. Bypass changeset validation just like the cascade
    # backfill test does.
    stack =
      Stack
      |> Repo.get!(stack.id)
      |> Ecto.Changeset.change(status: "deploying")
      |> Repo.update!()

    members =
      for position <- 1..member_count do
        {:ok, task} =
          Tasks.create_task(%{
            project_id: project.id,
            title: "Reprocess member #{position}"
          })

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

    {stack, members}
  end
end
