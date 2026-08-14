defmodule PlatformWeb.ExternalRedirect do
  @moduledoc """
  Single source of truth for SIBLING-HOST redirect URLs — chat
  (task 019f9257) and meet (task 019ffec0).

  External users must be PINNED to the `chat.` sibling host: their admission
  landing, their grant-recovery navigation, and the internal-`/chat` fence all
  redirect to an ABSOLUTE `https://<CHAT_HOST>/chat` URL rather than a
  host-relative path (a host-relative redirect keeps them on the suite host,
  which is exactly the leak this task closes).

  `CHAT_HOST` and `MEET_HOST` are exposed to request-time code as `:chat_host`
  and `:meet_host` in `config/runtime.exs`. Where either is unset, every helper
  here degrades to host-relative behavior so local flows never crash and never
  build a malformed `https:///chat` or `https:///meetings`.

  ## One reader per config key, so the two delegations point OPPOSITE ways

  `:chat_host` is read HERE and nowhere else; `PlatformWeb.ExternalSurface`
  needs the "is it configured?" answer and delegates INTO this module for it.
  `:meet_host` is read THERE and nowhere else; this module needs it to build
  `meet_url/1` and calls `ExternalSurface.meet_host/0` OUT to get it, and
  delegates `meet_host_configured?/0` out too.

  So `chat_host_configured?/0` is defined here and delegated away, while
  `meet_host_configured?/0` is delegated here from there. THAT ASYMMETRY IS
  THE POINT and must not be tidied: making both delegate the same direction
  necessarily gives one of the two keys a second reader, and two readers of one
  host value are two fences that can drift apart.
  """

  alias PlatformWeb.ExternalSurface

  @chat_path "/chat"
  @meet_path "/meetings"

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

  @doc """
  Is a meet host configured?

  Delegated OUT to `PlatformWeb.ExternalSurface`, the single reader of
  `:meet_host` — the mirror image of `chat_host_configured?/0`, which is
  defined here and delegated the other way. See the moduledoc: the asymmetry
  keeps each key to one reader and is deliberate.
  """
  @spec meet_host_configured?() :: boolean()
  defdelegate meet_host_configured?(), to: ExternalSurface

  @doc """
  The meet-host URL for `path` (default `/meetings`).

  Clause for clause the same shape as `chat_url/1`: absolute
  `https://<meet_host><path>` when `:meet_host` is configured; otherwise the
  host-relative `path` unchanged, so dev/test never emit `https:///meetings`.
  A blank host takes the host-relative branch too — `nil` alone is not the
  whole unconfigured case.

  The host comes from `ExternalSurface.meet_host/0`, never a second
  `Application.get_env/2` here.
  """
  @spec meet_url(String.t()) :: String.t()
  def meet_url(path \\ @meet_path) when is_binary(path) do
    path = ensure_leading_slash(path)

    case ExternalSurface.meet_host() do
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
