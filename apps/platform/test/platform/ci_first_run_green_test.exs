defmodule Platform.CiFirstRunGreenTest do
  @moduledoc """
  A drift alarm on the `first-run-green` job in `.github/workflows/ci.yml`
  (task 01a08d81). Like `Platform.CiRetryVisibilityTest`, this reads the
  workflow's TEXT: it detects the check being edited away or unwired, and it
  cannot prove GitHub executed any of it. The execution evidence is the pair of
  control runs recorded in the PR that added the job and in
  `notes/2026-09-10-ci-retry-census.md` §11.

  The contract pinned here: branch protection can only require a named check,
  and the `Test` job concludes `success` for both first-run-green and
  failed-then-retry-green. So there is a distinct job, `first-run-green`, keyed
  to THIS run's outcome — the `retry_fired` output the `Run tests` step writes
  — and it fails when the retry fired. It never re-runs tests, and `Test`'s own
  semantics are unchanged.

  Each assertion is scoped to the relevant slice of the workflow (the
  `Run tests` step body, the `first-run-green` job body, the `test` job's
  `outputs:` block), so prose elsewhere in the file cannot satisfy it.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  setup_all do
    lines = @ci_workflow |> File.read!() |> String.split("\n")
    {:ok, step: run_tests_step_body(lines), job: job_body(lines, "first-run-green")}
  end

  # The `- name: Run tests` step body: from that line to the next sibling entry
  # at step indent (`- name:` or a step-level comment). Same slicer as
  # Platform.CiRetryVisibilityTest, kept in step with it.
  defp run_tests_step_body(lines) do
    start =
      Enum.find_index(lines, &(String.trim(&1) == "- name: Run tests")) ||
        flunk("no `- name: Run tests` step in #{@ci_workflow}")

    rest = Enum.drop(lines, start + 1)

    len =
      Enum.find_index(rest, fn line -> Regex.match?(~r/^      (- name:|#)/, line) end) ||
        length(rest)

    rest |> Enum.take(len) |> Enum.join("\n")
  end

  # A job body: from `  <name>:` (job indent, two spaces) to the next line at
  # job indent (`  <word>:` or `  #`). Comments above the job are NOT included,
  # so the assertions below are on the job's YAML, not its rationale.
  defp job_body(lines, name) do
    start =
      Enum.find_index(lines, &(&1 == "  #{name}:")) ||
        flunk("no `#{name}:` job in #{@ci_workflow}")

    rest = Enum.drop(lines, start + 1)
    len = Enum.find_index(rest, &Regex.match?(~r/^  (\S|#)/, &1)) || length(rest)
    rest |> Enum.take(len) |> Enum.join("\n")
  end

  # Comment-stripped view of a body: the negative assertions must not be
  # satisfied (or defeated) by a `#` line that merely mentions the forbidden
  # text.
  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  # The body of one `<pattern>)` arm of the job's `case`: from that line to the
  # next `;;`. Empty string if the arm is absent, which fails the assertion on it.
  defp case_arm(code, pattern) do
    case Regex.run(~r/^\s*#{Regex.escape(pattern)}\)\n(.*?)^\s*;;/ms, code) do
      [_, body] -> body
      nil -> ""
    end
  end

  describe "the Run tests step records whether the retry fired" do
    test "the step has the id the job output reads", %{step: step} do
      # `id:` sits between `- name: Run tests` and `run:`, i.e. inside the slice.
      assert step =~ ~r/^\s+id: run-tests\s*$/m,
             "the `Run tests` step in ci.yml has lost `id: run-tests`, so " <>
               "`steps.run-tests.outputs.retry_fired` resolves to '' and the " <>
               "`first-run-green` job can only ever hit its 'output missing' branch."
    end

    test "retry_fired=true is written on the retry-green path, and false otherwise",
         %{step: step} do
      code = code_only(step)

      assert code =~ ~r/echo "retry_fired=true" >> "\$GITHUB_OUTPUT"/,
             "the retry-green branch of `Run tests` no longer writes " <>
               "`retry_fired=true` to $GITHUB_OUTPUT. `first-run-green` would then " <>
               "pass on every retry-green run — a check that reads as a gate while " <>
               "gating nothing."

      assert code =~ ~r/echo "retry_fired=false" >> "\$GITHUB_OUTPUT"/,
             "`Run tests` no longer writes `retry_fired=false` on the green-first-pass " <>
               "path, so `first-run-green` fails on every clean run."

      # Ordering: `true` must be written INSIDE the retry branch (after the
      # ::warning:: annotation) and `false` AFTER the whole `if !` block, so a
      # green first pass never passes through the `true` write.
      [warning_at, true_at, false_at] =
        for needle <- ["::warning::", "retry_fired=true", "retry_fired=false"] do
          {at, _} = :binary.match(code, needle)
          at
        end

      assert warning_at < true_at and true_at < false_at,
             "`retry_fired=true` must be written inside the retry branch (after the " <>
               "::warning:: annotation) and `retry_fired=false` after it; the order in " <>
               "ci.yml is now different, which changes which path writes what."
    end

    test "the Test job exposes retry_fired as a job output" do
      # Sharded: each `test-shard` leg records `steps.run-tests.outputs.retry_fired`
      # (Platform.CiTestShardsTest pins that and the OR across shards), and the
      # aggregating `test` job (named `Test`) exposes the result.
      lines = @ci_workflow |> File.read!() |> String.split("\n")
      test_job = job_body(lines, "test")
      shard_job = job_body(lines, "test-shard")

      assert test_job =~
               ~r/^    outputs:\n      retry_fired: \$\{\{ steps\.aggregate\.outputs\.retry_fired \}\}\s*$/m,
             "the `test` job in ci.yml no longer has `outputs: retry_fired: " <>
               "${{ steps.aggregate.outputs.retry_fired }}`. Without it the outcome " <>
               "never crosses the job boundary and `first-run-green` cannot read it."

      assert code_only(shard_job) =~
               ~r/RETRY_FIRED: \$\{\{ steps\.run-tests\.outputs\.retry_fired \}\}/,
             "`test-shard` no longer records `steps.run-tests.outputs.retry_fired`, " <>
               "so a retry in a shard never reaches `Test` or `first-run-green`."
    end
  end

  describe "the first-run-green job" do
    test "exists, depends on Test, and runs on the same runner class", %{job: job} do
      assert job =~ ~r/^    name: first-run-green\s*$/m,
             "the job's display name is no longer `first-run-green`. Branch protection " <>
               "requires checks BY NAME; renaming it silently un-requires it."

      assert job =~ ~r/^    needs: test\s*$/m,
             "`first-run-green` no longer `needs: test`, so `needs.test.outputs` is " <>
               "empty and the job cannot read whether the retry fired."

      assert job =~ ~r/^    runs-on: ubuntu-latest\s*$/m,
             "`first-run-green` is no longer on the same runner class as Test " <>
               "(GitHub-hosted `ubuntu-latest`)."

      refute code_only(job) =~ ~r/^    if:/m,
             "`first-run-green` has a job-level `if:`. A skipped job never reports, " <>
               "so the required check would sit pending (or be satisfied by a skip) " <>
               "on whatever runs the condition excludes."
    end

    test "reads the retry outcome from the job output and exits 1 on it", %{job: job} do
      code = code_only(job)

      assert code =~ ~r/\$\{\{ needs\.test\.outputs\.retry_fired \}\}/,
             "`first-run-green` no longer reads `needs.test.outputs.retry_fired`. " <>
               "Whatever it reads instead is not the outcome the Run tests step recorded."

      assert case_arm(code, "true") =~ ~r/^\s*exit 1\s*$/m,
             "`first-run-green` no longer exits 1 in its `true)` arm — the check " <>
               "would pass on a retry-green run."

      refute case_arm(code, "false") =~ ~r/exit 1/,
             "`first-run-green`'s `false)` arm exits 1, so the check fails on a clean run."
    end

    test "never runs tests and never retries", %{job: job} do
      code = code_only(job)

      refute code =~ ~r/mix test/,
             "`first-run-green` invokes `mix test`. It must read the outcome of the " <>
               "Test job's run, not produce a second run whose flakes are its own."

      refute code =~ ~r/--include slow/,
             "`--include slow` appeared in `first-run-green`; there is no test " <>
               "invocation for it to belong to."

      refute code =~ ~r/\|\|/,
             "`first-run-green` has a `||` retry. A retry on the check that exists to " <>
               "detect retries is the defect class this job closes."

      refute code =~ ~r/actions\/checkout/,
             "`first-run-green` checks the repo out; it needs nothing from the tree."
    end

    test "continue-on-error is scoped to pushes to main and nowhere else", %{job: job} do
      code = code_only(job)

      expr =
        case Regex.run(~r/^    continue-on-error:\s*(.+?)\s*$/m, code) do
          [_, expr] ->
            expr

          nil ->
            flunk(
              "`first-run-green` has no job-level `continue-on-error`. Without it a " <>
                "retry-green push to main concludes the whole workflow as `failure`, " <>
                "which is what task 01a136c1 stopped. It must be conditional, never a " <>
                "bare `true`: `first-run-green` is a REQUIRED check on PRs."
            )
        end

      assert expr =~ "github.event_name == 'push'",
             "the `continue-on-error` expression `#{expr}` no longer requires " <>
               "`github.event_name == 'push'`. `first-run-green` is a REQUIRED status " <>
               "check; on a pull_request run it must still fail the job."

      assert expr =~ "github.ref == 'refs/heads/main'",
             "the `continue-on-error` expression `#{expr}` no longer requires " <>
               "`github.ref == 'refs/heads/main'`. `first-run-green` is a REQUIRED status " <>
               "check; on a push to any other branch it must still fail the job."

      refute expr in ["true", "${{ true }}"],
             "`continue-on-error` is unconditional, which un-gates the required " <>
               "`first-run-green` check on PRs."
    end
  end
end
