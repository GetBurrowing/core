defmodule PlatformWeb.UserAvatarController do
  @moduledoc """
  `GET /api/app/users/:id/avatar`: a member's avatar for the Burrow apps'
  push notifications, sized so the apps never drop it.

  The push used to carry `users.avatar_url` (an identity-provider url)
  verbatim, and both apps drop a body over 256 KB and draw the letter disc.
  This route serves `Platform.Accounts.UserAvatarCache.app_variant/1`
  instead: the picture unchanged when it is at most 128 KB, otherwise a PNG
  thumbnail of at most 192 px a side. See that module for the bounded,
  SSRF-guarded fetch and the cache.

  Authenticated exactly like `GET /api/app/agents/:id/avatar`
  (`PlatformWeb.Plugs.AppBearerAuth` in the `:app_avatar` pipeline): any
  valid `app_sessions` bearer, the native equivalent of the authenticated
  session that renders the same picture in the chat. The url fetched is
  ALWAYS the row's `avatar_url`; the request supplies only the user id, and
  any query string (the push's `?v=` cache token) is ignored.

  Every failure is a 404, never a 500: a non-UUID or unknown id, a user with
  no absolute https avatar, and any failed fetch. The app then draws the
  letter, exactly as before this route existed.
  """

  use PlatformWeb, :controller

  alias Platform.Accounts.User
  alias Platform.Accounts.UserAvatarCache
  alias Platform.Repo

  def app_show(conn, %{"id" => id}) do
    with true <- Platform.UUID.valid?(id),
         %User{} = user <- Repo.get(User, id),
         {:ok, path, content_type} <- UserAvatarCache.app_variant(user) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      # `private`: behind a bearer check, so no shared proxy may keep a copy.
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_download({:file, path},
        filename: Path.basename(path),
        content_type: content_type,
        disposition: :inline
      )
    else
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end
end
