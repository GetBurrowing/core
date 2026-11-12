defmodule PlatformWeb.GamePageController do
  use PlatformWeb, :controller

  alias Platform.Games
  alias Platform.Chat.AttachmentStorage

  plug(:put_layout, html: false)
  plug(:put_root_layout, html: false)

  def show(conn, %{"slug" => slug} = params) do
    with %{} = game <- Games.get(slug),
         %{} = release <- Games.current_release(game) do
      user = Games.user(get_session(conn, :current_user_id))

      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> render(:show,
        gaming?: Platform.Gaming.enabled?(),
        games:
          Platform.Games.list_published() |> Enum.sort_by(&{&1["slug"] != "voltron", &1["title"]}),
        creator?: not is_nil(user) and Platform.Access.authorize_install(user) == :ok,
        project: Platform.Gaming.projects(user, [game])[game["slug"]],
        game: game,
        signup?: not is_nil(Games.signup_url(game)),
        release: release,
        user: user,
        community: Games.community(game, user),
        unsupported?: unsupported_device?(conn),
        community?: params["tab"] == "community",
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
    else
      _ -> send_resp(conn, 404, "Game not found")
    end
  end

  def sign_in(conn, %{"slug" => slug}) do
    if game = Games.get(slug) do
      render(conn, :sign_in,
        game: game,
        signup?: not is_nil(Games.signup_url(game)),
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )
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
         {:ok, _space_id} <- Games.join_community(game, user) do
      conn
      |> delete_session(:external_admission)
      |> redirect(to: "/games/#{slug}?tab=community")
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

  def player(conn, %{"slug" => slug}) do
    with %{} = game <- Games.get(slug),
         %{} = user <- Games.user(get_session(conn, :current_user_id)),
         {:ok, _} <- Games.artifact(game, game["current_version"]),
         {:ok, {_, bytes}} <- Games.Player.bootstrap(game, user, PlatformWeb.Endpoint.url()) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> download_started_cookie()
      |> send_download({:binary, bytes},
        filename: "BurrowPlayer-#{slug}.zip",
        content_type: "application/zip"
      )
    else
      nil -> redirect(conn, to: "/games/#{slug}/sign-in")
      _ -> send_resp(conn, 503, "Player download is temporarily unavailable")
    end
  end

  def updates(conn, %{"slug" => slug}) do
    if game = Games.get(slug) do
      release = Games.current_release(game)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        version: release["version"],
        sha256: release["sha256"],
        byte_size: release["byte_size"],
        download_path: "/games/#{slug}/player/releases/#{release["version"]}",
        launch_path: "Play Voltron.bat"
      })
    else
      send_resp(conn, 404, "Game not found")
    end
  end

  def player_release(conn, %{"slug" => slug, "version" => version}) do
    with %{} = game <- Games.get(slug),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, _} <- Games.Player.authorize(game, token) do
      send_release(conn, game, version)
    else
      _ -> send_resp(conn, 401, "Download sign-in expired. Get a new player from the game page.")
    end
  end

  defp send_release(conn, game, version) do
    with {:ok, attachment} <- Games.artifact(game, version),
         path <- AttachmentStorage.path_for(attachment.storage_key),
         {:ok, %{size: size}} <- File.stat(path),
         true <- size == attachment.byte_size do
      conn
      |> download_started_cookie()
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

  defp unsupported_device?(conn) do
    ua = get_req_header(conn, "user-agent") |> Enum.join(" ")

    not String.contains?(ua, "Windows NT") and
      String.contains?(ua, ["iPhone", "iPad", "Android", "Macintosh", "Linux"])
  end

  defp download_started_cookie(conn) do
    # Non-secret UI acknowledgement only: this cookie grants no access.
    nonce = conn.params["download_request"]

    if is_binary(nonce) and Regex.match?(~r/^[a-f0-9]{32}$/, nonce) do
      put_resp_cookie(conn, "burrow_game_download", nonce,
        http_only: false,
        secure: conn.scheme == :https,
        same_site: "Lax",
        max_age: 60
      )
    else
      conn
    end
  end
end
