defmodule Platform.Games.Player do
  @moduledoc "Download-only Windows player grants. No chat, account or server credentials enter the game."
  alias Platform.Games
  @salt "game-player-download-v1"
  @ttl 604_800

  def token(game, user),
    do: Phoenix.Token.sign(PlatformWeb.Endpoint, @salt, {game["slug"], user.id})

  def authorize(game, token) when is_binary(token) do
    with {:ok, {slug, id}} <-
           Phoenix.Token.verify(PlatformWeb.Endpoint, @salt, token, max_age: @ttl),
         true <- slug == game["slug"],
         %{} = user <- Games.user(id) do
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_, _), do: {:error, :unauthorized}

  def bootstrap(game, user, origin) do
    config = Jason.encode!(%{base_url: origin, slug: game["slug"], token: token(game, user)})
    script = File.read!(Application.app_dir(:platform, "priv/game_player/BurrowPlayer.ps1"))

    files = [
      {~c"BurrowPlayer.ps1", script},
      {~c"player.json", config},
      {~c"Play.bat",
       "@echo off\r\ncd /d \"%~dp0\"\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%~dp0BurrowPlayer.ps1\"\r\n"},
      {~c"READ ME.txt",
       "Extract this folder and open Play.bat. Play checks for the latest release and launches it locally. Chat opens the game's Burrow community. Keep this personal launcher private: its download-only sign-in lasts seven days. When it expires, download a fresh player from the game page. Game saves and old versions are kept. Windows prototype.\r\n"}
    ]

    :zip.create(~c"BurrowPlayer.zip", files, [:memory])
  end
end
