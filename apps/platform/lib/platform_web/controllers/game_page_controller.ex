defmodule PlatformWeb.GamePageController do
  use PlatformWeb, :controller

  alias Platform.Games
  alias Platform.Chat.AttachmentStorage

  plug(:put_layout, html: false)
  plug(:put_root_layout, html: false)

  def show(conn, %{"slug" => slug} = params) do
    with %{} = game <- Games.get(slug),
         %{} = release <- Games.current_release(game) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> render(:show,
        game: game,
        signup?: not is_nil(Games.signup_url(game)),
        release: release,
        user: Games.user(get_session(conn, :current_user_id)),
        community?: params["tab"] == "community",
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    else
      _ -> send_resp(conn, 404, "Game not found")
    end
  end

  def sign_in(conn, %{"slug" => slug}) do
    if Games.get(slug) do
      redirect(conn, to: "/auth/login?" <> URI.encode_query(%{game: slug}))
    else
      send_resp(conn, 404, "Game not found")
    end
  end

  def create_account(conn, %{"slug" => slug}) do
    with %{} = game <- Games.get(slug),
         url when is_binary(url) <- Games.signup_url(game) do
      redirect(conn, external: url)
    else
      _ ->
        conn
        |> put_status(503)
        |> text(
          "Account registration is not available yet. Return to the game page to sign in with an existing account."
        )
    end
  end

  def download(conn, %{"slug" => slug, "version" => version}) do
    with %{} = game <- Games.get(slug),
         %{} <- Games.release(game, version) do
      if Games.user(get_session(conn, :current_user_id)) do
        send_release(conn, game, version)
      else
        redirect(conn, to: "/games/#{slug}/sign-in")
      end
    else
      _ -> send_resp(conn, 404, "Release not found")
    end
  end

  def join_community(conn, %{"slug" => slug}) do
    with %{} = game <- Games.get(slug),
         %{} = user <- Games.user(get_session(conn, :current_user_id)),
         {:ok, space_id} <- Games.join_community(game, user) do
      conn
      |> delete_session(:external_admission)
      |> redirect(external: PlatformWeb.ExternalRedirect.chat_url("/chat/" <> space_id))
    else
      nil ->
        redirect(conn, to: "/games/#{slug}/sign-in")

      _ ->
        conn
        |> put_status(503)
        |> text(
          "The community is not available yet. Your game download is still available from its page."
        )
    end
  end

  defp send_release(conn, game, version) do
    with {:ok, attachment} <- Games.artifact(game, version),
         path <- AttachmentStorage.path_for(attachment.storage_key),
         {:ok, %{size: size}} <- File.stat(path),
         true <- size == attachment.byte_size do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> send_download({:file, path},
        filename: attachment.filename,
        content_type: attachment.content_type
      )
    else
      _ ->
        conn
        |> put_status(503)
        |> text(
          "This release is temporarily unavailable. Please return to the game page and try again."
        )
    end
  end
end
