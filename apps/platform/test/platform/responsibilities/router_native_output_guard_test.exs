defmodule Platform.Responsibilities.RouterNativeOutputGuardTest do
  @moduledoc """
  STANDING GUARD (task `019fa61c` stage 4): `dispatch_native/5` must not
  grow a call to `invoke_handle_output/3`.

  ## Why this looks like the obvious fix and is not implementable

  The defect this task exists to close is that `architecture.audit_diff`
  left no durable artefact for a federated (native) assignee. The
  shortest-looking fix is "call `invoke_handle_output/3` from the native
  branch too". It cannot work, and the reason is mechanical rather than
  stylistic:

    * `invoke_handle_output(responsibility, parsed, meta)`
      (`router.ex:1272`) needs a `parsed` value, and
      `run_external_dispatch/5` (`router.ex:1092`) is the ONLY place one
      exists — it is the parsed HTTP response body from
      `ExternalDispatcher.dispatch/4`.
    * The native path has no return value to parse at all.
      `call_agent_responder/1` (`router.ex:1549`) answers
      `{:ok, :dispatched}`, which means HANDOFF ACCEPTED, not OUTPUT
      CAPTURED. The federated agent answers later, out of band, through
      the `stage_architecture_audit` MCP tool.
    * Passing `nil` or `%{}` through anyway would reach
      `ArchitectureAuditDiff.extract_annotation/1`, which returns `nil`
      for both, so `handle_output/3` falls to its unrecognised-payload
      arm and returns `:ok`. The result is a debug log line and NOTHING
      written — a fix that looks applied and changes nothing.

  So the native path's artefact comes from `open_from_fire/2` at
  stage-complete (stage 2) and its note from the MCP tool (stage 3). This
  file keeps the tempting non-fix from being reintroduced by someone
  reading the two branches side by side and noticing the asymmetry.

  ## What this file does NOT claim

  It is a source-shape probe, not a behavioural test. It cannot tell you
  the native path works; it tells you nobody re-added a call that would
  write nothing. The behavioural cover is
  `architecture_audit_diff_native_artefact_test.exs` (native artefact)
  and `plan_engine_architect_drift_hook_test.exs` (external note).
  """
  use ExUnit.Case, async: true

  @router_path Path.expand("../../../lib/platform/responsibilities/router.ex", __DIR__)

  @probe "invoke_handle_output"

  setup_all do
    source = File.read!(@router_path)
    %{lines: String.split(source, "\n")}
  end

  # Slice one `defp <name>(` … matching `  end` out of the file. Elixir
  # closes a top-level function body with `end` at two-space indent, so
  # the first such line after the head is the function's own terminator.
  defp function_body(lines, name) do
    start =
      Enum.find_index(lines, fn line ->
        String.starts_with?(String.trim_leading(line), "defp #{name}(") and
          String.starts_with?(line, "  defp ")
      end)

    refute is_nil(start), "could not find `defp #{name}(` in #{@router_path}"

    rest = Enum.drop(lines, start)
    len = Enum.find_index(rest, &(&1 == "  end"))

    refute is_nil(len), "could not find the closing `end` of `defp #{name}/n`"

    Enum.take(rest, len + 1)
  end

  defp calls_probe?(lines), do: Enum.any?(lines, &String.contains?(&1, @probe))

  describe "GUARD: the native branch does not invoke handle_output" do
    test "dispatch_native/5 carries no invoke_handle_output call", %{lines: lines} do
      body = function_body(lines, "dispatch_native")

      refute calls_probe?(body),
             "`dispatch_native/5` now calls #{@probe}. There is no `parsed` value on " <>
               "the native path (`call_agent_responder/1` answers `{:ok, :dispatched}`, " <>
               "a handoff receipt), so this call writes NOTHING and adds a debug line. " <>
               "The federated architect's note arrives later via the " <>
               "`stage_architecture_audit` MCP tool — see this file's moduledoc."
    end

    # CONTROL 1: the probe can fire. A `refute` against a string that
    # never appears anywhere passes for the wrong reason, which is the
    # `019fa469` lesson about assertions passing adjacent to their claim.
    # Same detector, same file, opposite answer.
    test "CONTROL: the same probe DOES fire on the external branch", %{lines: lines} do
      body = function_body(lines, "run_external_dispatch")

      assert calls_probe?(body),
             "`run_external_dispatch/5` no longer calls #{@probe} — either the external " <>
               "path stopped handling output (a real regression) or this probe's spelling " <>
               "drifted, in which case the guard above is measuring nothing."
    end

    # CONTROL 2: the slicer really isolates a function rather than
    # returning something empty or the whole file. Both failure modes
    # would make CONTROL 1 and the guard agree with each other for
    # reasons unrelated to what they claim.
    test "CONTROL: the slicer returns a real, bounded function body", %{lines: lines} do
      native = function_body(lines, "dispatch_native")
      external = function_body(lines, "run_external_dispatch")

      # Non-trivial, and the identifying call each body is known to make.
      assert length(native) > 5
      assert Enum.any?(native, &String.contains?(&1, "call_agent_responder(signal)"))

      assert length(external) > 5
      assert Enum.any?(external, &String.contains?(&1, "safe_dispatch(responsibility"))

      # Bounded: neither slice swallowed the other, which is what would
      # happen if the terminator search ran past the function's own `end`.
      refute Enum.any?(native, &String.contains?(&1, "safe_dispatch(responsibility"))
      refute Enum.any?(external, &String.contains?(&1, "call_agent_responder(signal)"))
    end

    # CONTROL 3: the detector reports a violation when one is present.
    # Controls 1 and 2 prove the slice is right; this proves the predicate
    # would say so. Without it, a `calls_probe?/1` that always answered
    # `false` would satisfy the guard and CONTROL 2 both.
    test "CONTROL: the detector flags an injected call", %{lines: lines} do
      violating = function_body(lines, "dispatch_native") ++ ["    #{@probe}(r, nil, meta)"]

      assert calls_probe?(violating)
    end
  end
end
