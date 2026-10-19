defmodule Platform.GhUnavailableGuardTest do
  @moduledoc """
  `gh` is not installed in `ghcr.io/getburrowing/core` (`command -v gh` in
  the running container returns nothing). Every site that shelled out to it
  without checking therefore died with `ErlangError: :enoent` — an opaque
  failure indistinguishable from a git failure once it has been through a
  try/rescue, which is why the missing binary took a separate
  investigation to find.

  These tests scrub `PATH` so the binary genuinely cannot be resolved, then
  assert each site returns a distinct, greppable reason that names `gh`.

  `async: false` because `PATH` is process-global. ExUnit runs sync modules
  serially after every async module has finished.

  The `GitShellRunner` sites (`gh pr create`, `gh pr close`) are covered in
  `Platform.Tasks.StackDeployer.GitShellRunnerTest`.
  """

  use ExUnit.Case, async: false

  alias Platform.Tasks.AutoMerger
  alias Platform.Tasks.DeployMergeReconciler.GhMergeRunner
  alias PlatformWeb.GithubWebhookController

  test "AutoMerger.execute_merge/3 returns {:error, :gh_unavailable, _} when gh is missing" do
    result =
      without_gh(fn ->
        AutoMerger.execute_merge("https://github.com/test/repo", 42, "squash")
      end)

    assert {:error, :gh_unavailable, message} = result
    assert message =~ "gh"
    assert message =~ "42"
  end

  test "GithubWebhookController.find_pr_number_for_branch/2 returns {:error, :gh_unavailable}" do
    result =
      without_gh(fn ->
        GithubWebhookController.find_pr_number_for_branch(
          "https://github.com/test/repo",
          "task/019f9b28-20d9-7c11-9d0a-000000000001"
        )
      end)

    assert result == {:error, :gh_unavailable}
  end

  test "GhMergeRunner.merged_pr/1 returns {:error, :gh_unavailable} when gh is missing" do
    result =
      without_gh(fn ->
        GhMergeRunner.merged_pr(%{repo: "test/repo", branch: "task/x"})
      end)

    assert result == {:error, :gh_unavailable}
  end

  test "GhMergeRunner.commits_between/3 returns {:error, :gh_unavailable} when gh is missing" do
    result =
      without_gh(fn ->
        GhMergeRunner.commits_between(%{repo: "test/repo", branch: "task/x"}, "base", "head")
      end)

    assert result == {:error, :gh_unavailable}
  end

  test "GhMergeRunner.commits_between/3 returns {:error, {:invalid_repo, _}} for an " <>
         "unnormalizable repo, without ever shelling out to gh" do
    # A repo that will not normalize to an owner/name slug cannot be turned
    # into a `repos/<slug>/compare/...` path, so this must fail BEFORE
    # `gh` is invoked at all — proven by leaving `PATH` untouched and
    # asserting no `ErlangError` and no `gh_unavailable` surfaces.
    assert GhMergeRunner.commits_between(%{repo: "not a repo", branch: "task/x"}, "b", "h") ==
             {:error, {:invalid_repo, "not a repo"}}
  end

  # Run `fun` with a `PATH` that resolves nothing, then restore. Without the
  # guard, `System.cmd("gh", …)` raises `ErlangError: :enoent` here.
  defp without_gh(fun) do
    previous = System.get_env("PATH")
    System.put_env("PATH", Path.join(System.tmp_dir!(), "definitely-not-a-bin-dir"))

    try do
      fun.()
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end
  end
end
