defmodule Platform.Tasks.Stacks.DepInference.Adapter do
  @moduledoc """
  Behaviour for the LLM adapter used by
  `Platform.Tasks.Stacks.DepInference`.

  Kept intentionally minimal — a single `chat/2` callback so the
  production implementation (`AnthropicAdapter`) and the test double
  (`StubAdapter`) can be swapped via
  `Application.get_env(:platform, :dep_inference_adapter, ...)`.

  Contract: given a fully-rendered prompt string, return the LLM's
  raw text response body or an error tuple. The DepInference module
  is responsible for parsing the response — the adapter is a pure
  transport surface.

  Introduced in task 019f487d stage 2 (ADR 0045).
  """

  @callback chat(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
