defmodule Platform.Federation.NodeCommandHandler do
  @moduledoc """
  Routes OpenClaw node.invoke.request commands to Suite subsystems.
  Phase 1: all canvas commands are stubs that log and return success.
  """

  require Logger

  @canvas_commands ~w(canvas.present canvas.navigate canvas.eval canvas.snapshot canvas.a2ui_push canvas.a2ui_reset canvas.hide)

  def handle(command, params) when command in @canvas_commands do
    Logger.info("[NodeCommandHandler] #{command} params=#{inspect(params)}")
    {:ok, %{status: "received", command: command}}
  end

  def handle(command, _params) do
    Logger.warning("[NodeCommandHandler] unknown command: #{command}")
    {:error, "UNKNOWN_COMMAND", "Unknown command: #{command}"}
  end
end
