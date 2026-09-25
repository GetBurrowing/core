defmodule Platform.TestEnvPoolConfigTest do
  @moduledoc """
  Regression guard for the test-env sandbox pool sizing (task 01a0d265,
  stage 1 amendment; idea adopted from the displaced commit `bd2c0701`).

  On 2026-09-24 a seed-A `mix test` run on the moon rig produced 19 failures,
  of which 14 were setup `Sandbox.start_owner!/2` MatchErrors
  (`:queue_timeout`, "dropped from queue") and 5 were in-test linked-preload
  crashes on an owner's single connection. Root cause was arithmetic, not
  timing: the test repo's pool was smaller than ExUnit's concurrency.

  ExUnit's default `max_cases` is `System.schedulers_online() * 2`
  (elixir `lib/ex_unit/lib/ex_unit.ex:348` docs; `defp put_max_cases/1`
  fallback) and this repo does not override it (`test/test_helper.exs`), so
  the moon rig (16 schedulers) runs 32 tests in parallel while EVERY test
  holds one real pool connection for its whole lifetime
  (`Sandbox.start_owner!` in test/support/data_case.ex:42 and
  test/support/conn_case.ex:61). `config/test.exs` therefore sizes the pool
  to `max(System.schedulers_online() * 2 + 8, 24)`: `max_cases` coverage
  PLUS 8 spare connections that absorb the Class-3 leak-pinned connections
  (background tasks — Ecto parallel preloads, fire-and-forget lifecycle
  edges — still using a connection when their owner exits) during teardown.

  **This test FAILS if `pool_size` does not cover `max_cases + 8`** — e.g.
  if reverted to a fixed 10, or to bare `schedulers_online() * 2` (zero
  teardown headroom). It reads the LIVE runtime values (`Application.get_env`
  for the repo the tests actually use — this repo has no separate TestRepo —
  and `ExUnit.configuration()[:max_cases]`) rather than parsing the config
  file, so it survives formula drift. Do not "fix" a failure of this test by
  lowering the assertion — fix the pool sizing in `config/test.exs`.
  """

  use Platform.DataCase, async: true

  test "test-env sandbox pool covers ExUnit max_cases plus teardown headroom" do
    pool_size = Application.get_env(:platform, Platform.Repo)[:pool_size]
    max_cases = ExUnit.configuration()[:max_cases]

    assert is_integer(pool_size),
           "Platform.Repo test config has no integer :pool_size — the test-env " <>
             "sandbox pool sizing was removed or moved (task 01a0d265)"

    assert pool_size >= max_cases + 8,
           "pool_size (#{pool_size}) does not cover ExUnit max_cases (#{max_cases}) " <>
             "plus 8 headroom: every async test holds one sandbox connection for " <>
             "its whole lifetime (Sandbox.start_owner!), so the surplus owners queue " <>
             "on the pool and DBConnection drops their checkouts (:queue_timeout), " <>
             "while the +8 absorbs connections leak-pinned past teardown by " <>
             "background tasks. Fix the pool sizing in config/test.exs — do not " <>
             "lower this assertion (task 01a0d265, seed-A run of 2026-09-24)"
  end
end
