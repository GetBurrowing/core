defmodule Platform.CanvasPoolHelpers do
  @moduledoc """
  Waits on the canvas handler slot pool (`Platform.Canvas.ScriptEngine.Slots`).

  A run that ends by wall-clock timeout keeps its canvas-pool slot until its
  wasm Store is idle (js.ex `release_when_idle`), so a looping test can
  return while its slots are still draining. A test that starts against a
  non-empty node-wide pool is measuring the previous test (task 01a13aac
  stage 2). Shared by the script engine's adversarial and JS tests (task
  01a17b0b stage 3).
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Platform.CodeMode.Slots

  @pool Platform.Canvas.ScriptEngine.Slots

  @doc "Wait until the canvas pool holds no slot; flunk naming the holders after `timeout` ms."
  def await_canvas_pool_empty!(timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_canvas_pool_empty_until(deadline, timeout)
  end

  defp await_canvas_pool_empty_until(deadline, timeout) do
    held = Slots.held(@pool)

    cond do
      held.total == 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "the canvas pool still held #{held.total} slot(s) after #{timeout} ms: " <>
            inspect(held.by_runtime)
        )

      true ->
        Process.sleep(10)
        await_canvas_pool_empty_until(deadline, timeout)
    end
  end
end
