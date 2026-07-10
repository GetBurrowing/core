defmodule Platform.Tasks.Stacks.DepInference.StubAdapter do
  @moduledoc """
  Test-only adapter for `Platform.Tasks.Stacks.DepInference`.

  Reads its canned response from the current process dictionary, so a
  test case controls what the LLM "returns" without a real HTTP round
  trip. Also increments a per-process call counter so idempotency
  tests can assert the adapter was NOT called (or was called exactly
  N times through a retry).

  ## Usage

      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"edges": []})})
      # ... exercise code that calls DepInference.infer_edges/2 ...
      assert Process.get({:dep_inference_stub, :calls}, 0) == 1

  Seed a list to have successive calls pop responses in order:

      Process.put({:dep_inference_stub, :response},
                  [{:ok, ~s({"edges": []})}, {:error, :timeout}])

  Introduced in task 019f487d stage 2 (ADR 0045).
  """

  @behaviour Platform.Tasks.Stacks.DepInference.Adapter

  @impl true
  def chat(_prompt, _opts) do
    increment_call_count()
    pop_response()
  end

  # Reset the recorded call count for the current process. Convenience
  # for stage 3's e2e / integration setups.
  @spec reset_calls() :: :ok
  def reset_calls do
    Process.put({:dep_inference_stub, :calls}, 0)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp increment_call_count do
    count = Process.get({:dep_inference_stub, :calls}, 0)
    Process.put({:dep_inference_stub, :calls}, count + 1)
    :ok
  end

  defp pop_response do
    case Process.get({:dep_inference_stub, :response}) do
      nil ->
        {:error, :no_stub_response_configured}

      [next | rest] ->
        Process.put({:dep_inference_stub, :response}, rest)
        next

      [] ->
        {:error, :no_stub_response_configured}

      response ->
        response
    end
  end
end
