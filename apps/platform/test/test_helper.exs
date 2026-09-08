# The exclusion list is DERIVED from `Platform.TestQuarantine`, never written
# here. That module records why each quarantined test is untrustworthy and
# refuses to hide anything whose cause is deterministic or unknown — see its
# moduledoc for the incident (task 019fa06a) that made the distinction load-bearing.
# The second list is `Platform.PendingFix` (task 01a006e7 stage 1): tests
# written RED on purpose, before the fix. Kept in its OWN registry rather than
# filed under a quarantine class, because a known-open-defect test is
# deterministic and trustworthy — the opposite of what the quarantine records —
# and mislabelling it `:intermittent` to borrow excludability is exactly the
# confusion `TestQuarantine`'s moduledoc exists to end. Both lists are DERIVED;
# neither may become a literal, which `Platform.TestQuarantineTest` asserts.
# The third list is `Platform.SlowTests` (task 01a0826f stage 5): green,
# trustworthy tests whose only cost is real wall-clock sleep. Its own registry
# for the same reason `PendingFix` has one — "slow" is not "untrustworthy" and
# not "known-red", and borrowing either label to gain excludability is the lie
# both moduledocs forbid. CI runs `mix test --include slow`, so excluding here
# shortens the LOCAL default only; nothing stops running where it is enforced.
ExUnit.start(
  exclude:
    Platform.TestQuarantine.excluded_tags() ++
      Platform.PendingFix.excluded_tags() ++ Platform.SlowTests.excluded_tags()
)

# ONE lifecycle step registry for the whole run, under the default name,
# seeded with the SHIPPED allowlist and nothing else (task 019fe1b7 stage 3).
#
# Not the boot singleton — every `:start_*` gate stays false, and this starts
# outside the supervision tree. It is needed because a shipped default step
# now sits on every terminal edge, so any case that moves a task to `done` or
# `cancelled` resolves a step name; with no registry alive that lookup is a
# `GenServer.call` to an unregistered name, which EXITS rather than raises and
# so is not caught by the fire point's `rescue`.
#
# Shared rather than per-case on purpose: seeded from `@built_in_steps` alone,
# every instance is identical, so there is nothing to isolate. Cases that
# register EXTRA steps still start their own and point
# `:lifecycle_step_registry` at it — that override is what isolation rests on,
# and it is untouched. This process holds no Repo connection, so it cannot
# recreate the DataCase ownership cascade the start-flag audit guards.
{:ok, _lifecycle_step_registry} = Platform.Lifecycle.StepRegistry.start_link()

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end
