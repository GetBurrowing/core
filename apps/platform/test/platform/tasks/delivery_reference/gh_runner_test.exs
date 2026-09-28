defmodule Platform.Tasks.DeliveryReference.GhRunnerTest do
  # Pure functions only: nothing here shells out to `gh` or touches the
  # network (task 01a044b0 stage 1).
  use ExUnit.Case, async: true

  alias Platform.Tasks.DeliveryReference.GhRunner

  @slug "Startup-Suite/core"

  describe "merged_pull_requests_args/2" do
    test "builds a read-only `gh pr list --state merged` argv" do
      assert GhRunner.merged_pull_requests_args(@slug, 50) == [
               "pr",
               "list",
               "-R",
               @slug,
               "--state",
               "merged",
               "--limit",
               "50",
               "--json",
               "number,title,body,mergedAt,mergeCommit,url"
             ]
    end

    test "refuses a non-positive limit" do
      assert_raise FunctionClauseError, fn -> GhRunner.merged_pull_requests_args(@slug, 0) end
    end
  end

  describe "code_search_args/2" do
    test "builds a read-only `gh search code` argv with the term after --" do
      assert GhRunner.code_search_args(@slug, "no running stage") == [
               "search",
               "code",
               "--repo",
               @slug,
               "--json",
               "path",
               "--limit",
               "5",
               "--",
               "no running stage"
             ]
    end

    test "a term that looks like a flag stays a positional argument" do
      args = GhRunner.code_search_args(@slug, "--delete")
      assert List.last(args) == "--delete"
      assert Enum.at(args, -2) == "--"
    end
  end

  describe "decode_list/1" do
    test "a JSON array of objects decodes to {:ok, list}" do
      json = ~s([{"number": 1, "title": "a"}, {"number": 2, "title": "b"}])

      assert {:ok, [%{"number" => 1}, %{"number" => 2}]} = GhRunner.decode_list(json)
    end

    test "an empty JSON array is {:ok, []}" do
      assert GhRunner.decode_list("[]") == {:ok, []}
    end

    test "a JSON object is unavailable, not a list" do
      assert {:error, {:unavailable, _}} = GhRunner.decode_list(~s({"number": 1}))
    end

    test "garbage is unavailable" do
      assert {:error, {:unavailable, _}} = GhRunner.decode_list("HTTP 502: Bad Gateway")
    end

    test "an array holding a non-object is unavailable" do
      assert {:error, {:unavailable, _}} = GhRunner.decode_list(~s([1, "two"]))
    end
  end

  describe "code_search_result/1 — unavailable is not empty" do
    test "a non-zero exit is unavailable, NOT {:ok, []}" do
      result = GhRunner.code_search_result({:exit, 1, "HTTP 403: API rate limit exceeded"})

      refute result == {:ok, []}
      assert {:error, {:unavailable, message}} = result
      assert message =~ "rate limit"
    end

    test "a non-zero exit worded like a 404 is still unavailable, NOT {:ok, []}" do
      result = GhRunner.code_search_result({:exit, 1, "HTTP 404: Not Found"})

      refute result == {:ok, []}
      assert {:error, {:unavailable, _}} = result
    end

    test "a missing binary passes through as unavailable" do
      missing = {:error, {:unavailable, "`gh` (GitHub CLI) not found on PATH"}}
      assert GhRunner.code_search_result(missing) == missing
    end

    test "unparseable output on a zero exit is unavailable, NOT {:ok, []}" do
      assert {:error, {:unavailable, _}} = GhRunner.code_search_result({:ok, "not json"})
    end

    test "a hit without a path is unavailable" do
      assert {:error, {:unavailable, _}} = GhRunner.code_search_result({:ok, ~s([{"url": "x"}])})
    end

    test "only a zero exit printing [] is {:ok, []}" do
      assert GhRunner.code_search_result({:ok, "[]\n"}) == {:ok, []}
    end

    test "hits decode with their path" do
      assert {:ok, [%{"path" => "lib/a.ex"}]} =
               GhRunner.code_search_result({:ok, ~s([{"path": "lib/a.ex"}])})
    end
  end

  describe "merged_pull_requests_result/1 — unavailable is not empty" do
    test "a non-zero exit is unavailable, NOT {:ok, []}" do
      result =
        GhRunner.merged_pull_requests_result({:exit, 1, "Could not resolve to a Repository"})

      refute result == {:ok, []}
      assert {:error, {:unavailable, _}} = result
    end

    test "a missing binary passes through as unavailable" do
      missing = {:error, {:unavailable, "`gh` (GitHub CLI) not found on PATH"}}
      assert GhRunner.merged_pull_requests_result(missing) == missing
    end

    test "a JSON object on a zero exit is unavailable" do
      assert {:error, {:unavailable, _}} =
               GhRunner.merged_pull_requests_result({:ok, ~s({"number": 1})})
    end

    test "a merged-PR array decodes" do
      json =
        ~s([{"number": 1139, "title": "t", "body": "b", "mergedAt": "2026-09-28T00:00:00Z", ) <>
          ~s("mergeCommit": {"oid": "8bcdfd30"}, "url": "https://github.com/Startup-Suite/core/pull/1139"}])

      assert {:ok, [%{"number" => 1139, "mergeCommit" => %{"oid" => "8bcdfd30"}}]} =
               GhRunner.merged_pull_requests_result({:ok, json})
    end
  end

  test "the listing callbacks are optional on the Runner behaviour" do
    optional = Platform.Tasks.DeliveryReference.Runner.behaviour_info(:optional_callbacks)
    assert {:merged_pull_requests, 2} in optional
    assert {:code_search, 2} in optional
  end
end
