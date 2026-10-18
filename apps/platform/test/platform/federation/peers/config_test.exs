defmodule Platform.Federation.Peers.ConfigTest do
  @moduledoc "Task 01a0d90f stage 2: the federation switches fail closed."

  # async: false — flips global app env (:env, :peer_federation_allow_http).
  use ExUnit.Case, async: false

  alias Platform.Federation.Peers.Config

  setup do
    saved =
      for key <- [
            :env,
            :peer_federation_allow_http,
            :peer_federation_enabled,
            :peer_federation_signing_protocol
          ],
          into: %{},
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    :ok
  end

  test "config/test.exs pins federation off" do
    assert Application.fetch_env!(:platform, :peer_federation_enabled) == false
    refute Config.enabled?()
  end

  test "allow_http? is honoured outside prod" do
    Application.put_env(:platform, :env, :dev)
    Application.put_env(:platform, :peer_federation_allow_http, true)
    assert Config.allow_http?()

    Application.put_env(:platform, :peer_federation_allow_http, false)
    refute Config.allow_http?()
  end

  test "allow_http? is refused in prod even when set" do
    Application.put_env(:platform, :peer_federation_allow_http, true)

    # Positive control: the same setting is honoured outside prod.
    Application.put_env(:platform, :env, :test)
    assert Config.allow_http?()

    Application.put_env(:platform, :env, :prod)
    refute Config.allow_http?()
  end

  # task 01a14ba9 stage 2
  test "config/test.exs pins the signing protocol unset, which is v1" do
    assert Application.fetch_env!(:platform, :peer_federation_signing_protocol) == nil
    assert Config.signing_protocol() == "suite-federation/1"
  end

  test "signing_protocol reads PEER_FEDERATION_SIGNING_PROTOCOL as exactly \"burrow-federation/2\"" do
    Application.delete_env(:platform, :peer_federation_signing_protocol)
    original = System.get_env("PEER_FEDERATION_SIGNING_PROTOCOL")

    on_exit(fn ->
      if original,
        do: System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", original),
        else: System.delete_env("PEER_FEDERATION_SIGNING_PROTOCOL")
    end)

    System.delete_env("PEER_FEDERATION_SIGNING_PROTOCOL")
    assert Config.signing_protocol() == "suite-federation/1"

    for value <- ["burrow-federation/2 ", "BURROW-FEDERATION/2", "2", "true", ""] do
      System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", value)
      assert Config.signing_protocol() == "suite-federation/1", "#{inspect(value)} selected v2"
    end

    System.put_env("PEER_FEDERATION_SIGNING_PROTOCOL", "burrow-federation/2")
    assert Config.signing_protocol() == "burrow-federation/2"
  end
end
