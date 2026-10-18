defmodule PlatformWeb.Plugs.SessionCookieDomainTest do
  # async: false — these cases mutate application env
  # (:platform, :session_cookie_domain) and read process-global :persistent_term.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias PlatformWeb.Plugs.SessionCookieDomain

  # A stable per-test secret so cookie signing/verification is deterministic and
  # independent of the endpoint's runtime secret. Signing reads
  # secret_key_base from the *conn* at request time, so the write and read conns
  # below sign/verify with this value regardless of any memoized init.
  @secret_key_base String.duplicate("s3cr3t", 12)

  # Mirror PlatformWeb.Endpoint's real @session_options shape EXACTLY (same
  # signing_salt). SessionCookieDomain memoizes Plug.Session.init/1 in
  # :persistent_term keyed by the resolved domain ({module, domain}); using the
  # identical base opts here means the host-only ({module, nil}) memoization is
  # byte-for-byte what the app itself computes, so this test can never poison the
  # shared key that ConnCase-driven tests rely on. The domain-set key is unique
  # to this test and erased in on_exit.
  @base_opts [
    store: :cookie,
    key: "_platform_session",
    signing_salt: "LVkhtRt/",
    same_site: "Lax",
    http_only: true
  ]

  @cookie_key "_platform_session"
  @prod_domain ".example.net"

  setup do
    on_exit(fn ->
      Application.delete_env(:platform, :session_cookie_domain)
      # Drop this test's domain-set memoization so it cannot leak into any other
      # module. The host-only ({module, nil}) entry is intentionally left — it is
      # identical to what the app computes from @session_options.
      :persistent_term.erase({SessionCookieDomain, @prod_domain})
    end)

    :ok
  end

  describe "domain configured (prod: SESSION_COOKIE_DOMAIN=.example.net)" do
    setup do
      Application.put_env(:platform, :session_cookie_domain, @prod_domain)
      :ok
    end

    test "session cookie carries Domain and preserves SameSite=Lax + HttpOnly" do
      conn = write_session(%{hello: "world"})

      cookie = conn.resp_cookies[@cookie_key]
      assert cookie[:domain] == @prod_domain
      assert cookie[:same_site] == "Lax"
      assert cookie[:http_only] == true

      set_cookie = raw_set_cookie(conn)
      down = String.downcase(set_cookie)
      assert down =~ "domain=.example.net"
      assert down =~ "samesite=lax"
      assert down =~ "httponly"
    end

    test "round-trip: a value written with put_session reads back after re-fetch" do
      assert round_trip_value() == "trip-value"
    end
  end

  describe "domain unset (dev/test/CI/localhost: host-only, unchanged)" do
    setup do
      Application.delete_env(:platform, :session_cookie_domain)
      :ok
    end

    test "session cookie has NO Domain attribute (host-only regression guard)" do
      conn = write_session(%{hello: "world"})

      cookie = conn.resp_cookies[@cookie_key]
      refute Map.has_key?(cookie, :domain)
      assert cookie[:same_site] == "Lax"
      assert cookie[:http_only] == true

      refute String.downcase(raw_set_cookie(conn)) =~ "domain="
    end

    test "round-trip: a value written with put_session reads back after re-fetch" do
      assert round_trip_value() == "trip-value"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp base_conn(req_cookies) do
    conn = %{conn(:get, "/") | secret_key_base: @secret_key_base}

    Enum.reduce(req_cookies, conn, fn {k, v}, acc -> put_req_cookie(acc, k, v) end)
  end

  # Runs a conn through the wrapper plug exactly as the endpoint pipeline does:
  # init(@base_opts) then call/2.
  defp run_plug(conn) do
    SessionCookieDomain.call(conn, SessionCookieDomain.init(@base_opts))
  end

  defp write_session(kv) do
    conn =
      %{}
      |> base_conn()
      |> run_plug()
      |> fetch_session()

    conn = Enum.reduce(kv, conn, fn {k, v}, acc -> put_session(acc, k, v) end)
    send_resp(conn, 200, "ok")
  end

  # Write a session, extract the returned cookie value, replay it on a fresh conn
  # and confirm the signed value survives the wrapper's sign/verify round-trip.
  defp round_trip_value do
    write_conn = write_session(%{round: "trip-value"})
    cookie_value = write_conn.resp_cookies[@cookie_key].value

    read_conn =
      %{@cookie_key => cookie_value}
      |> base_conn()
      |> run_plug()
      |> fetch_session()

    get_session(read_conn, :round)
  end

  defp raw_set_cookie(conn) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.find(fn header -> String.starts_with?(header, @cookie_key <> "=") end)
  end
end
