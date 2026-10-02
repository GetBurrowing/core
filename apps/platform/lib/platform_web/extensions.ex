defmodule PlatformWeb.Extensions do
  @moduledoc """
  The LiveView half of `Platform.Extensions` (ADR 0055, task 01a0ee08).

  `attach_live_hooks/1` is called from every LiveView that can render an
  extension's canvas node, in the mount pipeline, so a node's JS hook always
  has a LiveView that answers its events. It attaches whatever
  `Platform.Extensions.live_hooks/0` lists at call time; with no extension
  configured it returns the socket unchanged.
  """

  @doc "Runs every extension's `(socket) -> socket` live hook, in configuration order."
  @spec attach_live_hooks(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach_live_hooks(socket) do
    Enum.reduce(Platform.Extensions.live_hooks(), socket, fn {module, fun}, acc ->
      apply(module, fun, [acc])
    end)
  end
end
