defmodule Platform.CiRetryVisibilityTest do
  @moduledoc """
  A drift alarm on the "Run tests" step in `.github/workflows/ci.yml`.

  Read what this is before trusting it. These tests read the workflow's TEXT.
  They detect the retry-visibility contract being edited away; they cannot
  prove GitHub executed any of it. Nothing in `apps/platform` runs `ci.yml`.
  It is a drift alarm, and is labelled as one rather than dressed up as proof
  of execution — the same framing as `Platform.SlowTestsTest`, for the same
  reason.

  The contract being pinned (task 01a08bfd): CI's `mix test` retry used to be
  anonymous. It re-ran the failed test alone, the test passed, the step went
  green, and the only trace was a fixed string that did not say WHICH test had
  failed. A flake that is always retried is a flake that never gets attention.
  Stage 2 made the retry name what it retried. This file is what stops a future
  editor quietly restoring the silent one-liner.

  Each assertion is scoped to the "Run tests" step body, sliced out of the
  workflow, so a matching string elsewhere in the file (or in a comment about
  this very contract) cannot satisfy it.
  """

  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  @ci_workflow Path.expand("../../../.github/workflows/ci.yml", @test_root)

  setup_all do
    {:ok, step: run_tests_step_body()}
  end

  # Slice the `- name: Run tests` step body out of the workflow: everything from
  # that line until the next sibling entry at the same indent (`- name:` or a
  # step-level comment). Scoping matters — an unscoped `source =~ ...` would be
  # satisfied by the prose in this moduledoc's counterpart comments in ci.yml.
  defp run_tests_step_body do
    lines = @ci_workflow |> File.read!() |> String.split("\n")

    start =
      Enum.find_index(lines, &(String.trim(&1) == "- name: Run tests")) ||
        flunk("no `- name: Run tests` step in #{@ci_workflow}")

    rest = Enum.drop(lines, start + 1)

    len =
      Enum.find_index(rest, fn line ->
        Regex.match?(~r/^      (- name:|#)/, line)
      end) || length(rest)

    rest |> Enum.take(len) |> Enum.join("\n")
  end

  # The `::warning::` annotation line only. Mutation 3 — restoring the old
  # fixed-string warning while leaving the harvest code above it in place —
  # is invisible to any check that greps the whole step, because
  # `failed_tests=` is still assigned. The annotation is the thing a human
  # reads, so the annotation is the thing asserted on.
  defp warning_line(step) do
    step
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "::warning::"))
    |> Enum.join("\n")
  end

  describe "the retry must name what it retried" do
    test "--include slow is on the first pass AND the retry", %{step: step} do
      assert step =~ ~r/mix test --include slow/,
             "the first `mix test` pass in ci.yml no longer passes --include slow, so " <>
               "every entry in Platform.SlowTests runs NOWHERE on the first pass."

      assert step =~ ~r/mix test --failed --max-cases 1 --include slow/,
             "the serial RETRY in ci.yml no longer passes --include slow. A `:slow` test " <>
               "that fails the first pass would then be silently skipped by the retry, the " <>
               "retry would go green because it ran nothing, and the build would report " <>
               "success for a test that never re-ran. Restore --include slow on the retry."
    end

    test "the retry branch writes a summary to $GITHUB_STEP_SUMMARY", %{step: step} do
      assert step =~ "GITHUB_STEP_SUMMARY",
             "the retry branch in ci.yml no longer writes to $GITHUB_STEP_SUMMARY. The " <>
               "retry-greened test names would then exist only as a transient annotation " <>
               "on the check run, with nothing on the job summary page — which is the " <>
               "surface a human actually opens. Restore the `Retry-greened tests` block."

      assert step =~ ~r/Retry-greened tests/,
             "the `Retry-greened tests` summary heading is gone from ci.yml. Without a " <>
               "titled block the summary is an unlabelled list nobody can act on."
    end

    test "the retry warning names the harvested tests, not just a fixed string", %{step: step} do
      warning = warning_line(step)

      refute warning == "",
             "ci.yml's retry branch emits no ::warning:: annotation at all. A retry that " <>
               "greens the build with no annotation is completely invisible."

      assert warning =~ ~r/\$(\{)?failed_tests/,
             "ci.yml's retry ::warning:: no longer interpolates $failed_tests — it is back " <>
               "to a fixed string that does not say WHICH test failed. That is exactly the " <>
               "anonymous retry task 01a08bfd existed to end: the flake still greens the " <>
               "build and nobody can tell which test it was. Restore the harvested names."

      assert step =~ ~r/failed_tests=\$\(/,
             "the failed-test harvest in ci.yml is gone, so $failed_tests in the warning " <>
               "would expand to nothing and the annotation would name no tests."
    end
  end
end
