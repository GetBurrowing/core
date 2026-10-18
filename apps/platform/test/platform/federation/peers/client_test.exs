defmodule Platform.Federation.Peers.ClientTest do
  @moduledoc """
  Task 01a0d90f stage 3: the outbound client and its SSRF guard (ADR 0054
  section 1, architect note 1).

  Every refusal asserts that NO request left the client (the `Req.Test` stub
  records each request it receives). The POSITIVE CONTROL is a hostname that
  resolves to a public address: its request does arrive, and arrives at the
  pinned IP, so a refusal is not an artefact of a stub that never answers.
  """

  # async: false — flips global app env (flag, allow_http, resolver, :env).
  use Platform.DataCase, async: false

  import Platform.FederationPeerFixtures

  alias Platform.Federation.Peers.Client

  @public {93, 184, 216, 34}

  setup do
    enable_federation!()
    test_pid = self()

    Req.Test.stub(Client, fn conn ->
      send(test_pid, {:peer_request, conn.method, conn.host, conn.request_path})
      Req.Test.json(conn, descriptor(remote_install()))
    end)

    :ok
  end

  defp refute_request, do: refute_received({:peer_request, _, _, _})

  describe "positive control" do
    test "a hostname resolving to a public address is fetched, pinned to that address" do
      resolve!(%{"peer.example.test" => [@public]})

      assert {:ok, %{"protocol" => "suite-federation/1"}} =
               Client.fetch_descriptor("https://peer.example.test")

      assert_received {:peer_request, "GET", "93.184.216.34", "/.well-known/suite-federation"}

      assert Client.check_url("https://peer.example.test/x") ==
               {:ok, %{url: "https://93.184.216.34/x", hostname: "peer.example.test"}}
    end

    test "a public IPv6 literal is allowed" do
      assert {:ok, %{hostname: "2606:4700::1111"}} =
               Client.check_url("https://[2606:4700::1111]/x")
    end
  end

  describe "refused before any request is made" do
    test "cloud metadata, loopback, private, CGNAT, unspecified and multicast IPv4" do
      for host <- ~w(169.254.169.254 127.0.0.1 10.1.2.3 172.16.5.4 192.0.2.1
                     100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255) do
        assert {:error, {:forbidden_address, ^host}} =
                 Client.fetch_descriptor("https://#{host}"),
               "#{host} was not refused"
      end

      refute_request()
    end

    test "loopback, unique-local, link-local, mapped and NAT64 IPv6" do
      for host <- ~w(::1 fc00::1 fd12:3456::1 fe80::1 ::ffff:10.0.0.1 64:ff9b::a9fe:a9fe) do
        assert {:error, {:forbidden_address, _}} = Client.fetch_descriptor("https://[#{host}]"),
               "#{host} was not refused"
      end

      refute_request()
    end

    test "a hostname that resolves to a private address" do
      resolve!(%{"inward.example.test" => [{10, 0, 0, 5}]})

      assert Client.fetch_descriptor("https://inward.example.test") ==
               {:error, {:forbidden_address, "10.0.0.5"}}

      refute_request()
    end

    test "a hostname with ANY private address among its answers" do
      resolve!(%{"mixed.example.test" => [@public, {127, 0, 0, 1}]})

      assert Client.fetch_descriptor("https://mixed.example.test") ==
               {:error, {:forbidden_address, "127.0.0.1"}}

      refute_request()
    end

    test "plain http outside the rig" do
      resolve!(%{"peer.example.test" => [@public]})

      assert Client.fetch_descriptor("http://peer.example.test") == {:error, :insecure_scheme}
      assert Client.fetch_descriptor("ftp://peer.example.test") == {:error, :insecure_scheme}
      refute_request()
    end

    test "unresolvable hosts and URLs with userinfo" do
      assert Client.fetch_descriptor("https://nowhere.example.test") == {:error, :unresolvable}

      assert Client.fetch_descriptor("https://user@peer.example.test") ==
               {:error, :malformed_url}

      refute_request()
    end
  end

  describe "the rig exception" do
    test "allow_http permits plain http to a private address, outside :prod only" do
      put_env_restored(:peer_federation_allow_http, true)

      assert {:ok, _} = Client.fetch_descriptor("http://dev-platform-peer-a:4000")
      assert_received {:peer_request, "GET", "dev-platform-peer-a", _}

      put_env_restored(:env, :prod)

      assert Client.fetch_descriptor("http://dev-platform-peer-a:4000") ==
               {:error, :insecure_scheme}

      assert {:error, {:forbidden_address, _}} = Client.fetch_descriptor("https://10.0.0.5")
      refute_request()
    end
  end

  describe "responses are values, never raises" do
    setup do
      resolve!(%{"peer.example.test" => [@public]})
      :ok
    end

    test "a redirect is not followed, even to a public host" do
      test_pid = self()

      Req.Test.stub(Client, fn conn ->
        send(test_pid, {:peer_request, conn.method, conn.host, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", "https://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert Client.fetch_descriptor("https://peer.example.test") ==
               {:error, {:http_status, 302, nil}}

      assert_received {:peer_request, "GET", "93.184.216.34", _}
      refute_request()
    end

    test "an oversized response is abandoned" do
      Req.Test.stub(Client, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("a", Client.max_response_bytes() + 1))
      end)

      assert Client.fetch_descriptor("https://peer.example.test") ==
               {:error, :response_too_large}
    end

    test "a compressed body the peer sent unasked is never inflated" do
      # A 64 KB cap on compressed bytes would admit a gzip body that inflates
      # to megabytes. The same bytes WITH decompression would decode to a
      # valid descriptor, so this refusal is the missing decompression step.
      gz = :zlib.gzip(Jason.encode!(descriptor(remote_install())))

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, gz)
      end)

      assert Client.fetch_descriptor("https://peer.example.test") == {:error, :invalid_descriptor}

      # control: the same stub, read by a Req that does decompress, decodes.
      # Req >= 0.6.1 no longer decompresses by default, so the control opts in
      # with `compressed: true` (task 01a0e8b5 bumped Req 0.5 -> 0.7).
      assert {:ok, %{body: %{"protocol" => "suite-federation/1"}}} =
               Req.get("https://93.184.216.34/.well-known/suite-federation",
                 plug: {Req.Test, Client},
                 compressed: true,
                 retry: false
               )
    end

    test "garbage, error statuses and transport failures" do
      Req.Test.stub(Client, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>not json") end)
      assert Client.fetch_descriptor("https://peer.example.test") == {:error, :invalid_descriptor}

      Req.Test.stub(Client, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert Client.send_envelope("https://peer.example.test", "{}", []) ==
               {:error, {:http_status, 500, "boom"}}

      Req.Test.stub(Client, &Req.Test.transport_error(&1, :timeout))

      assert Client.send_envelope("https://peer.example.test", "{}", []) ==
               {:error, {:transport, :timeout}}
    end

    test "send_envelope posts to the fixed inbox path and returns the decoded body" do
      test_pid = self()

      Req.Test.stub(Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posted, conn.request_path, body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{status: 200, body: %{"ok" => true}}} =
               Client.send_envelope("https://peer.example.test/", ~s({"a":1}), [
                 {"content-type", "application/json"}
               ])

      assert_received {:posted, "/federation/v1/inbox", ~s({"a":1})}
    end
  end

  describe "descriptor protocol ids (task 01a14ba9 stage 1)" do
    setup do
      resolve!(%{"peer.example.test" => [@public]})
      :ok
    end

    defp serve(desc) do
      Req.Test.stub(Client, fn conn -> Req.Test.json(conn, desc) end)
    end

    test "a v1 descriptor with no protocols list is normalised to [protocol]" do
      remote = remote_install()
      serve(descriptor(remote))

      assert {:ok, %{"protocol" => "suite-federation/1", "protocols" => ["suite-federation/1"]}} =
               Client.fetch_descriptor("https://peer.example.test")
    end

    test "a descriptor whose protocol is burrow-federation/2 is accepted" do
      remote = remote_install()
      serve(descriptor(remote, %{"protocol" => "burrow-federation/2"}))

      assert {:ok, %{"protocol" => "burrow-federation/2", "protocols" => ["burrow-federation/2"]}} =
               Client.fetch_descriptor("https://peer.example.test")
    end

    test "a protocols list the peer sends is kept as sent" do
      remote = remote_install()
      both = ["suite-federation/1", "burrow-federation/2"]
      serve(descriptor(remote, %{"protocols" => both}))

      assert {:ok, %{"protocol" => "suite-federation/1", "protocols" => ^both}} =
               Client.fetch_descriptor("https://peer.example.test")
    end

    test "an unknown protocol and a malformed protocols list are refused" do
      remote = remote_install()

      for protocol <- ["burrow-federation/1", "suite-federation/2", "other/1", nil] do
        serve(descriptor(remote, %{"protocol" => protocol}))

        assert Client.fetch_descriptor("https://peer.example.test") ==
                 {:error, :invalid_descriptor},
               "#{inspect(protocol)} was accepted"
      end

      for protocols <- ["burrow-federation/2", [1], %{}] do
        serve(descriptor(remote, %{"protocols" => protocols}))

        assert Client.fetch_descriptor("https://peer.example.test") ==
                 {:error, :invalid_descriptor},
               "protocols #{inspect(protocols)} was accepted"
      end
    end

    test "the fetch path is still /.well-known/suite-federation" do
      test_pid = self()

      Req.Test.stub(Client, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Req.Test.json(conn, descriptor(remote_install()))
      end)

      assert {:ok, _} = Client.fetch_descriptor("https://peer.example.test")
      assert_received {:path, "/.well-known/suite-federation"}
    end
  end
end
