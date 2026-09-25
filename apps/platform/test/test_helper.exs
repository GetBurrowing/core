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
# The fourth list is `Platform.IsolatedBeamTests` (task 01a08b49 stage 4): green,
# trustworthy, fast tests that MUTATE VM-GLOBAL STATE on purpose, so their
# correct behaviour corrupts a sibling module's reading of that same global.
# Its own registry for the same reason as the two below — "cannot share a BEAM"
# is not "untrustworthy", "known-red" or "slow", and borrowing any of those
# labels to gain excludability is the lie all three moduledocs forbid. ci.yml
# runs them in a SECOND `mix test --only isolated_beam` invocation, i.e. a
# separate OS process and therefore a separate BEAM, which is the property they
# need and which `--include` could never provide.
# The third list is `Platform.SlowTests` (task 01a0826f stage 5): green,
# trustworthy tests whose only cost is real wall-clock sleep. Its own registry
# for the same reason `PendingFix` has one — "slow" is not "untrustworthy" and
# not "known-red", and borrowing either label to gain excludability is the lie
# both moduledocs forbid. CI runs `mix test --include slow`, so excluding here
# shortens the LOCAL default only; nothing stops running where it is enforced.
ExUnit.start(
  exclude:
    Platform.TestQuarantine.excluded_tags() ++
      Platform.PendingFix.excluded_tags() ++
      Platform.SlowTests.excluded_tags() ++ Platform.IsolatedBeamTests.excluded_tags()
)

# `Platform.LivekitStubPlug` (see its moduledoc for the incident). Meeting
# tests that deliberately poke `url: "wss://livekit.test"` into `:platform,
# :livekit` app env must resolve that URL against a plug, not the network —
# a real DNS lookup per call was ~300 `:nxdomain` round-trips per full run,
# and the concurrent IO starves sibling LiveView child mounts past Phoenix's
# 5 s `child_mount` deadline. Set here rather than in `config/test.exs`
# because the client is a runtime `Req` struct and the plug module lives
# in `test/support`. Tests that script their own responses still override
# `:livekit_req_client` with a `Req.Test` plug — those overrides win over
# this default exactly as they did before.
#
# TWO guards make the default unracy. (1) An :persistent_term mirror that
# `Meetings.livekit_req_client/0` falls back to when the Application env key
# is briefly ABSENT — async tests' `on_exit` hooks delete the key globally,
# and while it is gone any concurrent CreateRoom from another module would
# otherwise fall back to a bare `Req.new()` and hit the real network
# (the residual ~230 :nxdomain events the first sweep run still showed).
# (2) A `:persistent_term` "no-stub ceiling": while the mirror is armed the
# fallback stays armed; the only writers that remove it are the few tests
# whose OWN stubs must run, which re-arm it on exit via the same helper.
# Application-env deletion therefore degrades to "still stubbed", never to
# "live network".
:persistent_term.put(
  {:platform, :livekit_req_client_fallback},
  Req.new(plug: {Platform.LivekitStubPlug, []}, retry: false)
)

Application.put_env(
  :platform,
  :livekit_req_client,
  Req.new(plug: {Platform.LivekitStubPlug, []}, retry: false)
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

# Pre-establish the sandbox pool's connections BEFORE ExUnit's startup
# burst (task 01a0d265 stage 4). Every async test's `start_owner!` routes
# through the pool's single `DBConnection.Ownership.Manager`, and an owner
# checkout that must first OPEN a Postgres connection costs a full
# handshake; 32 concurrent setups at suite start therefore serialize ~32
# handshakes behind one manager, and a checkout issued inside that burst
# can wait past a caller's fixed `GenServer.call` window — measured as
# `{:timeout, GenServer.call(…, {:enqueue, …}, 5000)}` in
# `Platform.Meetings.IntentQueue.MirrorFatalityTest` (seed 77, 2026-09-24
# 17:57Z run: the failing instance was the FIRST test to report, the
# stalled queue never answered and never crashed, and sibling instances
# of the same test raised the expected `MirrorError` seconds later once
# the burst had drained). Opening every pooled connection HERE — while
# ownership is still in its default :auto mode and before the mode-set
# below — turns those serialized handshakes into fast checkouts of
# already-established connections. Capacity moved in time, not patience
# widened: no deadline, queue_target, test body or assertion is touched.
if Process.whereis(Platform.Repo) do
  pool_size = Platform.Repo.config()[:pool_size] || 10

  1..pool_size
  |> Task.async_stream(
    fn _ -> Platform.Repo.query!("SELECT 1") end,
    max_concurrency: pool_size,
    timeout: 15_000,
    on_timeout: :kill_task
  )
  |> Enum.each(fn
    {:ok, _} -> :ok
    {:exit, reason} -> raise "sandbox pool prewarm failed: #{inspect(reason)}"
  end)
end

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end

# Preload every module of this app BEFORE ExUnit starts (task 01a0d265,
# stage 4, final round). The code server is ONE global serialization point:
# under ExUnit's 32-way startup burst, a first-touch `:code.ensure_loaded/1`
# queues behind every other first-touch, and the stalls are measured —
# seed 70007 (2026-09-24 17:23Z sweep) parked FOUR tests past their 60s
# ExUnit timeout with stacks sitting in `:code_server.call/1 ←
# :code.ensure_loaded/1`, and the same stall explains
# `MirrorFatalityTest`'s `{:timeout, GenServer.call(…, {:enqueue, …},
# 5000)}`: the queue server's first Repo call blocks on a lazily-loaded
# module, the test's call window expires, `on_exit` stops the queue
# mid-stall, and the log shows the stalled queue's meeting id EXACTLY ONCE
# (never answered, never crashed) while sibling instances of the same test
# — once the burst had drained — raised the expected `MirrorError` in
# milliseconds. Loading up front makes every later first-touch a no-op.
#
# Scope: this app's own modules only — the `Elixir.Platform.` prefix (which
# covers the `PlatformWeb.*` surface too, since it nests under the app) —
# NOT the deps: their modules are already loaded transitively by
# application startup or load on the same single server anyway, and
# loading thousands of dep beams here would be seconds of pure cost for
# no measured stall.
#
# Cost check: the preload is timed and printed; a meaningful regression
# against the ~13.5-minute full-run wall time is a finding to report, not
# silently accept. No side effects: loading an Elixir module runs no
# module body — compile-time effects already happened at compile — and
# `ensure_loaded/1` on an already-loaded module is a cheap no-op, which is
# exactly the property the burst needs.
preload_started_at = System.monotonic_time(:millisecond)

:code.all_available()
|> Enum.map(fn {modname, _path, _loaded} -> List.to_atom(modname) end)
|> Enum.filter(fn mod ->
  name = Atom.to_string(mod)

  String.starts_with?(name, "Elixir.Platform.") or
    String.starts_with?(name, "Elixir.PlatformWeb.")
end)
|> Task.async_stream(
  fn mod ->
    case :code.ensure_loaded(mod) do
      {:module, _} -> :ok
      {:error, reason} -> {:error, mod, reason}
    end
  end,
  max_concurrency: System.schedulers_online(),
  timeout: 60_000,
  on_timeout: :kill_task
)
|> Enum.each(fn
  {:ok, :ok} ->
    :ok

  {:ok, {:error, mod, reason}} ->
    raise "platform module preload failed for #{inspect(mod)}: #{inspect(reason)}"

  {:exit, reason} ->
    raise "platform module preload task failed: #{inspect(reason)}"
end)

IO.puts(
  "[test_helper] platform module preload done: " <>
    "#{:code.all_loaded() |> length()} modules loaded in " <>
    "#{System.monotonic_time(:millisecond) - preload_started_at}ms"
)
