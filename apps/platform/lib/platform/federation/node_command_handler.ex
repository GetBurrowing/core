defmodule Platform.Federation.NodeCommandHandler do
  @moduledoc """
  Routes OpenClaw node.invoke.request commands to Suite subsystems.

  **Canvas commands are deprecated** per ADR 0036. `canvas.present`,
  `canvas.navigate`, `canvas.hide`, `canvas.a2ui_push`, `canvas.a2ui_reset`
  and their aliases are removed. Agents should use the canonical
  `canvas.create` / `canvas.patch` / `canvas.describe` tools (Phase 4 of the
  canvas refactor) instead.

  Non-canvas stubs (`canvas.eval`, `canvas.snapshot`) are retained as they
  are unrelated round-trip commands scoped for Phase 3.
  """

  require Logger

  # ── Deprecated canvas commands ───────────────────────────────────────

  def handle("canvas.present", _params, _ctx), do: deprecated("canvas.present")
  def handle("canvas.navigate", _params, _ctx), do: deprecated("canvas.navigate")
  def handle("canvas.hide", _params, _ctx), do: deprecated("canvas.hide")
  def handle("canvas.a2ui_push", _params, _ctx), do: deprecated("canvas.a2ui_push")
  def handle("canvas.a2ui_reset", _params, _ctx), do: deprecated("canvas.a2ui_reset")
  def handle("canvas.a2ui.pushJSONL", _params, _ctx), do: deprecated("canvas.a2ui.pushJSONL")
  def handle("canvas.a2ui.reset", _params, _ctx), do: deprecated("canvas.a2ui.reset")

  # ── Reserved round-trip stubs ────────────────────────────────────────

  def handle("canvas.eval", _params, _ctx) do
    {:ok, %{result: nil, note: "canvas.eval requires client-side implementation"}}
  end

  def handle("canvas.snapshot", _params, _ctx) do
    {:ok, %{snapshot: nil, note: "canvas.snapshot requires client-side implementation"}}
  end

  # ── Unknown ──────────────────────────────────────────────────────────

  def handle(command, _params, _ctx) do
    Logger.warning("[NodeCommandHandler] unknown command: #{command}")
    {:error, "UNKNOWN_COMMAND", "Unknown command: #{command}"}
  end

  defp deprecated(name) do
    {:error, "COMMAND_DEPRECATED",
     "#{name} has been removed. Use the canvas.create / canvas.patch / canvas.describe agent tools (ADR 0036)."}
  end
end
