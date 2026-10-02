defmodule Platform.GameStream.RuntimeConfig do
  @moduledoc """
  Play's runtime settings, read from the OS environment at boot by
  `Platform.GameStream.Application.start/2` (ADR 0055, task 01a0ee08
  stage 3). Until stage 3 this was a block of core's `config/runtime.exs`;
  it moved with the module so core no longer reads any Play setting.

  ## `GAME_STREAM_ENABLED`

  A TRANSITIONAL gate, kept inside the module until every install is
  repointed to an image flavour
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 9. Install safety at merge`).
  `"true"` or `"1"` turns Play on; anything else, including unset, leaves it
  off. OFF BY DEFAULT IN EVERY ENVIRONMENT, dev included. Off keeps main's
  flag-off behaviour exactly: the `play` bundle stays known and grantable but
  lists no tools, a `play_session_*` call gets `game_stream_disabled`, the
  canvas kind is not registered and play frames are dropped.

  ## TURN (task 01a0db5f stage 5)

  Reuses hive's coturn (the meetings one); no second coturn.
  `GAME_STREAM_TURN_URLS` is a comma list (`turn:host:3479?transport=udp,...`),
  `GAME_STREAM_TURN_USERNAME` a static lt-cred-mech user, and the credential
  comes ONLY from the file named by `GAME_STREAM_TURN_CREDENTIAL_FILE`, read
  here at boot. Nothing here or in `Platform.GameStream.ice_servers/0` ever
  writes the credential to a log: a read failure reports the path and the
  POSIX reason, never the body. With any of the three missing,
  `ice_servers/0` is `[]` (host candidates, LAN).
  """

  @doc """
  The settings `env` (an OS-environment map, `System.get_env/0`'s shape)
  describes, as `[enabled: boolean, turn: keyword]`. Pure except for reading
  the credential file.
  """
  @spec read(%{optional(String.t()) => String.t()}) :: keyword()
  def read(env) when is_map(env) do
    [
      enabled: Map.get(env, "GAME_STREAM_ENABLED") in ["true", "1"],
      turn: [
        urls: turn_urls(env),
        username: turn_username(env),
        credential: turn_credential(env)
      ]
    ]
  end

  @doc "Reads `env` and puts the result in the `:game_stream` app env."
  @spec apply(%{optional(String.t()) => String.t()}) :: :ok
  def apply(env) do
    settings = read(env)
    Application.put_env(:game_stream, :enabled, Keyword.fetch!(settings, :enabled))
    Application.put_env(:game_stream, :turn, Keyword.fetch!(settings, :turn))
  end

  defp turn_urls(env) do
    env
    |> Map.get("GAME_STREAM_TURN_URLS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp turn_username(env) do
    case Map.get(env, "GAME_STREAM_TURN_USERNAME") do
      u when is_binary(u) and u != "" -> String.trim(u)
      _ -> nil
    end
  end

  defp turn_credential(env) do
    case Map.get(env, "GAME_STREAM_TURN_CREDENTIAL_FILE") do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, body} ->
            case String.trim(body) do
              "" -> nil
              credential -> credential
            end

          {:error, reason} ->
            IO.puts(
              :stderr,
              "[game_stream] GAME_STREAM_TURN_CREDENTIAL_FILE #{path} unreadable " <>
                "(#{:file.format_error(reason)}); game stream TURN is off"
            )

            nil
        end

      _ ->
        nil
    end
  end
end
