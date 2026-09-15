defmodule Platform.Tasks.DeliveryReferenceTest do
  @moduledoc """
  `async: false` because the runner seam is pinned through application
  env, which is global. Every pin is restored in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias Platform.Tasks.DeliveryReference

  @repo "https://github.com/Startup-Suite/core"

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @impl true
    def commit(_slug, sha), do: reply({:commit, sha})

    @impl true
    def pull_request(_slug, number), do: reply({:pr, number})

    defp reply(key) do
      responses = Application.get_env(:platform, :delivery_reference_stub, %{})
      Map.get(responses, key, {:error, :not_found})
    end
  end

  defmodule GhMissingRunner do
    @moduledoc """
    Stands in for a server whose image shipped without the `gh` binary —
    the state the production image has actually been in.
    """
    @behaviour Platform.Tasks.DeliveryReference.Runner

    @message "`gh` (GitHub CLI) not found on PATH"

    @impl true
    def commit(_slug, _sha), do: {:error, {:unavailable, @message}}

    @impl true
    def pull_request(_slug, _number), do: {:error, {:unavailable, @message}}
  end

  defp pin_runner(module) do
    previous = Application.get_env(:platform, :delivery_reference)
    Application.put_env(:platform, :delivery_reference, runner: module)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :delivery_reference)
        value -> Application.put_env(:platform, :delivery_reference, value)
      end
    end)
  end

  defp pin_responses(map) do
    previous = Application.get_env(:platform, :delivery_reference_stub)
    Application.put_env(:platform, :delivery_reference_stub, map)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :delivery_reference_stub)
        value -> Application.put_env(:platform, :delivery_reference_stub, value)
      end
    end)
  end

  describe "parse/1" do
    test "refuses free text, and the positive control shows the refusal is not blanket" do
      # NEGATIVE: none of these names an object anyone can check.
      for free_text <- ["shipped", "sha", "done in the PR", "", "   ", "shipped last week", "#"] do
        assert DeliveryReference.parse(free_text) == {:error, :unparseable},
               "expected #{inspect(free_text)} to be unparseable"
      end

      # POSITIVE CONTROL, in the same test on purpose: a `parse/1` that
      # returned `:unparseable` for everything would pass the block above
      # and be useless. These four spellings must parse.
      assert {:ok, %DeliveryReference{kind: :sha, value: "b85a4a96"}} =
               DeliveryReference.parse("b85a4a96")

      assert {:ok, %DeliveryReference{kind: :pr, value: 1018}} = DeliveryReference.parse("#1018")

      assert {:ok, %DeliveryReference{kind: :pr, value: 1018}} =
               DeliveryReference.parse("https://github.com/Startup-Suite/core/pull/1018")

      assert {:ok, %DeliveryReference{kind: :sha, value: "b85a4a96"}} =
               DeliveryReference.parse("https://github.com/Startup-Suite/core/commit/b85a4a96")
    end

    test "a UUID prefix that happens to be all hex PARSES as a sha" do
      # `01a0a552` is the first group of a task UUIDv7 and is also eight
      # valid hex characters, so the 7–40-hex rule admits it. Asserting
      # the way it actually lands rather than the way one might wish:
      # parse/1 cannot tell a short hex word from a short sha, and the
      # discrimination happens in resolve/2, where GitHub answers
      # `:not_found` for a sha no commit has.
      assert {:ok, %DeliveryReference{kind: :sha, value: "01a0a552"}} =
               DeliveryReference.parse("01a0a552")
    end

    test "trims, downcases the sha, and preserves the raw string" do
      assert {:ok, %DeliveryReference{kind: :sha, value: "b85a4a96", raw: "B85A4A96"}} =
               DeliveryReference.parse("  B85A4A96  ")
    end

    test "refuses near-misses rather than scanning for an embedded token" do
      for near_miss <- [
            # six hex chars — under the 7-char floor
            "b85a4a",
            # a hex word inside prose: a scanning parser would accept this
            "merged the deadbeef branch last week",
            "#1018 (merged)",
            "https://github.com/Startup-Suite/core/pull/1018/files",
            "https://gitlab.com/Startup-Suite/core/pull/1018",
            "https://github.com/Startup-Suite/core/issues/1018",
            "#0",
            "#12a"
          ] do
        assert DeliveryReference.parse(near_miss) == {:error, :unparseable},
               "expected #{inspect(near_miss)} to be unparseable"
      end
    end

    test "non-binary input is unparseable rather than a crash" do
      assert DeliveryReference.parse(nil) == {:error, :unparseable}
      assert DeliveryReference.parse(1018) == {:error, :unparseable}
    end
  end

  describe "resolve/2 — pull requests" do
    setup do
      pin_runner(StubRunner)
      :ok
    end

    test "an unmerged PR is :not_merged, and the merged control proves the stub works" do
      pin_responses(%{
        {:pr, 1} => {:ok, %{"state" => "OPEN", "url" => "u", "mergeCommit" => nil}},
        {:pr, 2} => {:ok, %{"state" => "CLOSED", "url" => "u", "mergeCommit" => nil}},
        {:pr, 3} =>
          {:ok,
           %{
             "state" => "MERGED",
             "url" => "https://github.com/Startup-Suite/core/pull/3",
             "mergedAt" => "2026-09-15T00:00:00Z",
             "mergeCommit" => %{"oid" => "b85a4a96b85a4a96b85a4a96b85a4a96b85a4a96"}
           }}
      })

      {:ok, open} = DeliveryReference.parse("#1")
      {:ok, closed} = DeliveryReference.parse("#2")
      {:ok, merged} = DeliveryReference.parse("#3")

      assert DeliveryReference.resolve(open, @repo) == {:error, :not_merged}
      assert DeliveryReference.resolve(closed, @repo) == {:error, :not_merged}

      # POSITIVE CONTROL: without this, the two refusals above are equally
      # consistent with a stub that simply never answers.
      assert {:ok, resolved} = DeliveryReference.resolve(merged, @repo)
      assert resolved["kind"] == "pr"
      assert resolved["value"] == 3
      assert resolved["url"] == "https://github.com/Startup-Suite/core/pull/3"
      assert resolved["merge_commit"] == "b85a4a96b85a4a96b85a4a96b85a4a96b85a4a96"
      assert {:ok, _, _} = DateTime.from_iso8601(resolved["resolved_at"])
    end

    test "a PR GitHub has never heard of is :not_found" do
      pin_responses(%{})
      {:ok, ref} = DeliveryReference.parse("#99999")
      assert DeliveryReference.resolve(ref, @repo) == {:error, :not_found}
    end
  end

  describe "resolve/2 — commits" do
    setup do
      pin_runner(StubRunner)
      :ok
    end

    test "an existing commit resolves with its url" do
      sha = "b85a4a96b85a4a96b85a4a96b85a4a96b85a4a96"

      pin_responses(%{
        {:commit, sha} =>
          {:ok,
           %{"sha" => sha, "html_url" => "https://github.com/Startup-Suite/core/commit/#{sha}"}}
      })

      {:ok, ref} = DeliveryReference.parse(sha)
      assert {:ok, resolved} = DeliveryReference.resolve(ref, @repo)
      assert resolved["kind"] == "sha"
      assert resolved["value"] == sha
      assert resolved["url"] =~ sha
    end

    test "a sha no commit has is :not_found" do
      pin_responses(%{})
      {:ok, ref} = DeliveryReference.parse("deadbeef")
      assert DeliveryReference.resolve(ref, @repo) == {:error, :not_found}
    end
  end

  describe "resolve/2 — unavailability is not absence" do
    test "a server without `gh` reports {:unavailable, msg}, NOT :not_found" do
      pin_runner(GhMissingRunner)

      {:ok, sha_ref} = DeliveryReference.parse("b85a4a96")
      {:ok, pr_ref} = DeliveryReference.parse("#1018")

      for ref <- [sha_ref, pr_ref] do
        assert {:error, {:unavailable, message}} = DeliveryReference.resolve(ref, @repo)
        assert message =~ "gh"
        # The whole point: "I could not check" must not read as
        # "it does not exist".
        refute DeliveryReference.resolve(ref, @repo) == {:error, :not_found}
      end
    end

    test "a project with no usable repo_url is {:unavailable, msg}, not :not_found" do
      pin_runner(StubRunner)
      {:ok, ref} = DeliveryReference.parse("b85a4a96")

      for bad <- [nil, "", "not a repo", "https://gitlab.com/owner/name"] do
        assert {:error, {:unavailable, _}} = DeliveryReference.resolve(ref, bad)
      end
    end
  end

  describe "resolve/2 — a URL naming a different repository is refused" do
    setup do
      pin_runner(StubRunner)

      pin_responses(%{
        {:pr, 3} =>
          {:ok,
           %{
             "state" => "MERGED",
             "mergeCommit" => %{"oid" => "b85a4a96"},
             "url" => "https://github.com/Startup-Suite/core/pull/3"
           }},
        {:commit, "b85a4a96"} => {:ok, %{"sha" => "b85a4a96"}}
      })

      :ok
    end

    test "a foreign PR URL is {:foreign_repo, named, project} — and the SAME number resolves under the project's own slug" do
      {:ok, foreign} = DeliveryReference.parse("https://github.com/someone/else/pull/3")

      assert {:error, {:foreign_repo, "someone/else", "Startup-Suite/core"}} =
               DeliveryReference.resolve(foreign, @repo)

      # POSITIVE CONTROL, and it is the load-bearing half: without it the
      # refusal above is satisfied by a check that refuses every URL. The
      # stub would have answered PR 3 happily — the refusal came from the
      # slug comparison, not from the lookup.
      {:ok, own} = DeliveryReference.parse("#{@repo}/pull/3")
      assert {:ok, %{"kind" => "pr", "value" => 3}} = DeliveryReference.resolve(own, @repo)
    end

    test "a foreign COMMIT URL is refused the same way, and the project's own commit URL is not" do
      {:ok, foreign} = DeliveryReference.parse("https://github.com/someone/else/commit/b85a4a96")

      assert {:error, {:foreign_repo, "someone/else", "Startup-Suite/core"}} =
               DeliveryReference.resolve(foreign, @repo)

      {:ok, own} = DeliveryReference.parse("#{@repo}/commit/b85a4a96")
      assert {:ok, %{"kind" => "sha"}} = DeliveryReference.resolve(own, @repo)
    end

    test "case and `.git` spelling do not manufacture a mismatch" do
      {:ok, ref} = DeliveryReference.parse("https://github.com/startup-suite/CORE/pull/3")

      assert {:ok, _} =
               DeliveryReference.resolve(ref, "https://github.com/Startup-Suite/core.git")
    end

    test "a reference that names NO repository (bare sha, `#n`) is unaffected by the check" do
      # The slug guard must not turn the two commonest spellings into
      # refusals: they name no repository, so there is nothing to compare.
      {:ok, sha} = DeliveryReference.parse("b85a4a96")
      {:ok, hash} = DeliveryReference.parse("#3")

      assert sha.slug == nil
      assert hash.slug == nil
      assert {:ok, _} = DeliveryReference.resolve(sha, @repo)
      assert {:ok, _} = DeliveryReference.resolve(hash, @repo)
    end
  end
end
