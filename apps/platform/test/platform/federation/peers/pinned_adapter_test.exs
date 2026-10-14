defmodule Platform.Federation.Peers.PinnedAdapterTest.PeerPlug do
  @moduledoc """
  A real HTTP endpoint for `PinnedAdapterTest`. `Req.Test` stubs run
  in-process and never open a socket, so a timeout or size-cap assertion
  made against a stub can pass while the adapter does nothing; these run
  over a live loopback socket.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/echo-host"} = conn, _opts) do
    send_resp(conn, 200, conn |> get_req_header("host") |> List.first() |> to_string())
  end

  def call(%{request_path: "/slow"} = conn, _opts) do
    Process.sleep(2_000)
    send_resp(conn, 200, "late")
  end

  def call(%{request_path: "/trickle"} = conn, _opts) do
    conn = send_chunked(conn, 200)

    # 200 chunks 50 ms apart: the whole body takes 10 s, so no host is slow
    # enough for it to complete inside the test's 300 ms deadline.
    Enum.reduce_while(1..200, conn, fn _, conn ->
      Process.sleep(50)

      case chunk(conn, "x") do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  def call(%{request_path: "/big"} = conn, _opts) do
    send_resp(conn, 200, :binary.copy("b", 100 * 1024))
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end

defmodule Platform.Federation.Peers.PinnedAdapterTest do
  @moduledoc """
  Task 01a0d90f stage 3: the unpooled, passive-mode Mint adapter behind the
  federation client, over a real socket.
  """

  use ExUnit.Case, async: true

  alias Platform.Federation.Peers.PinnedAdapter

  setup do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: Platform.Federation.Peers.PinnedAdapterTest.PeerPlug,
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    %{base: "http://127.0.0.1:#{port}"}
  end

  defp get(url, hostname, opts \\ []) do
    Req.request(
      url: url,
      retry: false,
      # as in Client: no accept-encoding, no decompression, so the cap is on
      # the bytes kept
      raw: true,
      compressed: false,
      adapter: PinnedAdapter.adapter(hostname, opts)
    )
  end

  test "connects to the URL's address while presenting the pinned hostname", %{base: base} do
    assert {:ok, %Req.Response{status: 200, body: host}} =
             get(base <> "/echo-host", "peer.example.test")

    assert host =~ "peer.example.test"
    refute host =~ "127.0.0.1"
  end

  test "the receive deadline holds against a server that never answers in time", %{base: base} do
    # The error kind is the evidence: without the deadline the server's 2 s
    # reply arrives and this is {:ok, "late"}. No wall-clock bound, which
    # measured the host's load, not the adapter (task 01a13aac).
    assert {:error, %Mint.TransportError{reason: :timeout}} =
             get(base <> "/slow", nil, receive_timeout: 200)
  end

  test "ONE deadline for the whole response: a trickling server cannot extend it", %{
    base: base
  } do
    # every chunk arrives well inside 300 ms of the last one; the whole body
    # takes 10 s. A per-read timeout would never fire here, so the body would
    # complete and this would be {:ok, _}: the error kind is the evidence.
    assert {:error, %Mint.TransportError{reason: :timeout}} =
             get(base <> "/trickle", nil, receive_timeout: 300)
  end

  test "a body over the cap is abandoned and flagged", %{base: base} do
    assert {:ok, %Req.Response{body: "", private: private}} =
             get(base <> "/big", nil, max_body: 64 * 1024)

    assert private[:peer_too_large] == true

    # control: the same body under a larger cap is read whole
    assert {:ok, %Req.Response{body: body}} = get(base <> "/big", nil, max_body: 200 * 1024)
    assert byte_size(body) == 100 * 1024
  end

  test "passive mode leaves the caller's mailbox alone", %{base: base} do
    send(self(), :unrelated_message)

    assert {:ok, %Req.Response{status: 200}} = get(base <> "/echo-host", nil)

    assert_received :unrelated_message
    refute_received {:tcp, _, _}
    refute_received {:tcp_closed, _}
  end

  test "a refused connection is an error value" do
    port = free_port()

    assert {:error, %Mint.TransportError{reason: :econnrefused}} =
             get("http://127.0.0.1:#{port}/", nil)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
