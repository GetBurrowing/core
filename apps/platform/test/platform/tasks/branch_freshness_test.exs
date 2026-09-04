defmodule Platform.Tasks.BranchFreshnessTest do
  @moduledoc """
  The probe exists to tell a branch that holds NOTHING apart from an
  ordinary branch that is merely behind, so every `:stale_stub`
  assertion here is paired with a `:fresh` control driven through the
  SAME stub with only the numbers changed. A predicate that answered
  `{:stale_stub, _}` unconditionally would satisfy the positive cases
  and prove nothing — and it would be the dangerous failure, because
  `stale_branch_step/3` offers a fast-forward on the strength of this
  answer.
  """

  use ExUnit.Case, async: true

  alias Platform.Tasks.BranchFreshness

  @repo_url "https://github.com/Startup-Suite/core"
  @branch "task/01a03fb9-46b4-7fef-8654-628a2874b5f0"
  @base "main"

  defmodule Runner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(_args), do: {:error, :not_stubbed}

    @impl true
    def default_branch_sha(_), do: {:error, :not_used}

    @impl true
    def create_ref(_), do: {:error, :not_used}

    @impl true
    def list_matching_refs(_), do: {:error, :not_used}

    @impl true
    def compare_refs(%{repo: repo, base: base, head: head}) do
      pid = Process.get(:freshness_test_pid) || self()
      send(pid, {:compare_refs, repo, base, head})
      Process.get(:freshness_test_answer, {:error, :unset})
    end
  end

  defp answering(answer) do
    Process.put(:freshness_test_pid, self())
    Process.put(:freshness_test_answer, answer)
    [runner: Runner]
  end

  describe "assess/4 — the defect signature" do
    test "no commits of its own while the base has moved is a stale stub naming the distance" do
      # The exact shape observed on task 01a03fb9-46b4: the branch sat at a
      # commit already on main, 25 behind, carrying nothing.
      opts = answering({:ok, %{ahead_by: 0, behind_by: 25}})

      assert {:stale_stub, 25} == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "the reported distance is the runner's behind_by, not a constant" do
      opts = answering({:ok, %{ahead_by: 0, behind_by: 412}})

      assert {:stale_stub, 412} == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end
  end

  describe "assess/4 — controls that must NOT be a stale stub" do
    test "a branch with commits of its own is fresh however far behind it is" do
      # This is the control that matters most. 412 of 412 remote task
      # branches are behind main; if `behind_by` alone decided, this would
      # answer `{:stale_stub, _}` and the prompt would offer to fast-forward
      # a branch that HAS work on it.
      opts = answering({:ok, %{ahead_by: 1, behind_by: 25}})

      assert :fresh == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "a branch far behind but far ahead is still fresh" do
      opts = answering({:ok, %{ahead_by: 14, behind_by: 986}})

      assert :fresh == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "identical to the base is fresh, not a stub" do
      # ahead 0 alone is not the signal: a branch level with main is the
      # ordinary state at a first dispatch, and there is nothing to warn about.
      opts = answering({:ok, %{ahead_by: 0, behind_by: 0}})

      assert :fresh == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end
  end

  describe "assess/4 — a failed probe is never a finding" do
    test "a runner error is :unknown" do
      opts = answering({:error, {:gh_error, "boom"}})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "a missing gh CLI is :unknown" do
      opts = answering({:error, :gh_unavailable, "no gh on PATH"})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "the disabled NoopRunner answer is :unknown" do
      opts = answering({:error, :branch_provisioning_disabled})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "a response missing the counts is :unknown" do
      opts = answering({:ok, %{status: "behind"}})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "negative counts are :unknown rather than a stub" do
      opts = answering({:ok, %{ahead_by: 0, behind_by: -3}})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, @base, opts)
    end

    test "a runner that RAISES is :unknown, not a crash" do
      # `assess/4` runs inside prompt rendering, inside the TaskRouter
      # GenServer. A raise here does not lose a paragraph, it kills the
      # dispatch. Adding `compare_refs/1` to the behaviour left a stub in
      # `task_router_branch_provisioning_test.exs` without the callback and
      # the UndefinedFunctionError took `do_dispatch_resolved/6` down with it.
      defmodule RaisingRunner do
        @moduledoc false
        @behaviour Platform.Tasks.BranchProvisioner.Runner

        @impl true
        def branch_head_sha(_args), do: {:error, :not_stubbed}
        @impl true
        def default_branch_sha(_), do: {:error, :not_used}
        @impl true
        def create_ref(_), do: {:error, :not_used}
        @impl true
        def list_matching_refs(_), do: {:error, :not_used}
        @impl true
        def compare_refs(_), do: raise("gh exploded")
      end

      assert :unknown ==
               BranchFreshness.assess(@repo_url, @branch, @base, runner: RaisingRunner)
    end

    test "a runner that EXITS is :unknown, not a crash" do
      defmodule ExitingRunner do
        @moduledoc false
        @behaviour Platform.Tasks.BranchProvisioner.Runner

        @impl true
        def branch_head_sha(_args), do: {:error, :not_stubbed}
        @impl true
        def default_branch_sha(_), do: {:error, :not_used}
        @impl true
        def create_ref(_), do: {:error, :not_used}
        @impl true
        def list_matching_refs(_), do: {:error, :not_used}
        @impl true
        def compare_refs(_), do: exit(:timeout)
      end

      assert :unknown ==
               BranchFreshness.assess(@repo_url, @branch, @base, runner: ExitingRunner)
    end

    test "a runner missing the callback entirely is :unknown, not a crash" do
      defmodule PartialRunner do
        @moduledoc false
        def list_matching_refs(_), do: {:ok, []}
      end

      assert :unknown ==
               BranchFreshness.assess(@repo_url, @branch, @base, runner: PartialRunner)
    end

    test "an unresolvable repo is :unknown and never reaches the runner" do
      opts = answering({:ok, %{ahead_by: 0, behind_by: 25}})

      assert :unknown == BranchFreshness.assess("not a repo url", @branch, @base, opts)
      refute_received {:compare_refs, _, _, _}
    end

    test "a nil branch is :unknown and never reaches the runner" do
      opts = answering({:ok, %{ahead_by: 0, behind_by: 25}})

      assert :unknown == BranchFreshness.assess(@repo_url, nil, @base, opts)
      refute_received {:compare_refs, _, _, _}
    end

    test "a nil base branch is :unknown and never reaches the runner" do
      opts = answering({:ok, %{ahead_by: 0, behind_by: 25}})

      assert :unknown == BranchFreshness.assess(@repo_url, @branch, nil, opts)
      refute_received {:compare_refs, _, _, _}
    end
  end

  describe "assess/4 — the comparison it actually asks for" do
    test "asks the normalized repo for base...head, in that order" do
      # Argument order is load-bearing: GitHub reports `ahead_by` relative to
      # HEAD, so swapping base and head exchanges the counts and inverts the
      # verdict. A stale stub would come back as :fresh and the warning would
      # never render.
      opts = answering({:ok, %{ahead_by: 0, behind_by: 25}})

      BranchFreshness.assess(@repo_url, @branch, @base, opts)

      assert_received {:compare_refs, "Startup-Suite/core", @base, @branch}
    end
  end
end
