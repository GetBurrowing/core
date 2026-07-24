defmodule PlatformWeb.ExternalRedirect do
  @moduledoc """
  Single source of truth for chat-host redirect URLs (task 019f9257).

  External users must be PINNED to the `chat.` sibling host: their admission
  landing, their grant-recovery navigation, and the internal-`/chat` fence all
  redirect to an ABSOLUTE `https://<CHAT_HOST>/chat` URL rather than a
  host-relative path (a host-relative redirect keeps them on the suite host,
  which is exactly the leak this task closes).

  `CHAT_HOST` is exposed to request-time code as `:chat_host` in
  `config/runtime.exs` (prod only). Dev / test / CI leave it unset — every
  helper here degrades to host-relative behavior so local flows never crash and
  never build a malformed `https:///chat`.
  """

  @chat_path "/chat"

  @doc """
  Is a chat host configured? Only prod sets `CHAT_HOST`; dev/test/CI leave it
  unset, in which case callers keep today's host-relative behavior.
  """
  @spec chat_host_configured?() :: boolean()
  def chat_host_configured? do
    case chat_host() do
      host when is_binary(host) -> String.trim(host) != ""
      _ -> false
    end
  end

  @doc """
  The chat-host URL for `path` (default `/chat`).

  Absolute `https://<chat_host><path>` when `:chat_host` is configured;
  otherwise the host-relative `path` unchanged — so `redirect(external:
  chat_url(...))` degrades to a same-host redirect in dev/test and never emits
  `https:///chat`.
  """
  @spec chat_url(String.t()) :: String.t()
  def chat_url(path \\ @chat_path) when is_binary(path) do
    path = ensure_leading_slash(path)

    case chat_host() do
      host when is_binary(host) ->
        case String.trim(host) do
          "" -> path
          trimmed -> "https://" <> trimmed <> path
        end

      _ ->
        path
    end
  end

  defp chat_host, do: Application.get_env(:platform, :chat_host)

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
