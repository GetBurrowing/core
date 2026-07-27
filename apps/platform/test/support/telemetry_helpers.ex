defmodule Platform.TelemetryHelpers do
  @moduledoc """
  Test helpers for the `:telemetry` handlers that `Platform.Application`
  attaches once at boot (`application.ex:12-27`).

  ## Why this module exists

  Those handlers are **VM-global**: `:telemetry` keys them by a fixed
  `@handler_id` in ETS, not per-process and not per-test. A test that
  detaches one and does not put it back leaves every later test in the
  same BEAM running with that bridge silently missing — and the symptom
  is not an error, it is an audit assertion that passes because nothing
  is listening. Task 019f9d80 traced exactly that: five test files
  detached a boot-attached handler and never restored it, which made
  `Platform.Accounts.ExternalAdmissionNotifierTest`'s durable-queue
  assertion fail 10/10 whenever `Platform.Audit.HistorianLatencyTest`
  was scheduled ahead of it, and that failure was written off as a flake
  across roughly eight briefs.

  ## Why calling `attach/0` is the whole restore

  Every boot-attached handler's `attach/0` is the single definition of
  its handler id, its event list, and its config. Restoring by calling
  that same function therefore cannot install the handler under a
  different configuration than boot installed — the "restored with drifted
  config" failure mode does not exist by construction. And since task
  019f9d80 stage 2 every `attach/0` is idempotent, so calling it when the
  handler is already attached is a no-op rather than an error.

  ## Why the `on_exit` is unconditional

  It runs whether or not the test detached anything, and whether or not
  the test passed. That is the point: it also covers a test that detaches
  **mid-body** to exercise the lifecycle (see
  `test/platform/meetings/telemetry_handler_test.exs`), where a failure
  between the detach and the manual re-attach would otherwise leak a
  detached global handler for the remainder of the run. The
  copy-pasted `on_exit(fn -> detach(); attach() end)` idiom this replaces
  does not cover that case, and having five independent copies of it with
  no enforcement is how the five offenders drifted off it in the first
  place.

      setup do
        Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)
        :ok
      end
  """

  @doc """
  Ensure `module` — a boot-attached telemetry handler — is attached for
  this test, and re-attach it unconditionally when the test exits.

  Raises if `module` does not export `attach/0`, which is the contract a
  boot-attached handler satisfies.
  """
  @spec ensure_boot_handler!(module()) :: :ok
  def ensure_boot_handler!(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :attach, 0) do
      raise ArgumentError,
            "#{inspect(module)} does not export attach/0 — " <>
              "ensure_boot_handler!/1 takes a boot-attached telemetry handler module"
    end

    :ok = module.attach()
    ExUnit.Callbacks.on_exit(fn -> :ok = module.attach() end)

    :ok
  end
end
