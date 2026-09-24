defmodule Platform.Mail.ConfigTest do
  @moduledoc """
  `Platform.Mail.Config.enabled?/0` fails closed (task 01a0cf21 stage 1):
  only the exact string "true" turns the module on, and injected config wins
  over the environment.
  """
  # Mutates global application and OS env.
  use ExUnit.Case, async: false

  alias Platform.Mail.Config

  setup do
    prior_app = Application.fetch_env(:platform, :mail_enabled)
    prior_env = System.get_env("MAIL_ENABLED")

    on_exit(fn ->
      case prior_app do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end

      case prior_env do
        nil -> System.delete_env("MAIL_ENABLED")
        value -> System.put_env("MAIL_ENABLED", value)
      end
    end)

    Application.delete_env(:platform, :mail_enabled)
    System.delete_env("MAIL_ENABLED")
    %{prior_app: prior_app}
  end

  test "config/test.exs pins the flag off via injected config", %{prior_app: prior_app} do
    # Read before setup cleared it, so the suite does not depend on the host env.
    assert prior_app == {:ok, false}
  end

  test "unset is disabled" do
    refute Config.enabled?()
  end

  test ~s(only the exact string "true" enables) do
    for value <- ["1", "TRUE", "True", "yes", "on", " true", "true ", ""] do
      System.put_env("MAIL_ENABLED", value)
      refute Config.enabled?(), "MAIL_ENABLED=#{inspect(value)} must be disabled"
    end

    System.put_env("MAIL_ENABLED", "true")
    assert Config.enabled?()
  end

  test "injected config wins over the environment, in both directions" do
    System.put_env("MAIL_ENABLED", "true")
    Application.put_env(:platform, :mail_enabled, false)
    refute Config.enabled?()

    System.delete_env("MAIL_ENABLED")
    Application.put_env(:platform, :mail_enabled, true)
    assert Config.enabled?()
  end

  test "an injected non-boolean is disabled" do
    Application.put_env(:platform, :mail_enabled, "true")
    refute Config.enabled?()
  end
end
