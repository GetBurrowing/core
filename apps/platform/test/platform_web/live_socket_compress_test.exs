defmodule PlatformWeb.LiveSocketCompressTest do
  @moduledoc """
  The `/live` websocket negotiates `permessage-deflate` (task 01a17b00 stage 2).

  Join replies for chat and tasks are 190 to 433 KiB of JSON, so the transport
  must be allowed to compress them. Phoenix's default is `compress: false`,
  which makes Bandit decline the extension even when the browser offers it.

  The integration half starts Bandit on an ephemeral loopback port with the
  endpoint as its plug and sends a raw HTTP/1.1 upgrade, so what it checks is
  the 101 response a browser would see.
  """
  use ExUnit.Case, async: true

  test "the /live socket carries compress: true in its websocket opts" do
    {"/live", Phoenix.LiveView.Socket, opts} =
      Enum.find(PlatformWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/live" end) ||
        flunk("no /live socket on PlatformWeb.Endpoint")

    assert Keyword.get(Keyword.fetch!(opts, :websocket), :compress) == true
  end

  describe "handshake against a real Bandit listener" do
    setup do
      pid =
        start_supervised!(
          {Bandit,
           plug: PlatformWeb.Endpoint,
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      %{port: port}
    end

    test "echoes permessage-deflate when the client offers it", %{port: port} do
      {status, headers} =
        upgrade(port, ["Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits"])

      assert status == 101
      extension = Map.get(headers, "sec-websocket-extensions")
      assert extension, "101 carried no Sec-WebSocket-Extensions header (compression declined)"
      assert extension =~ "permessage-deflate"
    end

    test "sends no extension header when the client offers none", %{port: port} do
      {status, headers} = upgrade(port, [])

      assert status == 101
      refute Map.has_key?(headers, "sec-websocket-extensions")
    end
  end

  defp upgrade(port, extra_headers) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    request =
      [
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1",
        "Host: 127.0.0.1:#{port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13"
      ] ++ extra_headers

    :ok = :gen_tcp.send(sock, Enum.join(request, "\r\n") <> "\r\n\r\n")
    response = recv_head(sock, "")
    :gen_tcp.close(sock)

    [status_line | header_lines] = String.split(response, "\r\n", trim: true)
    ["HTTP/1.1", code | _] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(k), String.trim(v)}
      end)

    {String.to_integer(code), headers}
  end

  defp recv_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      recv_head(sock, acc <> data)
    end
  end
end
