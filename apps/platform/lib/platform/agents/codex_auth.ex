defmodule Platform.Agents.CodexAuth do
  @moduledoc """
  Resolves Codex OAuth credentials from the local `.codex/auth.json` file.

  This keeps the chat-agent path aligned with the same persisted Codex auth state
  used elsewhere, without hard-coding provider secrets into app config.
  """

  @default_auth_relative_path ".codex/auth.json"

  @spec credentials(keyword()) :: {:ok, map()} | {:error, term()}
  def credentials(opts \\ []) do
    path = auth_file_path(opts)

    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         {:ok, token} <- access_token(decoded) do
      {:ok,
       %{
         access_token: token,
         auth_mode: :oauth,
         source: path,
         provider: :codex
       }}
    else
      {:error, :enoent} -> {:error, {:codex_auth_missing, path}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_codex_auth_json, error.data}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec auth_file_path(keyword()) :: String.t()
  def auth_file_path(opts \\ []) do
    Keyword.get_lazy(opts, :path, fn ->
      Application.get_env(:platform, :codex_auth_file) ||
        System.get_env("CODEX_AUTH_FILE") ||
        Path.join(System.user_home!(), @default_auth_relative_path)
    end)
  end

  defp access_token(%{"tokens" => %{"access_token" => token}})
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp access_token(%{"access_token" => token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp access_token(_decoded), do: {:error, :missing_access_token}
end
