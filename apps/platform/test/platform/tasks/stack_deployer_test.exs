defmodule Platform.Tasks.StackDeployerTest do
  use Platform.DataCase, async: false

  alias Platform.Tasks
  alias Platform.Tasks.{Stack, StackDeployer, Stacks}

  # ── Test git runner ───────────────────────────────────────────────────────
  #
  # An in-memory implementation of `Platform.Tasks.StackDeployer.GitRunner`
  # backed by an Agent. Tests configure the deployer to use this runner
  # and then assert against its captured calls and pre-seeded responses.

  defmodule FakeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    use Agent

    def start_link(opts) do
      initial = %{
        responses: Keyword.get(opts, :responses, []),
        default: Keyword.get(opts, :default, {:ok, %{status: :created, base_sha: "deadbee"}}),
        merge_responses: Keyword.get(opts, :merge_responses, []),
        merge_default:
          Keyword.get(opts, :merge_default, {:ok, %{status: :merged, merge_sha: "f00dbabe"}}),
        pr_responses: Keyword.get(opts, :pr_responses, []),
        pr_default:
          Keyword.get(
            opts,
            :pr_default,
            {:ok, %{number: 99, url: "https://github.com/test/repo/pull/99"}}
          ),
        diff_stat_responses: Keyword.get(opts, :diff_stat_responses, []),
        diff_stat_default: Keyword.get(opts, :diff_stat_default, {:ok, " 3 files changed"}),
        revert_responses: Keyword.get(opts, :revert_responses, []),
        revert_default:
          Keyword.get(
            opts,
            :revert_default,
            {:ok, %{status: :reverted, revert_sha: "revert0000"}}
          ),
        close_responses: Keyword.get(opts, :close_responses, []),
        close_default: Keyword.get(opts, :close_default, {:ok, :closed}),
        delete_responses: Keyword.get(opts, :delete_responses, []),
        delete_default: Keyword.get(opts, :delete_default, {:ok, :deleted}),
        # Bug #2 (task 019f708f). Reachability responses can be a plain
        # tuple that applies to every call, OR a `%{"sha" => response}`
        # map so a single test can queue different answers for
        # different member SHAs. Default is `{:ok, true}` — matches
        # NoopRunner and preserves pre-bug-#2 behavior for tests that
        # don't care about reachability.
        reachable_responses: Keyword.get(opts, :reachable_responses, %{}),
        reachable_default: Keyword.get(opts, :reachable_default, {:ok, true}),
        # Task 019f7b7e stage 4. The deployer calls
        # `list_added_migrations/1` TWICE per merge — once for the
        # member's added migrations (base = rollup) and once for those
        # already merged onto rollup (base = stack base_branch) — so
        # tests keyed responses by base_branch rather than queueing a
        # positional list, which would be brittle against call order.
        # Default `{:ok, []}` means "no migrations anywhere", the
        # no-collision case every pre-existing merge test expects.
        migrations_by_base: Keyword.get(opts, :migrations_by_base, %{}),
        migrations_default: Keyword.get(opts, :migrations_default, {:ok, []}),
        migrations_calls: [],
        calls: [],
        merge_calls: [],
        pr_calls: [],
        diff_stat_calls: [],
        revert_calls: [],
        close_calls: [],
        delete_calls: [],
        reachable_calls: []
      }

      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def stop, do: Agent.stop(__MODULE__)

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()
    def merge_calls, do: Agent.get(__MODULE__, & &1.merge_calls) |> Enum.reverse()
    def pr_calls, do: Agent.get(__MODULE__, & &1.pr_calls) |> Enum.reverse()
    def diff_stat_calls, do: Agent.get(__MODULE__, & &1.diff_stat_calls) |> Enum.reverse()
    def revert_calls, do: Agent.get(__MODULE__, & &1.revert_calls) |> Enum.reverse()
    def close_calls, do: Agent.get(__MODULE__, & &1.close_calls) |> Enum.reverse()
    def delete_calls, do: Agent.get(__MODULE__, & &1.delete_calls) |> Enum.reverse()
    def reachable_calls, do: Agent.get(__MODULE__, & &1.reachable_calls) |> Enum.reverse()
    def migrations_calls, do: Agent.get(__MODULE__, & &1.migrations_calls) |> Enum.reverse()

    @impl true
    def ensure_rollup_branch(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.responses do
            [head | rest] -> {head, rest}
            [] -> {state.default, []}
          end

        {response, %{state | calls: [args | state.calls], responses: remaining}}
      end)
      |> maybe_sleep()
    end

    # Stage 4: response tuples may be wrapped in `{:sleep, ms, actual}`
    # so a test can hold a caller inside the runner for `ms`
    # milliseconds — used by the advisory-lock concurrent-start tests.
    defp maybe_sleep({:sleep, ms, actual}) when is_integer(ms) and ms >= 0 do
      Process.sleep(ms)
      actual
    end

    defp maybe_sleep(other), do: other

    @impl true
    def merge_member_into_rollup(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.merge_responses do
            [head | rest] -> {head, rest}
            [] -> {state.merge_default, []}
          end

        {response, %{state | merge_calls: [args | state.merge_calls], merge_responses: remaining}}
      end)
      |> maybe_raise()
    end

    # Bug #1 test hook (task 019f708f): a queued response of the shape
    # `{:raise, message}` triggers a synchronous `raise RuntimeError, message`
    # so `handle_member_transition/3`'s new try/rescue is observable end-to-end.
    defp maybe_raise({:raise, message}) when is_binary(message), do: raise(RuntimeError, message)
    defp maybe_raise(other), do: other

    @impl true
    def open_stack_pr(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.pr_responses do
            [head | rest] -> {head, rest}
            [] -> {state.pr_default, []}
          end

        {response, %{state | pr_calls: [args | state.pr_calls], pr_responses: remaining}}
      end)
    end

    @impl true
    def diff_stat(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.diff_stat_responses do
            [head | rest] -> {head, rest}
            [] -> {state.diff_stat_default, []}
          end

        {response,
         %{
           state
           | diff_stat_calls: [args | state.diff_stat_calls],
             diff_stat_responses: remaining
         }}
      end)
    end

    @impl true
    def revert_member_merge(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.revert_responses do
            [head | rest] -> {head, rest}
            [] -> {state.revert_default, []}
          end

        {response,
         %{
           state
           | revert_calls: [args | state.revert_calls],
             revert_responses: remaining
         }}
      end)
    end

    @impl true
    def close_stack_pr(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.close_responses do
            [head | rest] -> {head, rest}
            [] -> {state.close_default, []}
          end

        {response,
         %{
           state
           | close_calls: [args | state.close_calls],
             close_responses: remaining
         }}
      end)
    end

    @impl true
    def delete_rollup_branch(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {response, remaining} =
          case state.delete_responses do
            [head | rest] -> {head, rest}
            [] -> {state.delete_default, []}
          end

        {response,
         %{
           state
           | delete_calls: [args | state.delete_calls],
             delete_responses: remaining
         }}
      end)
    end

    # Bug #2 (task 019f708f): return the queued reachability answer for
    # the requested SHA. `reachable_responses` may be a plain
    # `{:ok, boolean}` / `{:error, reason}` tuple (applies to every
    # call) OR a `%{"sha" => response}` map so one test can queue
    # distinct answers per SHA (e.g. a fabricated "deadbeef" returns
    # `{:ok, false}` while every other SHA returns `{:ok, true}`).
    @impl true
    def sha_reachable?(%{sha: sha} = args) do
      Agent.get_and_update(__MODULE__, fn state ->
        response =
          case state.reachable_responses do
            %{} = by_sha ->
              Map.get(by_sha, sha, state.reachable_default)

            other ->
              other || state.reachable_default
          end

        {response, %{state | reachable_calls: [args | state.reachable_calls]}}
      end)
    end

    # Task 019f7b7e stage 4: answer keyed on the requested base_branch.
    @impl true
    def list_added_migrations(%{base_branch: base} = args) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.migrations_by_base, base, state.migrations_default)

        {response, %{state | migrations_calls: [args | state.migrations_calls]}}
      end)
    end
  end

  setup do
    # Run the deployer synchronously in tests so we can observe results.
    prev = Application.get_env(:platform, :stack_deployer, [])

    Application.put_env(:platform, :stack_deployer,
      git_runner: FakeRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        FakeRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp project_with_repo!(opts \\ []) do
    repo_url = Keyword.get(opts, :repo_url, "https://github.com/test/stack-deployer-#{uniq()}")

    {:ok, project} =
      Tasks.create_project(%{
        name: "Stack Deployer Test #{uniq()}",
        repo_url: repo_url
      })

    project
  end

  defp project_without_repo! do
    {:ok, project} = Tasks.create_project(%{name: "No Repo #{uniq()}"})
    project
  end

  defp stack_for!(project, opts) do
    slug = Keyword.get(opts, :slug, "test-#{uniq()}")
    base = Keyword.get(opts, :base_branch, "main")

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stack #{slug}",
        base_branch: base,
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  # ── create_rollup_branch/1 ────────────────────────────────────────────────

  describe "create_rollup_branch/1" do
    test "happy path: runner is invoked with stack args and returns :created" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "abc1234"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "feature-x")

      assert {:ok, result} = StackDeployer.create_rollup_branch(stack)
      assert result.branch == "stack/feature-x"
      assert result.base_sha == "abc1234"
      assert result.status == :created
      assert %DateTime{} = result.created_at

      assert [call] = FakeRunner.calls()
      assert call.repo_url == project.repo_url
      assert call.base_branch == "main"
      assert call.rollup_branch == "stack/feature-x"
      assert call.project_id == project.id
      assert call.stack_id == stack.id
    end

    test "passes through a non-default base_branch" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "develop1"}}])

      project = project_with_repo!()

      stack =
        stack_for!(project, slug: "feature-y", base_branch: "develop")

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      assert [%{base_branch: "develop", rollup_branch: "stack/feature-y"}] =
               FakeRunner.calls()
    end

    test "idempotent: runner reports :already_exists → ok with status: :already_exists" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:ok, %{status: :already_exists, base_sha: "oldbase0"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "rerun")

      assert {:ok, result} = StackDeployer.create_rollup_branch(stack)
      assert result.status == :already_exists
      assert result.base_sha == "oldbase0"
      assert result.branch == "stack/rerun"
    end

    test "runner failure surfaces as {:error, reason} (does NOT raise)" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:error, {:git_failed, ["push", "origin", "x"], 128, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "auth-fail")

      assert {:error, {:git_failed, _, 128, "auth boom"}} =
               StackDeployer.create_rollup_branch(stack)

      assert [_] = FakeRunner.calls()
    end

    test "project missing repo_url → {:error, :no_repo_url} (no runner call)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "no-remote")

      assert {:error, :no_repo_url} = StackDeployer.create_rollup_branch(stack)
      assert FakeRunner.calls() == []
    end

    test "project deleted out from under us → {:error, :project_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      %Stack{} = stack = stack_for!(project, slug: "ghost")

      # Drop project_id to simulate a missing project lookup.
      stack = %Stack{stack | project_id: Ecto.UUID.generate()}

      assert {:error, :project_not_found} = StackDeployer.create_rollup_branch(stack)
      assert FakeRunner.calls() == []
    end

    # ─── ADR-0042 Decision 2: rollup_branch_ready stamp ───────────────────
    #
    # After a successful ensure_rollup_branch (either :created or
    # :already_exists), the deployer writes `stack.metadata["rollup_branch_ready"]`
    # so the HeartbeatScheduler's dispatch prompt can safely retarget member
    # branches from `origin/#{rollup_branch}` instead of the default branch.
    # A runner failure MUST NOT write the stamp — otherwise members would
    # dispatch against a non-existent rollup ref.

    test "stamps stack.metadata[rollup_branch_ready] with base_sha + timestamp on :created" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "abc1234"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "ready-created")

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      reloaded = Stacks.get_stack!(stack.id)
      ready = reloaded.metadata["rollup_branch_ready"]

      assert %{"at" => at, "base_sha" => "abc1234"} = ready
      assert {:ok, _, 0} = DateTime.from_iso8601(at)
    end

    test "stamps rollup_branch_ready even when runner reports :already_exists" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:ok, %{status: :already_exists, base_sha: "oldbase0"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "ready-idempotent")

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      reloaded = Stacks.get_stack!(stack.id)
      assert %{"base_sha" => "oldbase0"} = reloaded.metadata["rollup_branch_ready"]
    end

    test "does NOT stamp rollup_branch_ready when the runner fails" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:error, {:git_failed, ["push"], 128, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "no-stamp-on-fail")

      assert {:error, _} = StackDeployer.create_rollup_branch(stack)

      reloaded = Stacks.get_stack!(stack.id)
      refute Map.has_key?(reloaded.metadata || %{}, "rollup_branch_ready")
    end

    test "preserves prior stack.metadata keys when stamping" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "deadbee1"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "preserve-meta")

      # Pre-seed an unrelated metadata key that must survive.
      {:ok, stack} =
        Stacks.update_stack(stack, %{metadata: %{"phase_assignees" => %{"coding" => "agent-1"}}})

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      reloaded = Stacks.get_stack!(stack.id)
      assert reloaded.metadata["phase_assignees"] == %{"coding" => "agent-1"}
      assert %{"base_sha" => "deadbee1"} = reloaded.metadata["rollup_branch_ready"]
    end
  end

  # ── handle_stack_transition/3 ─────────────────────────────────────────────

  describe "handle_stack_transition/3" do
    test "fires create_rollup_branch on forming → in_progress" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "newbase0"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "transition")

      :ok = StackDeployer.handle_stack_transition(stack, :forming, :in_progress)

      assert [%{rollup_branch: "stack/transition"}] = FakeRunner.calls()
    end

    test "no-ops on other transitions" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "noop")

      :ok = StackDeployer.handle_stack_transition(stack, :in_progress, :in_review)
      :ok = StackDeployer.handle_stack_transition(stack, :forming, :abandoned)
      :ok = StackDeployer.handle_stack_transition(stack, :in_review, :deploying)

      assert FakeRunner.calls() == []
    end

    test "runner error is swallowed (returns :ok); never raises" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:error, {:git_failed, ["push"], 1, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "swallow")

      assert :ok = StackDeployer.handle_stack_transition(stack, :forming, :in_progress)

      assert [_] = FakeRunner.calls()
    end
  end

  # ── handle_stack_created/1 ────────────────────────────────────────────────

  describe "handle_stack_created/1" do
    test "fires create_rollup_branch at create-time with stack args" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "created00"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "created-hook")

      :ok = StackDeployer.handle_stack_created(stack)

      assert [call] = FakeRunner.calls()
      assert call.rollup_branch == "stack/created-hook"
      assert call.base_branch == "main"
      assert call.project_id == project.id
      assert call.repo_url == project.repo_url
    end

    test "project missing repo_url → no runner call, no raise" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "created-no-remote")

      assert :ok = StackDeployer.handle_stack_created(stack)
      assert FakeRunner.calls() == []
    end

    test "runner error is swallowed (returns :ok); never raises" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:error, {:git_failed, ["push"], 1, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "created-swallow")

      assert :ok = StackDeployer.handle_stack_created(stack)
      assert [_] = FakeRunner.calls()
    end

    test "idempotent against handle_stack_transition/3 (both call ensure_rollup_branch)" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [
            {:ok, %{status: :created, base_sha: "first000"}},
            {:ok, %{status: :already_exists, base_sha: "first000"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "created-idempotent")

      assert :ok = StackDeployer.handle_stack_created(stack)
      assert :ok = StackDeployer.handle_stack_transition(stack, :forming, :in_progress)

      assert [
               %{rollup_branch: "stack/created-idempotent"},
               %{rollup_branch: "stack/created-idempotent"}
             ] =
               FakeRunner.calls()
    end
  end

  # ── Stacks.start_stack/1 integration ──────────────────────────────────────

  describe "integration with Stacks.start_stack/1" do
    test "starting a stack triggers create_rollup_branch via the deployer hook" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "rooooot1"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "start-hook")

      # Cascade needs a root with an approved plan; otherwise the start
      # produces `:partial` (still triggers the deployer because the
      # stack-level status flip succeeds).
      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})

      assert {:ok, %{stack: started}} = Stacks.start_stack(stack)
      assert started.status == "in_progress"

      assert [call] = FakeRunner.calls()
      assert call.rollup_branch == "stack/start-hook"
      assert call.repo_url == project.repo_url
    end

    test "deployer error does NOT crash or alter the cascade result" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:error, {:git_failed, ["push"], 128, "permission denied"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "boom-deploy")

      {:ok, root} = Tasks.create_task(%{project_id: project.id, title: "Root"})
      {:ok, _} = Stacks.add_task(stack, root)
      {:ok, _} = Tasks.create_plan(%{task_id: root.id, status: "approved"})

      assert {:ok, %{stack: started, started: started_tasks}} = Stacks.start_stack(stack)
      assert started.status == "in_progress"
      assert length(started_tasks) == 1
      assert [_] = FakeRunner.calls()
    end

    test "no deployer call if start_stack rejects with :invalid_stack_status" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "already-going")
      {:ok, advanced} = Stacks.update_stack(stack, %{status: "in_progress"})

      assert {:error, :invalid_stack_status} = Stacks.start_stack(advanced)
      assert FakeRunner.calls() == []
    end
  end

  # ── GitShellRunner repo path resolution (smoke test of pure helper) ───────

  describe "GitShellRunner clone path scoping" do
    # Smoke-test the side-effect-free piece (clone_path_for + repo_root)
    # by configuring a custom repo_root and confirming the runner derives
    # a project-scoped subdirectory. Full git shell-out is exercised by
    # the e2e_behavior validation in stage 6 (a real bare repo on disk).

    test "ensure_rollup_branch on missing args returns {:error, :invalid_args}" do
      assert {:error, {:invalid_args, _}} =
               Platform.Tasks.StackDeployer.GitShellRunner.ensure_rollup_branch(%{})
    end

    test "merge_member_into_rollup on missing args returns {:error, :invalid_args}" do
      assert {:error, {:invalid_args, _}} =
               Platform.Tasks.StackDeployer.GitShellRunner.merge_member_into_rollup(%{})
    end

    # Regression for the moon container /app permission-denied crash on
    # 2026-07-17: the previous default `@default_repo_root "tmp/stack_deployer"`
    # `Path.expand`ed to `<CWD>/tmp/stack_deployer` — inside the release image
    # that resolved to `/app/tmp/stack_deployer`, which the beam (running as
    # UID 1000) could not `File.mkdir_p!/1` because `/app` was owned by root.
    # This test exercises the `ensure_clone/2` mkdir_p call with NO config
    # override in place, so the default runtime path is the only thing under
    # test. We deliberately use a bogus repo_url so the subsequent `git clone`
    # fails fast — we only care that the parent directory got created under a
    # writable location (System.tmp_dir!/0).
    test "default repo_root falls back to System.tmp_dir!/0 (writable in containers)" do
      # Force no override — the OTP config may have one set for the test env,
      # so remove it for the duration of the test. Restore on exit even if
      # the test crashes so we don't leak into sibling tests.
      original_config = Application.get_env(:platform, :stack_deployer)
      on_exit(fn -> Application.put_env(:platform, :stack_deployer, original_config) end)
      Application.delete_env(:platform, :stack_deployer)

      project_id = "test-#{System.unique_integer([:positive])}"
      expected_parent = Path.join(System.tmp_dir!(), "stack_deployer")
      expected_clone_path = Path.join(expected_parent, project_id)

      # Clean any stale scratch dir from prior runs of this project_id.
      on_exit(fn -> File.rm_rf(expected_clone_path) end)

      # A bogus repo_url guarantees `git clone` fails, but ensure_clone's
      # `File.mkdir_p!(Path.dirname(clone_path))` runs first — which is
      # exactly the call that crashed prod under the old hardcoded path.
      result =
        Platform.Tasks.StackDeployer.GitShellRunner.ensure_rollup_branch(%{
          repo_url: "file:///nonexistent/repo-for-mkdir-smoke-test.git",
          base_branch: "main",
          rollup_branch: "stack/mkdir-smoke",
          project_id: project_id
        })

      # We expect the clone to fail (bogus URL), NOT a mkdir_p crash.
      assert match?({:error, {:git_clone_failed, _, _}}, result),
             "expected git_clone_failed after mkdir_p succeeded, got #{inspect(result)}"

      # The parent directory must exist under System.tmp_dir!/0 — proving
      # the default runtime path resolved to a writable location.
      assert File.dir?(expected_parent),
             "expected parent directory #{expected_parent} to exist after ensure_clone/2"
    end
  end

  # ── merge_member_into_rollup/1 (stage 2) ─────────────────────────────────

  describe "merge_member_into_rollup/1" do
    test "happy path: review-ready member is merged and metadata is stamped" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "abc123def456"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "happy")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abc123def456", merged_at: %DateTime{}}} =
               StackDeployer.merge_member_into_rollup(task)

      # Member metadata stamped.
      reloaded = Tasks.get_task_record(task.id)
      stamp = reloaded.metadata["merged_into_rollup_at"]
      assert is_map(stamp)
      assert stamp["sha"] == "abc123def456"
      assert is_binary(stamp["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])

      # Runner was called with the right args.
      assert [call] = FakeRunner.merge_calls()
      assert call.repo_url == project.repo_url
      assert call.rollup_branch == stack.rollup_branch
      assert String.starts_with?(call.member_branch, "task/")
      assert call.member_slug == call.member_branch |> String.trim_leading("task/")
      assert call.project_id == project.id
      assert call.stack_id == stack.id
      assert call.member_task_id == task.id
    end

    test "conflict path: stack flips to blocked with metadata.conflict populated" do
      conflict_files = ["lib/foo.ex", "lib/bar.ex"]

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [
            {:error, :conflict, %{files: conflict_files, output: "CONFLICT (content): boom"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "conflict")
      task = review_ready_member!(project, stack)

      assert {:error, :conflict, ^conflict_files} =
               StackDeployer.merge_member_into_rollup(task)

      reloaded_stack = Stacks.get_stack(stack.id)
      assert reloaded_stack.status == "blocked"
      assert is_map(reloaded_stack.metadata)
      conflict = reloaded_stack.metadata["conflict"]
      assert conflict["member_task_id"] == task.id
      assert conflict["files"] == conflict_files
      assert is_binary(conflict["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(conflict["at"])

      # Member metadata NOT stamped on conflict.
      reloaded_task = Tasks.get_task_record(task.id)
      assert is_nil(get_in(reloaded_task.metadata, ["merged_into_rollup_at"]))
    end

    test "idempotency: already-merged member returns {:ok, :already_merged}" do
      {:ok, _} = FakeRunner.start_link(merge_responses: [])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "idempotent")
      task = review_ready_member!(project, stack)

      {:ok, task} =
        Tasks.update_task(task, %{
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "deadbeef",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_merged} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    # ── ADR-0042 Decision 2: fast-forward-only merge + pause-on-diverge ──
    #
    # Stage 1 makes every `task/<uuid>` branch cut FROM rollup HEAD so a
    # validated pass fast-forwards trivially. If the branch diverges
    # (someone rebased manually, a race left the cut against a stale
    # rollup, etc.) the runner reports `:not_fast_forwardable` and the
    # deployer PAUSES the task with `metadata["paused_reason"]` — it
    # does NOT flip the stack to `blocked` (that's reserved for genuine
    # conflicts). No auto-rebase — the human is expected to rebase the
    # task branch onto rollup HEAD to unstick.

    test "fast-forward merge stamps merged_at; stack NOT flipped to blocked; no paused_reason" do
      # Two members so the stack-PR gate stays :not_ready after the
      # first merge — that keeps this test focused on the merge path
      # and prevents the maybe_open_stack_pr hook from flipping the
      # stack to `deploying` as a benign side effect.
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "ffabc123"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "ff-happy")
      _unmerged = unmerged_member!(project, stack, position: 2)
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "ffabc123"}} =
               StackDeployer.merge_member_into_rollup(task)

      # Member metadata stamped.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == "ffabc123"
      assert is_binary(reloaded.metadata["merged_into_rollup_at"]["at"])
      # No pause stamp on the happy path.
      refute Map.has_key?(reloaded.metadata || %{}, "paused_reason")

      # Stack is NOT flipped to blocked (that's reserved for genuine
      # conflicts). No conflict metadata written. The maybe_open_stack_pr
      # hook stays :not_ready because a sibling remains unmerged, so the
      # stack status is untouched by this merge.
      reloaded_stack = Stacks.get_stack(stack.id)
      refute reloaded_stack.status == "blocked"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "conflict")
      assert is_nil(get_in(reloaded_stack.metadata || %{}, ["rollup_pr"]))
    end

    test "non-fast-forwardable halts task with paused_reason; stack status UNCHANGED" do
      diverge_detail = %{
        member_sha: "memberdead",
        rollup_sha: "rollupbeef",
        output: "fatal: Not possible to fast-forward, aborting."
      }

      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:error, :not_fast_forwardable, diverge_detail}])

      # Subscribe to the new telemetry event so we can prove it fires.
      handler_id = "test-not-ff-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stack_deployer, :not_fast_forwardable],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "diverged")
      task = review_ready_member!(project, stack)

      original_status = Stacks.get_stack(stack.id).status

      assert {:error, :not_fast_forwardable,
              %{member_sha: "memberdead", rollup_sha: "rollupbeef"}} =
               StackDeployer.merge_member_into_rollup(task)

      # Task metadata stamped with rollup_diverged paused_reason.
      reloaded_task = Tasks.get_task_record(task.id)
      paused = reloaded_task.metadata["paused_reason"]
      assert paused["kind"] == "rollup_diverged"
      assert paused["member_sha"] == "memberdead"
      assert paused["rollup_sha"] == "rollupbeef"
      assert paused["output"] =~ "Not possible to fast-forward"
      assert is_binary(paused["at"])
      assert {:ok, _, _} = DateTime.from_iso8601(paused["at"])

      # Merged-into-rollup NOT stamped (task didn't actually merge).
      assert is_nil(get_in(reloaded_task.metadata, ["merged_into_rollup_at"]))

      # Stack status UNCHANGED — divergence is task-scoped, not stack-scoped.
      reloaded_stack = Stacks.get_stack(stack.id)
      assert reloaded_stack.status == original_status
      refute reloaded_stack.status == "blocked"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "conflict")

      # Telemetry fired with expected metadata.
      assert_received {:telemetry, [:platform, :stack_deployer, :not_fast_forwardable],
                       %{count: 1},
                       %{
                         task_id: t_id,
                         stack_id: s_id,
                         member_sha: "memberdead",
                         rollup_sha: "rollupbeef"
                       }}

      assert t_id == task.id
      assert s_id == stack.id
    end

    test "non-conflict runner failure surfaces as {:error, reason}; stack not blocked" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:error, {:git_failed, ["push"], 128, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "auth-fail")
      task = review_ready_member!(project, stack)

      assert {:error, {:git_failed, _, 128, "auth boom"}} =
               StackDeployer.merge_member_into_rollup(task)

      reloaded_stack = Stacks.get_stack(stack.id)
      # Status is whatever the rollup recompute set it to (in_review or
      # earlier given the single in_review member). It must NOT be blocked.
      refute reloaded_stack.status == "blocked"
      refute Map.has_key?(reloaded_stack.metadata || %{}, "conflict")
    end

    test "non-stack member returns {:error, :not_in_stack}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      {:ok, lone_task} = Tasks.create_task(%{project_id: project.id, title: "Lone"})

      assert {:error, :not_in_stack} = StackDeployer.merge_member_into_rollup(lone_task)
      assert FakeRunner.merge_calls() == []
    end

    test "task at in_progress (not in_review) is :not_ready" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "too-early")
      task = stack_member_at_in_progress!(project, stack)

      assert {:ok, :not_ready} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "task at in_review with a pending review validation is :not_ready" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "still-running")
      task = stack_member_at_in_review_with_pending_review!(project, stack)

      assert {:ok, :not_ready} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "project missing repo_url → {:error, :no_repo_url}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "no-remote-merge")
      task = review_ready_member!(project, stack)

      assert {:error, :no_repo_url} = StackDeployer.merge_member_into_rollup(task)
      assert FakeRunner.merge_calls() == []
    end

    test "lookup-by-id: passing a binary task_id resolves to the record" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "bb1d000"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "byid")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "bb1d000"}} =
               StackDeployer.merge_member_into_rollup(task.id)
    end

    test "lookup-by-id: missing task returns {:error, :task_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :task_not_found} =
               StackDeployer.merge_member_into_rollup(Ecto.UUID.generate())
    end
  end

  # ── transition_task hook fires merge ─────────────────────────────────────

  describe "transition_task/2 → merge_member_into_rollup hook" do
    test "transitioning a stack member into in_review fires the runner merge" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "ab1c0ee"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "trigger")
      task = stack_member_at_in_progress!(project, stack)
      _ = pass_review_validations_for!(task)

      assert {:ok, updated} = Tasks.transition_task(task, "in_review")
      assert updated.status == "in_review"

      assert [call] = FakeRunner.merge_calls()
      assert call.member_task_id == task.id
      assert call.rollup_branch == stack.rollup_branch

      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == "ab1c0ee"
    end

    test "transitioning a non-stack task into in_review does NOT call the runner" do
      {:ok, _} = FakeRunner.start_link(merge_responses: [])

      project = project_with_repo!()
      task = lone_task_at_in_progress!(project)

      assert {:ok, _updated} = Tasks.transition_task(task, "in_review")
      assert FakeRunner.merge_calls() == []
    end

    test "merge runner failure does NOT crash the transition" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:error, {:git_failed, ["push"], 1, "boom"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "swallow-merge")
      task = stack_member_at_in_progress!(project, stack)
      _ = pass_review_validations_for!(task)

      assert {:ok, updated} = Tasks.transition_task(task, "in_review")
      assert updated.status == "in_review"
      assert [_] = FakeRunner.merge_calls()
    end
  end

  # ── Bug #1 (task 019f708f): try/rescue blocker on async merge raise ──────
  #
  # `Task.Supervisor.async_nolink` was silently swallowing any exception
  # raised inside the fn, stranding the member in `deploying` forever.
  # `handle_member_transition/3` now wraps the merge in try/rescue and, on
  # rescue, files an `execution.blocked` runtime event with
  # `needs_human: true` (mirrors the shape used by
  # `tool_surface.ex`'s `report_blocker`).

  describe "handle_member_transition/3 try/rescue blocker path" do
    test "runner raise fires an execution.blocked runtime event and returns :ok (async: false)" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:raise, "simulated merge failure: git conflict"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "blocker-raise")
      task = stack_member_at_in_review!(project, stack)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")
        end)

      assert log =~ "rollup merge raised"
      assert log =~ "simulated merge failure: git conflict"

      # Runtime event was recorded with the expected shape.
      import Ecto.Query

      events =
        Platform.Orchestration.RuntimeEvent
        |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
        |> Platform.Repo.all()

      assert [event] = events
      assert event.runtime_id == "stack_deployer"
      assert event.phase == "execution"
      assert event.payload["needs_human"] == true
      assert event.payload["reported_by"] == "stack_deployer"
      assert event.payload["stage_id"] == nil
      assert event.payload["description"] =~ "simulated merge failure: git conflict"
      assert event.payload["description"] =~ "Rollup merge raised"

      # The merge WAS attempted (runner was invoked once) before the raise.
      assert [_] = FakeRunner.merge_calls()
    end

    test "happy path does NOT fire a blocker" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "aabbc01"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "blocker-happy")
      task = stack_member_at_in_review!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert Platform.Orchestration.RuntimeEvent
             |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
             |> Platform.Repo.all() == []
    end

    # Gap 1 FIX 2 (task 019f921d) INVERTS the previous contract: a
    # `{:error, reason}` RETURN from the merge (git shell failure, auth,
    # network) now escalates a needs_human blocker instead of silently
    # stranding the member in `deploying`. See the dedicated escalation
    # tests below for the full benign/escalate matrix.
    test "runner {:error, reason} return NOW fires a needs_human blocker (Gap 1 FIX 2)" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:error, {:git_failed, ["push"], 128, "auth"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "blocker-tuple-error")
      task = stack_member_at_in_review!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      events =
        Platform.Orchestration.RuntimeEvent
        |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
        |> Platform.Repo.all()

      assert [event] = events
      assert event.runtime_id == "stack_deployer"
      assert event.payload["needs_human"] == true
      assert event.payload["reported_by"] == "stack_deployer"
      assert event.payload["description"] =~ "Rollup merge returned error"
      assert event.payload["description"] =~ "git_failed"
    end
  end

  # ── Gap 1 (task 019f921d): durable rollup-branch creation ────────────────
  #
  # FIX 1 — `do_merge_member/3` ensures the rollup branch exists before the
  # merge shell-out (a lost async create otherwise merges into a missing
  # ref). FIX 2 — `attempt_member_merge/1` escalates `{:error, _}` RETURNS,
  # not just raises, to a needs_human blocker; benign outcomes do NOT
  # double-file.

  describe "Gap 1 FIX 1: do_merge_member ensures the rollup branch" do
    test "ensures a missing rollup branch (branch absent → ensure creates → merge succeeds)" do
      # `responses` feeds the ensure_rollup_branch runner call; a fresh
      # `:created` result proves the branch was absent and ensure made it.
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:ok, %{status: :created, base_sha: "basecafe"}}],
          merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef01"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-ensure")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abcdef01"}} =
               StackDeployer.merge_member_into_rollup(task)

      # ensure_rollup_branch was invoked (branch was created) BEFORE the merge.
      assert [ensure_call] = FakeRunner.calls()
      assert ensure_call.rollup_branch == stack.rollup_branch
      assert [merge_call] = FakeRunner.merge_calls()
      assert merge_call.member_task_id == task.id

      # Member stamped — the merge actually landed.
      reloaded = Tasks.get_task_record(task.id)
      assert reloaded.metadata["merged_into_rollup_at"]["sha"] == "abcdef01"
    end

    test "already-existing rollup branch short-circuits ensure and still merges" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [{:ok, %{status: :already_exists, base_sha: "basecafe"}}],
          merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef02"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-exists")
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abcdef02"}} =
               StackDeployer.merge_member_into_rollup(task)

      assert [_ensure] = FakeRunner.calls()
      assert [_merge] = FakeRunner.merge_calls()
    end

    test "persistent ensure failure returns {:error, {:rollup_branch_unavailable, _}} and does NOT merge" do
      {:ok, _} =
        FakeRunner.start_link(
          # Every ensure attempt fails.
          responses: [],
          default: {:error, :ensure_boom},
          merge_responses: [{:ok, %{status: :merged, merge_sha: "should-not-happen"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-unavailable")
      task = review_ready_member!(project, stack)

      assert {:error, {:rollup_branch_unavailable, :ensure_boom}} =
               StackDeployer.merge_member_into_rollup(task)

      # The merge runner was NEVER invoked — we refuse to merge into a
      # branch we could not ensure.
      assert FakeRunner.merge_calls() == []

      # Member NOT stamped.
      reloaded = Tasks.get_task_record(task.id)
      assert is_nil(get_in(reloaded.metadata || %{}, ["merged_into_rollup_at"]))
    end
  end

  describe "Gap 1 FIX 2: attempt_member_merge escalates error returns" do
    test "a {:rollup_branch_unavailable, _} error return fires a needs_human blocker" do
      {:ok, _} =
        FakeRunner.start_link(
          responses: [],
          default: {:error, :ensure_boom}
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-esc-branch")
      task = stack_member_at_in_review!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert [event] =
               Platform.Orchestration.RuntimeEvent
               |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
               |> Platform.Repo.all()

      assert event.payload["needs_human"] == true
      assert event.payload["description"] =~ "rollup_branch_unavailable"
    end

    test "benign {:ok, :not_ready} does NOT fire a blocker" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-benign-notready")
      # A member at in_progress (not in_review) yields {:ok, :not_ready}.
      task = stack_member_at_in_progress!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert Platform.Orchestration.RuntimeEvent
             |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
             |> Platform.Repo.all() == []
    end

    test "benign {:ok, :already_merged} does NOT fire a blocker" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-benign-merged")
      task = stack_member_at_in_review!(project, stack)

      {:ok, _} =
        Tasks.update_task(task, %{
          metadata: %{
            "merged_into_rollup_at" => %{
              "sha" => "deadbeef",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      task = Tasks.get_task_record(task.id)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert Platform.Orchestration.RuntimeEvent
             |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
             |> Platform.Repo.all() == []
    end

    test "conflict return does NOT double-file a blocker (records its own conflict)" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [
            {:error, :conflict, %{files: ["lib/foo.ex"], output: "CONFLICT"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-conflict-nodup")
      task = stack_member_at_in_review!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert Platform.Orchestration.RuntimeEvent
             |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
             |> Platform.Repo.all() == []
    end

    test "divergence (:not_fast_forwardable) return does NOT double-file a blocker" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [
            {:error, :not_fast_forwardable, %{member_sha: "m", rollup_sha: "r", output: "not ff"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap1-diverge-nodup")
      task = stack_member_at_in_review!(project, stack)

      assert :ok = StackDeployer.handle_member_transition(task, "in_progress", "in_review")

      import Ecto.Query

      assert Platform.Orchestration.RuntimeEvent
             |> where([e], e.task_id == ^task.id and e.event_type == "execution.blocked")
             |> Platform.Repo.all() == []
    end
  end

  # ── Gap 2 (task 019f921d): stamp_merged advances the deploy tail ─────────
  #
  # A plan-complete member whose async merge stamp lands AFTER its
  # validations passed was stranded at `in_review` (M2-M5) because the
  # advance fired only on a validation-pass event or the 5-min sweep.
  # `stamp_merged/2` now drives `advance_member_to_deploying/1` off the
  # stamp it just wrote, causally, for EVERY member. Stack members carry a
  # `deploy_target` in production (the deploy-tail resolves
  # `no_op_wait_for_rollup`); the fixtures set it to mirror that.

  describe "Gap 2: stamp_merged advances member in_review -> deploying" do
    test "a merged member auto-advances to deploying with NO later validation-pass event" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef11"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap2-advance")
      # A second, unmerged member keeps the stack-PR gate `:not_ready`, so
      # this test isolates the per-member deploy-tail advance.
      _other = unmerged_member!(project, stack, position: 2)
      task = deployable_review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abcdef11"}} =
               StackDeployer.merge_member_into_rollup(task)

      # The member advanced in_review -> deploying purely off its own merge
      # stamp — no validation-pass event was fired after the merge.
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "advance is idempotent: a second merge attempt does not double-transition or crash" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef22"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap2-idempotent")
      _other = unmerged_member!(project, stack, position: 2)
      task = deployable_review_ready_member!(project, stack)

      assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)
      assert Tasks.get_task_record(task.id).status == "deploying"

      # Re-running the merge sees the existing stamp → {:ok, :already_merged},
      # never re-stamps and never re-advances.
      reloaded = Tasks.get_task_record(task.id)
      assert {:ok, :already_merged} = StackDeployer.merge_member_into_rollup(reloaded)
      assert Tasks.get_task_record(task.id).status == "deploying"

      # And an explicit redundant advance (the maybe_retrigger backstop) is
      # a no-op, not a crash or double-transition (self-guards on status).
      assert :noop = Stacks.advance_member_to_deploying(Tasks.get_task_record(task.id))
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    test "a member at deploying whose rollup PR already merged self-completes to done (existing path unbroken)" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef33"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap2-selfcomplete")
      task = deployable_review_ready_member!(project, stack)

      assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)

      # Stamp the stack's rollup PR as merged, then drive the deploying
      # member: the existing complete_no_op_member_if_rollup_merged path
      # must still self-complete deploying -> done.
      stack = Stacks.get_stack(stack.id)
      base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

      {:ok, _} =
        Stacks.update_stack(stack, %{
          metadata:
            Map.put(base_meta, "rollup_pr", %{
              "number" => 4242,
              "url" => "https://github.com/test/repo/pull/4242",
              "merged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
        })

      member = Tasks.get_task_record(task.id)
      assert member.status == "deploying"
      assert {:ok, done} = Stacks.complete_no_op_member_if_rollup_merged(member)
      assert done.status == "done"
    end
  end

  # A review-ready stack member that also carries a `deploy_target` (like a
  # real dispatched stack member), so the `in_review -> deploying` advance
  # resolves the `no_op_wait_for_rollup` strategy instead of failing with
  # `:no_deploy_target_resolved`.
  defp deployable_review_ready_member!(project, stack) do
    task = review_ready_member!(project, stack)
    {:ok, _} = Tasks.update_task(task, %{deploy_target: "production"})
    Tasks.get_task_record(task.id)
  end

  # Bug #1 test helper: a stack member sitting AT in_review with a passed
  # review stage so `handle_member_transition/3` treats the transition as
  # authoritative. We DO NOT drive it through `Tasks.transition_task/2`
  # here — the fixture directly stages the record so we can invoke the
  # deployer hook independently and observe both the happy and rescue
  # paths.
  defp stack_member_at_in_review!(project, stack) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Blocker Member #{uniq()}",
        status: "in_review"
      })

    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

    Tasks.get_task_record(task.id)
  end

  # ── Stage 2 helpers ───────────────────────────────────────────────────────

  defp review_ready_member!(project, stack) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Member #{uniq()}", status: "in_review"})

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    # Plan + review stage with ALL validations passed → review_ready? == true.
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "passed"})

    Tasks.get_task_record(task.id)
  end

  defp stack_member_at_in_review_with_pending_review!(project, stack) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Pending #{uniq()}",
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Task-level review",
        status: "running"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval", status: "pending"})

    Tasks.get_task_record(task.id)
  end

  defp stack_member_at_in_progress!(project, stack) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member #{uniq()}"})
    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: 1})
    # Approved plan required to allow transition into in_review later.
    {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    # ADR 0042 Decision 4: the commencement gate requires stack.status
    # == "in_progress" before a member can enter in_progress. Flip the
    # stack directly (bypassing start_stack cascade side effects) so
    # this helper only exercises the deployer hook it's meant to test.
    stack
    |> Ecto.Changeset.change(status: "in_progress")
    |> Platform.Repo.update!()

    {:ok, task} = Tasks.transition_task(task, "in_progress")
    Tasks.get_task_record(task.id)
  end

  defp lone_task_at_in_progress!(project) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Lone #{uniq()}"})
    {:ok, _} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, task} = Tasks.transition_task(task, "in_progress")
    task
  end

  # Add a passed review-stage validation set so review_ready?/1 returns true.
  defp pass_review_validations_for!(%{id: task_id}) do
    [plan] = Tasks.list_plans(task_id)

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 99,
        name: "Task-level review",
        status: "passed"
      })

    {:ok, _} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "lint_pass", status: "passed"})

    :ok
  end

  # ── maybe_open_stack_pr/1 (stage 4) ──────────────────────────────────────

  describe "maybe_open_stack_pr/1 — gate" do
    test "members partially merged → {:ok, :not_ready}; no PR shell-out" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "partial")

      # 4 members; only 3 stamped as merged.
      _ = merged_member!(project, stack, sha: "aaa1", position: 1)
      _ = merged_member!(project, stack, sha: "bbb2", position: 2)
      _ = merged_member!(project, stack, sha: "ccc3", position: 3)
      _ = unmerged_member!(project, stack, position: 4)

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "all members merged → stack flips to deploying, ONE PR opened, metadata.rollup_pr set" do
      pr_url = "https://github.com/test/repo/pull/137"

      {:ok, _} =
        FakeRunner.start_link(pr_responses: [{:ok, %{number: 137, url: pr_url}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "all-ready")

      _ = merged_member!(project, stack, sha: "shaone1", position: 1, title: "First member")
      _ = merged_member!(project, stack, sha: "shatwo2", position: 2, title: "Second member")
      _ = merged_member!(project, stack, sha: "shathr3", position: 3, title: "Third member")
      _ = merged_member!(project, stack, sha: "shafou4", position: 4, title: "Fourth member")

      assert {:ok, %{status: :opened, number: 137, url: ^pr_url, stack: deployed}} =
               StackDeployer.maybe_open_stack_pr(stack)

      assert deployed.status == "deploying"
      assert deployed.metadata["rollup_pr"]["number"] == 137
      assert deployed.metadata["rollup_pr"]["url"] == pr_url
      assert is_binary(deployed.metadata["rollup_pr"]["opened_at"])

      # Exactly ONE pr_create shell-out.
      assert [pr_call] = FakeRunner.pr_calls()
      assert pr_call.repo_url == project.repo_url
      assert pr_call.base_branch == stack.base_branch
      assert pr_call.rollup_branch == stack.rollup_branch
      assert pr_call.title == stack.name
      assert pr_call.project_id == project.id
      assert pr_call.stack_id == stack.id
    end

    test "empty stack → {:ok, :not_ready} (gate excludes 0-member stacks)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "empty")

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []
    end

    test "member status outside [in_review, deploying] → {:ok, :not_ready}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "wrong-status")

      # All 2 members have merged_into_rollup_at stamps, but one is
      # at "in_progress" (e.g. someone manually rolled it back). The
      # gate must reject.
      _ = merged_member!(project, stack, sha: "okay111", position: 1)

      m2 = merged_member!(project, stack, sha: "okay222", position: 2)
      {:ok, _} = Tasks.update_task(m2, %{status: "in_progress"})

      assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
      assert FakeRunner.pr_calls() == []
    end

    # ── Bug #2 (task 019f708f): reachability gate on all_members_ready?/2 ─

    test "member with unreachable stamp sha → {:ok, :not_ready}; no PR shell-out; warning logged" do
      # One of three merged members carries a stamp whose SHA the
      # runner reports NOT reachable from the rollup tip (fabricated
      # or reverted-out). all_members_ready? must veto the open.
      {:ok, _} =
        FakeRunner.start_link(
          reachable_responses: %{
            # Fabricated stamp: NOT reachable.
            "deadbeef" => {:ok, false},
            # Real stamps: reachable.
            "0ea0001" => {:ok, true},
            "0ea0002" => {:ok, true}
          }
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "unreachable-stamp")

      _ = merged_member!(project, stack, sha: "0ea0001", position: 1)
      offender = merged_member!(project, stack, sha: "deadbeef", position: 2)
      _ = merged_member!(project, stack, sha: "0ea0002", position: 3)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
        end)

      # Warning names the offender and its unreachable sha.
      assert log =~ "all_members_ready?"
      assert log =~ offender.id
      assert log =~ "deadbeef"
      assert log =~ "not reachable"
      assert log =~ stack.rollup_branch

      # No PR shell-out.
      assert FakeRunner.pr_calls() == []
      # Reachability runner WAS invoked (at least the offender).
      assert FakeRunner.reachable_calls() != []
    end

    test "reachability check errors are treated as unreachable (conservative gate)" do
      {:ok, _} =
        FakeRunner.start_link(
          reachable_responses: %{"bad0001" => {:error, :network_boom}, "a000001" => {:ok, true}}
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "unreachable-error")

      _ = merged_member!(project, stack, sha: "a000001", position: 1)
      _ = merged_member!(project, stack, sha: "bad0001", position: 2)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :not_ready} = StackDeployer.maybe_open_stack_pr(stack)
        end)

      assert log =~ "reachability check failed"
      assert log =~ ":network_boom"
      assert FakeRunner.pr_calls() == []
    end

    test "all stamps reachable → PR opens (regression: reachability gate does not spuriously fail)" do
      {:ok, _} =
        FakeRunner.start_link(
          # Default reachable_default is {:ok, true}; be explicit.
          reachable_default: {:ok, true},
          pr_responses: [{:ok, %{number: 555, url: "https://github.com/test/repo/pull/555"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "reachable-happy")

      _ = merged_member!(project, stack, sha: "eac1a01", position: 1)
      _ = merged_member!(project, stack, sha: "eac2b02", position: 2)

      assert {:ok, %{status: :opened, number: 555}} =
               StackDeployer.maybe_open_stack_pr(stack)

      # Reachability runner WAS invoked once per member.
      assert length(FakeRunner.reachable_calls()) == 2
      assert [pr_call] = FakeRunner.pr_calls()
      assert pr_call.rollup_branch == stack.rollup_branch
    end
  end

  describe "maybe_open_stack_pr/1 — idempotency" do
    test "stack with metadata.rollup_pr already set → {:ok, :already_open}; no shell-out" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "already")

      _ = merged_member!(project, stack, sha: "rea11dy", position: 1)

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 42,
              "url" => "https://github.com/test/repo/pull/42",
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_open} = StackDeployer.maybe_open_stack_pr(locked)
      assert FakeRunner.pr_calls() == []

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 42
    end

    test "stack with metadata.rollup_pr placeholder (status=opening) → :already_open (race guard)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "racing")

      _ = merged_member!(project, stack, sha: "race1", position: 1)

      {:ok, locked} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "status" => "opening",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, :already_open} = StackDeployer.maybe_open_stack_pr(locked)
      assert FakeRunner.pr_calls() == []
    end
  end

  describe "maybe_open_stack_pr/1 — PR body composition" do
    test "body contains member titles, shas, diff stat, and base→rollup framing" do
      pr_url = "https://github.com/test/repo/pull/200"

      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 200, url: pr_url}}],
          diff_stat_responses: [{:ok, " lib/foo.ex | 12 ++++++++++++\n 1 file changed"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "body")

      _ = merged_member!(project, stack, sha: "abc1234", position: 1, title: "Add foo")
      _ = merged_member!(project, stack, sha: "def5678", position: 2, title: "Refactor bar")

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)

      assert [pr_call] = FakeRunner.pr_calls()
      body = pr_call.body

      # Title and base/rollup framing present.
      assert body =~ stack.name
      assert body =~ stack.rollup_branch
      assert body =~ stack.base_branch

      # Both member titles + their shas present.
      assert body =~ "Add foo"
      assert body =~ "Refactor bar"
      assert body =~ "abc1234"
      assert body =~ "def5678"

      # Diff stat embedded.
      assert body =~ "1 file changed"
      assert body =~ "## Diff stat"

      # diff_stat called once with right args.
      assert [diff_call] = FakeRunner.diff_stat_calls()
      assert diff_call.repo_url == project.repo_url
      assert diff_call.base_branch == stack.base_branch
      assert diff_call.rollup_branch == stack.rollup_branch
    end

    test "diff_stat failure degrades gracefully — body still composes, no diff section" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 201, url: "https://github.com/test/repo/pull/201"}}],
          diff_stat_responses: [{:error, :network}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "no-diff")

      _ = merged_member!(project, stack, sha: "okay111", position: 1, title: "Member A")

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)

      assert [pr_call] = FakeRunner.pr_calls()
      assert pr_call.body =~ "Member A"
      refute pr_call.body =~ "## Diff stat"
    end
  end

  # ── ADR-0046 member 4 stage 4: failed planning gate in the PR body ────────
  #
  # The absence assertions below (clean stack, not_applicable stack) are
  # worthless on their own — they pass against a `build_pr_body/3` that
  # was never touched. They are paired IN THIS MODULE with the positive
  # control, which fails against that same untouched implementation. Read
  # the three together or not at all.

  describe "maybe_open_stack_pr/1 — planning gate section" do
    test "clean members: no gate section, no warning marker (paired with the positive control below)" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 210, url: "https://github.com/test/repo/pull/210"}}],
          diff_stat_responses: [{:ok, " 1 file changed"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gate-clean")

      _ =
        merged_member!(project, stack,
          sha: "aaa1111",
          position: 1,
          title: "Clean complete",
          planning_step_outcomes: %{
            "architecture" => %{"outcome" => "complete", "detail" => nil}
          }
        )

      _ = merged_member!(project, stack, sha: "bbb2222", position: 2, title: "Clean unrecorded")

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)
      assert [pr_call] = FakeRunner.pr_calls()
      body = pr_call.body

      refute body =~ "Gates that did not run"
      refute body =~ "⚠️"
      refute body =~ "GATE DID NOT RUN"

      # The body is otherwise composed as normal — proves the absence
      # above is not the absence of a body.
      assert body =~ "Clean complete"
      assert body =~ "Clean unrecorded"
      assert body =~ "## Members"
    end

    test "failed gate: section above ## Members names member, step and detail; clean member's line untouched" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 211, url: "https://github.com/test/repo/pull/211"}}],
          diff_stat_responses: [{:ok, " 2 files changed"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gate-failed")

      _ =
        merged_member!(project, stack,
          sha: "ccc3333",
          position: 1,
          title: "Gate broke here",
          planning_step_outcomes: %{
            "architecture" => %{
              "outcome" => "failed",
              "detail" => "econnrefused",
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        )

      _ =
        merged_member!(project, stack,
          sha: "ddd4444",
          position: 2,
          title: "Sibling is fine",
          planning_step_outcomes: %{
            "architecture" => %{"outcome" => "complete", "detail" => nil}
          }
        )

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)
      assert [pr_call] = FakeRunner.pr_calls()
      body = pr_call.body

      assert body =~ "Gates that did not run"
      assert body =~ "Gate broke here"
      assert body =~ "architecture"
      assert body =~ "econnrefused"

      # Section sits ABOVE `## Members` — a human scanning the top of the
      # PR body hits it before the member list.
      gate_at = :binary.match(body, "Gates that did not run") |> elem(0)
      members_at = :binary.match(body, "## Members") |> elem(0)
      assert gate_at < members_at

      # The body says these are dispatch failures, not skips.
      assert body =~ "not skips" or body =~ "NOT skips"

      lines = String.split(body, "\n")

      failed_line = Enum.find(lines, &String.contains?(&1, "[Gate broke here]"))
      assert failed_line =~ "ARCHITECTURE GATE DID NOT RUN"
      assert failed_line =~ "⚠️"

      clean_line = Enum.find(lines, &String.contains?(&1, "[Sibling is fine]"))
      assert clean_line =~ "— sha ddd4444"
      refute clean_line =~ "⚠️"
      refute clean_line =~ "GATE DID NOT RUN"
    end

    test "not_applicable is NOT a failed gate — renders nothing (ADR-0046:83 conflation guard)" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:ok, %{number: 212, url: "https://github.com/test/repo/pull/212"}}],
          diff_stat_responses: [{:ok, " 1 file changed"}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gate-na")

      _ =
        merged_member!(project, stack,
          sha: "eee5555",
          position: 1,
          title: "Nobody holds it",
          planning_step_outcomes: %{
            "architecture" => %{
              "outcome" => "not_applicable",
              "detail" => nil,
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        )

      assert {:ok, _} = StackDeployer.maybe_open_stack_pr(stack)
      assert [pr_call] = FakeRunner.pr_calls()
      body = pr_call.body

      refute body =~ "Gates that did not run"
      refute body =~ "⚠️"
      refute body =~ "GATE DID NOT RUN"
      refute body =~ "not_applicable"

      # …and the member is still listed normally.
      assert body =~ "Nobody holds it"
    end
  end

  describe "maybe_open_stack_pr/1 — failure handling" do
    test "gh failure rolls back placeholder + status flip; no half-deployed stack" do
      {:ok, _} =
        FakeRunner.start_link(
          pr_responses: [{:error, {:gh_failed, ["pr", "create"], 1, "auth boom"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "boom")

      _ = merged_member!(project, stack, sha: "ready11", position: 1)
      _ = merged_member!(project, stack, sha: "ready22", position: 2)

      assert {:error, {:gh_failed, _, 1, _}} = StackDeployer.maybe_open_stack_pr(stack)

      reloaded = Stacks.get_stack(stack.id)
      # Status rolled back; placeholder cleared.
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end

    test "stack not found returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.maybe_open_stack_pr(Ecto.UUID.generate())

      assert FakeRunner.pr_calls() == []
    end

    test "missing repo_url returns {:error, :no_repo_url} and does not flip stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()
      stack = stack_for!(project, slug: "noremote")

      _ = merged_member!(project, stack, sha: "rdy11", position: 1)

      assert {:error, :no_repo_url} = StackDeployer.maybe_open_stack_pr(stack)

      reloaded = Stacks.get_stack(stack.id)
      refute reloaded.status == "deploying"
      assert is_nil(get_in(reloaded.metadata || %{}, ["rollup_pr"]))
    end
  end

  # ── handle_rollup_pr_merged/1 (T6 success path) ──────────────────────────

  describe "handle_rollup_pr_merged/1" do
    test "transitions stack to done and stamps merged_at on rollup_pr metadata" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()

      stack = stack_for!(project, slug: "wrap")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 99,
              "url" => "https://github.com/test/repo/pull/99",
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, done_stack} = StackDeployer.handle_rollup_pr_merged(deployed)
      assert done_stack.status == "done"
      assert done_stack.metadata["rollup_pr"]["number"] == 99
      assert is_binary(done_stack.metadata["rollup_pr"]["merged_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(done_stack.metadata["rollup_pr"]["merged_at"])
    end

    test "idempotent on already-done stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "alreadydone")
      {:ok, done_stack} = Stacks.update_stack(stack, %{status: "done"})

      assert {:ok, returned} = StackDeployer.handle_rollup_pr_merged(done_stack)
      assert returned.id == stack.id
      assert returned.status == "done"
    end

    test "lookup-by-id resolves to the stack" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "by1d")

      {:ok, _} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 11}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(stack.id)
    end

    test "missing stack returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.handle_rollup_pr_merged(Ecto.UUID.generate())
    end
  end

  # ── Gap 4 (task 019f921d): unified deploy-gate contract + durable PR-open ─
  #
  # (1) member_ready_for_pr?/1 now delegates to the SHARED
  #     Stacks.member_landed_on_rollup?/1, so a genuinely-finished member
  #     (`done` + a bare-string stamp — the promote/sweep + manual-recon
  #     shape) is no longer rejected by the deploy gate. (2) A durable
  #     reconcile (Stacks.reconcile_deploying_stacks/0) re-fires the
  #     fire-and-forget rollup-PR open for a stack stranded at `deploying`.

  describe "Gap 4: unified deploy-gate contract (done + bare-string member)" do
    test "a fully-done stack with mismatched member shapes opens the rollup PR (no :not_ready false-negative)" do
      pr_url = "https://github.com/test/repo/pull/589"

      {:ok, _} =
        FakeRunner.start_link(pr_responses: [{:ok, %{number: 589, url: pr_url}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap4-mixed")

      # The exact shapes that stranded the Inbox stack: one member at
      # `deploying` with a `%{"sha"=>...}` MAP stamp, the other at `done`
      # with a BARE-STRING stamp.
      m1 = merged_member!(project, stack, sha: "a1b2c3d", position: 1)
      {:ok, _} = Tasks.update_task(m1, %{status: "deploying"})
      _m2 = done_bare_string_member!(project, stack, position: 2)

      # Stack already dispatched to deploying with NO rollup_pr yet.
      {:ok, stack} = Stacks.update_stack(stack, %{status: "deploying"})

      assert {:ok, %{status: :opened, number: 589, url: ^pr_url}} =
               StackDeployer.maybe_open_stack_pr(stack)

      assert [_pr_call] = FakeRunner.pr_calls()

      # A second invocation is idempotent.
      assert {:ok, :already_open} =
               StackDeployer.maybe_open_stack_pr(Stacks.get_stack(stack.id))

      assert length(FakeRunner.pr_calls()) == 1
    end
  end

  describe "Gap 4: reconcile_deploying_stacks/0 (durable PR-open retry)" do
    test "re-fires maybe_open_stack_pr for a deploying stack that lost its fire-and-forget open" do
      pr_url = "https://github.com/test/repo/pull/601"

      {:ok, _} =
        FakeRunner.start_link(pr_responses: [{:ok, %{number: 601, url: pr_url}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap4-reconcile")

      _m1 = merged_member!(project, stack, sha: "reca111", position: 1)
      _m2 = merged_member!(project, stack, sha: "reca222", position: 2)

      # Stack was dispatched to deploying but the async open never landed —
      # no rollup_pr metadata.
      {:ok, _} = Stacks.update_stack(stack, %{status: "deploying"})

      assert Stacks.reconcile_deploying_stacks() == 1

      # The PR opened on retry and the stamp is now durable.
      assert [_pr_call] = FakeRunner.pr_calls()
      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.metadata["rollup_pr"]["number"] == 601
    end

    test "is a no-op when rollup_pr is already stamped (idempotent)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "gap4-already-open")

      _m1 = merged_member!(project, stack, sha: "alr0001", position: 1)

      {:ok, _} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 42,
              "url" => "https://github.com/test/repo/pull/42",
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert Stacks.reconcile_deploying_stacks() == 0
      assert FakeRunner.pr_calls() == []
    end
  end

  # ── handle_rollup_pr_merged/1 → rollup branch delete (stage 3) ───────────

  describe "handle_rollup_pr_merged/1 — deletes rollup branch on success" do
    test "invokes runner.delete_rollup_branch with repo_url/rollup_branch/project_id/stack_id" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-ok")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 42}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert [call] = FakeRunner.delete_calls()
      assert call.repo_url == project.repo_url
      assert call.rollup_branch == stack.rollup_branch
      assert call.project_id == project.id
      assert call.stack_id == stack.id
    end

    test "status flip to done is preserved even when delete returns error (best-effort)" do
      {:ok, _} =
        FakeRunner.start_link(
          delete_responses: [{:error, {:branch_protected, "remote: error: protected branch"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-protected")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 77}}
        })

      assert {:ok, done_stack} = StackDeployer.handle_rollup_pr_merged(deployed)
      assert done_stack.status == "done"

      # Runner was invoked; delete failed but stack stayed done.
      assert [_call] = FakeRunner.delete_calls()

      reloaded = Stacks.get_stack(stack.id)
      assert reloaded.status == "done"
    end

    test "idempotent — already-done stack does NOT invoke delete (no double-push)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-idempotent")
      {:ok, done_stack} = Stacks.update_stack(stack, %{status: "done"})

      assert {:ok, returned} = StackDeployer.handle_rollup_pr_merged(done_stack)
      assert returned.id == stack.id
      assert returned.status == "done"

      assert FakeRunner.delete_calls() == []
    end

    test "already_absent from runner is not treated as error" do
      {:ok, _} =
        FakeRunner.start_link(delete_responses: [{:ok, :already_absent}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-absent")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 88}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)
      assert [_call] = FakeRunner.delete_calls()
    end

    test "telemetry [:rollup_branch_deleted] fires on success" do
      {:ok, _} = FakeRunner.start_link(delete_responses: [{:ok, :deleted}])

      handler_id = "test-rollup-deleted-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stack_deployer, :rollup_branch_deleted],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-telemetry-ok")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 100}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stack_deployer, :rollup_branch_deleted],
                       %{count: 1}, metadata}

      assert metadata.stack_id == stack.id
      assert metadata.rollup_branch == stack.rollup_branch
    end

    test "telemetry [:rollup_branch_delete_failed] fires with reason on error" do
      failure = {:git_failed, ["push", "origin", "--delete", "stack/x"], 128, "boom"}
      {:ok, _} = FakeRunner.start_link(delete_responses: [{:error, failure}])

      handler_id = "test-rollup-delete-failed-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stack_deployer, :rollup_branch_delete_failed],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "delete-telemetry-fail")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 200}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stack_deployer, :rollup_branch_delete_failed],
                       %{count: 1}, metadata}

      assert metadata.stack_id == stack.id
      assert metadata.rollup_branch == stack.rollup_branch
      assert metadata.reason == failure
    end

    test "project without repo_url skips runner (no delete_calls, no crash)" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_without_repo!()

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "no-repo-delete",
          name: "Stack no-repo-delete",
          base_branch: "main",
          rollup_branch: Stacks.rollup_branch_name("no-repo-delete")
        })

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 300}}
        })

      # Status still flips even though we can't delete without a repo_url.
      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      # Runner was NOT invoked (no project.repo_url to hand it).
      assert FakeRunner.delete_calls() == []
    end
  end

  # ── handle_rollup_pr_merged/2 → :stacks, :deploy, :pr_merged telemetry ───

  describe "handle_rollup_pr_merged/2 — new namespaced deploy telemetry (stage 5)" do
    test "emits [:platform, :stacks, :deploy, :pr_merged] with member_count + duration_ms" do
      {:ok, _} = FakeRunner.start_link([])

      handler_id = "test-stacks-deploy-pr-merged-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :pr_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-merged-tele")

      _ = merged_member!(project, stack, sha: "aaaa1111", position: 1)
      _ = merged_member!(project, stack, sha: "bbbb2222", position: 2)

      opened_at = DateTime.utc_now() |> DateTime.add(-45, :second) |> DateTime.to_iso8601()

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 501,
              "url" => "https://github.com/test/repo/pull/501",
              "opened_at" => opened_at
            }
          }
        })

      assert {:ok, %{status: "done"}} =
               StackDeployer.handle_rollup_pr_merged(deployed, "deadbeef1234")

      assert_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged],
                       %{count: 1, duration_ms_in_deploying: duration_ms}, metadata}

      assert metadata.stack_id == stack.id
      assert metadata.member_count == 2
      assert metadata.merge_commit_sha == "deadbeef1234"
      assert metadata.rollup_branch == stack.rollup_branch
      assert is_integer(duration_ms) and duration_ms >= 40_000
    end

    test "duration_ms_in_deploying is nil when rollup_pr.opened_at absent" do
      {:ok, _} = FakeRunner.start_link([])

      handler_id = "test-stacks-deploy-pr-merged-nodur-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :pr_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-merged-nodur")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 601}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged],
                       %{duration_ms_in_deploying: nil}, _metadata}
    end

    test "legacy [:platform, :stack_deployer, :rollup_pr_merged] still fires (back-compat)" do
      {:ok, _} = FakeRunner.start_link([])

      handler_id = "test-legacy-rollup-pr-merged-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stack_deployer, :rollup_pr_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "legacy-pr-merged")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 700}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stack_deployer, :rollup_pr_merged], %{count: 1},
                       metadata}

      assert metadata.stack_id == stack.id
      assert metadata.rollup_branch == stack.rollup_branch
    end

    test "cascade fires: members not yet done are transitioned via Stacks.cascade_members_to_done/1" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-merged-cascade")

      # `merged_member!` seeds each member at `in_review` — the fan-out
      # fallback the stage-5 cascade helper exists for (a member with
      # no `pr_merged` validation the T6 webhook could auto-pass).
      m1 = merged_member!(project, stack, sha: "cc111", position: 1)
      m2 = merged_member!(project, stack, sha: "cc222", position: 2)

      assert Platform.Tasks.get_task_record(m1.id).status == "in_review"
      assert Platform.Tasks.get_task_record(m2.id).status == "in_review"

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 800}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert Platform.Tasks.get_task_record(m1.id).status == "done"
      assert Platform.Tasks.get_task_record(m2.id).status == "done"
    end

    test "replay: second invocation short-circuits (idempotent on rollup_pr.merged_at)" do
      {:ok, _} = FakeRunner.start_link([])

      handler_id = "test-pr-merged-replay-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :pr_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-merged-replay")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 900}}
        })

      # First call — telemetry fires + delete kicks off.
      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)
      assert_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}

      # Reload — now has merged_at stamped, status = done.
      replayed = Platform.Tasks.Stacks.get_stack(stack.id)

      # Second call — short-circuit; no additional telemetry, no additional delete.
      before_delete_calls = FakeRunner.delete_calls()
      assert {:ok, ^replayed} = StackDeployer.handle_rollup_pr_merged(replayed)
      refute_received {:telemetry, [:platform, :stacks, :deploy, :pr_merged], _, _}
      assert FakeRunner.delete_calls() == before_delete_calls
    end
  end

  # ── Stacks.abandon_stack/2 never invokes delete_rollup_branch ────────────

  describe "Stacks.abandon_stack/2 — rollup branch left in place" do
    test "abandon does NOT invoke runner.delete_rollup_branch" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "abandon-leaves-branch")

      # Move through a couple of statuses so it's a realistic abandon.
      {:ok, deploying} = Stacks.update_stack(stack, %{status: "deploying"})

      assert {:ok, abandoned} = Stacks.abandon_stack(deploying, "manual abandon")
      assert abandoned.status == "abandoned"

      # Human-driven cleanup per ADR-0042: no runner invocation.
      assert FakeRunner.delete_calls() == []
    end
  end

  # ── per-member merge fires the stack-PR gate hook ────────────────────────

  describe "merge_member_into_rollup/1 — fires maybe_open_stack_pr hook" do
    test "successful per-member merge triggers the gate (PR opened when last merge lands)" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "1a5dee6"}}],
          pr_responses: [
            {:ok, %{number: 312, url: "https://github.com/test/repo/pull/312"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "hook-fires")

      # Pre-seed: 2 already-merged members in the stack.
      _ = merged_member!(project, stack, sha: "old111", position: 1)
      _ = merged_member!(project, stack, sha: "old222", position: 2)

      # The 3rd member is review-ready but not yet merged. We invoke
      # the per-member merge — its success path should fire the
      # stack PR gate, find all 3 members merged, and open ONE PR.
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "1a5dee6"}} =
               StackDeployer.merge_member_into_rollup(task)

      assert [_pr_call] = FakeRunner.pr_calls()

      reloaded_stack = Stacks.get_stack(stack.id)
      assert reloaded_stack.status == "deploying"
      assert reloaded_stack.metadata["rollup_pr"]["number"] == 312
    end

    test "successful per-member merge with members still pending → gate :not_ready, no PR" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "abcdef1"}}])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "still-pending")

      # Pre-seed: 1 already-merged + 1 unmerged member.
      _ = merged_member!(project, stack, sha: "old1111", position: 1)
      _ = unmerged_member!(project, stack, position: 2)

      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abcdef1"}} =
               StackDeployer.merge_member_into_rollup(task)

      # 1+1+1 merged out of 1+1+1+1 = still incomplete (the unmerged member is in_progress).
      assert FakeRunner.pr_calls() == []

      reloaded_stack = Stacks.get_stack(stack.id)
      refute reloaded_stack.status == "deploying"
    end
  end

  # ── Stage 4 helpers ───────────────────────────────────────────────────────

  # Gap 4 fixture: a member at `done` carrying a BARE-STRING
  # `merged_into_rollup_at` stamp — the legacy / manual-reconciliation shape
  # (predates the Bug#3 map-shape validator). We bypass `Tasks.update_task`'s
  # changeset validator via a raw `Ecto.Changeset.change` since that
  # validator now rejects non-map stamps for NEW writes; this reproduces the
  # exact end-state that the deploy gate must still accept.
  defp done_bare_string_member!(project, stack, opts) do
    position = Keyword.get(opts, :position, 1)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Done bare-string member #{uniq()}",
        status: "in_review"
      })

    {:ok, task} = Tasks.update_task(task, %{stack_id: stack.id, stack_position: position})

    base_meta = if is_map(task.metadata), do: task.metadata, else: %{}

    task
    |> Ecto.Changeset.change(%{
      status: "done",
      metadata:
        Map.put(base_meta, "merged_into_rollup_at", DateTime.utc_now() |> DateTime.to_iso8601())
    })
    |> Platform.Repo.update!()
  end

  defp merged_member!(project, stack, opts) do
    sha = Keyword.fetch!(opts, :sha)
    position = Keyword.get(opts, :position, 1)
    title = Keyword.get(opts, :title, "Merged member #{uniq()}")

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    # Bug #3 (task 019f708f): the changeset validator requires SHAs
    # to be at least 7 hex chars. Zero-pad shorter test fixtures
    # rather than touching every call site.
    padded_sha = pad_sha_for_validator(sha)

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{
            "sha" => padded_sha,
            "at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      })

    # ADR-0046 member 4 stage 4: seed a per-step planning outcome when a
    # test asks for one. Written through `planning_step_changeset/2`
    # because `Task.changeset/2` deliberately does not cast these fields
    # — `Tasks.update_task/3` cannot reach them.
    case Keyword.get(opts, :planning_step_outcomes) do
      nil ->
        task

      outcomes ->
        task
        |> Platform.Tasks.Task.planning_step_changeset(%{planning_step_outcomes: outcomes})
        |> Platform.Repo.update!()
    end
  end

  # Bug #3 helper: coerce short / non-hex shas into a
  # hex-shaped string at least 7 chars so the
  # `merged_into_rollup_at` shape validator accepts them without
  # touching every call site.
  defp pad_sha_for_validator(sha) when is_binary(sha) do
    hex_only = String.replace(sha, ~r/[^0-9a-fA-F]/, "0")

    if byte_size(hex_only) >= 7,
      do: hex_only,
      else: String.duplicate("0", 7 - byte_size(hex_only)) <> hex_only
  end

  defp unmerged_member!(project, stack, opts) do
    position = Keyword.get(opts, :position, 1)

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Unmerged #{uniq()}",
        status: "in_progress"
      })

    {:ok, task} =
      Tasks.update_task(task, %{stack_id: stack.id, stack_position: position})

    task
  end

  # ── handle_rollup_ci_failure/2 (stage 5) ─────────────────────────────────

  describe "handle_rollup_ci_failure/2 — atomic all-members bounce (stage 4)" do
    test "3-member stack: ALL members bounced back to in_progress; stack -> in_progress" do
      pr_url = "https://github.com/test/repo/pull/777"
      ci_run_url = "#{pr_url}/checks?check_run_id=42"
      head_sha = "headshaaa"

      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revertz1"}}],
          close_responses: [{:ok, :closed}]
        )

      # Telemetry probe for the new :pr_rejected event.
      test_pid = self()
      handler_id = "pr-rejected-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :deploy, :pr_rejected],
          fn event, measurements, metadata, _cfg ->
            send(test_pid, {:pr_rejected, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "bounce-atomic")

      # 3 stack members merged in chronological order; the 3rd (most
      # recent) is the heuristic offender whose merge commit is reverted.
      # But all 3 members must bounce.
      m1 = merged_member_with_time!(project, stack, sha: "aa1aaaa", position: 1, minutes_ago: 30)
      m2 = merged_member_with_time!(project, stack, sha: "bb2bbbb", position: 2, minutes_ago: 20)
      m3 = merged_member_with_time!(project, stack, sha: "cc3cccc", position: 3, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{
            "rollup_pr" => %{
              "number" => 777,
              "url" => pr_url,
              "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        })

      assert {:ok, %{status: :bounced, bounced_task_ids: bounced_ids, revert_sha: "revertz1"}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: ci_run_url,
                 head_sha: head_sha
               })

      # All 3 members reported as bounced.
      assert Enum.sort(bounced_ids) == Enum.sort([m1.id, m2.id, m3.id])

      # EVERY member: merged_into_rollup_at cleared, bounced_from_rollup
      # stamped with matching ci_run_url, status flipped to in_progress.
      for m <- [m1, m2, m3] do
        reloaded = Tasks.get_task_record(m.id)

        assert reloaded.status == "in_progress",
               "expected #{m.id} at in_progress, got #{reloaded.status}"

        assert is_nil(get_in(reloaded.metadata, ["merged_into_rollup_at"])),
               "expected #{m.id} to have merged_into_rollup_at cleared"

        stamp = reloaded.metadata["bounced_from_rollup"]
        assert stamp["ci_run_url"] == ci_run_url
        assert stamp["head_sha"] == head_sha
        assert stamp["sha"] == m.metadata["merged_into_rollup_at"]["sha"]
        assert is_binary(stamp["at"])
        assert {:ok, _, _} = DateTime.from_iso8601(stamp["at"])
      end

      # Stack: flipped to in_progress (NOT in_review), rollup_pr cleared.
      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "in_progress"
      assert is_nil(get_in(reloaded_stack.metadata || %{}, ["rollup_pr"]))

      # Runner: exactly ONE revert (scoped to the most-recently-merged
      # member's merge commit) + one PR close, on the right inputs.
      assert [revert_call] = FakeRunner.revert_calls()
      assert revert_call.repo_url == project.repo_url
      assert revert_call.rollup_branch == stack.rollup_branch
      assert revert_call.merge_sha == "cc3cccc"
      assert revert_call.project_id == project.id
      assert revert_call.stack_id == stack.id
      assert revert_call.member_task_id == m3.id

      assert [close_call] = FakeRunner.close_calls()
      assert close_call.repo_url == project.repo_url
      assert close_call.pr_number == 777
      assert close_call.stack_id == stack.id
      assert is_binary(close_call.comment)
      assert close_call.comment =~ ci_run_url

      # Telemetry: :pr_rejected fired exactly once with member_count: 3.
      assert_received {:pr_rejected, [:platform, :stacks, :deploy, :pr_rejected],
                       %{member_count: 3},
                       %{stack_id: sid, member_count: 3, revert_sha: "revertz1"}}

      assert sid == deployed.id
      refute_received {:pr_rejected, _, _, _}
    end

    test "mixed merged + unmerged members: unmerged members are also stamped and no-op transitioned" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revmix01"}}],
          close_responses: [{:ok, :closed}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "bounce-mixed")

      # One merged member (offender), one unmerged member already at in_progress.
      m1 = merged_member_with_time!(project, stack, sha: "mix1aaaa", position: 1, minutes_ago: 5)
      m2 = unmerged_member!(project, stack, position: 2)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 314}}
        })

      assert {:ok, %{status: :bounced, bounced_task_ids: bounced_ids}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/mix",
                 head_sha: "mixhead"
               })

      assert Enum.sort(bounced_ids) == Enum.sort([m1.id, m2.id])

      # Both members stamped with the bounce metadata.
      for m <- [m1, m2] do
        reloaded = Tasks.get_task_record(m.id)
        assert reloaded.status == "in_progress"
        assert reloaded.metadata["bounced_from_rollup"]["ci_run_url"] == "https://example/run/mix"
      end

      # The unmerged member's stamp has sha=nil since it never merged.
      reloaded_m2 = Tasks.get_task_record(m2.id)
      assert is_nil(reloaded_m2.metadata["bounced_from_rollup"]["sha"])
    end
  end

  describe "handle_rollup_ci_failure/2 — idempotency" do
    test "second invocation with the same ci_run_url no-ops after atomic bounce" do
      ci_run_url = "https://github.com/test/repo/pull/8/checks/99"

      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revertz2"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "idem")

      m1 = merged_member_with_time!(project, stack, sha: "old1aaa", position: 1, minutes_ago: 20)
      m2 = merged_member_with_time!(project, stack, sha: "old2bbb", position: 2, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 8}}
        })

      # First invocation: atomic bounce of both members.
      assert {:ok, %{status: :bounced, bounced_task_ids: bounced_ids}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: ci_run_url,
                 head_sha: "head1"
               })

      assert Enum.sort(bounced_ids) == Enum.sort([m1.id, m2.id])

      # Both members carry the bounce stamp; the guard fires on replay.
      reloaded_stack = Stacks.get_stack(deployed.id)

      assert {:ok, :already_bounced} =
               StackDeployer.handle_rollup_ci_failure(reloaded_stack, %{
                 ci_run_url: ci_run_url,
                 head_sha: "head1"
               })

      # Only the first invocation called the runner (no second revert).
      assert [_] = FakeRunner.revert_calls()
    end

    test "different ci_run_url on the same stack does NOT idempotent-skip" do
      # If a stack has been reused (bounced, re-merged, re-failed for a
      # new CI run), the fresh ci_run_url must trigger a new bounce.
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [
            {:ok, %{status: :reverted, revert_sha: "rev-first"}},
            {:ok, %{status: :reverted, revert_sha: "rev-second"}}
          ]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "idem-diff-run")

      m1 = merged_member_with_time!(project, stack, sha: "diff111a", position: 1, minutes_ago: 5)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 88}}
        })

      # First run bounces successfully.
      assert {:ok, %{status: :bounced}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/A",
                 head_sha: "hA"
               })

      # Simulate a partial re-merge on m1 (rollup PR reopened,
      # re-merged, then CI failed AGAIN with a different run URL).
      {:ok, _} =
        Tasks.update_task(Tasks.get_task_record(m1.id), %{
          status: "in_review",
          metadata:
            m1.id
            |> Tasks.get_task_record()
            |> Map.get(:metadata)
            |> Map.put("merged_into_rollup_at", %{
              "sha" => "e0e0eea",
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
        })

      {:ok, redeployed} =
        Stacks.update_stack(Stacks.get_stack(deployed.id), %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 89}}
        })

      # Second run (fresh ci_run_url) DOES bounce.
      assert {:ok, %{status: :bounced}} =
               StackDeployer.handle_rollup_ci_failure(redeployed, %{
                 ci_run_url: "https://example/run/B",
                 head_sha: "hB"
               })

      # Two revert calls total.
      assert [_, _] = FakeRunner.revert_calls()

      # Bounce stamp updated to the newer ci_run_url.
      assert Tasks.get_task_record(m1.id).metadata["bounced_from_rollup"]["ci_run_url"] ==
               "https://example/run/B"
    end
  end

  describe "handle_rollup_ci_failure/2 — heuristic ambiguity" do
    test "logs a warning when multiple merge candidates fit the window" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "ambig")

      _m1 = merged_member_with_time!(project, stack, sha: "amb1aaa", position: 1, minutes_ago: 30)
      _m2 = merged_member_with_time!(project, stack, sha: "amb2bbb", position: 2, minutes_ago: 20)
      _m3 = merged_member_with_time!(project, stack, sha: "amb3ccc", position: 3, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 33}}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :bounced}} =
                   StackDeployer.handle_rollup_ci_failure(deployed, %{
                     ci_run_url: "https://example/run/1",
                     head_sha: "h1"
                   })
        end)

      assert log =~ "CI attribution heuristic"
      assert log =~ "review may be required"
    end

    # Bug #2 (task 019f708f): the CI-failure heuristic still bounces
    # the last-merged member (stamp order is the only ordering signal
    # available on this path), but logs a warning when the picked
    # offender's stamp isn't actually reachable from the rollup tip.
    test "picks the last-merged offender even when its stamp is unreachable but logs a warning" do
      {:ok, _} =
        FakeRunner.start_link(
          reachable_responses: %{"dead001" => {:ok, false}},
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "revfake1"}}],
          close_responses: [{:ok, :closed}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pick-unreachable")

      # Single merged member with a fabricated stamp.
      m1 = merged_member!(project, stack, sha: "dead001", position: 1)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 44}}
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :bounced}} =
                   StackDeployer.handle_rollup_ci_failure(deployed, %{
                     ci_run_url: "https://example/run/pick",
                     head_sha: "h-pick"
                   })
        end)

      assert log =~ "pick_offender"
      assert log =~ m1.id
      assert log =~ "dead001"
      assert log =~ "NOT reachable"
      # Bounce still proceeded — a revert was attempted despite the warning.
      assert FakeRunner.revert_calls() != []
    end
  end

  describe "handle_rollup_ci_failure/2 — revert failure" do
    test "runner revert error returns {:error, reason}; NO member is stamped or transitioned" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:error, {:revert_failed, "conflict on revert"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "revert-boom")

      # Two members: the revert failure must abort the whole atomic bounce
      # before either member is touched.
      m1 = merged_member_with_time!(project, stack, sha: "rv1aaaa", position: 1, minutes_ago: 20)
      m2 = merged_member_with_time!(project, stack, sha: "rv2bbbb", position: 2, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 555}}
        })

      assert {:error, {:revert_failed, "conflict on revert"}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/x",
                 head_sha: "h1"
               })

      # Both members untouched — no bounce stamp, merged stamp intact,
      # status still in_review.
      for m <- [m1, m2] do
        reloaded = Tasks.get_task_record(m.id)

        assert reloaded.metadata["merged_into_rollup_at"]["sha"] ==
                 m.metadata["merged_into_rollup_at"]["sha"]

        assert is_nil(get_in(reloaded.metadata, ["bounced_from_rollup"]))
        assert reloaded.status == "in_review"
      end

      # Stack: still deploying — bounce aborted before the flip.
      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "deploying"
      assert reloaded_stack.metadata["rollup_pr"]["number"] == 555

      # PR close not attempted on revert failure.
      assert FakeRunner.close_calls() == []
    end
  end

  describe "handle_rollup_ci_failure/2 — PR close failure" do
    test "gh pr close failure does not crash; atomic bounce still proceeds" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "rev999"}}],
          close_responses: [{:error, {:gh_failed, ["pr", "close"], 1, "rate limited"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "pr-close-boom")

      m1 = merged_member_with_time!(project, stack, sha: "c1a1aaa", position: 1, minutes_ago: 10)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 12}}
        })

      assert {:ok, %{status: :bounced, bounced_task_ids: [bounced_id]}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/y",
                 head_sha: "h1"
               })

      assert bounced_id == m1.id

      # Bounce went through despite PR close failure.
      reloaded = Tasks.get_task_record(m1.id)
      assert reloaded.status == "in_progress"
      assert reloaded.metadata["bounced_from_rollup"]["sha"] == "c1a1aaa"

      reloaded_stack = Stacks.get_stack(deployed.id)
      assert reloaded_stack.status == "in_progress"
      assert is_nil(get_in(reloaded_stack.metadata || %{}, ["rollup_pr"]))

      assert [_] = FakeRunner.close_calls()
    end
  end

  describe "handle_rollup_ci_failure/2 — edge cases" do
    test "no merged member returns {:ok, :no_candidate}" do
      {:ok, _} = FakeRunner.start_link([])

      project = project_with_repo!()
      stack = stack_for!(project, slug: "nobody")

      _ = unmerged_member!(project, stack, position: 1)

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 22}}
        })

      assert {:ok, :no_candidate} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/z",
                 head_sha: "h1"
               })

      assert FakeRunner.revert_calls() == []
      assert FakeRunner.close_calls() == []
    end

    test "lookup-by-id resolves to the stack" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "rev123"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "byid")
      m1 = merged_member_with_time!(project, stack, sha: "byid111", position: 1, minutes_ago: 5)

      {:ok, _} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 1}}
        })

      assert {:ok, %{status: :bounced, bounced_task_ids: [id]}} =
               StackDeployer.handle_rollup_ci_failure(stack.id, %{
                 ci_run_url: "https://example/run/byid",
                 head_sha: "h1"
               })

      assert id == m1.id
    end

    test "missing stack returns {:error, :stack_not_found}" do
      {:ok, _} = FakeRunner.start_link([])

      assert {:error, :stack_not_found} =
               StackDeployer.handle_rollup_ci_failure(Ecto.UUID.generate(), %{
                 ci_run_url: "x",
                 head_sha: "y"
               })

      assert FakeRunner.revert_calls() == []
    end

    test "stack with no rollup_pr metadata skips close but still bounces" do
      {:ok, _} =
        FakeRunner.start_link(
          revert_responses: [{:ok, %{status: :reverted, revert_sha: "norev1"}}]
        )

      project = project_with_repo!()
      stack = stack_for!(project, slug: "no-pr-meta")

      m1 = merged_member_with_time!(project, stack, sha: "nopr111", position: 1, minutes_ago: 5)

      {:ok, deployed} = Stacks.update_stack(stack, %{status: "deploying", metadata: %{}})

      assert {:ok, %{status: :bounced, bounced_task_ids: [bounced_id]}} =
               StackDeployer.handle_rollup_ci_failure(deployed, %{
                 ci_run_url: "https://example/run/nopr",
                 head_sha: "h1"
               })

      assert bounced_id == m1.id
      assert FakeRunner.close_calls() == []
    end
  end

  # ── Stage 5 helpers ───────────────────────────────────────────────────────

  defp merged_member_with_time!(project, stack, opts) do
    sha = Keyword.fetch!(opts, :sha) |> pad_sha_for_validator()
    position = Keyword.get(opts, :position, 1)
    minutes_ago = Keyword.get(opts, :minutes_ago, 0)
    title = Keyword.get(opts, :title, "Merged member #{uniq()}")

    merged_at =
      DateTime.utc_now()
      |> DateTime.add(-minutes_ago * 60, :second)
      |> DateTime.to_iso8601()

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "in_review"
      })

    {:ok, task} =
      Tasks.update_task(task, %{
        stack_id: stack.id,
        stack_position: position,
        metadata: %{
          "merged_into_rollup_at" => %{"sha" => sha, "at" => merged_at}
        }
      })

    task
  end

  # ── Stage 4: advisory lock + ADR-0042 telemetry ─────────────────────────

  describe "advisory lock on create_rollup_branch/1 (ADR-0042 stage 4)" do
    test "concurrent handle_stack_created/1 on the SAME stack: one :created, one :already_exists" do
      # Two parallel Task.async'd callers race the same stack. Under
      # production (distinct DB connections per web worker), the
      # per-stack pg_advisory_xact_lock serialises them so the second
      # arrival sees `:already_exists`. Under the shared test sandbox
      # the connection is re-entrant, but the FakeRunner Agent queue is
      # FIFO so we still verify the observable contract: no error and
      # each caller sees the runner exactly once.

      {:ok, _} =
        FakeRunner.start_link(
          responses: [
            {:sleep, 50, {:ok, %{status: :created, base_sha: "shafirst"}}},
            {:ok, %{status: :already_exists, base_sha: "shafirst"}}
          ]
        )

      handler_id = "test-branch-created-concurrent-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_created],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "concurrent-start")

      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, parent, self())
            StackDeployer.handle_stack_created(stack)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # handle_stack_created/1 returns :ok under async: false — the
      # important thing is neither Task crashed or awaited into an exit.
      assert Enum.all?(results, &(&1 == :ok))

      # Both callers invoked the runner exactly once each.
      assert length(FakeRunner.calls()) == 2

      # Two telemetry emissions — one per caller, one :created and one
      # :already_exists (order across processes is non-deterministic).
      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_created],
                       %{duration_us: d1}, %{status: s1, stack_id: sid1}}

      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_created],
                       %{duration_us: d2}, %{status: s2, stack_id: sid2}}

      assert is_integer(d1) and d1 >= 0
      assert is_integer(d2) and d2 >= 0
      assert sid1 == stack.id
      assert sid2 == stack.id

      assert Enum.sort([s1, s2]) == [:already_exists, :created]
    end

    test "advisory lock is per-stack: two DIFFERENT stacks each complete without cross-blocking" do
      # Different stack ids hash to different advisory-lock keys
      # (`:erlang.phash2/2`) so they don't serialise under production.
      # Under the shared test sandbox both invocations still travel
      # through the single connection so we can't measure true
      # parallelism — we simply prove both stacks succeed and are each
      # invoked once against the runner.

      {:ok, _} =
        FakeRunner.start_link(
          responses: [
            {:ok, %{status: :created, base_sha: "shaAAA"}},
            {:ok, %{status: :created, base_sha: "shaBBB"}}
          ]
        )

      project = project_with_repo!()
      s1 = stack_for!(project, slug: "per-stack-a")
      s2 = stack_for!(project, slug: "per-stack-b")

      # Hash keys differ so production serialisation would be a
      # separate mutex per stack.
      key1 = :erlang.phash2(s1.id, 2_147_483_647)
      key2 = :erlang.phash2(s2.id, 2_147_483_647)
      assert key1 != key2

      parent = self()

      tasks =
        for stack <- [s1, s2] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, parent, self())
            StackDeployer.create_rollup_branch(stack)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      for res <- results do
        assert {:ok, %{status: :created}} = res
      end

      assert length(FakeRunner.calls()) == 2

      stack_ids_in_calls = FakeRunner.calls() |> Enum.map(& &1.stack_id) |> Enum.sort()
      assert stack_ids_in_calls == Enum.sort([s1.id, s2.id])
    end
  end

  describe "ADR-0042 telemetry: [:platform, :stacks, :rollup, ...]" do
    test "[:branch_created] fires on :created with duration_us + expected metadata keys" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :created, base_sha: "shaaaaa"}}])

      handler_id = "test-adr42-branch-created-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_created],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-create", base_branch: "develop")

      assert {:ok, _} = StackDeployer.create_rollup_branch(stack)

      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_created],
                       %{duration_us: duration_us}, metadata}

      assert is_integer(duration_us) and duration_us >= 0
      assert metadata.stack_id == stack.id
      assert metadata.rollup_branch == stack.rollup_branch
      assert metadata.base_branch == "develop"
      assert metadata.base_sha == "shaaaaa"
      assert metadata.status == :created
    end

    test "[:branch_created] fires on :already_exists too — status distinguishes" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:ok, %{status: :already_exists, base_sha: "oldSha0"}}])

      handler_id = "test-adr42-branch-existed-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_created],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-existed")

      assert {:ok, %{status: :already_exists}} = StackDeployer.create_rollup_branch(stack)

      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_created],
                       %{duration_us: _}, %{status: :already_exists}}
    end

    test "[:branch_created] does NOT fire on runner error" do
      {:ok, _} =
        FakeRunner.start_link(responses: [{:error, {:git_failed, ["push"], 128, "boom"}}])

      handler_id = "test-adr42-branch-error-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_created],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-error")

      assert {:error, _} = StackDeployer.create_rollup_branch(stack)

      refute_received {:telemetry, [:platform, :stacks, :rollup, :branch_created], _m, _md}
    end

    test "[:branch_deleted] fires on :deleted with duration_us + status metadata" do
      {:ok, _} = FakeRunner.start_link(delete_responses: [{:ok, :deleted}])

      handler_id = "test-adr42-branch-deleted-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_deleted],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-delete")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 501}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_deleted],
                       %{duration_us: duration_us}, metadata}

      assert is_integer(duration_us) and duration_us >= 0
      assert metadata.stack_id == stack.id
      assert metadata.rollup_branch == stack.rollup_branch
      assert metadata.status == :deleted
    end

    test "[:branch_deleted] fires with :already_absent status when runner reports absent" do
      {:ok, _} = FakeRunner.start_link(delete_responses: [{:ok, :already_absent}])

      handler_id = "test-adr42-branch-absent-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_deleted],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-absent")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 502}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      assert_received {:telemetry, [:platform, :stacks, :rollup, :branch_deleted],
                       %{duration_us: _}, %{status: :already_absent}}
    end

    test "[:branch_deleted] does NOT fire on runner delete error" do
      {:ok, _} =
        FakeRunner.start_link(
          delete_responses: [{:error, {:git_failed, ["push", "--delete"], 128, "boom"}}]
        )

      handler_id = "test-adr42-branch-delete-err-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :branch_deleted],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-delete-err")

      {:ok, deployed} =
        Stacks.update_stack(stack, %{
          status: "deploying",
          metadata: %{"rollup_pr" => %{"number" => 503}}
        })

      assert {:ok, %{status: "done"}} = StackDeployer.handle_rollup_pr_merged(deployed)

      refute_received {:telemetry, [:platform, :stacks, :rollup, :branch_deleted], _m, _md}
    end

    test "[:member_merged] fires on successful per-member merge with duration_us + metadata" do
      {:ok, _} =
        FakeRunner.start_link(merge_responses: [{:ok, %{status: :merged, merge_sha: "abccafe"}}])

      handler_id = "test-adr42-member-merged-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :member_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-merged")
      # Include a second unmerged member so the maybe_open_stack_pr
      # hook stays :not_ready and doesn't perturb the assertion window.
      _ = unmerged_member!(project, stack, position: 2)
      task = review_ready_member!(project, stack)

      assert {:ok, %{status: :merged, merge_sha: "abccafe"}} =
               StackDeployer.merge_member_into_rollup(task)

      assert_received {:telemetry, [:platform, :stacks, :rollup, :member_merged],
                       %{duration_us: duration_us}, metadata}

      assert is_integer(duration_us) and duration_us >= 0
      assert metadata.stack_id == stack.id
      assert metadata.task_id == task.id
      assert metadata.merge_sha == "abccafe"
      assert is_binary(metadata.member_branch)
      assert String.starts_with?(metadata.member_branch, "task/")
    end

    test "[:member_merged] does NOT fire on :not_fast_forwardable" do
      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [
            {:error, :not_fast_forwardable,
             %{member_sha: "m1", rollup_sha: "r1", output: "fatal: Not fast-forward"}}
          ]
        )

      handler_id = "test-adr42-member-notff-#{uniq()}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :stacks, :rollup, :member_merged],
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "adr42-notff")
      task = review_ready_member!(project, stack)

      assert {:error, :not_fast_forwardable, _} = StackDeployer.merge_member_into_rollup(task)

      refute_received {:telemetry, [:platform, :stacks, :rollup, :member_merged], _m, _md}
    end
  end

  # ── Rollup-time migration collision guard (task 019f7b7e stage 4) ────────

  # The member's branch adds `<ts>_member_thing.exs`; the rollup already
  # carries `<ts>_sibling_thing.exs` from a merged sibling. Same
  # timestamp, different filename — the exact shape that makes Ecto
  # silently skip one migration.
  defp colliding_runner!(stack, timestamp \\ "20260717000000") do
    FakeRunner.start_link(
      merge_responses: [{:ok, %{status: :merged, merge_sha: "c0111de0"}}],
      migrations_by_base: %{
        stack.rollup_branch =>
          {:ok, ["apps/platform/priv/repo/migrations/#{timestamp}_member_thing.exs"]},
        stack.base_branch =>
          {:ok, ["apps/platform/priv/repo/migrations/#{timestamp}_sibling_thing.exs"]}
      }
    )
  end

  describe "merge_member_into_rollup/1 — migration collision guard" do
    test "collision logs ERROR, stamps stack metadata, and the merge STILL proceeds" do
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-collide")
      {:ok, _} = colliding_runner!(stack)
      task = review_ready_member!(project, stack)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # The load-bearing assertion: the guard is advisory. A
          # detected collision must NOT halt the merge.
          assert {:ok, %{status: :merged, merge_sha: "c0111de0"}} =
                   StackDeployer.merge_member_into_rollup(task)
        end)

      assert log =~ "[StackDeployer] migration filename collision at rollup-merge time"
      assert log =~ "20260717000000_member_thing.exs"
      assert log =~ "20260717000000_sibling_thing.exs"

      # Merge really did land — member metadata stamped as normal.
      assert Tasks.get_task_record(task.id).metadata["merged_into_rollup_at"]["sha"] ==
               "c0111de0"

      # Stack metadata carries the collision record.
      reloaded = Repo.get!(Stack, stack.id)
      assert %{} = collision = reloaded.metadata["migration_collision"]
      assert collision["offender_task_id"] == task.id
      assert {:ok, _, _} = DateTime.from_iso8601(collision["at"])

      assert [%{} = entry] = collision["filenames"]
      assert entry["timestamp"] == "20260717000000"
      assert entry["member_file"] == "20260717000000_member_thing.exs"
      assert entry["rollup_file"] == "20260717000000_sibling_thing.exs"

      # Collision is advisory only — the stack is NOT flipped to blocked
      # the way a genuine merge conflict would be.
      refute reloaded.status == "blocked"
    end

    test "collision emits the migration_collision telemetry event" do
      handler_id =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stack_deployer, :migration_collision]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-collide-telemetry")
      {:ok, _} = colliding_runner!(stack)
      task = review_ready_member!(project, stack)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)
      end)

      assert_receive {[:platform, :stack_deployer, :migration_collision], _ref, %{count: 1}, meta}

      assert meta.stack_id == stack.id
      assert meta.member_task_id == task.id
    end

    test "distinct timestamps merge cleanly with no collision recorded" do
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-clean")

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "c1ea4001"}}],
          migrations_by_base: %{
            stack.rollup_branch =>
              {:ok, ["apps/platform/priv/repo/migrations/20260717000000_member.exs"]},
            stack.base_branch =>
              {:ok, ["apps/platform/priv/repo/migrations/20260718000000_sibling.exs"]}
          }
        )

      task = review_ready_member!(project, stack)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)
        end)

      refute log =~ "migration filename collision"
      refute Repo.get!(Stack, stack.id).metadata["migration_collision"]
    end

    test "an identical filename on both sides is NOT a collision" do
      # Normal after the member rebases onto rollup: the sibling's
      # already-merged migration shows up on the member's branch too.
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-same-file")
      shared = "apps/platform/priv/repo/migrations/20260717000000_shared.exs"

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "5a3e0001"}}],
          migrations_by_base: %{
            stack.rollup_branch => {:ok, [shared]},
            stack.base_branch => {:ok, [shared]}
          }
        )

      task = review_ready_member!(project, stack)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)
        end)

      refute log =~ "migration filename collision"
      refute Repo.get!(Stack, stack.id).metadata["migration_collision"]
    end

    test "the guard queries the member branch and the rollup branch" do
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-args")
      {:ok, _} = colliding_runner!(stack)
      task = review_ready_member!(project, stack)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = StackDeployer.merge_member_into_rollup(task)
      end)

      assert [member_call, rollup_call] = FakeRunner.migrations_calls()

      # Call 1: what this member adds on top of the rollup branch.
      assert member_call.base_branch == stack.rollup_branch
      assert String.starts_with?(member_call.head_branch, "task/")
      assert member_call.repo_url == project.repo_url
      assert member_call.project_id == project.id

      # Call 2: what siblings already merged onto the rollup branch.
      assert rollup_call.base_branch == stack.base_branch
      assert rollup_call.head_branch == stack.rollup_branch
    end

    test "a runner error in the guard is swallowed and the merge proceeds" do
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-runner-error")

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "e440c001"}}],
          migrations_default: {:error, :fetch_failed}
        )

      task = review_ready_member!(project, stack)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{status: :merged, merge_sha: "e440c001"}} =
                 StackDeployer.merge_member_into_rollup(task)
      end)

      refute Repo.get!(Stack, stack.id).metadata["migration_collision"]
    end

    test "migrations without a parseable timestamp prefix are ignored" do
      project = project_with_repo!()
      stack = stack_for!(project, slug: "mig-unparseable")

      {:ok, _} =
        FakeRunner.start_link(
          merge_responses: [{:ok, %{status: :merged, merge_sha: "04a25e11"}}],
          migrations_by_base: %{
            stack.rollup_branch => {:ok, ["apps/platform/priv/repo/migrations/README.md"]},
            stack.base_branch => {:ok, ["apps/platform/priv/repo/migrations/notes.txt"]}
          }
        )

      task = review_ready_member!(project, stack)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: :merged}} = StackDeployer.merge_member_into_rollup(task)
        end)

      refute log =~ "migration filename collision"
    end
  end
end
