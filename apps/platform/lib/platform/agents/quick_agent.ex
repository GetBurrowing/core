defmodule Platform.Agents.QuickAgent do
  @moduledoc """
  Minimal agent proof-of-life. Reads .openclaw workspace files,
  builds a system prompt, and calls Anthropic.

  This remains the lightweight chat surface entrypoint, but now routes through
  the real Anthropic provider adapter so the Agent Runtime's provider logic is
  the single source of truth for request formatting and OAuth headers.
  """

  require Logger

  alias Platform.Agents.Providers.Anthropic

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md)

  @doc """
  Send a message to the agent and get a response.
  Reads workspace files from the configured path, builds context,
  and calls Anthropic.
  """
  def chat(user_message, opts \\ []) do
    workspace_path = workspace_path()
    system_prompt = build_system_prompt(workspace_path)
    messages = (opts[:history] || []) ++ [%{"role" => "user", "content" => user_message}]

    case call_anthropic(system_prompt, messages, opts) do
      {:ok, response} ->
        Logger.info("Agent response: model=#{response.model} tokens=#{inspect(response.usage)}")
        {:ok, response}

      {:error, reason} ->
        Logger.error("Anthropic request failed: #{inspect(reason)}")
        {:error, format_error(reason)}
    end
  end

  defp build_system_prompt(workspace_path) do
    files =
      @workspace_files
      |> Enum.map(fn file ->
        path = Path.join(workspace_path, file)

        case File.read(path) do
          {:ok, content} -> "## #{file}\n\n#{content}"
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n---\n\n")

    """
    You are an AI agent running on the Startup Suite platform.
    Your identity and instructions are defined by the following workspace files:

    #{files}

    You are chatting with a user in the platform's Chat surface.
    Be yourself — follow SOUL.md and IDENTITY.md for your personality and voice.
    Keep responses concise and helpful.
    """
  end

  defp call_anthropic(system_prompt, messages, opts) do
    provider_opts = [
      system: system_prompt,
      model: opts[:model],
      max_tokens: opts[:max_tokens] || 2048
    ]

    case Anthropic.chat(
           %{credential_slug: "anthropic-oauth", accessor: {:platform, nil}},
           messages,
           provider_opts
         ) do
      {:ok, response} ->
        {:ok, response}

      {:error, :not_found} ->
        fallback_to_api_key(messages, provider_opts)

      {:error, {:auth_error, _status, _body}} ->
        fallback_to_api_key(messages, provider_opts)

      {:error, _reason} = error ->
        case api_key() do
          nil -> error
          _ -> fallback_to_api_key(messages, provider_opts)
        end
    end
  end

  defp fallback_to_api_key(messages, provider_opts) do
    case api_key() do
      nil -> {:error, :anthropic_credentials_not_configured}
      key -> Anthropic.chat(key, messages, provider_opts)
    end
  end

  defp format_error(:anthropic_credentials_not_configured),
    do: "Anthropic credentials not configured"

  defp format_error({:auth_error, status, _body}), do: "API error: #{status}"
  defp format_error({:api_error, status, _body}), do: "API error: #{status}"
  defp format_error({:rate_limited, _retry_after, _body}), do: "API error: 429"
  defp format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error(other), do: "Request failed: #{inspect(other)}"

  defp workspace_path do
    Application.get_env(:platform, :agent_workspace_path, "/data/agents/zip/workspace")
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      Application.get_env(:platform, :anthropic_api_key)
  end
end
