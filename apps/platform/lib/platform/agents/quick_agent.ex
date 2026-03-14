defmodule Platform.Agents.QuickAgent do
  @moduledoc """
  Minimal agent proof-of-life. Reads .openclaw workspace files,
  builds a system prompt, and calls the Anthropic API.

  This is a temporary module — will be replaced by the full
  Agent Runtime (ADR 0007) and Provider (ADR 0006) architecture.
  """

  require Logger

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md)
  @default_model "claude-sonnet-4-6-20250514"
  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  # OAuth tokens (sk-ant-oat*) require specific beta headers.
  # Without these, Anthropic rejects the token.
  @oauth_beta_headers [
    "oauth-2025-04-20",
    "claude-code-20250219",
    "interleaved-thinking-2025-05-14"
  ]

  @doc """
  Send a message to the agent and get a response.
  Reads workspace files from the configured path, builds context,
  and calls Anthropic.
  """
  def chat(user_message, opts \\ []) do
    workspace_path = workspace_path()
    api_key = api_key()

    if is_nil(api_key) do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      system_prompt = build_system_prompt(workspace_path)
      messages = opts[:history] || []
      messages = messages ++ [%{"role" => "user", "content" => user_message}]

      call_anthropic(api_key, system_prompt, messages, opts)
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

  defp call_anthropic(api_key, system_prompt, messages, opts) do
    model = opts[:model] || @default_model
    max_tokens = opts[:max_tokens] || 2048

    body = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "system" => system_prompt,
      "messages" => messages
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    # OAuth tokens (sk-ant-oat*) require additional beta headers
    headers =
      if is_oauth_token?(api_key) do
        beta_value = Enum.join(@oauth_beta_headers, ",")
        headers ++ [{"anthropic-beta", beta_value}]
      else
        headers
      end

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        content =
          resp_body
          |> Map.get("content", [])
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

        usage = Map.get(resp_body, "usage", %{})
        Logger.info("Agent response: model=#{model} tokens=#{inspect(usage)}")

        {:ok,
         %{
           content: content,
           model: resp_body["model"],
           usage: usage,
           stop_reason: resp_body["stop_reason"]
         }}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("Anthropic API error: status=#{status} body=#{inspect(resp_body)}")
        {:error, "API error: #{status}"}

      {:error, reason} ->
        Logger.error("Anthropic request failed: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp is_oauth_token?(key) when is_binary(key), do: String.contains?(key, "sk-ant-oat")
  defp is_oauth_token?(_), do: false

  defp workspace_path do
    Application.get_env(:platform, :agent_workspace_path, "/data/agents/zip/workspace")
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      Application.get_env(:platform, :anthropic_api_key)
  end
end
