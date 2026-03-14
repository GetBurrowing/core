defmodule Platform.Agents.QuickAgent do
  @moduledoc """
  Minimal agent proof-of-life. Reads .openclaw workspace files,
  builds a system prompt, and calls the Anthropic API.

  This is a temporary module — will be replaced by the full
  Agent Runtime (ADR 0007) and Provider (ADR 0006) architecture.
  """

  require Logger

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md)
  # OAuth tokens use short model IDs (no date suffix).
  # API key tokens use versioned model IDs.
  @oauth_model "claude-sonnet-4-6"
  @api_key_model "claude-sonnet-4-5-20250929"
  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  # Exact OAuth header set from @mariozechner/pi-ai anthropic.js (OpenClaw's upstream)
  # authToken (Bearer) + these headers is how OpenClaw authenticates OAuth tokens.
  @oauth_beta "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"
  @oauth_user_agent "claude-cli/2.1.62"

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
    is_oauth = is_oauth_token?(api_key)
    model = opts[:model] || if(is_oauth, do: @oauth_model, else: @api_key_model)
    max_tokens = opts[:max_tokens] || 2048

    body = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "system" => system_prompt,
      "messages" => messages
    }

    # Build headers exactly as OpenClaw's pi-ai anthropic.js does
    headers =
      if is_oauth do
        [
          {"Authorization", "Bearer #{api_key}"},
          {"anthropic-version", @api_version},
          {"anthropic-beta", @oauth_beta},
          {"user-agent", @oauth_user_agent},
          {"x-app", "cli"},
          {"anthropic-dangerous-direct-browser-access", "true"},
          {"content-type", "application/json"}
        ]
      else
        [
          {"x-api-key", api_key},
          {"anthropic-version", @api_version},
          {"anthropic-beta", "fine-grained-tool-streaming-2025-05-14"},
          {"content-type", "application/json"}
        ]
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
