# The exclusion list is DERIVED from `Platform.TestQuarantine`, never written
# here. That module records why each quarantined test is untrustworthy and
# refuses to hide anything whose cause is deterministic or unknown — see its
# moduledoc for the incident (task 019fa06a) that made the distinction load-bearing.
ExUnit.start(exclude: Platform.TestQuarantine.excluded_tags())

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
