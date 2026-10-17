defmodule Platform.Social.RuntimeConfigTest do
  # Mutates the global :social app env, so never async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Social.Publisher
  alias Platform.Social.RuntimeConfig

  setup do
    saved_publisher = Application.fetch_env(:social, :publisher)
    saved_zernio = Application.fetch_env(:social, Platform.Social.Publisher.Zernio)

    on_exit(fn ->
      restore(:publisher, saved_publisher)
      restore(Platform.Social.Publisher.Zernio, saved_zernio)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:social, key, value)
  defp restore(key, :error), do: Application.delete_env(:social, key)

  describe "with no publisher configured (the prod case)" do
    setup do
      Application.delete_env(:social, :publisher)
      :ok
    end

    test "SOCIAL_PUBLISHER=zernio selects the Zernio adapter" do
      assert Publisher.impl() == {:error, :publisher_not_configured}
      assert RuntimeConfig.apply(%{"SOCIAL_PUBLISHER" => "zernio"}) == :ok
      assert Publisher.impl() == Platform.Social.Publisher.Zernio
    end

    test "the value is trimmed and case-insensitive" do
      RuntimeConfig.apply(%{"SOCIAL_PUBLISHER" => " Zernio "})
      assert Publisher.impl() == Platform.Social.Publisher.Zernio
    end

    test "unset leaves impl/0 unconfigured" do
      RuntimeConfig.apply(%{})
      assert Publisher.impl() == {:error, :publisher_not_configured}
    end

    test "empty leaves impl/0 unconfigured" do
      RuntimeConfig.apply(%{"SOCIAL_PUBLISHER" => "  "})
      assert Publisher.impl() == {:error, :publisher_not_configured}
    end
  end

  describe "with the Fake preset (dev and test)" do
    setup do
      Application.put_env(:social, :publisher, Platform.Social.Publisher.Fake)
      :ok
    end

    test "unset leaves the Fake" do
      RuntimeConfig.apply(%{})
      assert Publisher.impl() == Platform.Social.Publisher.Fake
    end

    test "an unknown value leaves the Fake and warns naming the value" do
      log =
        capture_log(fn ->
          RuntimeConfig.apply(%{"SOCIAL_PUBLISHER" => "postiz"})
        end)

      assert Publisher.impl() == Platform.Social.Publisher.Fake
      assert log =~ "SOCIAL_PUBLISHER"
      assert log =~ "postiz"
    end
  end

  describe "SOCIAL_ZERNIO_BASE_URL and the key" do
    test "the base URL reaches the Zernio adapter config, keeping other keys" do
      Application.put_env(:social, Platform.Social.Publisher.Zernio,
        base_url: "https://before.test/api",
        other: :kept
      )

      RuntimeConfig.apply(%{"SOCIAL_ZERNIO_BASE_URL" => "https://zernio-override.test/api"})

      config = Application.get_env(:social, Platform.Social.Publisher.Zernio)
      assert Keyword.get(config, :base_url) == "https://zernio-override.test/api"
      assert Keyword.get(config, :other) == :kept
    end

    test "unset leaves the Zernio adapter config alone" do
      Application.put_env(:social, Platform.Social.Publisher.Zernio,
        base_url: "https://before.test/api"
      )

      RuntimeConfig.apply(%{})

      assert Application.get_env(:social, Platform.Social.Publisher.Zernio) ==
               [base_url: "https://before.test/api"]
    end

    test "a SOCIAL_ZERNIO_API_KEY entry is ignored and no key lands in app env" do
      Application.delete_env(:social, :publisher)
      Application.delete_env(:social, Platform.Social.Publisher.Zernio)
      before = Application.get_all_env(:social)

      env = %{"SOCIAL_ZERNIO_API_KEY" => "test-not-a-real-key"}

      assert RuntimeConfig.read(env) == [publisher: :unset, zernio_base_url: nil]
      RuntimeConfig.apply(env)

      assert Application.get_all_env(:social) == before
      refute inspect(Application.get_all_env(:social)) =~ "test-not-a-real-key"
    end
  end
end
