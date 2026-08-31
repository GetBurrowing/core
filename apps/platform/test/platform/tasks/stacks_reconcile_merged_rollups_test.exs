defmodule Platform.Tasks.StacksReconcileMergedRollupsTest do
  @moduledoc """
  `Stacks.reconcile_merged_rollups/0` — the backstop poll behind the
  rollup-PR merge webhook (task 01a05394 stage 2).

  The discriminating fixture is a rollup that IS merged in the stand-in
  origin (the fake runner answers `merged: true`) with NO webhook delivered
  at all: the stack is asserted to still be `deploying` BEFORE the poll
  runs, so a green headline cannot be the webhook's work. It is paired with
  the control a completes-everything poll would fail: a rollup the origin
  reports as NOT merged must be left alone, and
  `RollupWebhookProcessor.process_stack_merged_pr/4` must receive ZERO
  invocations — counted through the processor's own test seam
  (`Process.get(:webhook_stack_fault)` is evaluated as the very first line
  of that function), not inferred from downstream state.
  """

  # async: false — swaps the global `:platform, :stack_deployer` git_runner.
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Stacks, Task}

  defmodule MergeStateRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    def start_link do
      Agent.start_link(fn -> %{response: {:ok, unmerged()}, calls: []} end, name: __MODULE__)
    end

    def stop, do: Agent.stop(__MODULE__)
    def set_response(resp), do: Agent.update(__MODULE__, &%{&1 | response: resp})
    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

    def unmerged, do: %{merged: false, merged_at: nil, merge_commit_sha: nil, url: nil}

    def merged(sha) do
      %{
        merged: true,
        merged_at: "2026-08-30T12:00:00Z",
        merge_commit_sha: sha,
        url: "https://github.com/test/poll-repo/pull/4242"
      }
    end

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, :created}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 4242, url: "https://github.com/test/poll-repo/pull/4242"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}

    @impl true
    def pr_merge_state(args) do
      Agent.get_and_update(__MODULE__, fn state ->
        {state.response, %{state | calls: [args | state.calls]}}
      end)
    end
  end

  # A runner with NO `pr_merge_state/1` at all — the optional-callback gap.
  defmodule NoMergeStateRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, :created}
  end

  # Raises for exactly one repo; answers `unmerged` for every other.
  defmodule RaisingForOneRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, :created}

    @impl true
    def pr_merge_state(%{repo_url: "https://github.com/test/bad"}),
      do: raise("boom from origin")

    def pr_merge_state(_args),
      do: {:ok, %{merged: false, merged_at: nil, merge_commit_sha: nil, url: nil}}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    {:ok, _} = MergeStateRunner.start_link()

    Application.put_env(:platform, :stack_deployer,
      git_runner: MergeStateRunner,
      async: false
    )

    on_exit(fn ->
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        MergeStateRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    # Invocation counter for `process_stack_merged_pr/4`: the processor
    # evaluates this seam before doing anything else, so one message == one
    # invocation, and `refute_received` == zero.
    test_pid = self()
    Process.put(:webhook_stack_fault, fn -> send(test_pid, :process_stack_merged_pr_invoked) end)

    :ok
  end

  # Mirrors `build_stranded_stack!/2` in the webhook cascade test: a
  # `deploying` stack with a numbered rollup PR and members that satisfy the
  # fan-out's approved-plan guard. No webhook is ever delivered for it.
  defp deploying_stack_with_pr!(opts \\ []) do
    pr_number = Keyword.get(opts, :pr_number, 4242)
    member_count = Keyword.get(opts, :members, 2)
    slug = "poll-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Tasks.create_project(%{
        name: "Poll #{slug}",
        repo_url: Keyword.get(opts, :repo_url, "https://github.com/test/poll-repo")
      })

    rollup_pr =
      case pr_number do
        nil -> %{"status" => "opening"}
        n -> %{"number" => n, "url" => "https://github.com/test/poll-repo/pull/#{n}"}
      end

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Poll stack #{slug}",
        base_branch: "main",
        rollup_branch: "stack/#{slug}",
        status: Keyword.get(opts, :status, "deploying"),
        metadata: %{"rollup_pr" => rollup_pr}
      })

    members =
      for position <- 1..member_count//1 do
        {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member #{position}"})
        {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

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

        task
      end

    %{stack: stack, members: members, project: project}
  end

  defp reload(%Stack{id: id}), do: Repo.get!(Stack, id)

  describe "reconcile_merged_rollups/0 — merged on origin, webhook never delivered" do
    test "completes the stack through process_stack_merged_pr and stamps last_result=merged" do
      %{stack: stack, members: members} = deploying_stack_with_pr!(pr_number: 4242)
      MergeStateRunner.set_response({:ok, MergeStateRunner.merged("abc123merged")})

      # The discriminating precondition: origin says merged, nothing in the
      # DB knows it yet. If this fails the poll test below is vacuous.
      before = reload(stack)
      assert before.status == "deploying"
      refute Map.has_key?(before.metadata, "rollup_merge")
      refute Map.has_key?(before.metadata, "rollup_merge_watch")
      refute_received :process_stack_merged_pr_invoked

      summary = Stacks.reconcile_merged_rollups()

      assert summary == %{checked: 1, completed: 1, unmerged: 0, errored: 0}
      assert_received :process_stack_merged_pr_invoked
      refute_received :process_stack_merged_pr_invoked

      after_poll = reload(stack)
      assert after_poll.status == "done"
      assert after_poll.metadata["rollup_merge"]["merge_commit_sha"] == "abc123merged"
      assert after_poll.metadata["rollup_merge"]["merged_at"] == "2026-08-30T12:00:00Z"

      # The completion path's own metadata survives the watch stamp.
      assert after_poll.metadata["rollup_pr"]["number"] == 4242

      assert %{
               "last_result" => "merged",
               "last_error" => nil,
               "checks" => 1,
               "last_checked_at" => checked_at
             } = after_poll.metadata["rollup_merge_watch"]

      assert {:ok, _, _} = DateTime.from_iso8601(checked_at)

      for member <- members do
        assert Repo.get!(Task, member.id).status == "done"
      end

      # The runner was asked about THIS PR on THIS repo.
      assert [%{repo_url: "https://github.com/test/poll-repo", pr_number: 4242, stack_id: sid}] =
               MergeStateRunner.calls()

      assert sid == stack.id
    end

    test "a second pass over the now-done stack does not re-check it" do
      %{stack: stack} = deploying_stack_with_pr!()
      MergeStateRunner.set_response({:ok, MergeStateRunner.merged("sha1")})

      assert %{completed: 1} = Stacks.reconcile_merged_rollups()
      assert reload(stack).status == "done"
      assert_received :process_stack_merged_pr_invoked

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 0, completed: 0, unmerged: 0, errored: 0}

      refute_received :process_stack_merged_pr_invoked
      assert reload(stack).metadata["rollup_merge_watch"]["checks"] == 1
    end
  end

  describe "reconcile_merged_rollups/0 — control: genuinely unmerged rollup" do
    test "leaves the stack deploying, records unmerged, and never invokes process_stack_merged_pr" do
      %{stack: stack, members: members} = deploying_stack_with_pr!(pr_number: 77)
      MergeStateRunner.set_response({:ok, MergeStateRunner.unmerged()})

      assert reload(stack).status == "deploying"

      summary = Stacks.reconcile_merged_rollups()

      assert summary == %{checked: 1, completed: 0, unmerged: 1, errored: 0}
      # ZERO invocations — not "fewer".
      refute_received :process_stack_merged_pr_invoked

      after_poll = reload(stack)
      assert after_poll.status == "deploying"
      refute Map.has_key?(after_poll.metadata, "rollup_merge")
      assert after_poll.metadata["rollup_pr"] == stack.metadata["rollup_pr"]

      assert %{
               "last_result" => "unmerged",
               "last_error" => nil,
               "checks" => 1,
               "last_checked_at" => first_checked_at
             } = after_poll.metadata["rollup_merge_watch"]

      for member <- members do
        assert Repo.get!(Task, member.id).status == "deploying"
      end

      # A second unmerged pass bumps `checks` — the heartbeat an observer
      # uses to tell "still waiting" from "stuck" — and still completes
      # nothing.
      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 1, completed: 0, unmerged: 1, errored: 0}

      refute_received :process_stack_merged_pr_invoked

      second = reload(stack)
      assert second.status == "deploying"
      assert second.metadata["rollup_merge_watch"]["checks"] == 2
      assert second.metadata["rollup_merge_watch"]["last_result"] == "unmerged"
      assert is_binary(first_checked_at)
      assert length(MergeStateRunner.calls()) == 2
    end
  end

  describe "reconcile_merged_rollups/0 — could not answer" do
    test "runner error is recorded as error with last_error, counted in errored not unmerged" do
      %{stack: stack} = deploying_stack_with_pr!()
      MergeStateRunner.set_response({:error, {:gh_exit, 1, "gh: connection refused"}})

      summary = Stacks.reconcile_merged_rollups()

      assert summary == %{checked: 1, completed: 0, unmerged: 0, errored: 1}
      refute_received :process_stack_merged_pr_invoked

      after_poll = reload(stack)
      assert after_poll.status == "deploying"

      assert %{"last_result" => "error", "checks" => 1, "last_error" => err} =
               after_poll.metadata["rollup_merge_watch"]

      assert err =~ "gh_exit"
      assert err =~ "connection refused"
    end

    test "a runner without pr_merge_state/1 is an error, not a silent unmerged" do
      %{stack: stack} = deploying_stack_with_pr!()

      Application.put_env(:platform, :stack_deployer,
        git_runner: NoMergeStateRunner,
        async: false
      )

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 1, completed: 0, unmerged: 0, errored: 1}

      watch = reload(stack).metadata["rollup_merge_watch"]
      assert watch["last_result"] == "error"
      assert watch["last_error"] =~ "runner_missing_callback"
      assert reload(stack).status == "deploying"
    end

    test "a raise inside one stack's check is swallowed and the sweep continues" do
      %{stack: bad} = deploying_stack_with_pr!(repo_url: "https://github.com/test/bad")
      %{stack: good} = deploying_stack_with_pr!(repo_url: "https://github.com/test/good")

      bad_id = bad.id

      Application.put_env(:platform, :stack_deployer,
        git_runner: RaisingForOneRunner,
        async: false
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Stacks.reconcile_merged_rollups() ==
                   %{checked: 2, completed: 0, unmerged: 1, errored: 1}
        end)

      assert log =~ bad_id
      assert log =~ "boom from origin"

      assert reload(bad).metadata["rollup_merge_watch"]["last_result"] == "error"
      assert reload(bad).metadata["rollup_merge_watch"]["last_error"] =~ "boom from origin"
      assert reload(good).metadata["rollup_merge_watch"]["last_result"] == "unmerged"
      refute_received :process_stack_merged_pr_invoked
    end
  end

  describe "reconcile_merged_rollups/0 — candidate selection" do
    test "skips deploying stacks with no numbered rollup_pr and non-deploying stacks" do
      %{stack: opening} = deploying_stack_with_pr!(pr_number: nil)
      %{stack: in_progress} = deploying_stack_with_pr!(status: "in_progress")
      %{stack: done} = deploying_stack_with_pr!(status: "done")

      MergeStateRunner.set_response({:ok, MergeStateRunner.merged("would-complete")})

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 0, completed: 0, unmerged: 0, errored: 0}

      assert MergeStateRunner.calls() == []
      refute_received :process_stack_merged_pr_invoked

      for s <- [opening, in_progress, done] do
        refute Map.has_key?(reload(s).metadata, "rollup_merge_watch")
      end

      assert reload(opening).status == "deploying"
      assert reload(in_progress).status == "in_progress"
    end
  end

  describe "reconcile_stack_lifecycle/0 — rollup_merges summary key" do
    test "carries the poll's counts alongside the existing three" do
      %{stack: stack} = deploying_stack_with_pr!()
      MergeStateRunner.set_response({:ok, MergeStateRunner.unmerged()})

      assert %{
               commenced: c,
               pr_reopened: p,
               promoted: pr,
               rollup_merges: %{checked: 1, completed: 0, unmerged: 1, errored: 0}
             } = Stacks.reconcile_stack_lifecycle()

      assert is_integer(c) and is_integer(p) and is_integer(pr)
      assert reload(stack).status == "deploying"
      refute_received :process_stack_merged_pr_invoked
    end
  end
end
