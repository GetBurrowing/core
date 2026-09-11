defmodule Platform.IsolatedBeamTests do
  @moduledoc """
  Tests excluded from the default `mix test` because they cannot share a BEAM
  with the rest of the suite, and the named thing that still runs them.

  ## Why this is a FOURTH registry

  `Platform.TestQuarantine` records tests the suite cannot TRUST.
  `Platform.PendingFix` records tests that are RED on purpose.
  `Platform.SlowTests` records tests whose only cost is wall-clock time. An
  `:isolated_beam` test is none of those: it is trustworthy, deterministic,
  green, and fast. Its problem is that it MUTATES VM-GLOBAL STATE on purpose, so
  its correct behaviour corrupts a sibling's reading of that same global state.
  Filing it under any of the three would be a lie about its cause — the
  confusion `TestQuarantine`'s moduledoc exists to end. So it gets its own home,
  for the reason `SlowTests` got one.

  ## What "cannot share a BEAM" means here, concretely

  The entry below detaches `"platform-audit-telemetry"` deliberately, and
  `:telemetry`'s handler registry is VM-wide. Its orphans also exit
  ASYNCHRONOUSLY — `Ecto.Adapters.SQL.Sandbox.stop_owner/1` returns before the
  `{:shutdown, %DBConnection.ConnectionError{}}` exits propagate — so the detach
  can land after its own teardown, inside a sibling module's
  `:telemetry.list_handlers/1` window. Measured: CI run 34529749646 failed
  `QUEUED-DRAINED` on its first statement, `assert handler_attached?()`, with the
  guardian logging its repair one line later.

  ## Why exclusion is safe here, stated rather than assumed

    * Exclusion is DEFAULT-RUN only. `.github/workflows/ci.yml` carries a second
      `mix test --only isolated_beam` invocation, so every entry runs on every CI
      run of every PR — in its own OS process, which is the separate BEAM that is
      the entire point. `Platform.IsolatedBeamTestsTest` asserts that invocation
      is still spelled in the workflow.
    * The separation is not a scheduling preference that `async: false` could
      also buy. It cannot: `PlatformWeb.ConnCase` derives shared sandbox mode and
      the `drain_or_warn/1` teardown branch from `async:`, and `drain_or_warn/1`
      ignores `@tag sandbox_drain_timeout:`. Flipping the entry to `async: false`
      was measured on 2026-09-10 and turned its `{:exit, _}` into a rescued
      `{:raise, DBConnection.ConnectionError, _}`, i.e. it stopped detaching and
      stopped reproducing the defect while still looking like a passing test.
      Only a BEAM boundary works.

  ## Residual risk, named

  The guarantee is a CI invocation, and an invocation can be deleted.
  `Platform.IsolatedBeamTestsTest` asserts `ci.yml` still carries
  `--only isolated_beam`. That is a TEXT assertion — it proves the invocation is
  spelled in the workflow, not that GitHub ran it. It is a drift alarm, not proof
  of execution. The stronger property is that `mix test --only <tag>` FAILS when
  the tag matches nothing, so a vanished `@moduletag` breaks that step loudly
  instead of silently shrinking the run to zero.

  ## The contract

    * Every `@moduletag :isolated_beam` in the suite has an entry here naming the
      module and the global state it mutates.
    * `reason` says WHICH global the test mutates and whose reading it corrupts.
      "It is flaky in parallel" is not a reason.
    * Deleting an `@moduletag :isolated_beam` deletes its entry in the same commit.
  """

  @tag :isolated_beam

  @entries [
    %{
      tag: @tag,
      test:
        "test/platform_web/conn_case_supervised_orphan_beyond_drain_test.exs: " <>
          "PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainTest and " <>
          "PlatformWeb.ConnCaseSupervisedOrphanBeyondDrainObservationTest",
      ticket: "01a08b49",
      global: ":telemetry handler registry (`:telemetry.list_handlers/1`)",
      reason: """
      QUEUED-BEYOND-DRAIN detaches "platform-audit-telemetry" on purpose — that
      detach IS the defect it characterises, and it is the only test anywhere
      that demonstrates `Platform.Telemetry.HandlerGuardian` repairing a real
      VM-wide detach. The detach is VM-global and its orphans exit
      asynchronously after teardown, so it corrupts any sibling module that
      reads `list_handlers` as a per-case control. Its siblings in
      `conn_case_supervised_orphan_test.exs` do exactly that, as their positive
      control 1. Deleting this entry to get a green default run would leave the
      guardian with no test that it works.
      """,
      added_on: ~D[2026-09-10]
    }
  ]

  @doc "Every module that needs its own BEAM."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc "Keys every entry must carry."
  @spec required_keys() :: [atom()]
  def required_keys, do: [:tag, :test, :ticket, :global, :reason, :added_on]

  @doc """
  The ExUnit tags `test/test_helper.exs` excludes for BEAM-isolation cost.

  Derived, not literal — see the moduledoc, and `Platform.TestQuarantineTest`,
  which asserts `test_helper.exs` holds no literal exclusion list.
  """
  @spec excluded_tags([map()]) :: [atom()]
  def excluded_tags(entries \\ @entries) do
    entries |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end
end
