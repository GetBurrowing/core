defmodule Platform.SignInAdmin.ConfigTest do
  @moduledoc """
  Task 01a113ea stage 1: the sign-in users page switch is read at call time,
  fails closed, and never prints the pocket-id API key.
  """
  # async: false: swaps :platform app env and POCKET_ID_* OS env vars.
  use ExUnit.Case, async: false

  alias Platform.SignInAdmin.Config

  @app_keys [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]
  @env_vars ["POCKET_ID_ADMIN_ENABLED", "POCKET_ID_ADMIN_URL", "POCKET_ID_API_KEY"]
  @key "cfg-test-key-0123456789-SECRET"

  setup do
    saved_app = for key <- @app_keys, do: {key, Application.fetch_env(:platform, key)}
    saved_env = for var <- @env_vars, do: {var, System.get_env(var)}

    on_exit(fn ->
      for {key, value} <- saved_app do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end

      for {var, value} <- saved_env do
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end
    end)

    :ok
  end

  # Removes every injection key so the OS environment is what is read.
  defp env_only do
    Enum.each(@app_keys, &Application.delete_env(:platform, &1))
    Enum.each(@env_vars, &System.delete_env/1)
  end

  defp put_all_env do
    System.put_env("POCKET_ID_ADMIN_ENABLED", "true")
    System.put_env("POCKET_ID_ADMIN_URL", "http://pocket-id:1411")
    System.put_env("POCKET_ID_API_KEY", @key)
  end

  test "config/test.exs pins the switch off, so the host env cannot turn it on" do
    assert Application.fetch_env(:platform, :sign_in_admin_enabled) == {:ok, false}
    put_all_env()
    refute Config.enabled?()
  end

  describe "runtime read (not compile time)" do
    test "setting the three variables inside the test flips enabled?/0, deleting each flips it back" do
      env_only()
      refute Config.enabled?()

      put_all_env()
      assert Config.enabled?()

      for var <- @env_vars do
        value = System.get_env(var)
        System.delete_env(var)
        refute Config.enabled?(), "expected enabled?/0 false with #{var} unset"
        System.put_env(var, value)
        assert Config.enabled?()
      end
    end
  end

  describe "fail closed" do
    test "only the exact string \"true\" turns the switch on" do
      env_only()
      put_all_env()

      for value <- ["1", "TRUE", "True", "yes", "on", " true", "true ", ""] do
        System.put_env("POCKET_ID_ADMIN_ENABLED", value)
        refute Config.enabled?(), "expected #{inspect(value)} to leave the page off"
      end

      System.delete_env("POCKET_ID_ADMIN_ENABLED")
      refute Config.enabled?()

      System.put_env("POCKET_ID_ADMIN_ENABLED", "true")
      assert Config.enabled?()
    end

    test "a blank URL or a blank key leaves the page off" do
      env_only()
      put_all_env()

      System.put_env("POCKET_ID_ADMIN_URL", "   ")
      refute Config.enabled?()
      assert Config.url() == nil

      System.put_env("POCKET_ID_ADMIN_URL", "http://pocket-id:1411")
      System.put_env("POCKET_ID_API_KEY", "  ")
      refute Config.enabled?()
      assert Config.api_key() == nil
    end

    test "the injected switch overrides only the switch: URL and key are still required" do
      env_only()
      Application.put_env(:platform, :sign_in_admin_enabled, true)
      refute Config.enabled?()

      Application.put_env(:platform, :sign_in_admin_url, "http://stub.test")
      refute Config.enabled?()

      Application.put_env(:platform, :sign_in_admin_api_key, @key)
      assert Config.enabled?()

      Application.put_env(:platform, :sign_in_admin_enabled, "true")
      refute Config.enabled?(), "only the boolean true injection enables"
    end
  end

  describe "values" do
    test "url/0 trims whitespace and a trailing slash" do
      env_only()
      System.put_env("POCKET_ID_ADMIN_URL", " http://pocket-id:1411/ ")
      assert Config.url() == "http://pocket-id:1411"
    end

    test "api_key/0 wraps the key, and inspect/1 never prints it" do
      env_only()
      System.put_env("POCKET_ID_API_KEY", @key)

      key = Config.api_key()
      assert %Config.Key{value: @key} = key
      assert inspect(key) == "#SignInAdmin.Key<redacted>"
      refute inspect(key) =~ @key
      refute inspect({:ok, key, [key]}) =~ @key
    end

    test "public_base/0 is the OIDC issuer without a trailing slash" do
      assert Config.public_base() == "https://issuer.example.com"
      assert Config.public_base() == Platform.OIDC.issuer()

      original = Application.get_env(:platform, :oidc, [])
      on_exit(fn -> Application.put_env(:platform, :oidc, original) end)

      Application.put_env(
        :platform,
        :oidc,
        Keyword.put(original, :issuer, "https://auth.example.test/")
      )

      assert Config.public_base() == "https://auth.example.test"
    end
  end
end
