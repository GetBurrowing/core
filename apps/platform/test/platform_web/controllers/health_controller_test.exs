defmodule PlatformWeb.HealthControllerTest do
  @moduledoc """
  `GET /health` reports the build commit (task 01a089d5). The response must
  be shown to TRACK the build input: two injected shas produce two different
  bodies, and with nothing injected the fallback file path is exercised (the
  test env ships no `priv/build_commit`, asserted rather than assumed).
  """

  # async: false — mutates Application env.
  use PlatformWeb.ConnCase, async: false

  @sha_a "0123456789abcdef0123456789abcdef01234567"
  @sha_b "fedcba9876543210fedcba9876543210fedcba98"

  setup do
    on_exit(fn -> Application.delete_env(:platform, :build_commit) end)
    :ok
  end

  defp health(conn) do
    conn = get(conn, "/health")
    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    Jason.decode!(conn.resp_body)
  end

  test "reports the injected commit and tracks it when it changes", %{conn: conn} do
    Application.put_env(:platform, :build_commit, @sha_a)
    body_a = health(conn)
    assert body_a == %{"status" => "ok", "commit" => @sha_a}

    Application.put_env(:platform, :build_commit, @sha_b)
    body_b = health(conn)
    assert body_b == %{"status" => "ok", "commit" => @sha_b}
    refute body_a == body_b
  end

  test "falls back to unknown when no commit is injected and no build file exists", %{conn: conn} do
    Application.delete_env(:platform, :build_commit)

    refute File.exists?(Application.app_dir(:platform, "priv/build_commit")),
           "test env unexpectedly ships priv/build_commit — the fallback path is not what this exercises"

    assert health(conn) == %{"status" => "ok", "commit" => "unknown"}
  end

  describe "?deep=memory (task 01a18f76)" do
    @key "test-static-api-key-0123456789"

    defmodule OkProvider do
      @behaviour Platform.Memory.Provider
      @impl true
      def ingest(_entries, _config), do: {:ok, 0}
      @impl true
      def search(query, _opts, config) do
        send(Keyword.fetch!(config, :test_pid), {:searched, query})
        {:ok, []}
      end

      @impl true
      def delete(_ids, _config), do: {:ok, 0}
      @impl true
      def health(_c), do: :ok
    end

    defmodule ErrorProvider do
      @behaviour Platform.Memory.Provider
      @impl true
      def ingest(_entries, _config), do: {:ok, 0}
      @impl true
      def search(_query, _opts, _config), do: {:error, {:http, 503}}
      @impl true
      def delete(_ids, _config), do: {:ok, 0}
      @impl true
      def health(_c), do: :ok
    end

    defmodule SlowProvider do
      @behaviour Platform.Memory.Provider
      @impl true
      def ingest(_entries, _config), do: {:ok, 0}
      @impl true
      def search(_query, _opts, _config) do
        Process.sleep(5_000)
        {:ok, []}
      end

      @impl true
      def delete(_ids, _config), do: {:ok, 0}
      @impl true
      def health(_c), do: :ok
    end

    setup do
      prev = Application.get_env(:platform, :memory_service, [])
      Application.put_env(:platform, :sign_in_admin_api_key, @key)
      Application.put_env(:platform, :build_commit, @sha_a)

      on_exit(fn ->
        Application.put_env(:platform, :memory_service, prev)
        Application.delete_env(:platform, :sign_in_admin_api_key)
        Application.delete_env(:platform, :health_deep_memory_timeout_ms)
      end)

      :ok
    end

    defp use_provider(mod),
      do: Application.put_env(:platform, :memory_service, provider: mod, test_pid: self())

    defp deep(conn, auth) do
      conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
      conn = get(conn, "/health?deep=memory")
      assert conn.status == 200
      Jason.decode!(conn.resp_body)
    end

    @plain %{"status" => "ok", "commit" => @sha_a}

    test "no auth or a wrong key gets exactly the old body and triggers no search", %{conn: conn} do
      use_provider(OkProvider)

      for auth <- [nil, "Bearer wrong-key", "Bearer ", @key, "Basic " <> @key] do
        assert deep(conn, auth) == @plain
      end

      refute_received {:searched, _}
      # And the plain /health never searches either.
      assert health(conn) == @plain
      refute_received {:searched, _}
    end

    test "the right key with deep=memory runs one search and says ok", %{conn: conn} do
      use_provider(OkProvider)
      assert deep(conn, "Bearer " <> @key) == Map.put(@plain, "memory", "ok")
      assert_received {:searched, "probe"}
      # Without deep=memory the right key changes nothing.
      assert health(put_req_header(conn, "authorization", "Bearer " <> @key)) == @plain
    end

    test "a provider error is unavailable", %{conn: conn} do
      use_provider(ErrorProvider)
      assert deep(conn, "Bearer " <> @key) == Map.put(@plain, "memory", "unavailable")
    end

    test "a provider slower than the bound is unavailable", %{conn: conn} do
      use_provider(SlowProvider)
      Application.put_env(:platform, :health_deep_memory_timeout_ms, 50)
      assert deep(conn, "Bearer " <> @key) == Map.put(@plain, "memory", "unavailable")
    end

    test "no memory provider configured is unavailable", %{conn: conn} do
      use_provider(Platform.Memory.Providers.Noop)
      assert deep(conn, "Bearer " <> @key) == Map.put(@plain, "memory", "unavailable")
    end

    test "with no key configured, no bearer value unlocks it", %{conn: conn} do
      use_provider(OkProvider)
      Application.put_env(:platform, :sign_in_admin_api_key, nil)
      assert deep(conn, "Bearer ") == @plain
      assert deep(conn, "Bearer " <> @key) == @plain
      refute_received {:searched, _}
    end
  end
end
