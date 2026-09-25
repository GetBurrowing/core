defmodule Platform.Federation.Peers.ConfigTest do
  @moduledoc "Task 01a0d90f stage 2: the federation switches fail closed."

  # async: false — flips global app env (:env, :peer_federation_allow_http).
  use ExUnit.Case, async: false

  alias Platform.Federation.Peers.Config

  setup do
    saved =
      for key <- [:env, :peer_federation_allow_http, :peer_federation_enabled],
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
end
