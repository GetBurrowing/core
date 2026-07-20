# `:cascade_repro` tags the deterministic repro for the 2026-07-03
# DBConnection.OwnershipError cascade (task 019f3440).
#
# History worth knowing: the exclusion was added by stage 1 of PR #485 while
# the test was intentionally red, and the fix it guards landed in stage 2 of
# that SAME PR — but the exclusion was never lifted. The repro has therefore
# been dark ever since, which is how a regression of this fix would go
# unnoticed.
#
# It is STILL excluded, but for a different and narrower reason than before.
# Measured on `fix/test-suite-flakes` (2026-07-20):
#
#   * `mix test --only cascade_repro`  -> PASSES. The stage-2 fix is intact.
#   * inside the full parallel suite   -> FAILS intermittently, on assertion
#     (B) only ("transcript reaches a terminal state"). Assertion (A), the
#     actual leak guard (`exit_reason == :normal`), passes.
#
# Assertion (B) depends on `Summarizer.safe_fail_transcript/1`'s
# `try_borrow_sandbox/0` recovery — a TEST-ONLY hack that reaches for a
# DataCase-allowed singleton's sandbox connection so the terminal-status
# write can land from an unowned process. Under a full parallel run that
# singleton is frequently allowed to a DIFFERENT case's sandbox, the borrow
# returns `:no_sandbox`, and the transcript stays "processing". So (B) is
# asserting on scaffolding, not on production behaviour — in production
# `fail_transcript/1` simply succeeds and no borrow is involved.
#
# Un-excluding it as-is would trade a silent-regression risk for a ~50%
# flaky test in CI, which is a worse deal. The real fix is to drop or
# rewrite assertion (B) so the test depends only on (A) and (E), both of
# which are parallel-safe, and then delete this exclusion for good.
# Until then, run it explicitly: `mix test --only cascade_repro`.
ExUnit.start(exclude: [:files_service, :cascade_repro])

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end
