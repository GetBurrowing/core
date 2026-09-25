defmodule Platform.Federation.Peers.PinnedAdapter do
  @moduledoc """
  The `Req` adapter behind `Platform.Federation.Peers.Client` (task 01a0d90f
  stage 3). It opens ONE Mint connection per request, to exactly the address
  in the request URL, and closes it afterwards.

  ## Why not Req's default Finch adapter

  The SSRF guard in `Client.check_url/1` resolves the peer's host, checks
  every address, and rewrites the URL to the checked IP. The original name
  must still reach the Host header, TLS SNI and certificate verification,
  which is Mint's `:hostname` connect option. Through Req's Finch adapter
  that option lives in `connect_options`, and Req starts a separate Finch
  pool, registered under `Req.FinchSupervisor` and never stopped, for every
  distinct `connect_options` value. `relationship.propose` lets an
  UNAUTHENTICATED sender choose the host, so each fresh hostname would leave
  a permanent pool behind. One unpooled connection per request has no such
  residue, and federation traffic (one POST per envelope, one descriptor GET
  per handshake) does not need pooling.

  ## Behaviour

    * passive mode (`mode: :passive`), so nothing is delivered to, or read
      from, the calling process's mailbox. The caller may be a request
      process or a GenServer with its own messages;
    * connect timeout `:connect_timeout` (default 5 s);
    * ONE deadline, `:receive_timeout` (default 10 s), for the whole response
      from the moment the request is sent. A peer that trickles bytes cannot
      hold the caller past it;
    * the body is capped at `:max_body` bytes while it is read. Past the cap
      the connection is closed and the response is marked with the
      `:peer_too_large` private key and an empty body;
    * HTTP/1.1 only.

  Errors come back as `{request, exception}`, the Req adapter contract, and
  `Client` turns them into values.
  """

  @connect_timeout 5_000
  @receive_timeout 10_000
  @max_body 64 * 1024

  @doc """
  Returns a Req adapter (a 1-arity function) that connects to the URL's host
  while presenting `hostname` (nil: the URL's own host) for Host, SNI and
  certificate checks.
  """
  @spec adapter(String.t() | nil, keyword()) :: (Req.Request.t() ->
                                                   {Req.Request.t(), term()})
  def adapter(hostname, opts \\ []) do
    fn request -> run(request, hostname, opts) end
  end

  @doc false
  def run(%Req.Request{url: %URI{} = url} = request, hostname, opts) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @connect_timeout)
    receive_timeout = Keyword.get(opts, :receive_timeout, @receive_timeout)
    max_body = Keyword.get(opts, :max_body, @max_body)

    # Mint takes Host, SNI and the certificate name from `:hostname`; without
    # a pinned name that is the URL's own host.
    connect_opts = [
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: connect_timeout],
      hostname: hostname || url.host
    ]

    scheme = if url.scheme == "https", do: :https, else: :http

    case Mint.HTTP.connect(scheme, address(url.host), url.port, connect_opts) do
      {:ok, conn} ->
        send_and_receive(conn, request, receive_timeout, max_body)

      {:error, error} ->
        {request, error}
    end
  end

  defp send_and_receive(conn, request, receive_timeout, max_body) do
    method = request.method |> to_string() |> String.upcase()
    path = path(request.url)

    headers =
      for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}

    case Mint.HTTP.request(conn, method, path, headers, request.body || "") do
      {:ok, conn, ref} ->
        deadline = System.monotonic_time(:millisecond) + receive_timeout
        acc = %{status: nil, headers: [], body: [], size: 0}
        finish(request, receive_loop(conn, ref, deadline, max_body, acc))

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {request, error}
    end
  end

  defp receive_loop(conn, ref, deadline, max_body, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Mint.HTTP.close(conn)
      {:error, %Mint.TransportError{reason: :timeout}}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          case fold(responses, ref, max_body, acc) do
            {:done, acc} ->
              Mint.HTTP.close(conn)
              {:ok, acc}

            {:too_large, acc} ->
              Mint.HTTP.close(conn)
              {:too_large, acc}

            {:cont, acc} ->
              receive_loop(conn, ref, deadline, max_body, acc)
          end

        {:error, conn, error, _responses} ->
          Mint.HTTP.close(conn)
          {:error, error}
      end
    end
  end

  defp fold([], _ref, _max, acc), do: {:cont, acc}

  defp fold([{:status, ref, status} | rest], ref, max, acc),
    do: fold(rest, ref, max, %{acc | status: status})

  defp fold([{:headers, ref, headers} | rest], ref, max, acc),
    do: fold(rest, ref, max, %{acc | headers: acc.headers ++ headers})

  defp fold([{:data, ref, data} | rest], ref, max, acc) do
    size = acc.size + byte_size(data)

    if size > max do
      {:too_large, acc}
    else
      fold(rest, ref, max, %{acc | body: [acc.body | data], size: size})
    end
  end

  defp fold([{:done, ref} | _rest], ref, _max, acc), do: {:done, acc}
  defp fold([_other | rest], ref, max, acc), do: fold(rest, ref, max, acc)

  defp finish(request, {:ok, acc}) do
    {request,
     Req.Response.new(
       status: acc.status,
       headers: acc.headers,
       body: IO.iodata_to_binary(acc.body)
     )}
  end

  defp finish(request, {:too_large, acc}) do
    response =
      [status: acc.status || 200, headers: acc.headers, body: ""]
      |> Req.Response.new()
      |> Req.Response.put_private(:peer_too_large, true)

    {request, response}
  end

  defp finish(request, {:error, error}), do: {request, error}

  # An IP literal (what `Client.check_url/1` pins to) is passed as a tuple so
  # IPv6 works; a name (the rig) is passed through for the OS to resolve.
  defp address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _} -> host
    end
  end

  defp path(%URI{path: path, query: query}) do
    base = if path in [nil, ""], do: "/", else: path
    if query in [nil, ""], do: base, else: base <> "?" <> query
  end
end
