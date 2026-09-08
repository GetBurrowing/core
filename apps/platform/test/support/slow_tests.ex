defmodule Platform.SlowTests do
  @moduledoc """
  Tests excluded from the default `mix test` because they spend real wall-clock
  time asleep, and the named thing that still runs them.

  ## Why this is a THIRD registry

  `Platform.TestQuarantine` records tests the suite cannot TRUST. `Platform.PendingFix`
  records tests that are RED on purpose. A `:slow` test is neither: it is
  trustworthy, deterministic, and green. Its only sin is duration. Filing it
  under either existing registry would be a lie about its cause — the exact
  confusion `TestQuarantine`'s moduledoc exists to end, and which
  `PendingFix`'s moduledoc restates. So it gets its own home.

  ## Why exclude at all, given task `01a0826f`

  This registry is created by the task that fixed a **production timeout bug**,
  and the 16-second reproduction of that bug is the first entry. Excluding a
  regression guard for the bug you just fixed is exactly the move that deserves
  suspicion, so state the reasoning plainly:

    * Before this registry, `@tag :slow` was **inert**. `test/test_helper.exs`
      derived its exclusions from the quarantine and pending-fix registries and
      neither mentions `:slow`, so all six tagged tests ran on every default
      run and `mix test --include slow` was a no-op. Five of the six were
      tagged by earlier work that plainly believed the tag did something. A tag
      that does not do what its name says is a standing misreading hazard; the
      two honest resolutions are to make it real or to delete it, and deleting
      it loses the ability to ever separate them.

    * Exclusion is **local-default only**. `.github/workflows/ci.yml` runs
      `mix test --include slow`, so every entry here runs on every CI run of
      every PR. Nothing in this registry loses coverage where coverage is
      enforced; the default run gets its ~32s of pure sleep back.

    * The 16s timeout reproductions are additionally **not the only guard on
      their claim**. `ollama_test.exs` case (a) asserts the default client
      carries a `:receive_timeout` of at least 300s and case (d) drives a
      200ms configured timeout through a real Finch socket; both are fast, both
      die to deleting `receive_timeout:` from the default client. The slow case
      (c) is the end-to-end demonstration on top of them, not the sole witness.

  ## Residual risk, named

  The guarantee is a CI flag, and a flag can be dropped. `Platform.SlowTestsTest`
  asserts `ci.yml` still carries `--include slow`. That is a text assertion —
  it proves the flag is spelled in the workflow, not that GitHub honoured it —
  so it is a drift alarm, not a proof of execution. The stronger check is that
  removing the flag makes a named test fail rather than silently shrinking the
  run.

  ## The contract

    * Every `@tag :slow` in the suite has an entry here naming the test and the
      sleep it is paying for.
    * `reason` says what the wall-clock time buys. "It is slow" is not a reason;
      the number and what it demonstrates is.
    * Deleting a `@tag :slow` deletes its entry in the same commit.
  """

  @tag :slow

  @entries [
    %{
      tag: @tag,
      test:
        "test/platform/agents/providers/ollama_test.exs: " <>
          "(c) a response that takes longer than Req's 15s default still succeeds",
      ticket: "01a0826f",
      seconds: 16,
      reason: """
      Sleeps 16s in a real Bandit endpoint to clear Req's 15_000ms
      `receive_timeout` default by a margin no rounding can explain away. The
      number IS the claim, so it cannot be shrunk. Cases (a) and (d) in the
      same file cover the same mutation in milliseconds.
      """,
      added_on: ~D[2026-09-08]
    },
    %{
      tag: @tag,
      test:
        "test/platform/meetings/summarizer_test.exs: " <>
          "a completion returned after 16s still lands the transcript complete with a summary",
      ticket: "01a0826f",
      seconds: 16,
      reason: """
      The same 16s clearance, one layer up: proves the summariser call path —
      not just the provider adapter — survives a provider slower than Req's
      default. Same reason the number is fixed.
      """,
      added_on: ~D[2026-09-08]
    },
    %{
      tag: @tag,
      test:
        "test/platform/execution/run_server_test.exs: " <>
          "marks run pending before ack SLA and stale after it is missed",
      ticket: "01a0826f",
      seconds: 1,
      reason: """
      Drives a real 50ms stale timer through `Process.sleep`, so the assertion
      is about elapsed time rather than a mocked clock. Sub-second, but timing
      dependent: it belongs with the other wall-clock tests so a loaded box
      cannot turn it into a mystery failure in the default run.
      """,
      added_on: ~D[2026-09-08]
    },
    %{
      tag: @tag,
      test:
        "test/platform/execution/run_server_test.exs: ack before timeout keeps context current",
      ticket: "01a0826f",
      seconds: 1,
      reason: "Real 200ms stale timer, acked before it fires. Wall-clock dependent as above.\n",
      added_on: ~D[2026-09-08]
    },
    %{
      tag: @tag,
      test:
        "test/platform/execution/run_server_test.exs: marks run dead after stale + dead timeout",
      ticket: "01a0826f",
      seconds: 1,
      reason: "Real 30ms stale + 60ms dead timers elapsing in sequence.\n",
      added_on: ~D[2026-09-08]
    },
    %{
      tag: @tag,
      test:
        "test/platform/execution/run_server_test.exs: " <>
          "broadcasts ctx status changes for pending, current, and stale",
      ticket: "01a0826f",
      seconds: 1,
      reason: "Waits on real timers to observe all three broadcast transitions in order.\n",
      added_on: ~D[2026-09-08]
    }
  ]

  @doc "Every wall-clock-bound entry."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc "Keys every entry must carry."
  @spec required_keys() :: [atom()]
  def required_keys, do: [:tag, :test, :ticket, :seconds, :reason, :added_on]

  @doc """
  The ExUnit tags `test/test_helper.exs` excludes for wall-clock cost.

  Derived, not literal — see the moduledoc.
  """
  @spec excluded_tags([map()]) :: [atom()]
  def excluded_tags(entries \\ @entries) do
    entries |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
