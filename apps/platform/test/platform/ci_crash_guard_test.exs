defmodule Platform.CiCrashGuardTest do
  @moduledoc """
  A drift alarm on the crash guards in the `Run tests` step of
  `.github/workflows/ci.yml` (task 01a08e20). Like `Platform.CiRetryVisibilityTest`
  and `Platform.CiFirstRunGreenTest`, this reads the workflow's TEXT: it detects
  the guards being edited away or reordered, and it cannot prove GitHub executed
  any of them. The execution evidence is the set of control runs recorded in the
  PR that added them.

  The contract pinned here. On PR #997 attempt 1 the BEAM aborted mid-suite
  (`[asmjit] Assertion failed`, core dumped). A crash prints no ExUnit failure
  block, so the retry's name harvest was empty, `mix test --failed` ran an empty
  manifest, printed `There are no tests to run`, exited 0, and the job concluded
  success having run 9 tests. Two guards close that:

    1. Nameless-retry refusal — a non-zero first pass with an EMPTY harvest is a
       crash, not a flake; the step exits 1 BEFORE the retry command runs.
    2. Test-count floor — the first pass's own ExUnit summary line must be
       present and its total must be at least `MIN_TEST_COUNT` (a workflow env
       value). Since Elixir 1.20 that line reads `Result: N passed` (or
       `Result: P/N passed` with failures); before 1.20 it was
       `N tests, M failures`.

  Each assertion is scoped to the `Run tests` step body, comment-stripped, so a
  `#` line that merely mentions a literal cannot satisfy it.

  Control runs (task 01a08e20 stage 2, PR #1002, all on the task branch; every
  throwaway commit was followed by a revert whose tree is byte-identical to the
  fixed tip `b97a6ab4`, `git diff b97a6ab4 <revert>` empty):

    (a) crash halt   sha d1854a37  run 34554189291  Test failure, `Run tests`
        failure, annotation `initial mix test failed with no ExUnit failures
        harvested (crash, not flake)` present, no retry warning, no
        `retry_fired` output set, first-run-green skipped.
    (b) named flake  sha b501d2f6  run 34555108856  Test success, warning
        annotation names `zz_01a08e20_flake_control_test.exs:8`, retry-branch
        floor line `ran 16959 tests (floor MIN_TEST_COUNT=15000)`,
        retry_fired=true, first-run-green failure with its annotation.
    (c) clean        sha 978bc230  run 34555859883  Test success, first-run-green
        success, no `initial mix test failed` annotation, green-path floor line
        `ran 16958 tests`, retry_fired=false.
    (d) floor 49999  sha 5e4451f1  run 34556541972  first pass green (16958
        tests, 0 failures) so the GREEN-PATH call fired: annotation `main mix
        test pass ran 16958 tests, below MIN_TEST_COUNT=49999`, `Run tests` the
        only failing step, first-run-green skipped.
    column-0 measurement: sha 60b866df run 34552027555 (builder branch) — crash
        halt before the bare `echo`: step red, NO annotation registered.

  '1 in ~40' (one vacuous green in the 40-run census window) is a FLOOR on the
  crash rate, not an estimate — vacuous greens were invisible before this
  guard, so the census could only count the ones someone happened to notice.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  @refusal_error "::error::initial mix test failed with no ExUnit failures harvested (crash, not flake)"
  @retry_command "if mix test --failed --max-cases 1 --include slow; then"

  setup_all do
    source = File.read!(@ci_workflow)
    lines = String.split(source, "\n")
    {:ok, source: source, step: run_tests_step_body(lines)}
  end

  # The `- name: Run tests` step body: from that line to the next sibling entry
  # at step indent (`- name:` or a step-level comment). Same slicer as
  # Platform.CiRetryVisibilityTest and Platform.CiFirstRunGreenTest.
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

  # Comment-stripped view of a body.
  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp offset_of(code, needle) do
    case :binary.match(code, needle) do
      {at, _} -> at
      :nomatch -> flunk("`#{needle}` is not in the comment-stripped `Run tests` step body")
    end
  end

  describe "nameless-retry refusal" do
    test "a non-zero first pass with an empty harvest exits 1 with the refusal error",
         %{step: step} do
      code = code_only(step)

      assert code =~ ~r/^\s*if \[ -z "\$failed_tests" \]; then\s*$/m,
             "the `Run tests` step no longer tests `-z \"$failed_tests\"` in code. A " <>
               "crash (no ExUnit failure blocks) would again reach `mix test --failed` " <>
               "with an empty manifest, which exits 0 and greens the job on 9 tests."

      assert String.contains?(code, @refusal_error),
             "the refusal literal `#{@refusal_error}` is gone from the `Run tests` " <>
               "step. Whatever replaced it, a crash must fail the step with an " <>
               "::error:: naming it as a crash, not a flake."

      # The refusal must be the consequence of the emptiness test: the literal
      # lives inside the `-z` block, followed by `exit 1`, before anything else.
      # The block is exactly: bare `echo` (ExUnit's progress dots leave the
      # cursor mid-line and GitHub reads `::error::` only at column 0 —
      # control run 34552027555 was red with no annotation), the refusal,
      # `exit 1`. Nothing else — in particular no `$GITHUB_OUTPUT` write.
      assert code =~
               ~r/if \[ -z "\$failed_tests" \]; then\s*\n\s*echo\s*\n\s*echo "#{Regex.escape(@refusal_error)}"\s*\n\s*exit 1\s*\n\s*fi/,
             "the `-z \"$failed_tests\"` block is no longer exactly `echo` / refusal " <>
               "::error:: / `exit 1`. The old shape substituted a placeholder string " <>
               "and carried on into the retry — that placeholder is the vacuous green; " <>
               "and without the leading bare `echo` the annotation is not registered."

      refute code =~ ~r/failed_tests="\(no test names harvested/,
             "the placeholder assignment `failed_tests=\"(no test names harvested...\"` " <>
               "is back. It makes $failed_tests non-empty on a crash, so the refusal " <>
               "check above it can never fire."
    end

    test "the refusal writes nothing to $GITHUB_OUTPUT", %{step: step} do
      code = code_only(step)
      refusal_at = offset_of(code, @refusal_error)
      retry_at = offset_of(code, @retry_command)
      between = binary_part(code, refusal_at, retry_at - refusal_at)

      refute between =~ ~r/GITHUB_OUTPUT|retry_fired/,
             "something between the refusal error and the retry command writes to " <>
               "$GITHUB_OUTPUT. On a crash the retry never ran, so `retry_fired=true` " <>
               "would be a false statement; `first-run-green`'s `*)` arm handles the " <>
               "missing output."

      # And no write precedes the refusal either (the `-z` block is the first
      # thing after the harvest).
      refute binary_part(code, 0, refusal_at) =~ ~r/>> "\$GITHUB_OUTPUT"/,
             "a $GITHUB_OUTPUT write now precedes the nameless-retry refusal."
    end

    test "first-run-green's catch-all arm still fails on a missing retry_fired output",
         %{source: source} do
      lines = String.split(source, "\n")

      start =
        Enum.find_index(lines, &(&1 == "  first-run-green:")) || flunk("no first-run-green job")

      rest = Enum.drop(lines, start + 1)
      len = Enum.find_index(rest, &Regex.match?(~r/^  (\S|#)/, &1)) || length(rest)
      job = rest |> Enum.take(len) |> Enum.join("\n") |> code_only()

      assert [_, arm] = Regex.run(~r/^\s*\*\)\n(.*?)^\s*;;/ms, job),
             "`first-run-green` has lost its `*)` catch-all arm — the arm that " <>
               "handles the refusal's deliberately-missing `retry_fired` output."

      assert arm =~ ~r/^\s*exit 1\s*$/m,
             "`first-run-green`'s `*)` arm no longer exits 1 on a missing output."
    end

    test "the refusal sits after the harvest and before the retry command", %{step: step} do
      code = code_only(step)

      harvest_at = offset_of(code, "failed_tests=$(")
      refusal_at = offset_of(code, @refusal_error)
      retry_at = offset_of(code, @retry_command)

      assert harvest_at < refusal_at,
             "the refusal error is emitted before `failed_tests=$(` is assigned, so " <>
               "it tests a variable that has not been harvested yet."

      assert refusal_at < retry_at,
             "the refusal error is emitted AFTER the retry command. A crash would " <>
               "run `mix test --failed` on an empty manifest first — which is the " <>
               "vacuous green this guard exists to refuse."
    end

    test "the retry command is unchanged and there is still exactly one of it",
         %{step: step} do
      code = code_only(step)

      assert length(String.split(code, @retry_command)) - 1 == 1,
             "the serial retry command `#{@retry_command}` no longer appears exactly " <>
               "once in the `Run tests` step. The refusal is a guard IN FRONT of the " <>
               "retry, not a change to it."

      # No test invocation was added alongside the guards: the first pass and
      # the retry are the only two `mix test` COMMANDS in the step's code. A
      # command starts a line (optionally under `if` / `if !`); the phrase
      # also appears inside the step's `echo` strings, which are not counted.
      invocations = Regex.scan(~r/^\s*(?:if\s+!?\s*)?mix test\b/m, code)

      assert length(invocations) == 2,
             "the `Run tests` step now has #{length(invocations)} `mix test` " <>
               "invocations, expected 2 (first pass + serial retry). The crash guards " <>
               "read the first pass's log; they must not run tests of their own."
    end
  end

  describe "test-count floor on the main pass" do
    test "MIN_TEST_COUNT is a workflow env value with an integer floor", %{source: source} do
      assert [_, value] = Regex.run(~r/^  MIN_TEST_COUNT: (\d+)\s*$/m, source),
             "`MIN_TEST_COUNT: <integer>` is gone from ci.yml's workflow `env:` block. " <>
               "The floor must be one visible, editable number, not a literal buried " <>
               "in the step."

      floor = String.to_integer(value)

      # Sanity band, not a coverage assertion: below 1000 the floor cannot
      # distinguish a crash from the isolated_beam partition's `3 tests`; above
      # 50_000 nothing passes and the floor is a lie.
      assert floor >= 1000 and floor <= 50_000,
             "MIN_TEST_COUNT=#{floor} is outside the 1000..50000 band. It is a " <>
               "crash detector: far below the ~16.8k suite, far above a partition."
    end

    test "the step parses the first pass's ExUnit summary and compares to the floor",
         %{step: step} do
      code = code_only(step)

      assert code =~
               ~r/grep -oE 'Result: \[0-9\]\+\(\/\[0-9\]\+\)\? \(passed\|tests\)' "\$first_pass_log"/,
             "the `Run tests` step no longer greps the ExUnit 1.20 `Result: N passed` " <>
               "summary out of $first_pass_log. Without that parse the floor has " <>
               "nothing to compare."

      assert code =~ ~r/::error::main mix test pass printed no ExUnit summary line/,
             "the `Run tests` step no longer fails with an ::error:: when the first " <>
               "pass printed no summary line. That is the exact signature of PR #997 " <>
               "attempt 1 (crash, zero summary lines)."

      assert code =~ ~r/\[ "\$count" -lt "\$MIN_TEST_COUNT" \]/,
             "the `Run tests` step no longer compares the parsed count to " <>
               "$MIN_TEST_COUNT. The env value would then be decoration."

      assert code =~ ~r/::error::main mix test pass ran \$count tests, below MIN_TEST_COUNT=/,
             "the below-floor ::error:: naming the count and the floor is gone."
    end

    test "the floor is checked on the green path before retry_fired=false, and in the retry branch before the retry",
         %{step: step} do
      code = code_only(step)

      calls =
        Regex.scan(~r/^\s*assert_test_count_floor\s*$/m, code, return: :index)
        |> Enum.map(fn [{at, _}] -> at end)

      assert length(calls) == 2,
             "`assert_test_count_floor` is called #{length(calls)} times in the " <>
               "`Run tests` step; expected 2 — once in the retry branch, once on the " <>
               "green-first-pass path."

      [in_retry_at, green_at] = calls
      refusal_at = offset_of(code, @refusal_error)
      retry_at = offset_of(code, @retry_command)
      false_at = offset_of(code, "retry_fired=false")

      assert refusal_at < in_retry_at and in_retry_at < retry_at,
             "in the retry branch the floor must be checked after the nameless " <>
               "refusal and before the retry command; the order in ci.yml has changed."

      assert retry_at < green_at and green_at < false_at,
             "on the green path the floor must be checked before `retry_fired=false` " <>
               "is written, so a vacuous green never records itself as clean."
    end
  end
end
