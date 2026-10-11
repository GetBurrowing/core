defmodule PlatformWeb.AgentAvatarController do
  @moduledoc """
  Serves the bytes behind `agents.avatar_storage_key` (task `01a00122`
  stage 1).

  A controller is not a style choice here. `PlatformWeb.static_paths/0` is a
  fixed list served out of `priv/static`, which is baked into the release,
  so there is no writable public static directory to drop avatar files into.

  ## Authorization: any authenticated session, and nothing narrower

  Neither existing byte-serving route fits, and reusing either would blank
  the avatar for legitimate viewers rather than fail loudly:

    * `ChatAttachmentController` (`/chat/attachments/:id`) gates on SPACE
      MEMBERSHIP. An agent's face appears in meetings, the control center
      and the activity feed, none of which are a chat space.
    * `FileBlobController` (`/files/blob/:id`) gates on PROJECT ORG
      MEMBERSHIP. Agents are not project-scoped.

  An avatar must render for anyone who can already see the agent, and the
  set of surfaces that show an agent is wider than either gate. The avatar
  also carries no information the viewer does not already have — they are
  looking at the agent's name and color on the same row — so the session
  check IS the authorization boundary, not a placeholder for a finer one.

  The native app reaches the same action at `GET /api/app/agents/:id/avatar`
  (task `01a12773` stage 1), behind `PlatformWeb.Plugs.AppBearerAuth`
  instead of the session check. A valid `app_sessions` bearer is the native
  equivalent of "any authenticated session": the push notification drawing
  the sender's picture runs in the FCM service or the iOS Notification
  Service Extension, which carry the bearer and no cookie. That route uses
  `app_show/2`, which shares the lookup, so the 404 for a non-UUID, missing
  or imageless agent is identical; it differs only in serving a thumbnail of
  a large original (see `app_show/2`).

  ## Host-agnostic mount, deliberately

  Mounted in a match-any-host scope alongside `/chat/attachments/:id`, NOT
  in the fenced default scope. The fenced scope carries
  `:require_app_surface`, and with `:host_surface_enforcement` on, a request
  arriving at the `chat.` or `meet.` host 404s there. Avatar URLs are minted
  RELATIVE and rendered inside pages served from all three hosts, so a
  fenced route would leave every avatar broken on chat and meetings while
  looking correct in the control center.

  ## Content type

  Recovered from the storage key's extension via
  `AvatarStorage.content_type_for_key/1`, which is allowlist-gated —
  no column records an avatar's content type. `x-content-type-options:
  nosniff` is set for the same reason `ChatAttachmentController` sets it:
  the stored type is authoritative, and without the header a browser can
  reinterpret the response as HTML from its bytes and walk straight around
  the allowlist.

  Bytes go out via `AttachmentStorage.path_for/1` + `send_download/3`,
  matching both existing byte-serving controllers. That path is
  local-disk-specific; when an S3/R2 adapter lands, all three switch to
  streaming together.
  """

  use PlatformWeb, :controller

  alias Platform.Agents.Agent
  alias Platform.Agents.AvatarStorage
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo

  def show(conn, %{"id" => id}) do
    case fetch_avatar_key(id) do
      nil -> send_resp(conn, :not_found, "Not found")
      storage_key -> send_avatar(conn, storage_key)
    end
  end

  @doc """
  The native app route, `GET /api/app/agents/:id/avatar`.

  Same lookup and the same 404s as `show/2`, but the bytes come from
  `AvatarStorage.app_variant/1`: a 192 px PNG thumbnail of any original over
  128 KB. Both Burrow apps drop an avatar body over 256 KB and draw the
  letter disc, while uploads allow 5 MB and are stored unresized, so serving
  the original here left every large avatar off the notification. The
  browser route keeps serving the original.
  """
  def app_show(conn, %{"id" => id}) do
    with storage_key when is_binary(storage_key) <- fetch_avatar_key(id),
         {:ok, path, content_type} <- AvatarStorage.app_variant(storage_key) do
      send_file_inline(conn, path, Path.basename(path), content_type)
    else
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end

  # `Platform.UUID.valid?/1`, and the nil guard, are both load-bearing: `id`
  # arrives straight off the URL, and an unguarded `Repo.get(Agent, id)`
  # RAISES on a non-UUID rather than returning nil — so `/agents/x/avatar`
  # would be a 500 instead of a 404. Same trap documented at
  # `meetings.ex:4800`.
  defp fetch_avatar_key(id) when is_binary(id) do
    if Platform.UUID.valid?(id) do
      case Repo.get(Agent, id) do
        %Agent{avatar_storage_key: key} when is_binary(key) and key != "" -> key
        _ -> nil
      end
    end
  end

  defp send_avatar(conn, storage_key) do
    path = AttachmentStorage.path_for(storage_key)

    if File.exists?(path) do
      send_file_inline(
        conn,
        path,
        Path.basename(storage_key),
        AvatarStorage.content_type_for_key(storage_key)
      )
    else
      send_resp(conn, :not_found, "Not found")
    end
  end

  defp send_file_inline(conn, path, filename, content_type) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    # `private`: this response is behind a session check, so a shared
    # proxy must never hold a copy to hand to the next viewer.
    |> put_resp_header("cache-control", "private, no-cache")
    |> send_download({:file, path},
      filename: filename,
      content_type: content_type,
      disposition: :inline
    )
  end
end
