defmodule Platform.Chat.CanvasSupervisor do
  @moduledoc """
  Dynamic supervisor for per-canvas `Platform.Chat.Canvas.Server` processes.

  Canvases are first-class space-scoped objects (ADR 0036). Each active canvas
  runs an isolated GenServer that serializes writes, applies rebase-or-reject
  concurrency, and broadcasts patches on the canvas PubSub topic. Servers are
  started on demand and registered by id in `Platform.Chat.Registry`.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
