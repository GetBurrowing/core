defmodule Platform.Federation.Peers.Client do
  @moduledoc """
  The only outbound HTTP path for install-to-install federation (task
  01a0d90f stage 3, ADR 0054 sections 1-2): envelope delivery
  (`send_envelope/3`) and descriptor fetch (`fetch_descriptor/1`).

  Every function returns a value and never raises. Peer garbage, timeouts,
  refused connections and non-2xx answers all come back as
  `{:error, reason}`.

  ## Server-side request forgery guard

  `relationship.propose` makes this install fetch
  `<base_url>/.well-known/suite-federation` where `base_url` was chosen by an
  UNAUTHENTICATED sender. Without a guard that is a GET to any URL the sender
  likes, including `127.0.0.1`, the podman network, `core-postgres` and cloud
  metadata at `169.254.169.254`. So EVERY request this module makes first
  passes `check_url/1`:

    * the scheme must be `https`. Plain `http` is accepted only when
      `Config.allow_http?/0`, which is never true in `:prod`;
    * the URL must have a host and no userinfo;
    * the host is resolved (A and AAAA), and if ANY address is loopback,
      private (RFC 1918), CGNAT, link-local (which includes the metadata
      address), unique-local (fc00::/7), multicast, unspecified,
      documentation or otherwise reserved, the request is refused. An
      IPv4-mapped or NAT64 IPv6 address is judged by the IPv4 address it
      embeds;
    * the connection is PINNED to the address that was checked: the request
      goes to the IP, with Mint's `:hostname` option carrying the original
      name for the Host header, SNI and certificate verification. A second
      DNS answer (rebinding) is never consulted. The connection is made by
      `Platform.Federation.Peers.PinnedAdapter`, one unpooled Mint
      connection per request, because Req's Finch adapter would start a
      permanent pool per sender-chosen hostname (see its moduledoc).

  The rig exception: when `Config.allow_http?/0` is true (non-prod only, for
  the two-install rig on the test rig's podman `dev` network, whose peers have
  private addresses), the address checks and pinning are skipped.

  Redirects are never followed (`redirect: false`), so a public host cannot
  bounce the request inward, and a 3xx is an error. Response bodies are
  capped at `max_response_bytes/0` while streaming; a larger body is
  abandoned, not buffered. Bodies are never decompressed (`raw: true`), so
  the cap counts the bytes that are actually kept.

  Timeouts: connect 5 s, receive 10 s. No retries here; retry policy belongs
  to the per-peer connection, `Platform.Federation.Peers.PeerConnection`
  (stage 4). `config :platform, :peer_federation_timeouts, connect: ms,
  receive: ms` overrides either; the per-peer tests shorten the receive
  deadline this way so a slow peer is timed out by the REAL adapter
  deadline and not by a timer of their own.

  ## Tests

  `config :platform, :peer_federation_req_options` is merged into every
  request; `config/test.exs` sets `plug: {Req.Test, #{inspect(__MODULE__)}}`
  so no test reaches the network. `config :platform, :peer_federation_resolver`
  replaces DNS: either a map from host to a list of `:inet` address tuples
  (`config/test.exs` sets `%{}`, so an unstubbed host is `:unresolvable`),
  or a 1-arity function returning `{:ok, [ip_tuple]} | {:error, term}`.
  """

  import Bitwise

  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PinnedAdapter

  @connect_timeout 5_000
  @receive_timeout 10_000
  @max_response_bytes 64 * 1024
  @inbox_path "/federation/v1/inbox"
  @descriptor_path "/.well-known/suite-federation"
  @protocol "suite-federation/1"

  @type target :: %{url: String.t(), hostname: String.t() | nil}

  def connect_timeout, do: timeout(:connect, @connect_timeout)
  def receive_timeout, do: timeout(:receive, @receive_timeout)
  def max_response_bytes, do: @max_response_bytes

  @doc "The inbox URL for a base URL. The path is fixed, never taken from a descriptor."
  @spec inbox_url(String.t()) :: String.t()
  def inbox_url(base_url), do: String.trim_trailing(base_url, "/") <> @inbox_path

  @doc """
  POSTs one envelope to a peer's inbox. `to` is a `%Peer{}` or a base URL.
  Returns `{:ok, %{status: 2xx, body: decoded_or_raw}}` or `{:error, reason}`;
  a non-2xx answer is `{:error, {:http_status, status, peer_reason}}` where
  `peer_reason` is the peer's `"error"` string, if it sent one.
  """
  @spec send_envelope(Peer.t() | String.t(), binary(), [{String.t(), String.t()}]) ::
          {:ok, %{status: pos_integer(), body: term()}} | {:error, term()}
  def send_envelope(%Peer{base_url: base_url}, raw_body, headers),
    do: send_envelope(base_url, raw_body, headers)

  def send_envelope(base_url, raw_body, headers) when is_binary(base_url) do
    case request(:post, inbox_url(base_url), headers: headers, body: raw_body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: decode_json(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, peer_reason(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches and shape-checks a peer's `/.well-known/suite-federation`
  descriptor. Returns the decoded map (string keys) or `{:error, reason}`.
  """
  @spec fetch_descriptor(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_descriptor(base_url) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/") <> @descriptor_path

    case request(:get, url, headers: [{"accept", "application/json"}]) do
      {:ok, %{status: 200, body: body}} ->
        case decode_json(body) do
          %{"protocol" => @protocol, "install_id" => id, "keys" => keys} = desc
          when is_binary(id) and is_list(keys) ->
            {:ok, desc}

          _ ->
            {:error, :invalid_descriptor}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_descriptor(_), do: {:error, :malformed_url}

  @doc """
  The SSRF guard. Returns the pinned target for `url`, or the reason it is
  refused: `:malformed_url`, `:insecure_scheme`, `:unresolvable` or
  `{:forbidden_address, ip_string}`.
  """
  @spec check_url(String.t()) :: {:ok, target()} | {:error, term()}
  def check_url(url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri) do
      if Config.allow_http?() do
        {:ok, %{url: url, hostname: nil}}
      else
        pin(uri)
      end
    end
  end

  def check_url(_), do: {:error, :malformed_url}

  @doc """
  True when `ip` (an `:inet` tuple) is an address federation must never
  contact outside the rig.
  """
  @spec forbidden_address?(:inet.ip_address()) :: boolean()
  def forbidden_address?({a, b, _c, _d} = ip) when a in 0..255 and b in 0..255 do
    forbidden_v4?(ip)
  end

  def forbidden_address?({w1, w2, w3, w4, w5, w6, w7, w8}) do
    cond do
      # ::ffff:a.b.c.d (IPv4-mapped) and 64:ff9b::a.b.c.d (NAT64): judge the
      # embedded IPv4 address.
      {w1, w2, w3, w4, w5, w6} == {0, 0, 0, 0, 0, 0xFFFF} or
          {w1, w2, w3, w4, w5, w6} == {0x64, 0xFF9B, 0, 0, 0, 0} ->
        forbidden_v4?({w7 >>> 8, w7 &&& 0xFF, w8 >>> 8, w8 &&& 0xFF})

      # ::/96 — unspecified, loopback and the deprecated IPv4-compatible block.
      {w1, w2, w3, w4, w5, w6} == {0, 0, 0, 0, 0, 0} ->
        true

      # fc00::/7 unique-local
      (w1 &&& 0xFE00) == 0xFC00 ->
        true

      # fe80::/10 link-local
      (w1 &&& 0xFFC0) == 0xFE80 ->
        true

      # fec0::/10 site-local (deprecated)
      (w1 &&& 0xFFC0) == 0xFEC0 ->
        true

      # ff00::/8 multicast
      (w1 &&& 0xFF00) == 0xFF00 ->
        true

      # 2001:db8::/32 documentation
      w1 == 0x2001 and w2 == 0x0DB8 ->
        true

      # 100::/64 discard
      w1 == 0x0100 and w2 == 0 and w3 == 0 and w4 == 0 ->
        true

      true ->
        false
    end
  end

  def forbidden_address?(_), do: true

  # ── private ────────────────────────────────────────────────────────────

  defp forbidden_v4?({a, b, c, _d}) do
    cond do
      a == 0 -> true
      a == 10 -> true
      a == 100 and (b &&& 0xC0) == 64 -> true
      a == 127 -> true
      a == 169 and b == 254 -> true
      a == 172 and (b &&& 0xF0) == 16 -> true
      a == 192 and b == 0 and c == 0 -> true
      a == 192 and b == 0 and c == 2 -> true
      a == 192 and b == 168 -> true
      a == 198 and b in [18, 19] -> true
      a == 198 and b == 51 and c == 100 -> true
      a == 203 and b == 0 and c == 113 -> true
      a >= 224 -> true
      true -> false
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{host: host, userinfo: nil} = uri} when is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :malformed_url}
    end
  end

  defp check_scheme(%URI{scheme: "https"}), do: :ok

  defp check_scheme(%URI{scheme: "http"}) do
    if Config.allow_http?(), do: :ok, else: {:error, :insecure_scheme}
  end

  defp check_scheme(_), do: {:error, :insecure_scheme}

  defp pin(%URI{host: host} = uri) do
    with {:ok, addresses} <- resolve(host) do
      case Enum.find(addresses, &forbidden_address?/1) do
        nil ->
          [ip | _] = addresses
          pinned = %URI{uri | host: ip |> :inet.ntoa() |> to_string()}
          {:ok, %{url: URI.to_string(pinned), hostname: host}}

        bad ->
          {:error, {:forbidden_address, bad |> :inet.ntoa() |> to_string()}}
      end
    end
  end

  defp resolve(host) do
    literal =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.to_charlist()
      |> :inet.parse_strict_address()

    result =
      case {literal, resolver()} do
        {{:ok, ip}, _} -> {:ok, [ip]}
        {_, fun} when is_function(fun, 1) -> fun.(host)
        {_, %{} = static} -> {:ok, Map.get(static, host, [])}
      end

    case result do
      {:ok, [_ | _] = ips} -> {:ok, ips}
      _ -> {:error, :unresolvable}
    end
  end

  defp resolver do
    Application.get_env(:platform, :peer_federation_resolver, &dns_resolve/1)
  end

  defp dns_resolve(host) do
    name = String.to_charlist(host)

    ips =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(name, family) do
          {:ok, list} -> list
          {:error, _} -> []
        end
      end)

    {:ok, ips}
  end

  defp request(method, url, opts) do
    with {:ok, %{url: target_url, hostname: hostname}} <- check_url(url) do
      req_opts =
        [
          method: method,
          url: target_url,
          headers: Keyword.get(opts, :headers, []),
          redirect: false,
          retry: false,
          # Response bodies are never inflated. The byte cap counts the bytes
          # received, so inflating after it would let a 64 KB gzip body grow
          # to megabytes. Two things hold this today, and either alone
          # suffices: `into:` below (Req 0.5.17's decompress_body/1 skips any
          # request with `into` set) and `raw: true`. `raw` is the one that
          # still holds if `into` is ever dropped; the mutation that removes
          # only `raw` is therefore equivalent, and survives, by design.
          # `compressed: false` sends no accept-encoding, so a compliant peer
          # never compresses a body this client could not then decode.
          raw: true,
          compressed: false,
          adapter:
            PinnedAdapter.adapter(hostname,
              connect_timeout: connect_timeout(),
              receive_timeout: receive_timeout(),
              max_body: @max_response_bytes
            ),
          # Only the `Req.Test` plug path (tests) streams through `:into`;
          # PinnedAdapter applies the same cap itself.
          into: &collect_capped/2
        ]
        |> maybe_body(Keyword.get(opts, :body))
        |> Keyword.merge(Application.get_env(:platform, :peer_federation_req_options, []))

      try do
        case Req.request(req_opts) do
          {:ok, %Req.Response{} = resp} ->
            if Req.Response.get_private(resp, :peer_too_large),
              do: {:error, :response_too_large},
              else: {:ok, %{status: resp.status, body: resp.body}}

          {:error, %{reason: reason}} ->
            {:error, {:transport, reason}}

          {:error, _other} ->
            {:error, :transport}
        end
      rescue
        _ -> {:error, :transport}
      catch
        _, _ -> {:error, :transport}
      end
    end
  end

  defp timeout(key, default) do
    case Application.get_env(:platform, :peer_federation_timeouts, []) |> Keyword.get(key) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default
    end
  end

  defp maybe_body(opts, nil), do: opts
  defp maybe_body(opts, body), do: Keyword.put(opts, :body, body)

  defp collect_capped({:data, data}, {req, resp}) do
    body = if is_binary(resp.body), do: resp.body <> data, else: data

    if byte_size(body) > @max_response_bytes do
      {:halt,
       {req, resp |> Req.Response.put_private(:peer_too_large, true) |> Map.put(:body, "")}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_json(body), do: body

  defp peer_reason(body) do
    case decode_json(body) do
      %{"error" => reason} when is_binary(reason) -> String.slice(reason, 0, 64)
      _ -> nil
    end
  end
end
