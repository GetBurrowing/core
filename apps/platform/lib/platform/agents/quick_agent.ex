defmodule Platform.Agents.QuickAgent do
  @moduledoc """
  Minimal native chat agent entrypoint.

  Reads the configured workspace files to build a system prompt, then routes the
  request through the app's provider adapter using Codex OAuth credentials from
  the local `.codex/auth.json` state.
  """

  require Logger

  alias Platform.Agents.{CodexAuth, Providers.OpenAI, WorkspaceBootstrap}

  @workspace_files ~w(SOUL.md IDENTITY.md USER.md AGENTS.md)
  @default_model "gpt-5.4"

  @doc """
  Send a message to the agent and get a response.
  Reads workspace files from the configured path, builds context,
  and calls the configured chat provider.
  """
  def chat(user_message, opts \\ []) do
    workspace_path = workspace_path()
    system_prompt = build_system_prompt(workspace_path)
    messages = (opts[:history] || []) ++ [%{"role" => "user", "content" => user_message}]

    case call_provider(system_prompt, messages, opts) do
      {:ok, response} ->
        Logger.info("Agent response: model=#{response.model} tokens=#{inspect(response.usage)}")
        {:ok, response}

      {:error, reason} ->
        Logger.error("QuickAgent request failed: #{inspect(reason)}")
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

  defp call_provider(system_prompt, messages, opts) do
    with {:ok, credentials} <- credentials(opts) do
      provider_module().chat(credentials, messages, provider_opts(system_prompt, opts))
    end
  end

  defp credentials(opts) do
    auth_opts =
      case Keyword.get(opts, :codex_auth_path) do
        nil -> []
        path -> [path: path]
      end

    CodexAuth.credentials(auth_opts)
  end

  defp provider_opts(system_prompt, opts) do
    [
      system: system_prompt,
      model: model(opts),
      max_tokens: opts[:max_tokens] || 2048
    ]
  end

  defp model(opts) do
    Keyword.get(opts, :model) ||
      Application.get_env(:platform, :chat_agent_model) ||
      @default_model
  end

  defp provider_module do
    Application.get_env(:platform, :quick_agent_provider_module, OpenAI)
  end

  defp format_error({:codex_auth_missing, _path}), do: "Codex OAuth credentials not configured"
  defp format_error(:missing_access_token), do: "Codex OAuth credentials not configured"
  defp format_error({:auth_error, status, _body}), do: "API error: #{status}"
  defp format_error({:api_error, status, _body}), do: "API error: #{status}"
  defp format_error({:rate_limited, _retry_after, _body}), do: "API error: 429"
  defp format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  defp format_error(other), do: "Request failed: #{inspect(other)}"

  defp workspace_path do
    configured_path = Application.get_env(:platform, :agent_workspace_path, "/data/agents/zip")

    case WorkspaceBootstrap.resolve_layout(configured_path) do
      {:ok, layout} -> layout.workspace_path
      {:error, _reason} -> configured_path
    end
  end
end
