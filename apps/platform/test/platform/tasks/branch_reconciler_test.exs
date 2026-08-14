defmodule Platform.Tasks.BranchReconcilerTest do
  @moduledoc """
  The reconciler exists to tell a WRONG merge-control state apart from an
  ORDINARY one, so every negative here is paired with a positive control
  in the same setup: a check that always fired would pass the mismatch
  assertions while proving nothing.
  """

  use ExUnit.Case, async: true

  alias Platform.Tasks.BranchReconciler

  @repo_url "https://github.com/Startup-Suite/core"
  @recorded "task/01a001ac-0ad8-7ece-bea6-2c524238fb86"

  defmodule Runner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def default_branch_sha(_), do: {:error, :not_used}

    @impl true
    def create_ref(_), do: {:error, :not_used}

    @impl true
    def list_matching_refs(%{repo: repo, ref: ref}) do
      pid = Process.get(:reconciler_test_pid) || self()
      send(pid, {:list_matching_refs, repo, ref})
      Process.get(:reconciler_test_answer, {:ok, []})
    end
  end

  defp answering(answer) do
    Process.put(:reconciler_test_pid, self())
    Process.put(:reconciler_test_answer, answer)
    [runner: Runner]
  end

  describe "reconcile/3" do
    test "the recorded name present on the remote is :match" do
      opts = answering({:ok, ["refs/heads/" <> @recorded]})

      assert :match == BranchReconciler.reconcile(@repo_url, @recorded, opts)
    end

    test "a differently-named sibling under the same 8-hex prefix is a mismatch naming it" do
      opts = answering({:ok, ["refs/heads/task/ext-app-badge", "refs/heads/task/01a001ac-other"]})

      assert {:mismatch, found} = BranchReconciler.reconcile(@repo_url, @recorded, opts)
      assert "task/ext-app-badge" in found
      refute @recorded in found
    end

    test "queries the 8-hex prefix glob, not the full recorded name" do
      opts = answering({:ok, []})

      BranchReconciler.reconcile(@repo_url, @recorded, opts)

      assert_received {:list_matching_refs, "Startup-Suite/core", "heads/task/01a001ac"}
    end

    test "a runner error is :unknown, never a mismatch" do
      for answer <- [
            {:error, :gh_unavailable, "`gh` not found on PATH"},
            {:error, :branch_provisioning_disabled},
            :nonsense
          ] do
        assert :unknown == BranchReconciler.reconcile(@repo_url, @recorded, answering(answer))
      end
    end

    test "no refs at all is :unknown — an absent probe is not a found branch" do
      assert :unknown == BranchReconciler.reconcile(@repo_url, @recorded, answering({:ok, []}))
    end

    test "an unresolvable repo and an unparseable branch are :unknown" do
      opts = answering({:ok, ["refs/heads/task/ext-app-badge"]})

      assert :unknown == BranchReconciler.reconcile("not a repo", @recorded, opts)
      assert :unknown == BranchReconciler.reconcile(@repo_url, "feature/whatever", opts)
      assert :unknown == BranchReconciler.reconcile(@repo_url, nil, opts)
    end
  end
end
