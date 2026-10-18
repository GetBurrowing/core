defmodule Platform.Vault.QueryLogTest do
  @moduledoc """
  Task 01a131c5 stage 2: Ecto's :debug query log renders CAST params, so an
  INSERT/UPDATE carrying the Cloak-typed `encrypted_data` field printed the
  plaintext secret into the server log. Measured on the dev-on-test-host rig: one
  `INSERT INTO "vault_credentials"` line held the e2e canary verbatim.

  Every write carrying `encrypted_data` now passes `log: false`. The positive
  control asserts the same capture DOES contain the access-log INSERT, so an
  empty capture (wrong level, no query logging at all) cannot pass this.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Vault

  @value "fake-query-log-PLAINTEXT-789"
  @rotated "fake-query-log-ROTATED-012"

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "put, put_inline and rotate never write the value to the query log" do
    slug = "query-log-#{System.unique_integer([:positive])}"
    inline = "query-log-inline-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        {:ok, _} = Vault.put(slug, "api_key", @value, scope: {:platform, nil})

        {:ok, _} =
          Vault.rotate(slug, @rotated, scope: {:platform, nil}, accessor: {:system, nil})

        {:ok, _} = Vault.put_inline(inline, @value)
        {:ok, _} = Vault.put_inline(inline, @rotated)
      end)

    # Positive control: query logging is live in this capture.
    assert log =~ ~s(INSERT INTO "vault_access_log")

    refute log =~ @value
    refute log =~ @rotated
  end
end
