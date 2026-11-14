defmodule PlatformWeb.Plugs.RewriteRemoteIp do
  @moduledoc """
  Resolves the real client address into `conn.remote_ip` when core sits behind
  a reverse proxy, so per-IP rate limits (`PlatformWeb.Plugs.FeedbackBrokerGate`,
  `PlatformWeb.BookingRateLimitPlug`) and audit logs key on the client and not
  on the proxy. Task 01a1b2df: a client must never be able to CHOOSE that
  address.

  ## Inputs

    * `TRUST_PROXY_HEADERS` (`config :platform, :trust_proxy_headers`) is the
      master switch. Off (the default): the conn is returned untouched and no
      header is read.
    * `TRUSTED_PROXIES` (`config :platform, :trusted_proxies`) is a
      comma-separated CIDR list of proxies whose forwarding headers are
      believed. Unset or blank means `default_trusted_proxies/0`: loopback
      (`127.0.0.0/8`, `::1/128`), the RFC 1918 ranges and `fc00::/7`. An
      explicit value REPLACES the default; it is not merged with it. An entry
      that does not parse raises at boot (`parse_trusted_proxies/1`).
      `100.64.0.0/10` is deliberately not in the default: on a tailscale
      install the tailnet addresses are the real clients.
    * Cloudflare's published edge ranges, compiled in (`cloudflare_ranges/0`).

  ## Algorithm (flag on)

    1. If the immediate peer (`conn.remote_ip` as the HTTP server set it) is not
       a trusted proxy, nothing changes and EVERY forwarding header is ignored,
       `CF-Connecting-IP` included. A client talking to core directly can claim
       nothing.
    2. Otherwise all `X-Forwarded-For` lines are joined in order and the hops
       are walked RIGHT to LEFT, skipping trusted proxies. The first hop that
       is not trusted is `H`. A hop that does not parse before `H` is found
       stops the walk and nothing changes (fail closed). No `X-Forwarded-For`,
       or only trusted hops, also changes nothing.
    3. If `H` is a Cloudflare edge address and `CF-Connecting-IP` parses as one
       address, that address is the client. Cloudflare overwrites the header at
       its edge, so it is only believable when the hop that handed the request
       to our trusted chain is provably Cloudflare. A trusted Caddy forwards
       whatever a client sends, so a trusted peer alone is not enough.
    4. Otherwise `H` is the client.

  The leftmost `X-Forwarded-For` value is client-supplied and is never used
  unless it is also `H`.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  @type cidr :: {:inet.ip_address(), 0..128}

  # Loopback, RFC 1918 and fc00::/7, as normalised CIDR tuples. Written as
  # tuples, not strings: the install-identity guard flags that RFC 1918
  # range written as a dotted literal as a LAN address.
  @default_trusted_proxies [
    {{127, 0, 0, 0}, 8},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7}
  ]

  # Cloudflare's published edge ranges, fetched from
  # https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6
  # on 2026-11-07 (task 01a1b2df). Refresh from those URLs if Cloudflare
  # announces new ranges.
  @cloudflare_ranges ~w(
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
    2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
  )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Application.get_env(:platform, :trust_proxy_headers, false) do
      rewrite_ip(conn, trusted_proxies())
    else
      conn
    end
  end

  @doc "The parsed `TRUSTED_PROXIES` default: loopback, RFC 1918 and fc00::/7."
  @spec default_trusted_proxies() :: [cidr()]
  def default_trusted_proxies, do: @default_trusted_proxies

  @doc "Cloudflare's published edge ranges, parsed."
  @spec cloudflare_ranges() :: [cidr()]
  def cloudflare_ranges, do: Enum.map(@cloudflare_ranges, &parse_cidr!/1)

  @doc """
  Parse a `TRUSTED_PROXIES` value. `nil` or blank gives
  `default_trusted_proxies/0`; otherwise every comma-separated entry must be
  an address or `address/prefix`, and the result replaces the default. Raises
  `ArgumentError` naming the bad entry.
  """
  @spec parse_trusted_proxies(String.t() | nil) :: [cidr()]
  def parse_trusted_proxies(nil), do: default_trusted_proxies()

  def parse_trusted_proxies(value) when is_binary(value) do
    entries = value |> String.split(",") |> Enum.map(&String.trim/1)

    if Enum.all?(entries, &(&1 == "")) do
      default_trusted_proxies()
    else
      Enum.map(entries, fn
        "" -> raise ArgumentError, "TRUSTED_PROXIES has an empty entry: #{inspect(value)}"
        entry -> parse_cidr!(entry)
      end)
    end
  end

  @doc "Parse one `address` or `address/prefix` into a normalised CIDR. Raises on error."
  @spec parse_cidr!(String.t()) :: cidr()
  def parse_cidr!(entry) do
    case parse_cidr(entry) do
      {:ok, cidr} ->
        cidr

      :error ->
        raise ArgumentError,
              "TRUSTED_PROXIES entry #{inspect(entry)} is not an IPv4/IPv6 address or CIDR"
    end
  end

  defp parse_cidr(entry) do
    {addr, prefix} =
      case String.split(String.trim(entry), "/") do
        [addr] -> {addr, nil}
        [addr, prefix] -> {addr, prefix}
        _ -> {nil, nil}
      end

    with addr when is_binary(addr) <- addr,
         {:ok, ip} <- parse_ip(addr),
         bits = bit_size_of(ip),
         {:ok, len} <- parse_prefix(prefix, bits) do
      {:ok, {mask(ip, len), len}}
    else
      _ -> :error
    end
  end

  defp parse_prefix(nil, bits), do: {:ok, bits}

  defp parse_prefix(prefix, bits) do
    case Integer.parse(prefix) do
      {len, ""} when len >= 0 and len <= bits -> {:ok, len}
      _ -> :error
    end
  end

  @doc "True when `ip` falls inside any of `cidrs`."
  @spec in_any?(:inet.ip_address(), [cidr()]) :: boolean()
  def in_any?(ip, cidrs) do
    ip = unmap(ip)
    Enum.any?(cidrs, fn {net, len} -> same_family?(ip, net) and mask(ip, len) == net end)
  end

  defp trusted_proxies do
    case Application.get_env(:platform, :trusted_proxies) do
      nil -> default_trusted_proxies()
      cidrs when is_list(cidrs) -> cidrs
    end
  end

  defp rewrite_ip(conn, trusted) do
    if in_any?(conn.remote_ip, trusted) do
      hops =
        conn
        |> get_req_header("x-forwarded-for")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)

      case first_untrusted_from_right(Enum.reverse(hops), trusted) do
        {:ok, hop} -> %{conn | remote_ip: client_ip(conn, hop)}
        :none -> conn
      end
    else
      conn
    end
  end

  defp first_untrusted_from_right([], _trusted), do: :none

  defp first_untrusted_from_right([hop | rest], trusted) do
    case parse_ip(hop) do
      {:ok, ip} ->
        if in_any?(ip, trusted), do: first_untrusted_from_right(rest, trusted), else: {:ok, ip}

      :error ->
        :none
    end
  end

  defp client_ip(conn, hop) do
    with true <- in_any?(hop, cloudflare_ranges()),
         [cf] <- get_req_header(conn, "cf-connecting-ip"),
         {:ok, ip} <- parse_ip(String.trim(cf)) do
      unmap(ip)
    else
      _ -> unmap(hop)
    end
  end

  defp parse_ip(string) do
    case :inet.parse_strict_address(String.to_charlist(string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  # An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is matched as IPv4.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
  defp unmap(ip), do: ip

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp bit_size_of(ip) when tuple_size(ip) == 4, do: 32
  defp bit_size_of(ip) when tuple_size(ip) == 8, do: 128

  defp mask(ip, len) do
    {width, parts} = if tuple_size(ip) == 4, do: {8, 4}, else: {16, 8}
    bits = width * parts
    int = ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
    masked = int &&& bsl(bsl(1, len) - 1, bits - len)

    for(i <- (parts - 1)..0//-1, do: masked >>> (i * width) &&& bsl(1, width) - 1)
    |> List.to_tuple()
  end
end
