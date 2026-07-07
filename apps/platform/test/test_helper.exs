# `:cascade_repro` is the deterministic-repro tag for the 2026-07-03
# DBConnection.OwnershipError cascade (task 019f3440). The test proves
# the leak by design — it is expected to FAIL on current main and PASS
# after the stage-2 fix. It stays out of the default run so CI doesn't
# treat the intentional-red as a real failure; invoke it explicitly via
# `mix test --only cascade_repro`.
ExUnit.start(exclude: [:files_service, :cascade_repro])

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end
