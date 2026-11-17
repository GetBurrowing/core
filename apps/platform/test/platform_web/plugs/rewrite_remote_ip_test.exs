defmodule PlatformWeb.Plugs.RewriteRemoteIpTest do
  @moduledoc """
  Task 01a1b2df: `RewriteRemoteIp` resolves the client from the trusted-proxy
  chain, so a client can never choose `conn.remote_ip`.

  async: false — flips `:trust_proxy_headers` and `:trusted_proxies`.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias PlatformWeb.Plugs.RewriteRemoteIp

  setup do
    saved =
      for key <- [:trust_proxy_headers, :trusted_proxies],
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:platform, key, value)
        {key, :error} -> Application.delete_env(:platform, key)
      end)
    end)

    Application.put_env(:platform, :trust_proxy_headers, true)
    Application.delete_env(:platform, :trusted_proxies)
    :ok
  end

  defp request(peer, headers) do
    conn = conn(:get, "/")
    conn = %{conn | remote_ip: peer}

    Enum.reduce(headers, conn, fn {k, v}, acc ->
      %{acc | req_headers: acc.req_headers ++ [{k, v}]}
    end)
  end

  defp run(conn), do: RewriteRemoteIp.call(conn, RewriteRemoteIp.init([]))

  test "a forged leading XFF entry is ignored" do
    out = request({127, 0, 0, 1}, [{"x-forwarded-for", "6.6.6.6, 198.51.100.7"}]) |> run()

    assert out.remote_ip == {198, 51, 100, 7}
    refute out.remote_ip == {6, 6, 6, 6}
  end

  test "trusted hops are skipped right to left" do
    out =
      request({172, 18, 0, 5}, [{"x-forwarded-for", "6.6.6.6, 198.51.100.7, 172.18.0.3"}])
      |> run()

    assert out.remote_ip == {198, 51, 100, 7}
  end

  test "multiple XFF header lines are joined in order" do
    out =
      request({127, 0, 0, 1}, [
        {"x-forwarded-for", "6.6.6.6"},
        {"x-forwarded-for", "198.51.100.7, 10.0.0.2"}
      ])
      |> run()

    assert out.remote_ip == {198, 51, 100, 7}
  end

  test "CF-Connecting-IP is used only when the first untrusted hop is a Cloudflare edge" do
    out =
      request({127, 0, 0, 1}, [
        {"x-forwarded-for", "6.6.6.6, 162.158.1.1"},
        {"cf-connecting-ip", "198.51.100.9"}
      ])
      |> run()

    assert out.remote_ip == {198, 51, 100, 9}
  end

  test "CF-Connecting-IP from a non-Cloudflare hop is ignored" do
    out =
      request({127, 0, 0, 1}, [
        {"x-forwarded-for", "198.51.100.7"},
        {"cf-connecting-ip", "6.6.6.6"}
      ])
      |> run()

    assert out.remote_ip == {198, 51, 100, 7}
  end

  test "an untrusted peer's headers are all ignored" do
    out =
      request({203, 0, 113, 50}, [
        {"x-forwarded-for", "6.6.6.6"},
        {"cf-connecting-ip", "6.6.6.6"}
      ])
      |> run()

    assert out.remote_ip == {203, 0, 113, 50}
  end

  test "an unparsable hop fails closed" do
    out = request({127, 0, 0, 1}, [{"x-forwarded-for", "198.51.100.7, not-an-ip"}]) |> run()

    assert out.remote_ip == {127, 0, 0, 1}
  end

  test "TRUSTED_PROXIES replaces the default" do
    Application.put_env(:platform, :trusted_proxies, [{{127, 0, 0, 1}, 32}])

    out = request({10, 0, 0, 2}, [{"x-forwarded-for", "6.6.6.6"}]) |> run()

    assert out.remote_ip == {10, 0, 0, 2}
  end

  test "IPv6 hops and ranges" do
    out =
      request({0, 0, 0, 0, 0, 0, 0, 1}, [{"x-forwarded-for", "2001:db8::66, 2001:db8::7"}])
      |> run()

    assert out.remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}
  end

  test "with TRUST_PROXY_HEADERS off nothing changes" do
    Application.put_env(:platform, :trust_proxy_headers, false)

    conn_in =
      request({127, 0, 0, 1}, [
        {"x-forwarded-for", "6.6.6.6, 162.158.1.1"},
        {"cf-connecting-ip", "6.6.6.6"}
      ])

    conn_out = run(conn_in)
    assert conn_out == conn_in
  end

  test "no XFF, or only trusted hops, leaves the peer" do
    assert request({127, 0, 0, 1}, []) |> run() |> Map.fetch!(:remote_ip) == {127, 0, 0, 1}

    assert request({127, 0, 0, 1}, [{"x-forwarded-for", "10.1.2.3, 172.20.0.4"}])
           |> run()
           |> Map.fetch!(:remote_ip) == {127, 0, 0, 1}
  end

  test "100.64.0.0/10 (tailnet) is not trusted by default" do
    out = request({100, 64, 0, 9}, [{"x-forwarded-for", "6.6.6.6"}]) |> run()
    assert out.remote_ip == {100, 64, 0, 9}

    out = request({127, 0, 0, 1}, [{"x-forwarded-for", "6.6.6.6, 100.101.102.103"}]) |> run()
    assert out.remote_ip == {100, 101, 102, 103}
  end

  test "an IPv4-mapped IPv6 peer is matched as IPv4" do
    out =
      request({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, [{"x-forwarded-for", "198.51.100.7"}])
      |> run()

    assert out.remote_ip == {198, 51, 100, 7}
  end

  describe "parse_trusted_proxies/1" do
    test "unset or blank is the default" do
      default = RewriteRemoteIp.default_trusted_proxies()
      assert RewriteRemoteIp.parse_trusted_proxies(nil) == default
      assert RewriteRemoteIp.parse_trusted_proxies("") == default
      assert RewriteRemoteIp.parse_trusted_proxies("  ") == default

      assert default == [
               {{127, 0, 0, 0}, 8},
               {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
               {{10, 0, 0, 0}, 8},
               {{172, 16, 0, 0}, 12},
               {{192, 168, 0, 0}, 16},
               {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}
             ]
    end

    test "an explicit list replaces the default, masks host bits and accepts bare addresses" do
      assert RewriteRemoteIp.parse_trusted_proxies(" 10.1.2.3/8, 172.18.0.7 ,2001:db8::1/32") ==
               [
                 {{10, 0, 0, 0}, 8},
                 {{172, 18, 0, 7}, 32},
                 {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}
               ]
    end

    test "explicit full-width and zero-length prefixes are accepted" do
      assert RewriteRemoteIp.parse_trusted_proxies("10.255.255.254/32, 2001:db8::7/128") == [
               {{10, 255, 255, 254}, 32},
               {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}, 128}
             ]

      assert RewriteRemoteIp.parse_trusted_proxies("0.0.0.0/0") == [{{0, 0, 0, 0}, 0}]
    end

    test "a bad entry raises naming it" do
      for bad <- [
            "10.0.0.0/33",
            "not-a-cidr",
            "10.0.0.0/8, nope",
            "::1/129",
            "10.0.0/8",
            "1.2.3.4/x",
            "10.0.0.0/8,,"
          ] do
        assert_raise ArgumentError, ~r/TRUSTED_PROXIES/, fn ->
          RewriteRemoteIp.parse_trusted_proxies(bad)
        end
      end
    end

    test "in_any?/2 matches CIDR boundaries" do
      cidrs = RewriteRemoteIp.parse_trusted_proxies("172.16.0.0/12,fc00::/7")
      assert RewriteRemoteIp.in_any?({172, 31, 255, 255}, cidrs)
      refute RewriteRemoteIp.in_any?({172, 32, 0, 0}, cidrs)
      refute RewriteRemoteIp.in_any?({172, 15, 255, 255}, cidrs)
      assert RewriteRemoteIp.in_any?({0xFDFF, 1, 0, 0, 0, 0, 0, 1}, cidrs)
      refute RewriteRemoteIp.in_any?({0xFE00, 0, 0, 0, 0, 0, 0, 1}, cidrs)
    end

    test "the compiled Cloudflare ranges parse" do
      ranges = RewriteRemoteIp.cloudflare_ranges()
      assert length(ranges) == 22
      assert RewriteRemoteIp.in_any?({162, 158, 1, 1}, ranges)
      assert RewriteRemoteIp.in_any?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1}, ranges)
      refute RewriteRemoteIp.in_any?({198, 51, 100, 7}, ranges)
    end
  end
end
