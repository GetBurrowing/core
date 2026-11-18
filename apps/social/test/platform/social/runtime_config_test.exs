defmodule Platform.Social.RuntimeConfigTest do
  # Mutates the global :social app env, so never async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Social.Publisher
  alias Platform.Social.RuntimeConfig

  setup do
    saved_publisher = Application.fetch_env(:social, :publisher)
    saved_zernio = Application.fetch_env(:social, Platform.Social.Publisher.Zernio)
    saved_trends = Application.fetch_env(:social, :trends)
    saved_wikimedia = Application.fetch_env(:social, :trends_wikimedia)

    on_exit(fn ->
      restore(:publisher, saved_publisher)
      restore(Platform.Social.Publisher.Zernio, saved_zernio)
      restore(:trends, saved_trends)
      restore(:trends_wikimedia, saved_wikimedia)
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

      assert Keyword.take(RuntimeConfig.read(env), [:publisher, :zernio_base_url]) ==
               [publisher: :unset, zernio_base_url: nil]

      RuntimeConfig.apply(env)

      assert Application.get_all_env(:social) == before
      refute inspect(Application.get_all_env(:social)) =~ "test-not-a-real-key"
    end
  end

  describe "Trends settings" do
    setup do
      Application.put_env(:social, :trends, kept: :yes)
      Application.put_env(:social, :trends_wikimedia, kept: :yes)
      :ok
    end

    defp trends, do: Application.get_env(:social, :trends)
    defp wikimedia, do: Application.get_env(:social, :trends_wikimedia)

    test "unset touches nothing: Trends stays off with no source and no contact" do
      RuntimeConfig.apply(%{})
      assert trends() == [kept: :yes]
      assert wikimedia() == [kept: :yes]
    end

    test "SOCIAL_TRENDS_ENABLED=true (trimmed, case-insensitive) switches fetching on" do
      RuntimeConfig.apply(%{"SOCIAL_TRENDS_ENABLED" => " True "})
      assert Keyword.get(trends(), :enabled) == true
      assert Keyword.get(trends(), :kept) == :yes
    end

    test "any other SOCIAL_TRENDS_ENABLED value leaves it off and warns" do
      for value <- ["1", "yes", "on"] do
        log = capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_ENABLED" => value}) end)
        refute Keyword.get(trends(), :enabled) == true
        assert log =~ "SOCIAL_TRENDS_ENABLED"
      end
    end

    test "SOCIAL_TRENDS_ENABLED=false sets it off explicitly" do
      Application.put_env(:social, :trends, enabled: true)
      RuntimeConfig.apply(%{"SOCIAL_TRENDS_ENABLED" => "false"})
      assert Keyword.get(trends(), :enabled) == false
    end

    test "an invalid SOCIAL_TRENDS_ENABLED switches off an already-enabled config" do
      for value <- ["1", "yes", "on", "enabled"] do
        Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
        log = capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_ENABLED" => value}) end)
        assert Keyword.get(trends(), :enabled) == false
        assert log =~ "SOCIAL_TRENDS_ENABLED"
      end
    end

    test "an invalid SOCIAL_TRENDS_SOURCE clears an already-configured source" do
      for value <- ["hn", "hacker_news", "Wikimedia_Pageviews"] do
        Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
        log = capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_SOURCE" => value}) end)
        assert Keyword.get(trends(), :source) == nil
        assert log =~ value
      end
    end

    test "from a fully enabled config, an invalid source stops the fetch" do
      Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
      Application.put_env(:social, :trends_wikimedia, contact: "ops@example.test")

      capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_SOURCE" => "hn"}) end)
      assert Platform.Social.Trends.Refresher.refresh() == {:error, :invalid_source}
    end

    test "from a fully enabled config, an invalid enabled value stops the fetch" do
      Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
      Application.put_env(:social, :trends_wikimedia, contact: "ops@example.test")

      capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_ENABLED" => "yes"}) end)
      assert Platform.Social.Trends.Refresher.refresh() == {:error, :disabled}
    end

    test "unset keeps an already-enabled config as it is" do
      Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
      RuntimeConfig.apply(%{})
      assert trends() == [enabled: true, source: "wikimedia_pageviews"]
    end

    test "SOCIAL_TRENDS_SOURCE selects only an allow-listed source" do
      RuntimeConfig.apply(%{"SOCIAL_TRENDS_SOURCE" => " wikimedia_pageviews "})
      assert Keyword.get(trends(), :source) == "wikimedia_pageviews"
    end

    test "an unknown source, HN included, is not set and warns naming it" do
      for value <- ["hacker_news", "Wikimedia_Pageviews", "anything"] do
        Application.put_env(:social, :trends, kept: :yes)
        log = capture_log(fn -> RuntimeConfig.apply(%{"SOCIAL_TRENDS_SOURCE" => value}) end)
        assert Keyword.get(trends(), :source) == nil
        assert log =~ "SOCIAL_TRENDS_SOURCE"
        assert log =~ value
      end
    end

    test "SOCIAL_TRENDS_REFRESH_INTERVAL_MS takes a positive integer; anything else warns" do
      RuntimeConfig.apply(%{"SOCIAL_TRENDS_REFRESH_INTERVAL_MS" => "7200000"})
      assert Keyword.get(trends(), :refresh_interval_ms) == 7_200_000

      for value <- ["0", "-5", "soon", "1.5"] do
        Application.put_env(:social, :trends, kept: :yes)

        log =
          capture_log(fn ->
            RuntimeConfig.apply(%{"SOCIAL_TRENDS_REFRESH_INTERVAL_MS" => value})
          end)

        assert Keyword.get(trends(), :refresh_interval_ms) == nil
        assert log =~ "SOCIAL_TRENDS_REFRESH_INTERVAL_MS"
      end
    end

    test "SOCIAL_TRENDS_WIKIMEDIA_CONTACT is trimmed into the Wikimedia config, never logged" do
      # Capture every level, so a debug or info line naming the contact fails too.
      # (The module is not async, so changing the global level is safe here.)
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          RuntimeConfig.apply(%{"SOCIAL_TRENDS_WIKIMEDIA_CONTACT" => "  ops@example.test  "})
        end)

      assert Keyword.get(wikimedia(), :contact) == "ops@example.test"
      assert Keyword.get(wikimedia(), :kept) == :yes
      refute log =~ "ops@example.test"
    end

    test "an empty contact leaves none, so the refresher refuses to fetch" do
      RuntimeConfig.apply(%{
        "SOCIAL_TRENDS_ENABLED" => "true",
        "SOCIAL_TRENDS_SOURCE" => "wikimedia_pageviews",
        "SOCIAL_TRENDS_WIKIMEDIA_CONTACT" => "   "
      })

      assert Keyword.get(wikimedia(), :contact) == nil
      assert Platform.Social.Trends.Refresher.refresh() == {:error, :missing_contact}
    end

    test "with all three set, the refresher passes its config gates and stops at Studio" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Platform.Repo)

      RuntimeConfig.apply(%{
        "SOCIAL_TRENDS_ENABLED" => "true",
        "SOCIAL_TRENDS_SOURCE" => "wikimedia_pageviews",
        "SOCIAL_TRENDS_WIKIMEDIA_CONTACT" => "ops@example.test"
      })

      # No profile has Studio on in the sandbox: the next gate, not a config refusal.
      assert Platform.Social.Trends.Refresher.refresh() == {:error, :no_enabled_profile}
    end
  end
end
