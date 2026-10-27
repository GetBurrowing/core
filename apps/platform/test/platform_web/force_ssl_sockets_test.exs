defmodule PlatformWeb.ForceSslSocketsTest do
  @moduledoc """
  Prod's `force_ssl` must exclude every websocket path the endpoint mounts.

  The tunnel in front of core does not send `x-forwarded-proto` on a
  websocket upgrade, so Plug.SSL answers an unlisted socket with a 301 and the
  client reconnects forever. The remote terminal (`/terminal/ws`, task
  01a17b17) shipped that way on 2026-10-27: prod logged "Plug.SSL is
  redirecting GET /terminal/ws/websocket" once per retry.

  `force_ssl` is compile-time, so this reads `config/prod.exs` directly rather
  than the test env's endpoint config.
  """
  use ExUnit.Case, async: true

  @prod_config Path.expand("../../config/prod.exs", __DIR__)

  defp excluded_paths do
    @prod_config
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:platform)
    |> Keyword.fetch!(PlatformWeb.Endpoint)
    |> Keyword.fetch!(:force_ssl)
    |> Keyword.fetch!(:exclude)
    |> Keyword.fetch!(:paths)
  end

  defp websocket_paths do
    for {path, _module, opts} <- PlatformWeb.Endpoint.__sockets__(),
        Keyword.get(opts, :websocket, true) != false,
        not String.starts_with?(path, "/phoenix/live_reload"),
        do: path <> "/websocket"
  end

  test "the endpoint mounts at least the sockets this guard was written for" do
    paths = websocket_paths()

    for known <-
          ~w(/live/websocket /runtime/ws/websocket /terminal/ws/websocket /agent-host/websocket) do
      assert known in paths, "#{known} is no longer mounted; update this test"
    end
  end

  test "every websocket path is excluded from prod's force_ssl" do
    missing = websocket_paths() -- excluded_paths()

    assert missing == [],
           "add #{inspect(missing)} to force_ssl exclude paths in config/prod.exs"
  end
end
