defmodule Platform.Tasks.Stacks.DepInference.AnthropicAdapter do
  @moduledoc """
  Production LLM adapter for `Platform.Tasks.Stacks.DepInference`.

  Routes the rendered `stacks.dep_inference.v1` prompt through
  `Platform.Agents.Providers.Anthropic.chat/3` with strict-JSON
  system prompt, `temperature: 0.0`, and `max_tokens: 2048`. Mirrors
  the shape of `Platform.Meetings.Summarizer.call_llm/3` so credential
  resolution and response-extraction stay consistent with the other
  legacy-legacy LLM call site.

  Introduced in task 019f487d stage 2 (ADR 0045).
  """

  @behaviour Platform.Tasks.Stacks.DepInference.Adapter

  alias Platform.Agents.Providers.Anthropic

  @system_prompt "You output strict JSON only."
  @default_max_tokens 2048
  @default_api_key_env "ANTHROPIC_API_KEY"

  @impl true
  def chat(prompt, opts \\ []) when is_binary(prompt) do
    credentials = credentials(opts)

    messages = [%{role: "user", content: prompt}]

    call_opts =
      [
        system: @system_prompt,
        temperature: 0.0,
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
      ]
      |> maybe_put(:model, Keyword.get(opts, :model))

    case Anthropic.chat(credentials, messages, call_opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %{content: [%{"text" => text} | _]}} when is_binary(text) ->
        {:ok, text}

      {:ok, other} ->
        {:error, {:unrecognized_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credentials(opts) do
    env = Keyword.get(opts, :api_key_env, @default_api_key_env)

    case System.get_env(env) do
      nil -> %{credential_slug: "anthropic"}
      "" -> %{credential_slug: "anthropic"}
      key -> %{api_key: key}
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
