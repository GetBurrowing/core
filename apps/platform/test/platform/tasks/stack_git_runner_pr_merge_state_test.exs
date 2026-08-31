defmodule Platform.Tasks.StackGitRunnerPrMergeStateTest do
  @moduledoc """
  Unit tests for the `pr_merge_state/1` runner callback (task 01a05394
  stage 1).

  These drive `GitShellRunner.parse_pr_merge_state/1` DIRECTLY rather than
  shelling out to a real `gh`: a test that depends on the GitHub CLI being
  installed passes or fails on host state, and an uninstalled binary prints
  nothing, so that failure mode is silent.
  """
  use ExUnit.Case, async: true

  alias Platform.Tasks.StackDeployer.GitShellRunner
  alias Platform.Tasks.StackDeployer.NoopRunner

  describe "parse_pr_merge_state/1" do
    test "a merged payload yields merged: true with the merge commit sha" do
      payload =
        Jason.encode!(%{
          "merged" => true,
          "mergedAt" => "2026-08-30T12:00:00Z",
          "mergeCommit" => %{"oid" => "abc123def4567890"},
          "url" => "https://github.com/example/example/pull/4242"
        })

      assert {:ok, state} = GitShellRunner.parse_pr_merge_state(payload)

      assert state == %{
               merged: true,
               merged_at: "2026-08-30T12:00:00Z",
               merge_commit_sha: "abc123def4567890",
               url: "https://github.com/example/example/pull/4242"
             }
    end

    test "an unmerged payload yields merged: false with nil sha and nil merged_at" do
      payload =
        Jason.encode!(%{
          "merged" => false,
          "mergedAt" => nil,
          "mergeCommit" => nil,
          "url" => "https://github.com/example/example/pull/4242"
        })

      assert {:ok, state} = GitShellRunner.parse_pr_merge_state(payload)
      assert state.merged == false
      assert state.merged_at == nil
      assert state.merge_commit_sha == nil
      assert state.url == "https://github.com/example/example/pull/4242"
    end

    test "malformed output is an error, not a silent merged: false" do
      output = "gh: could not resolve to a PullRequest\n"

      assert {:error, {:pr_view_unparseable, ^output}} =
               GitShellRunner.parse_pr_merge_state(output)
    end

    test "valid JSON missing the merged key is unparseable rather than fail-open" do
      output = Jason.encode!(%{"url" => "https://github.com/example/example/pull/1"})

      assert {:error, {:pr_view_unparseable, ^output}} =
               GitShellRunner.parse_pr_merge_state(output)
    end

    test "a non-boolean merged value is unparseable rather than truthy" do
      output = Jason.encode!(%{"merged" => "true"})

      assert {:error, {:pr_view_unparseable, ^output}} =
               GitShellRunner.parse_pr_merge_state(output)
    end
  end

  describe "pr_merge_state/1 argument validation" do
    test "missing required keys returns :invalid_args without shelling out" do
      assert {:error, {:invalid_args, _}} = GitShellRunner.pr_merge_state(%{})

      assert {:error, {:invalid_args, _}} =
               GitShellRunner.pr_merge_state(%{repo_url: "example/example"})

      assert {:error, {:invalid_args, _}} =
               GitShellRunner.pr_merge_state(%{repo_url: "example/example", pr_number: 0})
    end
  end

  describe "NoopRunner.pr_merge_state/1" do
    test "defaults to merged: false so the backstop poll is a no-op in test env" do
      assert {:ok, %{merged: false, merged_at: nil, merge_commit_sha: nil, url: nil}} =
               NoopRunner.pr_merge_state(%{repo_url: "example/example", pr_number: 1})
    end
  end

  describe "the GitRunner behaviour" do
    test "declares pr_merge_state/1 as an optional callback" do
      optional =
        Platform.Tasks.StackDeployer.GitRunner.behaviour_info(:optional_callbacks)

      assert {:pr_merge_state, 1} in optional

      assert {:pr_merge_state, 1} in Platform.Tasks.StackDeployer.GitRunner.behaviour_info(
               :callbacks
             )
    end
  end
end
